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

import "core:log"
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
    format_config: Format_Config_Cache,
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
    // Settings-driven admin gate; main-thread only, like the Manager's own
    // enabled/features (handles/supports are never called off the main thread).
    admin_enabled:  bool,
    admin_features: bit_set[lang.Request_Kind],
}

engine_create :: proc() -> ^Engine {
    e := new(Engine)
    e.admin_enabled = true
    e.admin_features = lang.FEATURES_ALL
    e.language = ts_odin.tree_sitter_odin()
    // Without it resolve answers nothing for every kind past formatting, which
    // reads as "found nothing" rather than as a broken engine — so say so.
    query, offset, err := ts.query_new(e.language, ts_odin.LOCALS)
    if err == .None {
        e.locals = query
    } else {
        log.errorf("odin: the LOCALS query failed at byte %d: %v", offset, err)
    }
    e.index.alloc = context.allocator
    e.index.files = make(map[string]File_Entry, 0, e.index.alloc)
    e.config.alloc = context.allocator
    e.format_config.alloc = context.allocator
    e.builtins.alloc = context.allocator
    treecache.init(&e.trees)
    return e
}

// Wraps the engine as a lang.Backend for lang.manager_register.
engine_backend :: proc(e: ^Engine) -> lang.Backend {
    return lang.Backend {
        data            = e,
        name            = "odin (in-client)",
        handles         = handles,
        resolve         = resolve,
        destroy         = engine_destroy,
        supports        = supports,
        notify          = notify,
        on_type_trigger = on_type_trigger,
    }
}

@(private)
handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".odin" && (cast(^Engine)data).admin_enabled
}

// The characters that fire format-on-type. Only `}`: it closes a block, which
// is the one keystroke whose reindent the typist expects, and mid-line typing
// leaves the buffer unparseable, which the printer refuses anyway.
@(private)
ON_TYPE_TRIGGERS :: "}"

@(private)
on_type_trigger :: proc(data: rawptr, ext, char: string) -> bool {
    return ext == ".odin" && char == ON_TYPE_TRIGGERS
}

// Both are server-side seams: an in-client analyzer answers with edits computed
// up front, so it has no command to run and nothing about a candidate left to
// resolve. Declined outright rather than left to answer ok=false.
@(private)
UNSUPPORTED :: bit_set[lang.Request_Kind]{.Execute_Command, .Resolve_Completion}

// The settings-driven per-kind gate: every capability the engine has
// (definition, goto, completion, formatting, …) is unconditional, so only a
// kind the config turned off for this engine specifically, or one the engine
// never implements, answers false here.
@(private)
supports :: proc(data: rawptr, ext: string, kind: lang.Request_Kind) -> bool {
    if kind in UNSUPPORTED {
        return false
    }
    return kind in (cast(^Engine)data).admin_features
}

engine_set_enabled :: proc(e: ^Engine, enabled: bool) {
    e.admin_enabled = enabled
}

engine_set_features :: proc(e: ^Engine, features: bit_set[lang.Request_Kind]) {
    e.admin_features = features
}

// The engine keeps no document mirror — it reads the buffer out of each request
// — so only a save is of interest: it drops the file's index entry, and the next
// cross-file lookup re-parses it.
@(private)
notify :: proc(data: rawptr, event: lang.Doc_Event, path, ext, source: string, revision: u64) {
    if event != .Saved {
        return
    }
    index_forget(cast(^Engine)data, path)
}

@(private)
engine_destroy :: proc(data: rawptr) {
    e := cast(^Engine) data
    if e.locals != nil {
        ts.query_delete(e.locals)
    }
    index_clear(e)
    config_clear(e)
    format_config_clear(e)
    builtins_clear(e)
    treecache.destroy(&e.trees)
    free(e)
}
