// Signature help: resolve the call the caret sits in and report the callee's
// signature line with the active parameter's span within it.
package odin

import "core:os"
import "core:strings"
import "core:sync"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// Resolves the call the caret sits inside to its procedure declaration and fills
// `res.signature` with that proc's signature line plus the byte range, within
// the line, of the parameter the caret is currently on. The call's function is
// resolved the same three ways goto is — same-file, package-qualified
// (`pkg.fn(...)`) and cross-file workspace scan — so signature help follows the
// same reach. Only procedures produce a result; a call of a non-proc is ignored.
@(private)
signature_help :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    call, ok := enclosing_call(root, req.source, req.offset)
    if !ok {
        return
    }
    fn := ts.node_child_by_field_name(call, "function")
    if ts.node_is_null(fn) {
        return
    }

    src, _, d, found := resolve_call_target(e, parser, root, req, call, fn)
    if !found || d.kind != "function" {
        return
    }

    label := signature_text(src, d) // cloned into context.allocator (the Manager's)
    active := call_active_param(call, req.offset)
    astart, aend := active_param_span(label, active)
    res.signature = lang.Signature_Info {
        label        = label,
        active_start = astart,
        active_end   = aend,
    }
    res.ok = true
}

// Nearest call_expression enclosing `offset`, so a caret anywhere inside a call's
// argument list (including the whitespace between arguments) resolves to that
// call. The innermost call wins, so `outer(inner(|))` picks `inner`.
@(private)
enclosing_call :: proc(root: ts.Node, source: string, offset: int) -> (ts.Node, bool) {
    off := u32(clamp(offset, 0, len(source)))
    n := ts.node_named_descendant_for_byte_range(root, off, off)
    for !ts.node_is_null(n) {
        if string(ts.node_type(n)) == "call_expression" {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// Index of the argument the caret is on: the count of top-level commas in the
// call's parentheses before `offset`. Commas are direct `,` children of the
// call_expression, so a nested call's commas (buried in an argument subtree)
// never leak in. A caret before the first `(` (e.g. on the function name) is 0.
@(private)
call_active_param :: proc(call: ts.Node, offset: int) -> int {
    active := 0
    seen_open := false
    for i in 0 ..< ts.node_child_count(call) {
        c := ts.node_child(call, i)
        switch string(ts.node_type(c)) {
        case "(":
            seen_open = true
        case ")":
            return active
        case ",":
            if seen_open && int(ts.node_start_byte(c)) < offset {
                active += 1
            } else if seen_open {
                return active
            }
        }
    }
    return active
}

// Resolves a call's function operand to its procedure declaration, returning the
// source it lives in and the Def within it. Handles `pkg.fn(...)` (the call node
// nests under a member_expression carrying the package operand) by following the
// import into that package's directory; otherwise the bare function name is
// resolved same-file first, then across the workspace. The returned source is the
// worker's temp-allocated file text (job-lifetime), so the Def's slices stay
// valid after the parse tree is freed.
@(private)
resolve_call_target :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    call, fn: ts.Node,
) -> (source: string, path: string, d: Def, ok: bool) {
    // `pkg.fn(args)`: the call is the second child of a member_expression whose
    // first child is the package operand. Resolve `fn` in that package's dir.
    if parent := ts.node_parent(call); !ts.node_is_null(parent) &&
        string(ts.node_type(parent)) == "member_expression" {
        pkg_node := ts.node_named_child(parent, 0)
        if same_node(ts.node_named_child(parent, 1), call) && is_identifier(pkg_node) && is_identifier(fn) {
            pkg := ts.node_text(pkg_node, req.source)
            name := ts.node_text(fn, req.source)
            if raw, ok := import_path(root, req.source, pkg); ok {
                if dir, dok := package_dir(e, raw, req.path, req.workspace); dok {
                    return find_proc_in_dir(e, parser, dir, name, req.path)
                }
            }
            return "", "", {}, false
        }
    }

    if !is_identifier(fn) {
        return "", "", {}, false
    }
    name := ts.node_text(fn, req.source)

    // Same file: a top-level procedure of this name (locals of the same name are
    // not callables we can sign, so require the "function" kind).
    defs := collect_defs(e, root, req.source)
    if d, ok := resolve_local(defs[:], name, int(ts.node_start_byte(fn))); ok && d.kind == "function" {
        return req.source, req.path, d, true
    }

    // Workspace: the index points at the file declaring the procedure; re-parse
    // just that one for its Def (the caller needs the live source and decl range).
    if req.workspace != "" {
        path, ok := "", false
        sync.lock(&e.index.mutex)
        index_sync(e, parser, req)
        if p, found := index_first_path(e, name, req.path, "function"); found {
            path = strings.clone(p, context.temp_allocator)
            ok = true
        }
        sync.unlock(&e.index.mutex)
        if ok {
            return first_proc_in_file(e, parser, path, name)
        }
    }
    return "", "", {}, false
}

// First top-level procedure named `name` in `path`, with the file's source and
// path (so the Def stays valid past the parse, and a type its signature names
// keeps a file whose imports qualify it). Reused by the package and workspace
// scans.
@(private)
first_proc_in_file :: proc(
    e: ^Engine,
    parser: ts.Parser,
    path, name: string,
) -> (source: string, file: string, d: Def, ok: bool) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return "", "", {}, false
    }
    src := string(data)

    tree := ts.parser_parse_string(parser, src)
    if tree == nil {
        return "", "", {}, false
    }
    defer ts.tree_delete(tree)

    defs := collect_defs(e, ts.tree_root_node(tree), src)
    for def in defs {
        if def.top_level && def.kind == "function" && def.name == name {
            return src, path, def, true
        }
    }
    return "", "", {}, false
}

// First top-level procedure named `name` in one package directory (all its .odin
// files, non-recursively — an Odin package is a flat directory). `skip` is the
// requesting file's path, left out so the live buffer's stale on-disk copy loses.
@(private)
find_proc_in_dir :: proc(
    e: ^Engine,
    parser: ts.Parser,
    dir, name, skip: string,
) -> (source: string, path: string, d: Def, ok: bool) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return "", "", {}, false
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return "", "", {}, false
    }

    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == skip {
            continue
        }
        if src, file, def, found := first_proc_in_file(e, parser, info.fullpath, name); found {
            return src, file, def, found
        }
    }
    return "", "", {}, false
}
