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

    // Signature help works off the caret's position inside a call's argument
    // list, not an identifier under it, so it resolves the call before the
    // identifier/import goto logic below.
    if req.kind == .Signature_Help {
        signature_help(e, parser, root, req, res)
        return
    }

    // Completion works off the partial word before the caret (which may not yet
    // parse to an identifier), so it runs before the identifier/import goto logic.
    if req.kind == .Completion {
        complete(e, parser, root, req, res)
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
    //    Hover wants the first hit; go-to-definition gathers every match so an
    //    ambiguous name (declared in several packages) offers a picker.
    if req.workspace != "" {
        if req.kind == .Definition {
            resolve_definition_workspace(e, parser, req, name, res)
        } else {
            scan_workspace(e, parser, req, name, hover_start, hover_end, res)
        }
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

// Go-to-definition's cross-file scan. Gathers every workspace file's top-level
// declaration named `name` into res.symbols; unlike scan_workspace (first hit
// wins, used by hover) it never stops early, because the flat cross-file match
// ignores package boundaries — the same name can be declared in several
// packages and the user should choose. A single hit collapses back to
// res.location (the direct-jump path the caller already handles); two or more
// stay as candidates for a picker.
@(private = "file")
resolve_definition_workspace :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    req: ^Request,
    name: string,
    res: ^Result,
) {
    count := 0
    def_scan_dir(e, parser, req.workspace, req, name, res, &count, 0)
    switch len(res.symbols) {
    case 0:
        // Unresolved: res.ok stays false so the caller reports "no definition".
    case 1:
        // Single definition: collapse to the location a direct jump uses, moving
        // the (Manager-owned) path into it and freeing the row's other strings.
        sym := res.symbols[0]
        res.location = Location{path = sym.path, start = sym.offset, end = sym.offset + len(sym.name)}
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
        delete(res.symbols)
        res.symbols = nil
        res.ok = true
    case:
        // Ambiguous: leave the candidates in res.symbols for the picker.
        res.ok = true
    }
}

@(private = "file")
def_scan_dir :: proc(
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
            def_scan_dir(e, parser, info.fullpath, req, name, res, count, depth + 1)
            continue
        }
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        // The request buffer was already searched (with unsaved edits) by the
        // same-file lexical pass; skip its on-disk copy.
        if info.fullpath == req.path {
            continue
        }
        count^ += 1
        def_scan_file(e, parser, info.fullpath, name, res)
    }
}

