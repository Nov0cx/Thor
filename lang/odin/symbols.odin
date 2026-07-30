// The list-shaped features: document and workspace symbol outlines, reference
// search, and rename.
package odin

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// Appends `source`'s top-level declarations (in `path`) to res.symbols. Reuses
// collect_defs — the same walk go-to-definition uses — and keeps only the
// file-scope symbols a symbol list should show (procedures, types, enums,
// constants and package-level vars), dropping parameters, struct fields, labels
// and the package/import namespace captures. Each field is cloned into
// context.allocator (the Manager's), freed on the main thread after the editor
// reads them; the signature is the real Odin declaration line.
@(private)
collect_symbols_into :: proc(e: ^Engine, root: ts.Node, source, path: string, res: ^lang.Result) {
    defs := collect_defs(e, root, source)
    for d in defs {
        if !d.top_level || !symbol_kind_shown(d.kind) {
            continue
        }
        ident_start := clamp(d.ident_start, 0, len(source))
        append(&res.symbols, lang.Symbol {
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
@(private)
collect_document_symbols :: proc(e: ^Engine, root: ts.Node, source, path: string, res: ^lang.Result) {
    collect_symbols_into(e, root, source, path, res)
    slice.sort_by(res.symbols[:], proc(a, b: lang.Symbol) -> bool {
        return a.offset < b.offset
    })
    res.ok = true
}

// Fills `res` with every top-level declaration across the workspace: the live
// buffer first (so unsaved edits win over its on-disk copy, which is skipped),
// then every other file straight from the symbol index (no re-parse of unchanged
// files). Sorted by name (ties by path) for a stable, fuzzy-searchable list.
@(private)
collect_workspace_symbols :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    if req.path != "" {
        collect_symbols_into(e, root, req.source, req.path, res)
    }
    if req.workspace != "" {
        sync.lock(&e.index.mutex)
        index_sync(e, parser, req)
        index_all_symbols(e, req.path, res)
        sync.unlock(&e.index.mutex)
    }
    slice.sort_by(res.symbols[:], proc(a, b: lang.Symbol) -> bool {
        if a.name != b.name {
            return a.name < b.name
        }
        return a.path < b.path
    })
    res.ok = true
}

// Gathers every occurrence of the identifier under the caret ("find usages").
// The kind of match is chosen by resolution: a name that binds to a local or a
// parameter is confined to that declaration's scope in this one file (so an `x`
// in one procedure never lists an unrelated `x` in another); anything else —
// top-level, or a name that doesn't resolve locally — is matched by name across
// the whole workspace, mirroring how cross-file goto flat-matches top-level
// names (no package/type awareness yet, so this is textual-but-AST-aware). Each
// occurrence becomes a lang.Symbol carrying its file, line, offset and the source
// line it sits on for a code-context preview.
@(private)
collect_references :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    name := ts.node_text(ident, req.source)

    defs := collect_defs(e, root, req.source)
    if d, found := resolve_local(defs[:], name, req.offset); found && !d.top_level {
        // Local / parameter: only its own scope in this file, and for an
        // order-dependent local only from its declaration on — an earlier use in
        // the same block names whatever this one shadows.
        start := d.visible_from > 0 ? d.ident_start : d.scope_start
        collect_ident_refs(root, req.source, name, req.path, start, d.scope_end, res)
    } else {
        // Top-level or unresolved: this whole buffer, then every workspace file
        // the index says mentions the name (the rest can't contain a usage).
        collect_ident_refs(root, req.source, name, req.path, 0, len(req.source), res)
        if req.workspace != "" {
            paths := make([dynamic]string, context.temp_allocator)
            sync.lock(&e.index.mutex)
            index_sync(e, parser, req)
            index_ref_files(e, name, req.path, &paths)
            sync.unlock(&e.index.mutex)
            for path in paths {
                if lang.request_cancelled(req) {
                    return
                }
                ref_scan_file(e, parser, path, name, res)
            }
        }
    }

    slice.sort_by(res.symbols[:], proc(a, b: lang.Symbol) -> bool {
        if a.path != b.path {
            return a.path < b.path
        }
        return a.offset < b.offset
    })
    res.ok = len(res.symbols) > 0
}

// Appends every `identifier` node in `node`'s subtree whose text equals `name`
// and whose span falls within [within_start, within_end) to res.symbols. Each is
// a reference lang.Symbol: the source line it sits on is the preview, path/line/offset
// the jump target. Owned strings use context.allocator (the Manager's).
@(private)
collect_ident_refs :: proc(node: ts.Node, source, name, path: string, within_start, within_end: int, res: ^lang.Result) {
    if is_identifier(node) {
        s := int(ts.node_start_byte(node))
        end := int(ts.node_end_byte(node))
        if s >= within_start && end <= within_end && ts.node_text(node, source) == name {
            append(&res.symbols, lang.Symbol {
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
@(private)
source_line :: proc(source: string, offset: int) -> string {
    lo := clamp(offset, 0, len(source))
    start := strings.last_index_byte(source[:lo], '\n') + 1 // -1 + 1 == 0 for the first line
    end := len(source)
    if nl := strings.index_byte(source[lo:], '\n'); nl >= 0 {
        end = lo + nl
    }
    return strings.clone(strings.trim_space(source[start:end]))
}

// Re-parses one workspace file and appends its occurrences of `name` to `res`.
// Called only for files the index flagged as mentioning the name.
@(private)
ref_scan_file :: proc(e: ^Engine, parser: ts.Parser, path, name: string, res: ^lang.Result) {
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

// Renames the symbol under the caret to `req.new_name`, returning the
// replacements as `res.edits` rather than touching any file — the editor applies
// them, so the change lands in an open buffer's undo history instead of behind
// its back. Every occurrence find-references would list becomes one edit, so
// rename inherits that reach *and* its imprecision: a local or parameter is
// confined to its declaration's scope in this file, but a top-level name is
// matched across the workspace, and until the type layer lands an unrelated
// same-named symbol in another package is renamed with it. Answers nothing when
// the caret is not on an identifier or the new name isn't a legal Odin one.
@(private)
rename :: proc(e: ^Engine, parser: ts.Parser, root: ts.Node, req: ^lang.Request, res: ^lang.Result) {
    if !valid_identifier(req.new_name) {
        return
    }
    ident, ok := identifier_at(root, req.source, req.offset)
    if !ok {
        return
    }
    name := ts.node_text(ident, req.source)
    if name == req.new_name {
        return // renaming to itself: no edits, nothing to apply
    }

    collect_references(e, parser, root, req, res)
    if !res.ok {
        return
    }

    // The reference rows are consumed here: each one's span becomes an edit and
    // its `path` moves into that edit, so a rename result carries edits alone
    // and the display-only fields are freed rather than handed to the editor.
    for sym in res.symbols {
        append(&res.edits, lang.Text_Edit {
            path     = sym.path,
            start    = sym.offset,
            end      = sym.offset + len(name),
            old_text = strings.clone(name),
            new_text = strings.clone(req.new_name),
        })
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
    }
    delete(res.symbols)
    res.symbols = nil // handed over to `edits`; job_free must not free it twice
    res.ok = len(res.edits) > 0
}

// True when `s` can be written as an Odin identifier: a leading letter or `_`,
// then letters, digits and `_`, and not a keyword or builtin type name.
@(private)
valid_identifier :: proc(s: string) -> bool {
    if s == "" || (s[0] >= '0' && s[0] <= '9') {
        return false
    }
    for i in 0 ..< len(s) {
        if !is_word_byte(s[i]) {
            return false
        }
    }
    for kw in ODIN_KEYWORDS {
        if s == kw {
            return false
        }
    }
    return true
}
