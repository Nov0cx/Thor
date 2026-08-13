// The server table: `settings/lsp.json` beside the binary, overlaid by
// `<workspace>/.thor/lsp.json`. Read here with `core:encoding/json` and not
// through `setting`, which imports `lang` and would close a cycle.
package lsp

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

import lang ".."

// Beside the binary, staged by build.odin with the rest of `settings/`. Thor
// moves its working directory to the executable at startup, so the path is
// relative.
GLOBAL_CONFIG :: "settings/lsp.json"

// The user layer, beside the shipped one. A build and an update replace
// `settings/` wholesale and leave `user/` alone, so this is where a change the
// user makes belongs.
USER_CONFIG :: "user/lsp.json"

WORKSPACE_CONFIG_DIR :: ".thor"
WORKSPACE_CONFIG :: "lsp.json"

// One configured language server. Every string and slice is owned by the Config
// that holds it.
Server_Config :: struct {
    id:           string,   // owned; the key a workspace entry overlays on
    extensions:   []string, // owned; each with its leading '.'
    command:      []string, // owned; [0] is the program, resolved on PATH when not absolute
    cwd:          string,   // owned; empty is the workspace root
    env:          []string, // owned; "K=V" overlay on the parent environment
    root_markers: []string, // owned
    init_options: string,   // owned; JSON text, "" when the key is absent
    settings:     string,   // owned; JSON text, "" when the key is absent
    // The admin gate this entry starts at. Both seed the Server's own
    // admin_enabled/admin_features, which the settings then own outright.
    features:     bit_set[lang.Request_Kind],
    enabled:      bool,
    override:     bool, // register ahead of the in-client Odin engine
}

// The merged table. Owns every server in it.
Config :: struct {
    servers:   [dynamic]Server_Config, // owned
    allocator: runtime.Allocator,
}

// Reads the shipped table, then the user's, then the workspace's. A file that is
// absent, unreadable or malformed contributes nothing: a broken workspace file
// must not remove the servers the shipped one names.
config_load :: proc(workspace: string, allocator := context.allocator) -> Config {
    cfg := Config {
        servers   = make([dynamic]Server_Config, allocator),
        allocator = allocator,
    }
    config_merge_file(&cfg, GLOBAL_CONFIG)
    config_merge_file(&cfg, USER_CONFIG)
    if workspace != "" {
        path, jerr := filepath.join({workspace, WORKSPACE_CONFIG_DIR, WORKSPACE_CONFIG}, context.temp_allocator)
        if jerr == nil {
            config_merge_file(&cfg, path)
        }
    }
    config_finish(&cfg)
    return cfg
}

config_destroy :: proc(cfg: ^Config) {
    for &server in cfg.servers {
        server_config_destroy(&server, cfg.allocator)
    }
    delete(cfg.servers)
    cfg.servers = nil
}

// The configured server for `ext`, compared without case because a path carries
// whatever case the file system gave it. The first enabled claimant wins: two
// enabled entries on one extension is a config mistake, not a fallback chain.
config_server_for :: proc(cfg: ^Config, ext: string) -> (^Server_Config, bool) {
    if ext == "" {
        return nil, false
    }
    for &server in cfg.servers {
        if !server.enabled {
            continue
        }
        for candidate in server.extensions {
            if strings.equal_fold(candidate, ext) {
                return &server, true
            }
        }
    }
    return nil, false
}

@(private)
config_merge_file :: proc(cfg: ^Config, path: string) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return
    }
    config_merge_text(cfg, string(data))
}