// Appends `path`'s top-level declaration named `name` (if any) to res.symbols as
// a candidate row: the real Odin declaration line, its kind and the jump target.
// Top-level names are unique within a file, so it stops at the first match.
@(private = "file")
def_scan_file :: proc(e: ^Odin_Engine, parser: ts.Parser, path, name: string, res: ^Result) {
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
        if !d.top_level || d.name != name {
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
        return
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

// Resolves the call the caret sits inside to its procedure declaration and fills
// `res.signature` with that proc's signature line plus the byte range, within
// the line, of the parameter the caret is currently on. The call's function is
// resolved the same three ways goto is — same-file, package-qualified
// (`pkg.fn(...)`) and cross-file workspace scan — so signature help follows the
// same reach. Only procedures produce a result; a call of a non-proc is ignored.
@(private = "file")
signature_help :: proc(e: ^Odin_Engine, parser: ts.Parser, root: ts.Node, req: ^Request, res: ^Result) {
    call, ok := enclosing_call(root, req.source, req.offset)
    if !ok {
        return
    }
    fn := ts.node_child_by_field_name(call, "function")
    if ts.node_is_null(fn) {
        return
    }

    src, d, found := resolve_call_target(e, parser, root, req, call, fn)
    if !found || d.kind != "function" {
        return
    }

    label := signature_text(src, d) // cloned into context.allocator (the Manager's)
    active := call_active_param(call, req.offset)
    astart, aend := active_param_span(label, active)
    res.signature = Signature_Info {
        label        = label,
        active_start = astart,
        active_end   = aend,
    }
    res.ok = true
}

// Nearest call_expression enclosing `offset`, so a caret anywhere inside a call's
// argument list (including the whitespace between arguments) resolves to that
// call. The innermost call wins, so `outer(inner(|))` picks `inner`.
@(private = "file")
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
@(private = "file")
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
@(private = "file")
resolve_call_target :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    root: ts.Node,
    req: ^Request,
    call, fn: ts.Node,
) -> (string, Def, bool) {
    // `pkg.fn(args)`: the call is the second child of a member_expression whose
    // first child is the package operand. Resolve `fn` in that package's dir.
    if parent := ts.node_parent(call); !ts.node_is_null(parent) &&
        string(ts.node_type(parent)) == "member_expression" {
        pkg_node := ts.node_named_child(parent, 0)
        if same_node(ts.node_named_child(parent, 1), call) && is_identifier(pkg_node) && is_identifier(fn) {
            pkg := ts.node_text(pkg_node, req.source)
            name := ts.node_text(fn, req.source)
            if raw, ok := import_path(root, req.source, pkg); ok {
                if dir, dok := package_dir(raw, req.path, req.workspace); dok {
                    return find_proc_in_dir(e, parser, dir, name, req.path)
                }
            }
            return "", {}, false
        }
    }

    if !is_identifier(fn) {
        return "", {}, false
    }
    name := ts.node_text(fn, req.source)

    // Same file: a top-level procedure of this name (locals of the same name are
    // not callables we can sign, so require the "function" kind).
    defs := collect_defs(e, root, req.source)
    if d, ok := resolve_local(defs[:], name, int(ts.node_start_byte(fn))); ok && d.kind == "function" {
        return req.source, d, true
    }

    // Workspace: scan sibling files for a matching top-level procedure.
    if req.workspace != "" {
        count := 0
        return find_proc_dir(e, parser, req.workspace, req, name, &count, 0)
    }
    return "", {}, false
}

// First top-level procedure named `name` in `path`, with the file's source (so
// the Def stays valid past the parse). Reused by the package and workspace scans.
@(private = "file")
first_proc_in_file :: proc(e: ^Odin_Engine, parser: ts.Parser, path, name: string) -> (string, Def, bool) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return "", {}, false
    }
    source := string(data)

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return "", {}, false
    }
    defer ts.tree_delete(tree)

    defs := collect_defs(e, ts.tree_root_node(tree), source)
    for d in defs {
        if d.top_level && d.kind == "function" && d.name == name {
            return source, d, true
        }
    }
    return "", {}, false
}

// First top-level procedure named `name` in one package directory (all its .odin
// files, non-recursively — an Odin package is a flat directory). `skip` is the
// requesting file's path, left out so the live buffer's stale on-disk copy loses.
@(private = "file")
find_proc_in_dir :: proc(e: ^Odin_Engine, parser: ts.Parser, dir, name, skip: string) -> (string, Def, bool) {
    handle, open_err := os.open(dir)
    if open_err != nil {
        return "", {}, false
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return "", {}, false
    }

    for info in infos {
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == skip {
            continue
        }
        if src, d, ok := first_proc_in_file(e, parser, info.fullpath, name); ok {
            return src, d, ok
        }
    }
    return "", {}, false
}

// First top-level procedure named `name` anywhere in the workspace. Mirrors
// scan_dir's guards and skip-live-buffer rule, returning the declaration rather
// than filling a Definition result.
@(private = "file")
find_proc_dir :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    dir: string,
    req: ^Request,
    name: string,
    count: ^int,
    depth: int,
) -> (string, Def, bool) {
    if count^ >= SCAN_FILE_LIMIT || depth > SCAN_DEPTH_LIMIT {
        return "", {}, false
    }

    handle, open_err := os.open(dir)
    if open_err != nil {
        return "", {}, false
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return "", {}, false
    }

    for info in infos {
        if count^ >= SCAN_FILE_LIMIT {
            break
        }
        if info.type == .Directory {
            if info.name == ".git" || strings.has_prefix(info.name, ".") {
                continue
            }
            if src, d, ok := find_proc_dir(e, parser, info.fullpath, req, name, count, depth + 1); ok {
                return src, d, ok
            }
            continue
        }
        if !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == req.path {
            continue
        }
        count^ += 1
        if src, d, ok := first_proc_in_file(e, parser, info.fullpath, name); ok {
            return src, d, ok
        }
    }
    return "", {}, false
}

