// In-client Odin analyzer: the first lang.Backend, running natively on the
// Manager's worker thread with no subprocess and no serialization. It parses
// with the vendored tree-sitter grammar, then resolves an identifier to its
// declaration using the grammar's LOCALS query for lexical scope, falling back
// to a workspace-wide scan of top-level declarations for cross-file symbols.
//
// The engine's lifetime and the Backend seam live here; the analysis is split
// by concern across the rest of the package (see resolve.odin for the entry
// point every request funnels through).
package odin

import "core:sync"

import lang ".."
import "../../treecache"
import ts "../../vendor/odin-tree-sitter"
import ts_odin "../../vendor/odin-tree-sitter/parsers/odin"

// Files scanned in one cross-file lookup, and directory depth, so a huge tree
// can't stall a goto. Mirrors thor_collect_files' guards.
@(private)
SCAN_FILE_LIMIT :: 4000
@(private)
SCAN_DEPTH_LIMIT :: 12

Engine :: struct {
    language: ts.Language,
    locals:   ts.Query, // compiled once, immutable, shared read-only across workers
    index:    Symbol_Index,
    config:   Config_Cache,
    // Resident per-buffer trees, so a request re-parses only what the last edit
    // touched. Scope: the request buffer only. The workspace files the
    // cross-file scans visit (`index_reparse`, `ref_scan_file`, `scan_file`, …)
    // are stat-gated by the symbol index and still parse whole — caching them
    // would thrash the slots for no win.
    trees:    treecache.Cache,
    // One compiler run at a time (see check_package): a second Diagnostics
    // request gives up here rather than starting a rival `odin check`.
    check_mutex: sync.Mutex,
    // The implicit scope — what `base:builtin` and `base:runtime` export — which
    // the semantic classifier needs before it can call any name undeclared. Built
    // once from the toolchain on disk and kept for the process: it is a property
    // of the installed compiler, not of the workspace, so nothing invalidates it.
    builtins:       Builtin_Cache,
    builtin_mutex:  sync.Mutex,
}

engine_create :: proc() -> ^Engine {
    e := new(Engine)
    e.language = ts_odin.tree_sitter_odin()
    query, _, err := ts.query_new(e.language, ts_odin.LOCALS)
    if err == .None {
        e.locals = query
    }
    e.index.alloc = context.allocator
    e.index.files = make(map[string]File_Entry, 0, e.index.alloc)
    e.config.alloc = context.allocator
    e.builtins.alloc = context.allocator
    treecache.init(&e.trees)
    return e
}

// Wraps the engine as a lang.Backend for lang.manager_register.
engine_backend :: proc(e: ^Engine) -> lang.Backend {
    return lang.Backend {
        data    = e,
        name    = "odin (in-client)",
        handles = handles,
        resolve = resolve,
        destroy = engine_destroy,
    }
}

@(private)
handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".odin"
}

@(private)
engine_destroy :: proc(data: rawptr) {
    e := cast(^Engine) data
    if e.locals != nil {
        ts.query_delete(e.locals)
    }
    index_clear(e)
    config_clear(e)
    builtins_clear(e)
    treecache.destroy(&e.trees)
    free(e)
}
