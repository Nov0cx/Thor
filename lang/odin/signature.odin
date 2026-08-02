// Signature help: resolve the call the caret sits in and report the callee's
// signature line with the active parameter's span within it. A call of a
// procedure group (`sizes :: proc{sized_a, sized_b}`) reports one signature per
// member, since the group itself declares no parameters to show.
package odin

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// How many members of a procedure group are expanded into signatures. A cap
// rather than a limit anyone is expected to reach: the popup is drawn one line
// per entry above the caret, so a pathological group would otherwise cover the
// buffer it is meant to annotate.
@(private)
OVERLOAD_LIMIT :: 32

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

// The parameter count of a signature label, and whether its last parameter is
// variadic (`args: ..int`) and so absorbs any number of arguments past the ones
// before it. Reads the first parenthesized group — the parameter list; a
// `-> (a, b)` result tuple comes after it and is never reached — tracking
// bracket depth so a comma inside a nested type (`b: proc(x: int)`,
// `c: [dynamic]int`) doesn't split a parameter, the same way active_param_span
// does.
@(private)
param_arity :: proc(label: string) -> (count: int, variadic: bool) {
    open := strings.index_byte(label, '(')
    if open < 0 {
        return 0, false
    }
    depth := 0
    commas := 0
    empty := true // an empty list is 0 parameters, not 1
    for i := open; i < len(label); i += 1 {
        switch label[i] {
        case '(', '[', '{':
            depth += 1
            continue
        case ')', ']', '}':
            depth -= 1
            if depth == 0 {
                return empty ? 0 : commas + 1, variadic
            }
            continue
        case ' ', '\t':
            continue
        case ',':
            if depth == 1 {
                commas += 1
            }
        case '.':
            if depth == 1 && i + 1 < len(label) && label[i + 1] == '.' {
                variadic = true
            }
        }
        empty = false
    }
    return 0, false
}

