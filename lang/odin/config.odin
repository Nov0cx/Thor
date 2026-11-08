// Per-workspace analyzer configuration, read from
// `<workspace>/.thor/odin-analyzer.lua` and cached on the engine.
package odin

import "base:runtime"
import "core:encoding/json"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import lang ".."
import "../../luaconf"
import odinsema "sema"

// Per-workspace language-backend config, read from `<workspace>/.thor/` — the
// same workspace config folder Thor keeps its `settings.lua` in. Thor's own
// file (not `ols.json`), though the shape — a `collections` array, `enable_*`
// toggles — is deliberately familiar.
@(private)
WORKSPACE_CONFIG_DIR :: ".thor"
@(private)
ANALYZER_CONFIG :: "odin-analyzer.lua"

// Language-backend settings for one workspace, read from
// `<workspace>/.thor/odin-analyzer.lua`. Only the settings the in-client engine
// can act on are kept: import collections (a name → its root directory, so `import
// "shared:foo"` resolves), the feature-enable toggles, the target, the defines and the
// severity of each live diagnostic id. Absent keys take the defaults — no collections,
// every feature on, the host target, every diagnostic an error.
@(private)
Config :: struct {
    severities:              map[string]Severity_Setting, // owned ids from `"diagnostics"`
    collections:             map[string]string, // name → resolved absolute dir
    target_os:               odinsema.Target_OS,   // .Unknown when not set
    target_arch:             odinsema.Target_Arch, // .Unknown when not set
    defines:                 [dynamic]odinsema.Target_Define, // owned names and string values
    enable_hover:            bool,
    enable_document_symbols: bool,
    enable_references:       bool,
    enable_rename:           bool,
    enable_completion:       bool,
    enable_snippets:         bool, // completion inserts a procedure call with its parameters as stops
    inlay_types:             bool, // inlay hints show the type of a `:=` name
    inlay_parameters:        bool, // inlay hints show the parameter name of an argument
    package_diagnostics:     bool, // live diagnostics also cover the other files of the package
    diagnostics_telemetry:   bool, // the compiler check logs where it and the live check disagree
    naming:                  odinsema.Naming_Rules, // the spellings `style/naming` accepts
}

// What `"diagnostics": {"<id>": ...}` sets for the live diagnostics of one id.
@(private)
Severity_Setting :: enum u8 {
    Off,
    Hint,
    Warning,
    Error,
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

// Ensures the cache reflects `<workspace>/.thor/odin-analyzer.lua` on disk. Rebuilds when the
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
        severities              = make(map[string]Severity_Setting),
        defines                 = make([dynamic]odinsema.Target_Define),
        enable_hover            = true,
        enable_document_symbols = true,
        enable_references       = true,
        enable_rename           = true,
        enable_completion       = true,
        enable_snippets         = true,
        inlay_types             = true,
        inlay_parameters        = true,
        naming                  = odinsema.DEFAULT_NAMING_RULES,
    }
}

