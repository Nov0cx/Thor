// In-client Odin analyzer: the first Language backend, running natively on the
// Manager's worker thread with no subprocess and no serialization. It parses
// with the vendored tree-sitter grammar, then resolves an identifier to its
// declaration using the grammar's LOCALS query for lexical scope, falling back
// to a workspace-wide scan of top-level declarations for cross-file symbols.
package lang

import "core:os"
import "core:strings"

import ts "../vendor/odin-tree-sitter"
import ts_odin "../vendor/odin-tree-sitter/parsers/odin"

// Files scanned in one cross-file lookup, and directory depth, so a huge tree
// can't stall a goto. Mirrors thor_collect_files' guards.
@(private = "file")
SCAN_FILE_LIMIT :: 4000
@(private = "file")
SCAN_DEPTH_LIMIT :: 12

Odin_Engine :: struct {
    language: ts.Language,
    locals:   ts.Query, // compiled once, immutable, shared read-only across workers
}

odin_engine_create :: proc() -> ^Odin_Engine {
    e := new(Odin_Engine)
    e.language = ts_odin.tree_sitter_odin()
    query, _, err := ts.query_new(e.language, ts_odin.LOCALS)
    if err == .None {
        e.locals = query
    }
    return e
}

// Wraps the engine as a Backend for manager_register.
odin_engine_backend :: proc(e: ^Odin_Engine) -> Backend {
    return Backend {
        data    = e,
        name    = "odin (in-client)",
        handles = odin_handles,
        resolve = odin_resolve,
        destroy = odin_destroy,
    }
}

@(private = "file")
odin_handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".odin"
}

@(private)
odin_destroy :: proc(data: rawptr) {
    e := cast(^Odin_Engine) data
    if e.locals != nil {
        ts.query_delete(e.locals)
    }
    free(e)
}

// A declaration found in a parsed tree: the identifier being declared, the byte
// range of the scope it is visible in, and the enclosing declaration node used
// for hover text.
@(private = "file")
Def :: struct {
    name:        string, // slice into the parsed source
    ident_start: int,
    ident_end:   int,
    kind:        string, // LOCALS capture suffix: "function", "type", "var", ...
    scope_start: int,
    scope_end:   int,
    top_level:   bool, // no enclosing block: visible across the whole file/package
    decl_start:  int,
    decl_end:    int,
}

@(private)
odin_resolve :: proc(data: rawptr, req: ^Request, res: ^Result) {
    e := cast(^Odin_Engine) data
    if e.locals == nil {
        return
    }

    // One parser per call (parsers are not shareable across threads); reused for
    // the request buffer and every workspace file the cross-file scan visits.
    parser := ts.parser_new()
    defer ts.parser_delete(parser)
    ts.parser_set_language(parser, e.language)

    tree := ts.parser_parse_string(parser, req.source)
    if tree == nil {
        return
    }
    defer ts.tree_delete(tree)
    root := ts.tree_root_node(tree)

    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    name := ts.node_text(ident, req.source)
    hover_start := int(ts.node_start_byte(ident))
    hover_end := int(ts.node_end_byte(ident))

    // 1) Same file: lexical resolution via the LOCALS query.
    defs := collect_defs(e, root, req.source)
    if d, found := resolve_local(defs[:], name, req.offset); found {
        fill_result(res, req, req.path, req.source, d, hover_start, hover_end)
        return
    }

    // 2) Workspace: scan sibling files for a matching top-level declaration.
    if req.workspace != "" {
        scan_workspace(e, parser, req, name, hover_start, hover_end, res)
    }
}

// Smallest identifier node covering `offset`, also probing offset-1 so a caret
// resting just after an identifier still resolves it.
@(private = "file")
identifier_at :: proc(root: ts.Node, source: string, offset: int) -> (ts.Node, bool) {
    off := u32(clamp(offset, 0, len(source)))
    if n := ts.node_named_descendant_for_byte_range(root, off, off); is_identifier(n) {
        return n, true
    }
    if offset > 0 {
        p := off - 1
        if n := ts.node_named_descendant_for_byte_range(root, p, p); is_identifier(n) {
            return n, true
        }
    }
    return {}, false
}

@(private = "file")
is_identifier :: proc(n: ts.Node) -> bool {
    return !ts.node_is_null(n) && string(ts.node_type(n)) == "identifier"
}

