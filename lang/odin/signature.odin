// Signature help: resolve the call the caret sits in and report the callee's
// signature line with the active parameter's span within it. A call of a
// procedure group (`sizes :: proc{sized_a, sized_b}`) reports one signature per
// member, since the group itself declares no parameters to show.
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

    src, path, d, found := resolve_call_target(e, parser, root, req, call, fn)
    if !found || d.kind != "function" {
        return
    }

    active := call_active_param(call, req.offset)
    entries := make([dynamic]lang.Signature_Entry, context.allocator)

    // A procedure group stands in for its members: its own declaration names no
    // parameters, so signing the group would show a call's arguments against an
    // empty list. The members are what the call actually reaches.
    if d.overload {
        overload_entries(e, parser, root, req, src, path, d, active, &entries)
    }
    // An ordinary procedure — or a group none of whose members could be found
    // (every one written qualified, or declared outside its package). The group's
    // own declaration is then still the most informative thing there is.
    if len(entries) == 0 {
        append(&entries, signature_entry(signature_text(src, d), active))
    }

    res.signature = lang.Signature_Info {
        entries = entries,
        active  = pick_overload(entries[:], call_arg_count(call, req.source), active),
    }
    res.ok = true
}

// Pairs an already-owned label with the span of its `active`-th parameter. The
// label is moved, not cloned: signature_text already allocated it in the
// Manager's allocator, where job_free expects to find it.
@(private)
signature_entry :: proc(label: string, active: int) -> lang.Signature_Entry {
    start, end := active_param_span(label, active)
    return lang.Signature_Entry{label = label, active_start = start, active_end = end}
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

// How many arguments the call is written with: the top-level commas in its
// parentheses plus one, or 0 for an empty `()`. Like call_active_param it reads
// only the `,` children of the call_expression, so a nested call's own arguments
// never leak in. This counts what is *written*, a trailing empty argument
// included (`f(1,|)` is two) — mid-call that is exactly the arity the user is
// heading for, which is what picks the overload.
@(private)
call_arg_count :: proc(call: ts.Node, source: string) -> int {
    open, close := -1, -1
    commas := 0
    for i in 0 ..< ts.node_child_count(call) {
        c := ts.node_child(call, i)
        switch string(ts.node_type(c)) {
        case "(":
            if open < 0 {
                open = int(ts.node_end_byte(c))
            }
        case ")":
            if close < 0 {
                close = int(ts.node_start_byte(c))
            }
        case ",":
            if open >= 0 && close < 0 {
                commas += 1
            }
        }
    }
    if open < 0 || close < open || close > len(source) {
        return 0
    }
    if strings.trim_space(source[open:close]) == "" {
        return 0
    }
    return commas + 1
}

// The parameters a signature label declares: how many there are, how many must
// be written (a defaulted one may be left out), and whether the last is variadic
// (`args: ..int`) and so absorbs any number of arguments past the ones before
// it. Reads the first parenthesized group — the parameter list; a `-> (a, b)`
// result tuple comes after it and is never reached — and splits it on its
// top-level commas, so a comma inside a nested type (`b: proc(x: int)`,
// `c: [dynamic]int`) doesn't split a parameter.
@(private)
param_arity :: proc(label: string) -> (count, required: int, variadic: bool) {
    inner, ok := after_paren_group(label, want_inner = true)
    if !ok || strings.trim_space(inner) == "" {
        return 0, 0, false // an empty list is 0 parameters, not 1
    }
    parts := split_top_level(inner)
    count = len(parts)
    variadic = strings.contains(parts[count - 1], "..")
    for part, i in parts {
        // A default (`loc := #caller_location`) and the variadic tail are both
        // optional, so neither is an argument the call has to write.
        if strings.contains(part, "=") || (variadic && i == count - 1) {
            continue
        }
        required += 1
    }
    return
}

// Whether a call of `argc` arguments fits a signature label's parameter list:
// every required parameter written, and no more than the list takes unless its
// tail is variadic.
@(private)
arity_takes :: proc(label: string, argc: int) -> bool {
    count, required, variadic := param_arity(label)
    return argc >= required && (variadic || argc <= count)
}

// The entry a call best matches. Arity is the strong signal, and the one that
// actually separates a group's members (`proc(int)` from `proc(int, int)`). When
// nothing fits — a call still being typed, or a group whose members differ by
// parameter *type* rather than count, which this does not read — the first entry
// with a parameter in the slot the caret sits on wins, and failing that the
// first entry: a call in progress must still show something.
@(private)
pick_overload :: proc(entries: []lang.Signature_Entry, argc, active: int) -> int {
    if len(entries) <= 1 {
        return 0
    }
    for entry, i in entries {
        if arity_takes(entry.label, argc) {
            return i
        }
    }
    for entry, i in entries {
        if count, _, variadic := param_arity(entry.label); variadic || active < count {
            return i
        }
    }
    return 0
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

    // Package, then workspace (see index_package_dir): the index points at the
    // file declaring the procedure; re-parse just that one for its Def (the
    // caller needs the live source and decl range).
    if req.workspace != "" {
        path, ok := "", false
        sync.lock(&e.index.mutex)
        index_sync(e, parser, req)
        same_package := true
        p, found := index_first_path(e, name, req.path, "function", index_package_dir(e, req.path), true)
        if !found {
            p, found = index_first_path(e, name, req.path, "function", "", false)
            same_package = false
        }
        if found {
            path = strings.clone(p, context.temp_allocator)
            ok = true
        }
        sync.unlock(&e.index.mutex)
        if ok {
            return first_proc_in_file(e, parser, path, name, same_package)
        }
    }

    // The implicit scope: `append(...)`, `make(...)`, `len(...)` are declared by
    // the toolchain rather than by anything here, and the cache names the one
    // file to read. Everything downstream then treats them as any other callee —
    // a group signs its members, an argument's expected type reads its parameter.
    if sym, bok := builtin_symbol(e, parser, name); bok {
        return first_proc_in_file(e, parser, sym.path, name, false)
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
    same_package: bool,
) -> (source: string, file: string, d: Def, ok: bool) {
    src, sok := source_read(path)
    if !sok {
        return "", "", {}, false
    }

    tree := ts.parser_parse_string(parser, src)
    if tree == nil {
        return "", "", {}, false
    }
    defer ts.tree_delete(tree)

    defs := collect_defs(e, ts.tree_root_node(tree), src)
    for def in defs {
        if def.top_level && def.kind == "function" && def.name == name &&
           def_reaches(def.visibility, same_package) {
            return src, path, def, true
        }
    }
    return "", "", {}, false
}

// First top-level procedure named `name` in one package directory (all its .odin
// files, non-recursively — an Odin package is a flat directory). `skip` is the
// requesting file's path, left out so the live buffer's stale on-disk copy loses.
// Reached through a qualifier (`pkg.f(`), so `dir` is another package and only
// its public procedures are in reach.
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
        if src, file, def, found := first_proc_in_file(e, parser, info.fullpath, name, false); found {
            return src, file, def, found
        }
    }
    return "", "", {}, false
}

// Expands a procedure group into one entry per member. The members are located
// package-locally (see overload_sites); one that resolves to nothing is left out,
// so a group written entirely qualified produces no entries at all and the caller
// falls back to the group's own declaration.
@(private)
overload_entries :: proc(
    e: ^Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^lang.Request,
    group_src, group_path: string,
    d: Def,
    active: int,
    out: ^[dynamic]lang.Signature_Entry,
) {
    for site in overload_sites(e, parser, root, req, group_src, group_path, d) {
        if site.label != "" {
            append(out, signature_entry(site.label, active))
        }
    }
}