// Parses the config file into `cache.cfg`, layering onto the defaults already in
// place: the recognized `enable_*` booleans and every `collections` entry (a
// relative path resolves against the workspace, an absolute one is used as-is).
// Unknown keys are ignored, so the file can carry settings this engine doesn't
// act on. context.allocator is the engine allocator (set by config_ensure).
@(private)
config_parse :: proc(cache: ^Config_Cache, workspace, path: string) {
    value, status, message := luaconf.eval_file(path)
    if status == .Failed {
        log.warnf("odin-analyzer.lua: %s", message)
    }
    obj, ook := value.(json.Object)
    if status != .Ok || !ook {
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
    if b, ok := obj["enable_completion"].(json.Boolean); ok {
        cache.cfg.enable_completion = bool(b)
    }
    if b, ok := obj["enable_snippets"].(json.Boolean); ok {
        cache.cfg.enable_snippets = bool(b)
    }
    if b, ok := obj["inlay_types"].(json.Boolean); ok {
        cache.cfg.inlay_types = bool(b)
    }
    if b, ok := obj["inlay_parameters"].(json.Boolean); ok {
        cache.cfg.inlay_parameters = bool(b)
    }
    if b, ok := obj["package_diagnostics"].(json.Boolean); ok {
        cache.cfg.package_diagnostics = bool(b)
    }
    if b, ok := obj["diagnostics_telemetry"].(json.Boolean); ok {
        cache.cfg.diagnostics_telemetry = bool(b)
    }

    config_parse_target(cache, obj)
    config_parse_diagnostics(cache, obj)
    config_parse_naming(cache, obj)

    arr, aok := luaconf.as_array(obj["collections"])
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
        if !is_collection_name(name) {
            log.warnf("odin-analyzer.lua: collection name %q is not an identifier and was dropped", name)
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

// Reads `"diagnostics": {"<id>": "off" | "hint" | "warning" | "error"}`. An unknown id or value is dropped
// with a warning. context.allocator is the engine allocator.
@(private = "file")
config_parse_diagnostics :: proc(cache: ^Config_Cache, obj: json.Object) {
    raw, has := obj["diagnostics"]
    if !has {
        return
    }
    entries, ok := raw.(json.Object)
    if !ok {
        log.warnf("odin-analyzer.lua: \"diagnostics\" is not an object and was ignored")
        return
    }
    for id, value in entries {
        if !known_code(id) {
            log.warnf("odin-analyzer.lua: diagnostic id %q is unknown and was dropped", id)
            continue
        }
        text, is_string := value.(json.String)
        setting: Severity_Setting
        switch {
        case is_string && text == "off":
            setting = .Off
        case is_string && text == "hint":
            setting = .Hint
        case is_string && text == "warning":
            setting = .Warning
        case is_string && text == "error":
            setting = .Error
        case:
            log.warnf("odin-analyzer.lua: severity of %q is not \"off\", \"hint\", \"warning\" or \"error\" and was dropped", id)
            continue
        }
        if _, exists := cache.cfg.severities[id]; exists {
            cache.cfg.severities[id] = setting
        } else {
            cache.cfg.severities[strings.clone(id)] = setting
        }
    }
}

// Reads `"naming": {"type": "ada_case", ...}`. The keys are `type`, `proc`, `variable`, `constant` and
// `enum_member`; a value is `"ada_case"`, `"snake_case"`, `"screaming_snake_case"` or `"any"`, which
// switches the rule off. An unknown key or value is dropped with a warning.
@(private = "file")
config_parse_naming :: proc(cache: ^Config_Cache, obj: json.Object) {
    raw, has := obj["naming"]
    if !has {
        return
    }
    entries, ok := raw.(json.Object)
    if !ok {
        log.warnf("odin-analyzer.lua: \"naming\" is not an object and was ignored")
        return
    }
    for key, value in entries {
        rule: ^odinsema.Name_Styles
        switch key {
        case "type":        rule = &cache.cfg.naming.type
        case "proc":        rule = &cache.cfg.naming.procedure
        case "variable":    rule = &cache.cfg.naming.variable
        case "constant":    rule = &cache.cfg.naming.constant
        case "enum_member": rule = &cache.cfg.naming.enum_member
        case:
            log.warnf("odin-analyzer.lua: naming key %q is unknown and was dropped", key)
            continue
        }
        text, is_string := value.(json.String)
        if is_string && text == "any" {
            rule^ = {}
        } else if style, known := odinsema.style_from_key(text); is_string && known {
            rule^ = {style}
        } else {
            log.warnf("odin-analyzer.lua: naming of %q is not \"ada_case\", \"snake_case\", \"screaming_snake_case\" or \"any\" and was dropped", key)
        }
    }
}

// Reads `"target": {"os": "linux", "arch": "amd64"}` and `"defines": {"NAME": value}`, where a value is
// a boolean, an integer or a string. context.allocator is the engine allocator.
@(private)
config_parse_target :: proc(cache: ^Config_Cache, obj: json.Object) {
    if raw, has := obj["target"]; has {
        target, tok := raw.(json.Object)
        if !tok {
            log.warnf("odin-analyzer.lua: \"target\" is not an object and was ignored")
        }
        if os_name, ok := target["os"].(json.String); tok && ok {
            cache.cfg.target_os = odinsema.target_os_from_string(os_name)
            if cache.cfg.target_os == .Unknown {
                log.warnf("odin-analyzer.lua: target os %q is unknown and was ignored", os_name)
            }
        } else if tok && "os" in target {
            log.warnf("odin-analyzer.lua: target os is not a string and was ignored")
        }
        if arch_name, ok := target["arch"].(json.String); tok && ok {
            cache.cfg.target_arch = odinsema.target_arch_from_string(arch_name)
            if cache.cfg.target_arch == .Unknown {
                log.warnf("odin-analyzer.lua: target arch %q is unknown and was ignored", arch_name)
            }
        } else if tok && "arch" in target {
            log.warnf("odin-analyzer.lua: target arch is not a string and was ignored")
        }
    }

    config_validate_target(cache)

    raw, has := obj["defines"]
    if !has {
        return
    }
    defines, dok := raw.(json.Object)
    if !dok {
        log.warnf("odin-analyzer.lua: \"defines\" is not an object and was ignored")
        return
    }
    for name, value in defines {
        if !is_collection_name(name) {
            log.warnf("odin-analyzer.lua: define name %q is not an identifier and was dropped", name)
            continue
        }
        d: odinsema.Define_Value
        #partial switch v in value {
        case json.Boolean:
            d = bool(v)
        case json.Integer:
            d = i64(v)
        case json.Float:
            if f64(i64(v)) != f64(v) {
                log.warnf("odin-analyzer.lua: define %q is not an integer and was dropped", name)
                continue
            }
            d = i64(v)
        case json.String:
            d = strings.clone(v)
        case:
            log.warnf("odin-analyzer.lua: define %q is not a boolean, integer or string and was dropped", name)
            continue
        }
        append(&cache.cfg.defines, odinsema.Target_Define{name = strings.clone(name), value = d})
    }
}

// The `-target:` value of an os and arch pair, empty when the compiler has no such target.
@(private)
target_triple :: proc(target_os: odinsema.Target_OS, arch: odinsema.Target_Arch) -> string {
    #partial switch target_os {
    case .Windows:
        #partial switch arch {
        case .amd64: return "windows_amd64"
        case .i386:  return "windows_i386"
        case .arm64: return "windows_arm64"
        }
    case .Linux:
        #partial switch arch {
        case .amd64: return "linux_amd64"
        case .i386:  return "linux_i386"
        case .arm64: return "linux_arm64"
        case .arm32: return "linux_arm32"
        case .riscv64: return "linux_riscv64"
        }
    case .Darwin:
        #partial switch arch {
        case .amd64: return "darwin_amd64"
        case .arm64: return "darwin_arm64"
        }
    case .FreeBSD:
        #partial switch arch {
        case .amd64: return "freebsd_amd64"
        case .arm64: return "freebsd_arm64"
        case .i386:  return "freebsd_i386"
        }
    case .OpenBSD:
        if arch == .amd64 {
            return "openbsd_amd64"
        }
    case .NetBSD:
        #partial switch arch {
        case .amd64: return "netbsd_amd64"
        case .arm64: return "netbsd_arm64"
        }
    case .Haiku:
        if arch == .amd64 {
            return "haiku_amd64"
        }
    case .WASI:
        #partial switch arch {
        case .wasm32: return "wasi_wasm32"
        case .wasm64p32: return "wasi_wasm64p32"
        }
    case .JS:
        #partial switch arch {
        case .wasm32: return "js_wasm32"
        case .wasm64p32: return "js_wasm64p32"
        }
    case .Orca:
        if arch == .wasm32 {
            return "orca_wasm32"
        }
    case .Freestanding:
        #partial switch arch {
        case .wasm32: return "freestanding_wasm32"
        case .wasm64p32: return "freestanding_wasm64p32"
        case .amd64: return "freestanding_amd64_sysv"
        case .arm64: return "freestanding_arm64"
        case .riscv64: return "freestanding_riscv64"
        }
    }
    return ""
}

