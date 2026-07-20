// In-client Odin analyzer: the first Language backend, running natively on the
// Manager's worker thread with no subprocess and no serialization. It parses
// with the vendored tree-sitter grammar, then resolves an identifier to its
// declaration using the grammar's LOCALS query for lexical scope, falling back
// to a workspace-wide scan of top-level declarations for cross-file symbols.
package lang

import "core:os"
import "core:path/filepath"
import "core:slice"
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

    // Document symbols need no caret: enumerate the whole file and return.
    if req.kind == .Document_Symbols {
        collect_document_symbols(e, root, req.source, req.path, res)
        return
    }

    // Workspace symbols enumerate every top-level declaration across the tree,
    // starting from the live buffer (unsaved edits) then every sibling file.
    if req.kind == .Workspace_Symbols {
        collect_workspace_symbols(e, parser, root, req, res)
        return
    }

    // References need the identifier under the caret, but not the import/selector
    // resolution the goto flow runs — they gather every occurrence of the name.
    if req.kind == .References {
        collect_references(e, parser, root, req, res)
        return
    }

    // Caret on an import declaration itself (its alias or its quoted path):
    // resolve to the imported package. Handled before identifier_at because the
    // path string is not an identifier, so a caret resting on it would otherwise
    // fail outright.
    if imp, in_import := enclosing_import(root, req.source, req.offset); in_import {
        if raw, rok := import_string(imp, req.source); rok {
            if dir, dok := package_dir(raw, req.path, req.workspace); dok {
                anchor_start := int(ts.node_start_byte(imp))
                anchor_end := int(ts.node_end_byte(imp))
                open_package(dir, raw, req, res, anchor_start, anchor_end)
            }
        }
        return
    }

    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    name := ts.node_text(ident, req.source)
    hover_start := int(ts.node_start_byte(ident))
    hover_end := int(ts.node_end_byte(ident))

    // 0) Package-qualified selector: `pkg.Symbol`. When the operand names a
    //    package imported by this file, the symbol lives in that package's
    //    directory, so resolve there and never fall through to the flat scan
    //    (which ignores package boundaries and could match a same-named symbol
    //    in an unrelated package). Selectors on plain values (`v.field`) fall
    //    through: type-aware member access is not implemented yet.
    if pkg_ident, member_ident, is_sel := selector_parts(ident); is_sel && is_identifier(pkg_ident) {
        pkg := ts.node_text(pkg_ident, req.source)
        if raw, found := import_path(root, req.source, pkg); found {
            if dir, dok := package_dir(raw, req.path, req.workspace); dok {
                if same_node(ident, member_ident) {
                    scan_package(e, parser, dir, req, name, hover_start, hover_end, res)
                } else {
                    open_package(dir, raw, req, res, hover_start, hover_end)
                }
            }
            return
        }
    }

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

