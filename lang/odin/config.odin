// Per-workspace analyzer configuration, read from
// `<workspace>/.thor/odin-analyzer.json` and cached on the engine.
package odin

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import lang ".."

// Per-workspace language-backend config, read from `<workspace>/.thor/` — the
// same workspace config folder Thor keeps its `settings.json` in. Thor's own
// file (not `ols.json`), though the shape — a `collections` array, `enable_*`
// toggles — is deliberately familiar.
@(private)
WORKSPACE_CONFIG_DIR :: ".thor"
@(private)
ANALYZER_CONFIG :: "odin-analyzer.json"

// Language-backend settings for one workspace, read from
// `<workspace>/.thor/odin-analyzer.json`. Only the settings the in-client engine
// can act on are kept: import collections (a name → its root directory, so `import
// "shared:foo"` resolves) and the feature-enable toggles. Absent keys take the
// defaults — no collections, every feature on.
@(private)
Config :: struct {
    collections:             map[string]string, // name → resolved absolute dir
    enable_hover:            bool,
    enable_document_symbols: bool,
    enable_references:       bool,
    enable_rename:           bool,
}

// The engine's cached view of one workspace's config file, guarded by its own
// mutex and stat-invalidated exactly like the symbol index: the file is re-read only
// when the workspace changes or its modtime/size moves, so the common request
// pays a single `stat`, not a parse. A missing or malformed file still caches
// the defaults (so a miss isn't re-parsed every request). Owned strings use
// `alloc` (the engine allocator), never the per-request Manager allocator.
@(private)
Config_Cache :: struct {
    mutex:     sync.Mutex,
    alloc:     runtime.Allocator,
    workspace: string, // engine-owned; the workspace this was loaded for
    loaded:    bool,
    modtime:   i64,
    size:      i64,
    cfg:       Config,
}

// Ensures the cache reflects `<workspace>/.thor/odin-analyzer.json` on disk. Rebuilds when the
// workspace changed or the file's stat moved; otherwise leaves the parsed view
// in place. All owned storage lands in the engine allocator (context set
// locally, so callees inherit it). Caller holds cache.mutex.
@(private)
config_ensure :: proc(cache: ^Config_Cache, workspace: string) {
    if workspace == "" {
        return
    }
    context.allocator = cache.alloc // every clone/make below is engine-owned

    path, jerr := filepath.join({workspace, WORKSPACE_CONFIG_DIR, ANALYZER_CONFIG}, context.temp_allocator)
    if jerr != nil {
        return
    }
    present := false
    mt, sz: i64
    if info, err := os.stat(path, context.temp_allocator); err == nil {
        present = true
        mt = info.modification_time._nsec
        sz = info.size
    }

    if cache.loaded && cache.workspace == workspace && cache.modtime == mt && cache.size == sz {
        return // unchanged since last read — keep the parsed view
    }

    config_free(cache)
    cache.cfg = config_defaults()
    if cache.workspace != workspace {
        delete(cache.workspace, cache.alloc)
        cache.workspace = strings.clone(workspace)
    }
    cache.loaded = true
    cache.modtime = mt
    cache.size = sz

    if present {
        config_parse(cache, workspace, path)
    }
}

// A fresh Config with the defaults: no collections, every feature on. Uses
// context.allocator (the engine allocator, set by config_ensure).
@(private)
config_defaults :: proc() -> Config {
    return Config {
        collections             = make(map[string]string),
        enable_hover            = true,
        enable_document_symbols = true,
        enable_references       = true,
        enable_rename           = true,
    }
}

// Parses the config file into `cache.cfg`, layering onto the defaults already in
// place: the recognized `enable_*` booleans and every `collections` entry (a
// relative path resolves against the workspace, an absolute one is used as-is).
// Unknown keys are ignored, so the file can carry settings this engine doesn't
// act on. context.allocator is the engine allocator (set by config_ensure).
@(private)
config_parse :: proc(cache: ^Config_Cache, workspace, path: string) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return
    }
    value, perr := json.parse(data, allocator = context.temp_allocator)
    if perr != .None {
        return
    }
    obj, ook := value.(json.Object)
    if !ook {
        return
    }

    if b, ok := obj["enable_hover"].(json.Boolean); ok {
        cache.cfg.enable_hover = bool(b)
    }
    if b, ok := obj["enable_document_symbols"].(json.Boolean); ok {
        cache.cfg.enable_document_symbols = bool(b)
    }
    if b, ok := obj["enable_references"].(json.Boolean); ok {
        cache.cfg.enable_references = bool(b)
    }
    if b, ok := obj["enable_rename"].(json.Boolean); ok {
        cache.cfg.enable_rename = bool(b)
    }

    arr, aok := obj["collections"].(json.Array)
    if !aok {
        return
    }
    for item in arr {
        entry, eok := item.(json.Object)
        if !eok {
            continue
        }
        name, nok := entry["name"].(json.String)
        p, pok := entry["path"].(json.String)
        if !nok || !pok || name == "" || p == "" {
            continue
        }
        dir: string
        if filepath.is_abs(p) {
            dir = strings.clone(p)
        } else {
            joined, jerr := filepath.join({workspace, p})
            if jerr != nil {
                continue
            }
            dir = joined
        }
        // Last entry for a name wins (mirrors a map assignment); free the prior.
        if old, exists := cache.cfg.collections[name]; exists {
            delete(old, cache.alloc)
            cache.cfg.collections[name] = dir
        } else {
            cache.cfg.collections[strings.clone(name)] = dir
        }
    }
}

// Resolved root directory of the workspace-defined collection `coll`, or false
// when the config declares no such collection. The path is cloned into scratch
// so it outlives the lock.
@(private)
config_collection_dir :: proc(e: ^Engine, coll, workspace: string) -> (string, bool) {
    if workspace == "" || coll == "" {
        return "", false
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    if dir, ok := cache.cfg.collections[coll]; ok {
        return strings.clone(dir, context.temp_allocator), true
    }
    return "", false
}

// True when the workspace config permits the feature the request `kind` serves.
// Kinds with no toggle (definition, workspace symbols, signature help,
// completion) are always on; the four gated ones — hover, document symbols,
// references, rename — honor the config, defaulting to on when unset.
@(private)
config_allows :: proc(e: ^Engine, workspace: string, kind: lang.Request_Kind) -> bool {
    #partial switch kind {
    case .Hover, .Document_Symbols, .References, .Rename:
    case:
        return true
    }
    if workspace == "" {
        return true // no workspace, no config to consult — defaults are all on
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    #partial switch kind {
    case .Hover:
        return cache.cfg.enable_hover
    case .Document_Symbols:
        return cache.cfg.enable_document_symbols
    case .References:
        return cache.cfg.enable_references
    case .Rename:
        return cache.cfg.enable_rename
    }
    return true
}

// Frees the cached config's owned collection strings and the map itself. Element
// deletes name the engine allocator explicitly (the map may be torn down from a
// context whose allocator differs, as in engine_destroy).
@(private)
config_free :: proc(cache: ^Config_Cache) {
    for name, dir in cache.cfg.collections {
        delete(name, cache.alloc)
        delete(dir, cache.alloc)
    }
    delete(cache.cfg.collections)
    cache.cfg.collections = nil
}

// Tears the whole config cache down on destroy: its collections and the stored
// workspace path.
@(private)
config_clear :: proc(e: ^Engine) {
    cache := &e.config
    config_free(cache)
    delete(cache.workspace, cache.alloc)
    cache.workspace = ""
    cache.loaded = false
}