// Merges the `servers` array of one file into the table, keyed on `id`: a known
// id overlays field by field, a new id is appended. Only a key that is present
// replaces a field, so a workspace file states the one thing it changes. Unknown
// keys are ignored, so the file can carry settings a later version acts on.
@(private)
config_merge_text :: proc(cfg: ^Config, text: string) {
    value, perr := json.parse(transmute([]u8)text, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
    if perr != .None {
        return
    }
    root, rok := value.(json.Object)
    if !rok {
        return
    }
    list, lok := root["servers"].(json.Array)
    if !lok {
        return
    }

    for item in list {
        entry, eok := item.(json.Object)
        if !eok {
            continue
        }
        id, iok := entry["id"].(json.String)
        if !iok || id == "" {
            continue
        }
        at := config_index(cfg, string(id))
        if at < 0 {
            append(
                &cfg.servers,
                Server_Config {
                    id = strings.clone(string(id), cfg.allocator),
                    features = lang.FEATURES_ALL,
                    enabled = true,
                },
            )
            at = len(cfg.servers) - 1
        }
        server_overlay(&cfg.servers[at], entry, cfg.allocator)
    }
}

@(private)
config_index :: proc(cfg: ^Config, id: string) -> int {
    for server, index in cfg.servers {
        if server.id == id {
            return index
        }
    }
    return -1
}

// Drops the entries that name no server to start: an empty `command`. An entry
// with `enabled: false` stays — it seeds the server's admin gate off, which
// keeps it listed in Settings and turnable back on.
@(private)
config_finish :: proc(cfg: ^Config) {
    kept := 0
    for &server in cfg.servers {
        if len(server.command) == 0 {
            server_config_destroy(&server, cfg.allocator)
            continue
        }
        cfg.servers[kept] = server
        kept += 1
    }
    resize(&cfg.servers, kept)
}

// Applies one file's entry onto a server, replacing only the fields it names.
@(private)
server_overlay :: proc(server: ^Server_Config, entry: json.Object, alloc: runtime.Allocator) {
    if arr, ok := entry["extensions"].(json.Array); ok {
        strings_free(server.extensions, alloc)
        server.extensions = extension_list(arr, alloc)
    }
    if arr, ok := entry["command"].(json.Array); ok {
        strings_free(server.command, alloc)
        server.command = string_list(arr, alloc)
    }
    if arr, ok := entry["root_markers"].(json.Array); ok {
        strings_free(server.root_markers, alloc)
        server.root_markers = string_list(arr, alloc)
    }
    if obj, ok := entry["env"].(json.Object); ok {
        strings_free(server.env, alloc)
        server.env = env_list(obj, alloc)
    }
    if text, ok := entry["cwd"].(json.String); ok {
        delete(server.cwd, alloc)
        server.cwd = strings.clone(string(text), alloc)
    }
    if value, ok := entry["initialization_options"]; ok {
        delete(server.init_options, alloc)
        server.init_options = json_text(value, alloc)
    }
    if value, ok := entry["settings"]; ok {
        delete(server.settings, alloc)
        server.settings = json_text(value, alloc)
    }
    if obj, ok := entry["features"].(json.Object); ok {
        for name, value in obj {
            allowed, bok := value.(json.Boolean)
            if !bok {
                continue
            }
            kind, kok := lang.feature_from_name(name)
            if !kok {
                continue
            }
            if allowed {
                server.features += {kind}
            } else {
                server.features -= {kind}
            }
        }
    }
    if value, ok := entry["enabled"].(json.Boolean); ok {
        server.enabled = bool(value)
    }
    if value, ok := entry["override"].(json.Boolean); ok {
        server.override = bool(value)
    }
}

@(private)
server_config_destroy :: proc(server: ^Server_Config, alloc: runtime.Allocator) {
    delete(server.id, alloc)
    delete(server.cwd, alloc)
    delete(server.init_options, alloc)
    delete(server.settings, alloc)
    strings_free(server.extensions, alloc)
    strings_free(server.command, alloc)
    strings_free(server.root_markers, alloc)
    strings_free(server.env, alloc)
    server^ = {}
}

// Every string of a JSON array, the entries that are not strings dropped.
@(private)
string_list :: proc(arr: json.Array, alloc: runtime.Allocator) -> []string {
    count := 0
    for item in arr {
        if text, ok := item.(json.String); ok && text != "" {
            count += 1
        }
    }
    if count == 0 {
        return nil
    }
    out := make([]string, count, alloc)
    at := 0
    for item in arr {
        text, ok := item.(json.String)
        if !ok || text == "" {
            continue
        }
        out[at] = strings.clone(string(text), alloc)
        at += 1
    }
    return out
}

// The same, with the leading '.' a config may omit put back. Case is left as
// written — the lookup compares without case.
@(private)
extension_list :: proc(arr: json.Array, alloc: runtime.Allocator) -> []string {
    out := string_list(arr, alloc)
    for &text in out {
        if strings.has_prefix(text, ".") {
            continue
        }
        dotted := strings.concatenate({".", text}, alloc)
        delete(text, alloc)
        text = dotted
    }
    return out
}

// An environment overlay as the "K=V" entries shell.Child_Spec takes.
@(private)
env_list :: proc(obj: json.Object, alloc: runtime.Allocator) -> []string {
    count := 0
    for name, value in obj {
        if _, ok := value.(json.String); ok && name != "" {
            count += 1
        }
    }
    if count == 0 {
        return nil
    }
    out := make([]string, count, alloc)
    at := 0
    for name, value in obj {
        text, ok := value.(json.String)
        if !ok || name == "" {
            continue
        }
        out[at] = strings.concatenate({name, "=", string(text)}, alloc)
        at += 1
    }
    return out
}

// A nested object kept as JSON text: initializationOptions and `settings` pass
// through to the server verbatim, so nothing here needs to understand them. Map
// keys are sorted, so one config always produces one text.
@(private)
json_text :: proc(value: json.Value, alloc: runtime.Allocator) -> string {
    if _, ok := value.(json.Null); ok {
        return ""
    }
    text, err := json.unparse(value, {sort_maps_by_key = true}, alloc)
    if err != nil {
        return ""
    }
    return text
}

@(private)
strings_free :: proc(list: []string, alloc: runtime.Allocator) {
    for text in list {
        delete(text, alloc)
    }
    delete(list, alloc)
}