// Runs the LOCALS query over `root` and records every @definition.* capture with
// the scope it is visible in.
@(private = "file")
collect_defs :: proc(e: ^Odin_Engine, root: ts.Node, source: string) -> [dynamic]Def {
    defs := make([dynamic]Def, context.temp_allocator)

    cursor := ts.query_cursor_new()
    defer ts.query_cursor_delete(cursor)
    ts.query_cursor_exec(cursor, e.locals, root)

    for match in ts.query_cursor_next_match(cursor) {
        for i in 0 ..< int(match.capture_count) {
            c := match.captures[i]
            cname := ts.query_capture_name_for_id(e.locals, c.index)
            if !strings.has_prefix(cname, "definition") {
                continue
            }

            ident := c.node
            d: Def
            d.name = ts.node_text(ident, source)
            d.ident_start = int(ts.node_start_byte(ident))
            d.ident_end = int(ts.node_end_byte(ident))
            d.kind = strings.has_prefix(cname, "definition.") ? cname[len("definition."):] : ""
            d.scope_start = 0
            d.scope_end = len(source)

            // Scope: a parameter is visible in its procedure; a local is visible
            // in its enclosing block; anything with neither is top-level and
            // visible file-wide (procs, structs, enums, package-level consts).
            if d.kind == "parameter" {
                if pd, has := ancestor_type(ident, "procedure_declaration"); has {
                    d.scope_start = int(ts.node_start_byte(pd))
                    d.scope_end = int(ts.node_end_byte(pd))
                } else {
                    d.top_level = true
                }
            } else if blk, has := ancestor_type(ident, "block"); has {
                d.scope_start = int(ts.node_start_byte(blk))
                d.scope_end = int(ts.node_end_byte(blk))
            } else {
                d.top_level = true
            }

            if decl, has := ancestor_suffix(ident, "_declaration"); has {
                d.decl_start = int(ts.node_start_byte(decl))
                d.decl_end = int(ts.node_end_byte(decl))
            } else {
                d.decl_start = d.ident_start
                d.decl_end = d.ident_end
            }

            append(&defs, d)
        }
    }

    // The vendored LOCALS query models `:=` locals as `variable_declaration`,
    // but this grammar parses `x := v` as an `assignment_statement` with a `:=`
    // operator token, so the query misses them. Collect those directly.
    collect_short_decls(root, source, &defs)
    return defs
}

// Adds `name := value` short declarations as local definitions. Distinguished
// from reassignment (`name = value`) by the operator token type: `:=` declares,
// `=` does not. A block-local scope is used, matching a `:=`'s visibility.
@(private = "file")
collect_short_decls :: proc(node: ts.Node, source: string, defs: ^[dynamic]Def) {
    if string(ts.node_type(node)) == "assignment_statement" {
        // Walk the leading children: identifiers (and commas for `a, b := ...`)
        // up to the operator. A `:=` there makes those identifiers definitions.
        lead := make([dynamic]ts.Node, context.temp_allocator)
        is_decl := false
        for i in 0 ..< ts.node_child_count(node) {
            c := ts.node_child(node, i)
            switch string(ts.node_type(c)) {
            case "identifier":
                append(&lead, c)
                continue
            case ",":
                continue
            case ":=":
                is_decl = true
            }
            break
        }

        if is_decl {
            for ident in lead {
                d: Def
                d.name = ts.node_text(ident, source)
                d.ident_start = int(ts.node_start_byte(ident))
                d.ident_end = int(ts.node_end_byte(ident))
                d.kind = "var"
                d.scope_start = int(ts.node_start_byte(node))
                d.scope_end = len(source)
                if blk, has := ancestor_type(ident, "block"); has {
                    d.scope_start = int(ts.node_start_byte(blk))
                    d.scope_end = int(ts.node_end_byte(blk))
                } else {
                    d.top_level = true
                }
                d.decl_start = int(ts.node_start_byte(node))
                d.decl_end = int(ts.node_end_byte(node))
                append(defs, d)
            }
        }
    }

    for i in 0 ..< ts.node_child_count(node) {
        collect_short_decls(ts.node_child(node, i), source, defs)
    }
}

// Picks the visible declaration of `name` nearest `offset`: a local shadows a
// file-scope symbol, an inner block shadows an outer, ties break by proximity.
@(private = "file")
resolve_local :: proc(defs: []Def, name: string, offset: int) -> (Def, bool) {
    best: Def
    found := false
    for d in defs {
        if d.name != name {
            continue
        }
        if !d.top_level && (offset < d.scope_start || offset > d.scope_end) {
            continue
        }
        if !found || def_better(d, best, offset) {
            best = d
            found = true
        }
    }
    return best, found
}