// Odin keywords and builtin types offered as completion candidates alongside the
// resolved identifiers.
@(private = "file")
ODIN_KEYWORDS :: [?]string {
    "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context",
    "continue", "defer", "distinct", "do", "dynamic", "else", "enum",
    "fallthrough", "for", "foreign", "if", "import", "in", "map", "matrix",
    "not_in", "or_else", "or_return", "package", "proc", "return", "struct",
    "switch", "transmute", "typeid", "union", "using", "when", "where",
    "bool", "b8", "b16", "b32", "b64",
    "int", "i8", "i16", "i32", "i64", "i128",
    "uint", "u8", "u16", "u32", "u64", "u128", "uintptr",
    "f16", "f32", "f64",
    "complex32", "complex64", "complex128",
    "quaternion64", "quaternion128", "quaternion256",
    "rune", "string", "cstring", "rawptr", "any", "byte",
    "true", "false", "nil",
}

// Bytes that make up an Odin identifier, for finding the partial word the caret
// is completing.
@(private = "file")
is_word_byte :: proc(b: u8) -> bool {
    return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b >= 0x80
}

// Code completion for the partial identifier before the caret. Two contexts:
// after `pkg.` (the operand names an imported package) it lists that package's
// top-level declarations; otherwise it offers the identifiers in scope — locals
// and parameters visible at the caret, this file's and this package's top-level
// declarations, the imported package names, and the Odin keywords and builtin
// types. All filtered by the typed prefix (case-sensitive) and de-duplicated by
// name. Name-based, like the rest of the engine: with no type inference,
// `value.field` member completion isn't offered.
@(private = "file")
complete :: proc(e: ^Odin_Engine, parser: ts.Parser, root: ts.Node, req: ^Request, res: ^Result) {
    src := req.source
    off := clamp(req.offset, 0, len(src))

    // The partial word being completed: the run of identifier bytes before the caret.
    start := off
    for start > 0 && is_word_byte(src[start - 1]) {
        start -= 1
    }
    prefix := src[start:off]

    // `pkg.<prefix>`: the char before the word is a `.` preceded by an identifier
    // that names an imported package. List that package's top-level symbols.
    if start > 0 && src[start - 1] == '.' {
        op_end := start - 1
        op_start := op_end
        for op_start > 0 && is_word_byte(src[op_start - 1]) {
            op_start -= 1
        }
        if op_start < op_end {
            pkg := src[op_start:op_end]
            if raw, found := import_path(root, src, pkg); found {
                if dir, dok := package_dir(raw, req.path, req.workspace); dok {
                    seen := make(map[string]bool, 0, context.temp_allocator)
                    complete_dir_toplevel(e, parser, dir, prefix, "", res, &seen)
                }
            }
        }
        // A selector on a value (`v.field`) needs type inference we don't have yet.
        finish_completion(res)
        return
    }

    seen := make(map[string]bool, 0, context.temp_allocator)

    // In-scope locals and parameters, plus this file's top-level declarations
    // (collect_defs yields both).
    defs := collect_defs(e, root, src)
    for d in defs {
        if !completion_def_ok(d, off) || !completion_matches(d.name, prefix) {
            continue
        }
        add_completion(res, src, d, &seen)
    }

    // This package's sibling files (an Odin package is one flat directory): their
    // top-level declarations are visible here unqualified.
    if req.path != "" {
        complete_dir_toplevel(e, parser, filepath.dir(req.path), prefix, req.path, res, &seen)
    }

    // Imported package names are completable identifiers too (`widgets`, `fmt`) —
    // the operand you then qualify with `.` — though they're not declarations
    // collect_defs yields.
    for i in 0 ..< ts.node_named_child_count(root) {
        child := ts.node_named_child(root, i)
        if string(ts.node_type(child)) != "import_declaration" {
            continue
        }
        if name, _, iok := import_name_and_path(child, src); iok && completion_matches(name, prefix) && name not_in seen {
            seen[name] = true
            append(&res.symbols, Symbol {
                name      = strings.clone(name),
                kind      = strings.clone("namespace"),
                signature = strings.clone(name),
            })
        }
    }

    // Keywords and builtin types.
    for kw in ODIN_KEYWORDS {
        if completion_matches(kw, prefix) && kw not_in seen {
            seen[kw] = true
            append(&res.symbols, Symbol {
                name      = strings.clone(kw),
                kind      = strings.clone("keyword"),
                signature = strings.clone(kw),
            })
        }
    }

    finish_completion(res)
}