// The entry a call best matches. An exact arity match is the strong signal, and
// the one that actually separates a group's members (`proc(int)` from
// `proc(int, int)`); a variadic tail absorbs any surplus. When nothing matches
// exactly — a call still being typed, or a group whose members differ by
// parameter *type* rather than count, which this does not read — the first entry
// with a parameter in the slot the caret sits on wins, and failing that the
// first entry: a call in progress must still show something.
@(private)
pick_overload :: proc(entries: []lang.Signature_Entry, argc, active: int) -> int {
    if len(entries) <= 1 {
        return 0
    }
    for entry, i in entries {
        count, variadic := param_arity(entry.label)
        if count == argc || (variadic && argc >= count - 1) {
            return i
        }
    }
    for entry, i in entries {
        if count, variadic := param_arity(entry.label); variadic || active < count {
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

// ---------------------------------------------------------------------------
// Procedure groups
// ---------------------------------------------------------------------------

// Expands a procedure group into one entry per member. A group's members are
// ordinary procedures declared in the group's own package, so they are looked up
// there: first in the live buffer when it belongs to that package (its on-disk
// copy may be stale, and a member being edited must still answer), then across
// the package directory. The directory pass matches *every* outstanding member
// against each file it parses rather than restarting per member — a group of
// five in a twenty-file package sits on the per-keystroke path, and one parse per
// member per file would be twenty-five of them.
//
// A member that resolves to nothing is left out; a member written qualified
// (`proc{foo, other.bar}`) is one of those, since the lookup here is
// package-local.
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
    members := overload_members(parser, group_src, d)
    if len(members) == 0 {
        return
    }
    labels := make([]string, len(members), context.temp_allocator)

    dir := filepath.dir(group_path) // a slice of group_path, no allocation
    if dir == filepath.dir(req.path) {
        defs := collect_defs(e, root, req.source)
        fill_member_labels(defs[:], req.source, members, labels)
    }
    if labels_missing(labels) {
        scan_package_members(e, parser, req, dir, members, labels)
    }

    for label in labels {
        if label != "" {
            append(out, signature_entry(label, active))
        }
    }
}

// The member names of a procedure group, read off a re-parse of its declaration
// text. A re-parse rather than a walk of the original tree because there may not
// be one: a cross-file callee's tree is freed by first_proc_in_file before this
// runs, and only its source survives. A textual split of the braces would have to
// model comments and line breaks the member list is allowed to carry, which the
// grammar already does. The snippet is prefixed with a package clause so it
// parses as the file it came from; the names slice into that prefixed copy, which
// lives on the worker's temp allocator for the rest of the job.
@(private)
overload_members :: proc(parser: ts.Parser, source: string, d: Def) -> []string {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.decl_end, start, len(source))
    text := strings.concatenate({"package p\n", source[start:end]}, context.temp_allocator)

    tree := ts.parser_parse_string(parser, text)
    if tree == nil {
        return nil
    }
    defer ts.tree_delete(tree)

    group, found := find_node_type(ts.tree_root_node(tree), "overloaded_procedure_declaration")
    if !found {
        return nil
    }

    names := make([dynamic]string, context.temp_allocator)
    named := false // the group's own name is the first identifier, past any @(...)
    for i in 0 ..< ts.node_named_child_count(group) {
        c := ts.node_named_child(group, i)
        if !is_identifier(c) {
            continue // an attributes node before the name, or a qualified member
        }
        if !named {
            named = true
            continue
        }
        append(&names, ts.node_text(c, text))
        if len(names) >= OVERLOAD_LIMIT {
            break
        }
    }
    return names[:]
}

// First node of type `want` in a pre-order walk from `n`.
@(private = "file")
find_node_type :: proc(n: ts.Node, want: string) -> (ts.Node, bool) {
    if ts.node_is_null(n) {
        return {}, false
    }
    if string(ts.node_type(n)) == want {
        return n, true
    }
    for i in 0 ..< ts.node_child_count(n) {
        if found, ok := find_node_type(ts.node_child(n, i), want); ok {
            return found, ok
        }
    }
    return {}, false
}

// Fills the still-empty slots of `labels` from the top-level procedures of
// `defs`, matched by name. A slot already filled is left alone, so the first
// source consulted — the live buffer — wins over the stale copy on disk.
@(private)
fill_member_labels :: proc(defs: []Def, source: string, members: []string, labels: []string) {
    for member, i in members {
        if labels[i] != "" {
            continue
        }
        for d in defs {
            if d.top_level && d.kind == "function" && d.name == member {
                labels[i] = signature_text(source, d) // cloned into the Manager's allocator
                break
            }
        }
    }
}

// Fills the remaining members from the package directory `dir`, parsing each
// .odin file once and matching every outstanding member against it. The
// requesting file is skipped — its live text has already answered — and the walk
// stops as soon as nothing is outstanding. Cancellation is polled per file: this
// runs on the typing-driven path, where the next keystroke supersedes it.
@(private)
scan_package_members :: proc(
    e: ^Engine,
    parser: ts.Parser,
    req: ^lang.Request,
    dir: string,
    members: []string,
    labels: []string,
) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }

    for info in infos {
        if lang.request_cancelled(req) {
            return
        }
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == req.path {
            continue
        }
        data, rerr := os.read_entire_file(info.fullpath, context.temp_allocator)
        if rerr != nil {
            continue
        }
        src := string(data)
        tree := ts.parser_parse_string(parser, src)
        if tree == nil {
            continue
        }
        fill_member_labels(collect_defs(e, ts.tree_root_node(tree), src)[:], src, members, labels)
        ts.tree_delete(tree)
        if !labels_missing(labels) {
            return
        }
    }
}

// Whether any member is still unresolved — so the package scan knows to run at
// all, and when to stop.
@(private)
labels_missing :: proc(labels: []string) -> bool {
    for label in labels {
        if label == "" {
            return true
        }
    }
    return false
}