// Nearest import_declaration enclosing `offset`, so a caret anywhere on an
// import line (its alias identifier or its quoted path) resolves to the package.
@(private = "file")
enclosing_import :: proc(root: ts.Node, source: string, offset: int) -> (ts.Node, bool) {
    off := u32(clamp(offset, 0, len(source)))
    n := ts.node_named_descendant_for_byte_range(root, off, off)
    for !ts.node_is_null(n) {
        if string(ts.node_type(n)) == "import_declaration" {
            return n, true
        }
        n = ts.node_parent(n)
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

// Appends `source`'s top-level declarations (in `path`) to res.symbols. Reuses
// collect_defs — the same walk go-to-definition uses — and keeps only the
// file-scope symbols a symbol list should show (procedures, types, enums,
// constants and package-level vars), dropping parameters, struct fields, labels
// and the package/import namespace captures. Each field is cloned into
// context.allocator (the Manager's), freed on the main thread after the editor
// reads them; the signature is the real Odin declaration line.
@(private = "file")
collect_symbols_into :: proc(e: ^Odin_Engine, root: ts.Node, source, path: string, res: ^Result) {
    defs := collect_defs(e, root, source)
    for d in defs {
        if !d.top_level || !symbol_kind_shown(d.kind) {
            continue
        }
        ident_start := clamp(d.ident_start, 0, len(source))
        append(&res.symbols, Symbol {
            name      = strings.clone(d.name),
            kind      = strings.clone(d.kind),
            signature = signature_text(source, d),
            path      = strings.clone(path),
            line      = strings.count(source[:ident_start], "\n") + 1,
            offset    = d.ident_start,
        })
    }
}

// Fills `res` with one file's top-level declarations for a document outline,
// sorted by position for a stable outline.
@(private = "file")
collect_document_symbols :: proc(e: ^Odin_Engine, root: ts.Node, source, path: string, res: ^Result) {
    collect_symbols_into(e, root, source, path, res)
    slice.sort_by(res.symbols[:], proc(a, b: Symbol) -> bool {
        return a.offset < b.offset
    })
    res.ok = true
}

// Fills `res` with every top-level declaration across the workspace: the live
// buffer first (so unsaved edits win over its on-disk copy, which is skipped),
// then every sibling .odin file. Bounded by the same file/depth guards as the
// cross-file goto scan. Sorted by name (ties by path) for a stable, fuzzy-
// searchable list — an on-demand scan, re-run each time the picker is opened.
@(private = "file")
collect_workspace_symbols :: proc(e: ^Odin_Engine, parser: ts.Parser, root: ts.Node, req: ^Request, res: ^Result) {
    if req.path != "" {
        collect_symbols_into(e, root, req.source, req.path, res)
    }
    if req.workspace != "" {
        count := 0
        collect_symbols_dir(e, parser, req.workspace, req, res, &count, 0)
    }
    slice.sort_by(res.symbols[:], proc(a, b: Symbol) -> bool {
        if a.name != b.name {
            return a.name < b.name
        }
        return a.path < b.path
    })
    res.ok = true
}

// Recurses the workspace, collecting every .odin file's top-level symbols.
// Mirrors scan_dir's guards and skips list, but never stops early: it gathers
// all files rather than resolving one name.
@(private = "file")
collect_symbols_dir :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    dir: string,
    req: ^Request,
    res: ^Result,
    count: ^int,
    depth: int,
) {
    if count^ >= SCAN_FILE_LIMIT || depth > SCAN_DEPTH_LIMIT {
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
        if count^ >= SCAN_FILE_LIMIT {
            return
        }
        if info.type == .Directory {
            if info.name == ".git" || strings.has_prefix(info.name, ".") {
                continue
            }
            collect_symbols_dir(e, parser, info.fullpath, req, res, count, depth + 1)
            continue
        }
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        // The live buffer was already collected, with unsaved edits; skip its
        // on-disk copy so a symbol isn't listed twice.
        if info.fullpath == req.path {
            continue
        }
        count^ += 1
        collect_symbols_file(e, parser, info.fullpath, res)
    }
}

@(private = "file")
collect_symbols_file :: proc(e: ^Odin_Engine, parser: ts.Parser, path: string, res: ^Result) {
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

    collect_symbols_into(e, ts.tree_root_node(tree), source, path, res)
}

// Gathers every occurrence of the identifier under the caret ("find usages").
// The kind of match is chosen by resolution: a name that binds to a local or a
// parameter is confined to that declaration's scope in this one file (so an `x`
// in one procedure never lists an unrelated `x` in another); anything else —
// top-level, or a name that doesn't resolve locally — is matched by name across
// the whole workspace, mirroring how cross-file goto flat-matches top-level
// names (no package/type awareness yet, so this is textual-but-AST-aware). Each
// occurrence becomes a Symbol carrying its file, line, offset and the source
// line it sits on for a code-context preview.
@(private = "file")
collect_references :: proc(e: ^Odin_Engine, parser: ts.Parser, root: ts.Node, req: ^Request, res: ^Result) {
    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    name := ts.node_text(ident, req.source)

    defs := collect_defs(e, root, req.source)
    if d, found := resolve_local(defs[:], name, req.offset); found && !d.top_level {
        // Local / parameter: only its own scope in this file.
        collect_ident_refs(root, req.source, name, req.path, d.scope_start, d.scope_end, res)
    } else {
        // Top-level or unresolved: this whole buffer, then every workspace file.
        collect_ident_refs(root, req.source, name, req.path, 0, len(req.source), res)
        if req.workspace != "" {
            count := 0
            ref_scan_dir(e, parser, req.workspace, req, name, res, &count, 0)
        }
    }

    slice.sort_by(res.symbols[:], proc(a, b: Symbol) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
    res.ok = len(res.symbols) > 0
}

// Appends every `identifier` node in `node`'s subtree whose text equals `name`
// and whose span falls within [within_start, within_end) to res.symbols. Each is
// a reference Symbol: the source line it sits on is the preview, path/line/offset
// the jump target. Owned strings use context.allocator (the Manager's).
@(private = "file")
collect_ident_refs :: proc(node: ts.Node, source, name, path: string, within_start, within_end: int, res: ^Result) {
    if is_identifier(node) {
        s := int(ts.node_start_byte(node))
        end := int(ts.node_end_byte(node))
        if s >= within_start && end <= within_end && ts.node_text(node, source) == name {
            append(&res.symbols, Symbol {
                name      = strings.clone(name),
                kind      = strings.clone("reference"),
                signature = source_line(source, s),
                path      = strings.clone(path),
                line      = strings.count(source[:clamp(s, 0, len(source))], "\n") + 1,
                offset    = s,
            })
        }
    }
    for i in 0 ..< ts.node_child_count(node) {
        collect_ident_refs(ts.node_child(node, i), source, name, path, within_start, within_end, res)
    }
}

// The whole source line `offset` falls on, trimmed — a reference row's code
// preview. Cloned into context.allocator.
@(private = "file")
source_line :: proc(source: string, offset: int) -> string {
    lo := clamp(offset, 0, len(source))
    start := strings.last_index_byte(source[:lo], '\n') + 1 // -1 + 1 == 0 for the first line
    end := len(source)
    if nl := strings.index_byte(source[lo:], '\n'); nl >= 0 {
        end = lo + nl
    }
    return strings.clone(strings.trim_space(source[start:end]))
}

// Recurses the workspace collecting every .odin file's occurrences of `name`.
// Mirrors collect_symbols_dir's guards and skip-live-buffer rule, but gathers
// name matches rather than declarations.
@(private = "file")
ref_scan_dir :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    dir: string,
    req: ^Request,
    name: string,
    res: ^Result,
    count: ^int,
    depth: int,
) {
    if count^ >= SCAN_FILE_LIMIT || depth > SCAN_DEPTH_LIMIT {
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
        if count^ >= SCAN_FILE_LIMIT {
            return
        }
        if info.type == .Directory {
            if info.name == ".git" || strings.has_prefix(info.name, ".") {
                continue
            }
            ref_scan_dir(e, parser, info.fullpath, req, name, res, count, depth + 1)
            continue
        }
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        // The live buffer was already searched, with unsaved edits; skip its
        // on-disk copy so an occurrence isn't listed twice (or from stale text).
        if info.fullpath == req.path {
            continue
        }
        count^ += 1
        ref_scan_file(e, parser, info.fullpath, name, res)
    }
}

@(private = "file")
ref_scan_file :: proc(e: ^Odin_Engine, parser: ts.Parser, path, name: string, res: ^Result) {
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

    collect_ident_refs(ts.tree_root_node(tree), source, name, path, 0, len(source), res)
}

// LOCALS capture suffixes that belong in a document outline. Excludes
// "parameter"/"field" (nested), "namespace" (package name and import aliases)
// and "" (labels).
@(private = "file")
symbol_kind_shown :: proc(kind: string) -> bool {
    switch kind {
    case "function", "type", "enum", "constant", "var":
        return true
    }
    return false
}

// Writes the resolved declaration into the result for the requested feature.
// Owned strings use context.allocator, which the worker set to the Manager's
// allocator, so they are freed on the main thread after the editor reads them.
@(private = "file")
fill_result :: proc(res: ^Result, req: ^Request, path, source: string, d: Def, hover_start, hover_end: int) {
    #partial switch req.kind {
    case .Definition:
        res.location = Location {
            path  = strings.clone(path),
            start = d.ident_start,
            end   = d.ident_end,
        }
        res.ok = true
    case .Hover:
        res.hover = Hover_Info {
            text  = declaration_text(source, d),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
    }
}

// One-line signature for a symbol-list row: `name :: type`, trimmed. Starts at
// the declared identifier (so any leading `@(...)` attribute is skipped) and
// stops at the body brace or first newline. `foo :: proc(x: int) -> int {` and
// `Point :: struct {` yield `foo :: proc(x: int) -> int` and `Point :: struct`.
// Cloned into context.allocator.
@(private = "file")
signature_text :: proc(source: string, d: Def) -> string {
    start := clamp(d.ident_start, 0, len(source))
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

// The full declaration text for a hover popup: the whole declaration node,
// trimmed, including any leading `@(...)` attribute (the grammar nests it as the
// declaration's first child, so decl_start already covers it). A procedure keeps
// only its signature — the body brace onward is dropped — while a type
// declaration (struct/enum/union/bit_field) or any other multi-line declaration
// is shown complete, across every line. Cloned into context.allocator.
@(private = "file")
declaration_text :: proc(source: string, d: Def) -> string {
    start := clamp(d.decl_start, 0, len(source))
    end := clamp(d.decl_end, start, len(source))
    text := source[start:end]

    // Procedures: show the signature, not the body. The first `{` opens the body
    // (attributes use `(...)`, the signature has no brace), so cutting there keeps
    // any attribute line and the `name :: proc(...) -> ...` head.
    if d.kind == "function" {
        if brace := strings.index_byte(text, '{'); brace >= 0 {
            text = text[:brace]
        }
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

// True when both nodes are non-null and cover the same byte range. tree-sitter
// Nodes are values, not pointers, so identity is compared by span.
@(private = "file")
same_node :: proc(a, b: ts.Node) -> bool {
    return !ts.node_is_null(a) && !ts.node_is_null(b) &&
        ts.node_start_byte(a) == ts.node_start_byte(b) &&
        ts.node_end_byte(a) == ts.node_end_byte(b)
}

// If `ident` is part of a `pkg.member` selector, returns the package operand
// node and the member (symbol) node, whether the caret sits on either side.
// Handles the three grammar shapes this produces:
//   `pkg.Symbol`      -> member_expression (identifier . identifier)
//   `pkg.fn(args)`    -> member_expression (identifier . call_expression)
//   `pkg.Type` (type) -> field_type        (identifier . identifier)
@(private = "file")
selector_parts :: proc(ident: ts.Node) -> (pkg: ts.Node, member: ts.Node, ok: bool) {
    p := ts.node_parent(ident)
    if ts.node_is_null(p) {
        return {}, {}, false
    }
    pt := string(ts.node_type(p))

    if pt == "member_expression" || pt == "field_type" {
        a := ts.node_named_child(p, 0)
        b := ts.node_named_child(p, 1)
        if ts.node_is_null(a) || ts.node_is_null(b) {
            return {}, {}, false
        }
        // `pkg.fn(args)`: the member is the call's function identifier.
        if string(ts.node_type(b)) == "call_expression" {
            if fn := ts.node_child_by_field_name(b, "function"); !ts.node_is_null(fn) {
                b = fn
            }
        }
        return a, b, true
    }

    // Caret on `fn` in `pkg.fn(args)`: the identifier's parent is the call, whose
    // parent is the member_expression carrying the package operand.
    if pt == "call_expression" {
        gp := ts.node_parent(p)
        if !ts.node_is_null(gp) && string(ts.node_type(gp)) == "member_expression" {
            a := ts.node_named_child(gp, 0)
            if same_node(ts.node_named_child(gp, 1), p) {
                return a, ident, true
            }
        }
    }

    return {}, {}, false
}

// Import path (the collection-qualified or relative string) declared in `root`
// for the package named `pkg`, matching either an explicit alias or the name
// derived from the path's last segment.
@(private = "file")
import_path :: proc(root: ts.Node, source: string, pkg: string) -> (string, bool) {
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        if name, raw, ok := import_name_and_path(child, source); ok && name == pkg {
            return raw, true
        }
    }
    return "", false
}

// Package name and path for one import_declaration. The name is the explicit
// alias when present, otherwise the path's last segment.
@(private = "file")
import_name_and_path :: proc(imp: ts.Node, source: string) -> (name: string, raw: string, ok: bool) {
    raw, ok = import_string(imp, source)
    if !ok {
        return "", "", false
    }
    if alias := ts.node_child_by_field_name(imp, "alias"); !ts.node_is_null(alias) && is_identifier(alias) {
        return ts.node_text(alias, source), raw, true
    }
    return package_name_from_path(raw), raw, true
}

// The quoted path of an import_declaration, unquoted (via the string_content
// child, falling back to trimming the quote bytes).
@(private = "file")
import_string :: proc(imp: ts.Node, source: string) -> (string, bool) {
    for i in 0 ..< ts.node_named_child_count(imp) {
        c := ts.node_named_child(imp, i)
        if string(ts.node_type(c)) != "string" {
            continue
        }
        for j in 0 ..< ts.node_named_child_count(c) {
            sc := ts.node_named_child(c, j)
            if string(ts.node_type(sc)) == "string_content" {
                return ts.node_text(sc, source), true
            }
        }
        t := ts.node_text(c, source)
        t = strings.trim_prefix(t, "\"")
        t = strings.trim_suffix(t, "\"")
        return t, true
    }
    return "", false
}

// Last path segment of an import path, after any collection prefix and any
// slash: "core:fmt" -> "fmt", "core:odin/parser" -> "parser", "../lang" -> "lang".
@(private = "file")
package_name_from_path :: proc(raw: string) -> string {
    s := raw
    if colon := strings.last_index_byte(s, ':'); colon >= 0 {
        s = s[colon + 1:]
    }
    if slash := strings.last_index_byte(s, '/'); slash >= 0 {
        s = s[slash + 1:]
    }
    if back := strings.last_index_byte(s, '\\'); back >= 0 {
        s = s[back + 1:]
    }
    return s
}

// Directory an import path points at. Relative paths resolve against the
// importing file's directory (fully in-workspace). `core:`/`vendor:`/`base:`
// collections resolve against ODIN_ROOT when the environment exposes it;
// unknown collections have no mapping. Returned dir is scratch-allocated.
@(private = "file")
package_dir :: proc(raw: string, req_path: string, workspace: string) -> (string, bool) {
    if colon := strings.index_byte(raw, ':'); colon >= 0 {
        coll := raw[:colon]
        sub := raw[colon + 1:]
        if coll == "core" || coll == "vendor" || coll == "base" {
            root := odin_root()
            if root == "" {
                return "", false
            }
            joined, err := filepath.join({root, coll, sub}, context.temp_allocator)
            return joined, err == nil
        }
        return "", false
    }

    base := filepath.dir(req_path)
    joined, jerr := filepath.join({base, raw}, context.temp_allocator)
    if jerr != nil {
        return "", false
    }
    cleaned, cerr := filepath.clean(joined, context.temp_allocator)
    if cerr != nil {
        return joined, true
    }
    return cleaned, true
}

// Odin's install root, so `core:`/`vendor:`/`base:` imports can be located. The
// ODIN_ROOT environment variable wins when set (lets a user point at a different
// toolchain); otherwise fall back to the compiler's own root, baked in at build
// time as the `ODIN_ROOT` constant — this is what makes the standard library
// resolve out of the box, with no environment set up.
@(private = "file")
odin_root :: proc() -> string {
    if v, found := os.lookup_env("ODIN_ROOT", context.temp_allocator); found && v != "" {
        return v
    }
    return ODIN_ROOT
}

// Scans one package directory (all its .odin files, non-recursively — an Odin
// package is a single flat directory) for a matching top-level declaration.
@(private = "file")
scan_package :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    dir: string,
    req: ^Request,
    name: string,
    hover_start, hover_end: int,
    res: ^Result,
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
        if res.ok {
            return
        }
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        scan_file(e, parser, info.fullpath, req, name, hover_start, hover_end, res)
    }
}

// Caret on the package operand itself (`pkg` in `pkg.Symbol`): "go to package".
// Definition jumps to the head of the file named like the package (the `foo.odin`
// entry file in package `foo`, the usual convention). When no such file exists it
// falls back to the package's first .odin file (lexicographically), so the caret
// still lands inside the package rather than reporting nothing. Hover shows the
// import path.
@(private = "file")
open_package :: proc(dir, raw: string, req: ^Request, res: ^Result, hover_start, hover_end: int) {
    #partial switch req.kind {
    case .Definition:
        handle, open_err := os.open(dir)
        if open_err != nil {
            return
        }
        defer os.close(handle)
        infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
        if read_err != nil {
            return
        }
        want := strings.concatenate({filepath.base(dir), ".odin"}, context.temp_allocator)
        first_name := "" // lexicographically first .odin file, the fallback target
        first_path := ""
        for info in infos {
            if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
                continue
            }
            if info.name == want {
                res.location = Location{path = strings.clone(info.fullpath), start = 0, end = 0}
                res.ok = true
                return
            }
            if first_name == "" || info.name < first_name {
                first_name = info.name
                first_path = info.fullpath
            }
        }
        // No `foo.odin`: land on the package's first file so navigation still works.
        if first_path != "" {
            res.location = Location{path = strings.clone(first_path), start = 0, end = 0}
            res.ok = true
        }
    case .Hover:
        text := strings.concatenate({"import \"", raw, "\""}, context.temp_allocator)
        res.hover = Hover_Info {
            text  = strings.clone(text),
            start = hover_start,
            end   = hover_end,
        }
        res.ok = true
    }
}