// Drops a configured os and arch pair the compiler has no target for. A key left unset takes the host's.
// context.allocator is the engine allocator.
@(private = "file")
config_validate_target :: proc(cache: ^Config_Cache) {
    if cache.cfg.target_os == .Unknown && cache.cfg.target_arch == .Unknown {
        return
    }
    host := odinsema.target_host()
    target_os := cache.cfg.target_os != .Unknown ? cache.cfg.target_os : host.os
    arch := cache.cfg.target_arch != .Unknown ? cache.cfg.target_arch : host.arch
    if target_triple(target_os, arch) == "" {
        log.warnf("odin-analyzer.lua: target %v/%v is not a compiler target and was ignored", target_os, arch)
        cache.cfg.target_os = .Unknown
        cache.cfg.target_arch = .Unknown
    }
}

// The target a workspace is analyzed for: the host, overlaid by the os, arch and defines of its config.
// The defines are cloned into context.temp_allocator, so the target outlives the lock.
@(private)
config_target :: proc(e: ^Engine, workspace: string) -> odinsema.Target {
    target := odinsema.target_host()
    if workspace == "" {
        return target
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    if cache.cfg.target_os != .Unknown {
        target.os = cache.cfg.target_os
    }
    if cache.cfg.target_arch != .Unknown {
        target.arch = cache.cfg.target_arch
    }
    if len(cache.cfg.defines) == 0 {
        return target
    }
    defines, err := make([]odinsema.Target_Define, len(cache.cfg.defines), context.temp_allocator)
    if err != nil {
        return target
    }
    for d, i in cache.cfg.defines {
        value := d.value
        if s, is_string := value.(string); is_string {
            value = strings.clone(s, context.temp_allocator)
        }
        defines[i] = {name = strings.clone(d.name, context.temp_allocator), value = value}
    }
    target.defines = defines
    return target
}

// True for a name the compiler takes as a collection: an identifier. The name
// goes into a compiler argument, so nothing else is let through.
@(private)
is_collection_name :: proc(name: string) -> bool {
    if name == "" {
        return false
    }
    for index in 0 ..< len(name) {
        switch name[index] {
        case 'a' ..= 'z', 'A' ..= 'Z', '_':
            continue
        case '0' ..= '9':
            if index > 0 {
                continue
            }
        }
        return false
    }
    return true
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

// One workspace-declared collection: its name and its resolved root directory.
@(private)
Collection :: struct {
    name: string,
    dir:  string,
}

// Names of every collection the workspace config declares, cloned into scratch
// so they outlive the lock. Lets a caller that has no particular collection in
// mind — searching them all for a package, as the add-import action does — reach
// them without holding the config mutex while it walks the disk.
@(private)
config_collection_names :: proc(e: ^Engine, workspace: string) -> []string {
    colls := config_collections(e, workspace)
    out := make([dynamic]string, 0, len(colls), context.temp_allocator)
    for c in colls {
        append(&out, c.name)
    }
    return out[:]
}

// Every collection the workspace config declares, cloned into scratch so the
// pairs outlive the lock. For a caller that needs both halves at once — the
// `-collection:` flags an `odin check` run is given.
@(private)
config_collections :: proc(e: ^Engine, workspace: string) -> []Collection {
    out := make([dynamic]Collection, context.temp_allocator)
    if workspace == "" {
        return out[:]
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    for name, dir in cache.cfg.collections {
        append(
            &out,
            Collection {
                name = strings.clone(name, context.temp_allocator),
                dir = strings.clone(dir, context.temp_allocator),
            },
        )
    }
    return out[:]
}

// True when the workspace config permits the feature the request `kind` serves.
// Kinds with no toggle (definition, signature help) are always on; the gated
// ones — hover, document symbols, references, rename, completion — honor the
// config, defaulting to on when unset.
@(private)
config_allows :: proc(e: ^Engine, workspace: string, kind: lang.Request_Kind) -> bool {
    #partial switch kind {
    case .Hover, .Document_Symbols, .Workspace_Symbols, .References, .Rename, .Completion:
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
    case .Document_Symbols, .Workspace_Symbols:
        return cache.cfg.enable_document_symbols
    case .References:
        return cache.cfg.enable_references
    case .Rename:
        return cache.cfg.enable_rename
    case .Completion:
        return cache.cfg.enable_completion
    }
    return true
}

// The severity the workspace config sets for each diagnostic id, cloned into context.temp_allocator
// so it outlives the lock. Empty when the workspace has no config.
@(private)
config_severities :: proc(e: ^Engine, workspace: string) -> map[string]Severity_Setting {
    out := make(map[string]Severity_Setting, context.temp_allocator)
    if workspace == "" {
        return out
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    for id, setting in cache.cfg.severities {
        out[strings.clone(id, context.temp_allocator)] = setting
    }
    return out
}

// The spellings `style/naming` accepts in the workspace; the defaults when it has no config.
@(private)
config_naming :: proc(e: ^Engine, workspace: string) -> odinsema.Naming_Rules {
    if workspace == "" {
        return odinsema.DEFAULT_NAMING_RULES
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    return cache.cfg.naming
}

// True when completion inserts procedure snippets; on when the workspace has no config.
@(private)
config_snippets :: proc(e: ^Engine, workspace: string) -> bool {
    if workspace == "" {
        return true
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    return cache.cfg.enable_snippets
}

// Which inlay hints the workspace config turns on; both when the workspace has no config.
@(private)
config_inlays :: proc(e: ^Engine, workspace: string) -> (types, parameters: bool) {
    if workspace == "" {
        return true, true
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    return cache.cfg.inlay_types, cache.cfg.inlay_parameters
}

// True when the workspace config turns on live diagnostics for the whole package; off by default.
@(private)
config_package_diagnostics :: proc(e: ^Engine, workspace: string) -> bool {
    if workspace == "" {
        return false
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    return cache.cfg.package_diagnostics
}

// True when the workspace config turns on the disagreement log of the compiler check; off by default.
@(private)
config_telemetry :: proc(e: ^Engine, workspace: string) -> bool {
    if workspace == "" {
        return false
    }
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    config_ensure(cache, workspace)
    return cache.cfg.diagnostics_telemetry
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
    for d in cache.cfg.defines {
        delete(d.name, cache.alloc)
        if s, ok := d.value.(string); ok {
            delete(s, cache.alloc)
        }
    }
    delete(cache.cfg.defines)
    cache.cfg.defines = nil
    for id in cache.cfg.severities {
        delete(id, cache.alloc)
    }
    delete(cache.cfg.severities)
    cache.cfg.severities = nil
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
