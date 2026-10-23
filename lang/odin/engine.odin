// In-client Odin analyzer: a lang.Backend that runs on the Manager's worker threads.
// It formats with the native printer, reports `odin check` diagnostics and the
// live syntax errors of the new parser, lists document and workspace symbols
// from the item trees of package odinsema, renders package documentation, and goes to
// definitions, finds references and renames through its scopes.
// Completion and the other kinds return with the new engine
// (`odin-analyzer-plan.md`); until then the engine declines them.
package odin

import "core:sync"

import lang ".."

Engine :: struct {
    config:        Config_Cache,
    format_config: Format_Config_Cache,
    parses:        Parse_Cache,
    index:         Symbol_Index,
    packages:      Package_Cache,
    root:          Odin_Root,
    // One compiler run at a time (see check_package).
    check_mutex:   sync.Mutex,
    // Settings-driven admin gate; main thread only.
    admin_enabled:  bool,
    admin_features: bit_set[lang.Request_Kind],
}

// The kinds the engine answers.
IMPLEMENTED :: bit_set[lang.Request_Kind]{
    .Diagnostics,
    .Syntax_Diagnostics,
    .Format,
    .Format_Range,
    .Format_On_Type,
    .Document_Symbols,
    .Workspace_Symbols,
    .Definition,
    .References,
    .Rename,
    .Package_Doc,
}

engine_create :: proc() -> ^Engine {
    e := new(Engine)
    e.admin_enabled = true
    e.admin_features = lang.FEATURES_ALL
    e.config.alloc = context.allocator
    e.format_config.alloc = context.allocator
    e.parses.alloc = context.allocator
    e.parses.entries = make([dynamic]Parse_Entry, 0, PARSE_CACHE_SLOTS + 1)
    e.index.alloc = context.allocator
    e.packages.alloc = context.allocator
    e.packages.entries = make([dynamic]^Package_Entry, 0, PACKAGE_CACHE_SLOTS + 1)
    e.root.alloc = context.allocator
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
        on_type_trigger = on_type_trigger,
    }
}

@(private)
handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".odin" && (cast(^Engine)data).admin_enabled
}

// Format-on-type fires on `}` only: it closes a block.
@(private)
ON_TYPE_TRIGGERS :: "}"

@(private)
on_type_trigger :: proc(data: rawptr, ext, char: string) -> bool {
    return ext == ".odin" && char == ON_TYPE_TRIGGERS
}

@(private)
supports :: proc(data: rawptr, ext: string, kind: lang.Request_Kind) -> bool {
    return kind in IMPLEMENTED && kind in (cast(^Engine)data).admin_features
}

engine_set_enabled :: proc(e: ^Engine, enabled: bool) {
    e.admin_enabled = enabled
}

engine_set_features :: proc(e: ^Engine, features: bit_set[lang.Request_Kind]) {
    e.admin_features = features
}

// Answers one request on a worker thread.
@(private)
resolve :: proc(data: rawptr, req: ^lang.Request, res: ^lang.Result) {
    e := cast(^Engine)data
    if lang.request_cancelled(req) {
        return
    }
    #partial switch req.kind {
    case .Diagnostics:
        check_package(e, req, res)
    case .Syntax_Diagnostics:
        syntax_diagnostics(e, req, res)
    case .Format:
        format_document(e, req, res, 0, len(req.source))
    case .Format_Range:
        format_document(e, req, res, req.offset, req.end)
    case .Format_On_Type:
        lo, hi := line_bounds(req.source, req.offset)
        format_document(e, req, res, lo, hi)
    case .Document_Symbols:
        if config_allows(e, req.workspace, req.kind) {
            document_symbols(e, req, res)
        }
    case .Workspace_Symbols:
        if config_allows(e, req.workspace, req.kind) {
            workspace_symbols(e, req, res)
        }
    case .Definition:
        if config_allows(e, req.workspace, req.kind) {
            definition(e, req, res)
        }
    case .References:
        if config_allows(e, req.workspace, req.kind) {
            references(e, req, res)
        }
    case .Rename:
        if config_allows(e, req.workspace, req.kind) {
            rename(e, req, res)
        }
    case .Package_Doc:
        if config_allows(e, req.workspace, req.kind) {
            package_doc(e, req, res)
        }
    }
}

@(private)
engine_destroy :: proc(data: rawptr) {
    e := cast(^Engine)data
    config_clear(e)
    format_config_clear(e)
    parse_cache_clear(&e.parses)
    index_clear(&e.index)
    package_cache_clear(&e.packages)
    odin_root_clear(&e.root)
    free(e)
}