// Whether a declaration belongs in the general completion list: an in-scope
// local or parameter (visible at the caret), or any file-scope declaration.
// Struct fields, the package/import namespace and labels are excluded — a field
// is only reachable through an instance, which needs type inference.
@(private = "file")
completion_def_ok :: proc(d: Def, off: int) -> bool {
    switch d.kind {
    case "field", "namespace", "label", "":
        return false
    }
    if d.top_level {
        return true
    }
    return off >= d.scope_start && off <= d.scope_end
}

// Case-sensitive prefix match; an empty prefix matches everything.
@(private = "file")
completion_matches :: proc(name, prefix: string) -> bool {
    return strings.has_prefix(name, prefix)
}

// Appends a completion candidate for `d`, de-duplicated by name. The label is the
// declaration line for a top-level symbol, or just the name for a local/param.
// Owned strings clone into context.allocator (the Manager's).
@(private = "file")
add_completion :: proc(res: ^Result, source: string, d: Def, seen: ^map[string]bool) {
    if d.name in seen^ {
        return
    }
    seen^[d.name] = true
    label := d.top_level ? signature_text(source, d) : strings.clone(d.name)
    append(&res.symbols, Symbol {
        name      = strings.clone(d.name),
        kind      = strings.clone(d.kind),
        signature = label,
    })
}

// Appends one directory's top-level declarations (its .odin files, non-recursive
// — an Odin package is a flat dir) whose names match `prefix`, skipping `skip`
// (the requesting file, whose live buffer was scanned already).
@(private = "file")
complete_dir_toplevel :: proc(
    e: ^Odin_Engine,
    parser: ts.Parser,
    dir, prefix, skip: string,
    res: ^Result,
    seen: ^map[string]bool,
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
        if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
            continue
        }
        if info.fullpath == skip {
            continue
        }
        data, rerr := os.read_entire_file(info.fullpath, context.temp_allocator)
        if rerr != nil {
            continue
        }
        source := string(data)
        tree := ts.parser_parse_string(parser, source)
        if tree == nil {
            continue
        }
        defs := collect_defs(e, ts.tree_root_node(tree), source)
        for d in defs {
            if d.top_level && symbol_kind_shown(d.kind) && completion_matches(d.name, prefix) {
                add_completion(res, source, d, seen)
            }
        }
        ts.tree_delete(tree)
    }
}

// Sorts completion candidates by name for a stable list and flags the result ok
// when any matched.
@(private = "file")
finish_completion :: proc(res: ^Result) {
    slice.sort_by(res.symbols[:], proc(a, b: Symbol) -> bool {
        return a.name < b.name
    })
    res.ok = len(res.symbols) > 0
}