@(private = "file")
def_better :: proc(a, b: Def, offset: int) -> bool {
    if a.top_level != b.top_level {
        return !a.top_level // a local shadows a file-scope symbol
    }
    if !a.top_level {
        aw := a.scope_end - a.scope_start
        bw := b.scope_end - b.scope_start
        if aw != bw {
            return aw < bw // the tighter (inner) scope wins
        }
    }
    return abs(a.ident_start - offset) < abs(b.ident_start - offset)
}

// Walks the workspace for a file with a matching top-level declaration; the
// first hit fills `res` and stops the walk. A persistent index would replace
// this re-scan (see the package notes); it is correctness-first for now, and
// runs on a worker thread off an explicit user action, not per keystroke.
@(private = "file")
scan_workspace :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    req: ^Request,
    name: string,
    hover_start, hover_end: int,
    res: ^Result,
) {
    count := 0
    scan_dir(e, parser, req.workspace, req, name, hover_start, hover_end, res, &count, 0)
}

@(private = "file")
scan_dir :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    dir: string,
    req: ^Request,
    name: string,
    hover_start, hover_end: int,
    res: ^Result,
    count: ^int,
    depth: int,
) {
    if res.ok || count^ >= SCAN_FILE_LIMIT || depth > SCAN_DEPTH_LIMIT {
        return
    }

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
        if res.ok || count^ >= SCAN_FILE_LIMIT {
            return
        }
        if info.type == .Directory {
            if info.name == ".git" || strings.has_prefix(info.name, ".") {
                continue
            }
            scan_dir(e, parser, info.fullpath, req, name, hover_start, hover_end, res, count, depth + 1)
            continue
        }
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        // The request buffer was already searched, with unsaved edits; skip its
        // on-disk copy so we don't resolve to a stale definition.
        if info.fullpath == req.path {
            continue
        }
        count^ += 1
        scan_file(e, parser, info.fullpath, req, name, hover_start, hover_end, res)
    }
}

@(private = "file")
scan_file :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    path: string,
    req: ^Request,
    name: string,
    hover_start, hover_end: int,
    res: ^Result,
) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return
    }
    source := string(data)

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return
    }
    defer ts.tree_delete(tree)

    defs := collect_defs(e, ts.tree_root_node(tree), source)
    for d in defs {
        if d.top_level && d.name == name {
            fill_result(res, req, path, source, d, hover_start, hover_end)
            return
        }
    }
}

// Writes the resolved declaration into the result for the requested feature.
// Owned strings use context.allocator, which the worker set to the Manager's
// allocator, so they are freed on the main thread after the editor reads them.
@(private = "file")
fill_result :: proc(res: ^Result, req: ^Request, path, source: string, d: Def, hover_start, hover_end: int) {
    switch req.kind {
    case .Definition:
        res.location = Location {
            path  = strings.clone(path),
            start = d.ident_start,
            end   = d.ident_end,
        }
        res.ok = true
    case .Hover:
        res.hover = Hover_Info {
            text  = signature_text(source, d),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
    }
}

// The declaration's signature: its text up to the body brace or first newline,
// trimmed. For `foo :: proc(x: int) -> int {` that yields `foo :: proc(x: int)
// -> int`. Cloned into context.allocator.
@(private = "file")
signature_text :: proc(source: string, d: Def) -> string {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.decl_end, start, len(source))
    text := source[start:end]

    if brace := strings.index_byte(text, '{'); brace >= 0 {
        text = text[:brace]
    }
    if nl := strings.index_byte(text, '\n'); nl >= 0 {
        text = text[:nl]
    }
    return strings.clone(strings.trim_space(text))
}

// Nearest ancestor whose node type equals `type`.
@(private = "file")
ancestor_type :: proc(node: ts.Node, type: string) -> (ts.Node, bool) {
    n := ts.node_parent(node)
    for !ts.node_is_null(n) {
        if string(ts.node_type(n)) == type {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}

// Nearest ancestor whose node type ends with `suffix` (e.g. "_declaration").
@(private = "file")
ancestor_suffix :: proc(node: ts.Node, suffix: string) -> (ts.Node, bool) {
    n := ts.node_parent(node)
    for !ts.node_is_null(n) {
        if strings.has_suffix(string(ts.node_type(n)), suffix) {
            return n, true
        }
        n = ts.node_parent(n)
    }
    return {}, false
}
