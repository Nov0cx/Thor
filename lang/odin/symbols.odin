// The list-shaped features: document and workspace symbol outlines, and rename.
// The reference scan both of the latter stand on lives in references.odin.
package odin

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

// Renames the symbol under the caret to `req.new_name`, returning the
// replacements as `res.edits` rather than touching any file — the editor applies
// them, so the change lands in an open buffer's undo history instead of behind
// its back. Every occurrence find-references would list becomes one edit, so
// rename inherits that reach *and* its precision: each occurrence is one the
// reference scan proved binds to the same declaration — a local to its own
// scope, a package symbol to its package (bare there, qualified elsewhere), a
// field to the struct declaring it — and one it could not judge stays in, since
// a usage left behind is code left broken. Answers nothing when the caret is not
// on an identifier or the new name isn't a legal Odin one.
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