// Byte range, within a signature line, of the `active`-th parameter — used to
// emphasize the argument the caret is on. Splits the first parenthesized group
// (the parameter list; a `-> (a, b)` return tuple comes after and is never
// reached) on top-level commas, tracking bracket depth so a comma inside a nested
// type (`b: proc(x: int)`, `c: [dynamic]int`) doesn't split a parameter. Returns
// an empty range when `active` is past the last parameter.
@(private = "file")
active_param_span :: proc(label: string, active: int) -> (int, int) {
    open := strings.index_byte(label, '(')
    if open < 0 {
        return 0, 0
    }
    depth := 0
    idx := 0
    param_start := open + 1
    for i := open; i < len(label); i += 1 {
        switch label[i] {
        case '(', '[', '{':
            depth += 1
        case ')', ']', '}':
            depth -= 1
            if depth == 0 {
                if idx == active {
                    return trim_span(label, param_start, i)
                }
                return 0, 0
            }
        case ',':
            if depth == 1 {
                if idx == active {
                    return trim_span(label, param_start, i)
                }
                idx += 1
                param_start = i + 1
            }
        }
    }
    return 0, 0
}

// Shrinks [start, end) past leading and trailing ASCII spaces/tabs.
@(private = "file")
trim_span :: proc(label: string, start, end: int) -> (int, int) {
    s, e := start, end
    for s < e && (label[s] == ' ' || label[s] == '\t') {
        s += 1
    }
    for e > s && (label[e - 1] == ' ' || label[e - 1] == '\t') {
        e -= 1
    }
    return s, e
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
// falls back to the .odin file whose name is fuzzily closest to the package name
// (a prefix like `foo_windows.odin` beats an unrelated `zebra.odin`), so the
// caret still lands on the most package-like file rather than reporting nothing.
// Hover shows the import path.
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
        pkg := filepath.base(dir)
        want := strings.concatenate({pkg, ".odin"}, context.temp_allocator)
        best_name := "" // the fuzzily-closest .odin file, the fallback target
        best_path := ""
        best_score := 0
        for info in infos {
            if info.type == .Directory || !strings.has_suffix(info.name, ".odin") {
                continue
            }
            if info.name == want {
                res.location = Location{path = strings.clone(info.fullpath), start = 0, end = 0}
                res.ok = true
                return
            }
            // Higher score is closer; ties break lexicographically for a stable pick.
            s := pkg_file_score(strings.trim_suffix(info.name, ".odin"), pkg)
            if best_name == "" || s > best_score || (s == best_score && info.name < best_name) {
                best_name = info.name
                best_path = info.fullpath
                best_score = s
            }
        }
        // No `foo.odin`: land on the closest file so navigation still works.
        if best_path != "" {
            res.location = Location{path = strings.clone(best_path), start = 0, end = 0}
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

// Fuzzy closeness of a file stem to the package name, higher is closer. A shared
// prefix and contiguous runs score highest, and a full subsequence match adds a
// bonus; when the package name isn't even a subsequence the shared-prefix length
// still orders the candidates, so the package-operand fallback always lands on
// the most package-like file (`foo_windows` over `zebra` for package `foo`).
@(private = "file")
pkg_file_score :: proc(stem, pkg: string) -> int {
    score := 0

    n := min(len(stem), len(pkg))
    prefix := 0
    for prefix < n && ascii_lower(stem[prefix]) == ascii_lower(pkg[prefix]) {
        prefix += 1
    }
    score += prefix * 8

    // Subsequence of pkg within stem, rewarding contiguous runs.
    qi := 0
    streak := 0
    for i in 0 ..< len(stem) {
        if qi >= len(pkg) {
            break
        }
        if ascii_lower(stem[i]) == ascii_lower(pkg[qi]) {
            score += 2 + streak
            streak += 1
            qi += 1
        } else {
            streak = 0
        }
    }
    if qi == len(pkg) {
        score += 20 // the whole package name is present in order
    }

    score -= abs(len(stem) - len(pkg)) / 4 // prefer a similar length
    return score
}

@(private = "file")
ascii_lower :: proc(b: u8) -> u8 {
    return b >= 'A' && b <= 'Z' ? b + 32 : b
}
