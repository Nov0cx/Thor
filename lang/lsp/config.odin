// The server table: `settings/lsp.json` beside the binary, overlaid by
// `<workspace>/.thor/lsp.json`. Read here with `core:encoding/json` and not
// through `setting`, which imports `lang` and would close a cycle.
package lsp

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
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
    name:         string,   // owned; display name, the id when the key is absent
    extensions:   []string, // owned; each with its leading '.'
    command:      []string, // owned; [0] is the program, resolved on PATH when not absolute
    cwd:          string,   // owned; empty is the workspace root
    env:          []string, // owned; "K=V" overlay on the parent environment
    root_markers: []string, // owned
    init_options: string,   // owned; JSON text, "" when the key is absent
    settings:     string,   // owned; JSON text, "" when the key is absent
    // Setup data the host acts on. This package never runs an installer, opens a
    // URL or runs a command; it only carries the text.
    install:      string, // owned; the install command for this platform, "" when none
    docs_url:     string, // owned
    setup_command: string, // owned; a plugin command the host offers as "Configure..."
    // The admin gate this entry starts at. Both seed the Server's own
    // admin_enabled/admin_features, which the settings then own outright.
    features:     bit_set[lang.Request_Kind],
    enabled:      bool,
    override:     bool, // register ahead of the in-client Odin engine
}

// A complaint about one config file. A problem never removes a server another
// layer named: it is reported and the load carries on.
Config_Problem :: struct {
    file:    string, // owned; "" when the merge itself found it
    id:      string, // owned; the entry it names, "" for a file-level problem
    message: string, // owned
}

// The merged table. Owns every server in it.
Config :: struct {
    servers:   [dynamic]Server_Config,  // owned
    problems:  [dynamic]Config_Problem, // owned
    workspace: string,                  // owned; the root ${workspace} expands to
    allocator: runtime.Allocator,
}

// Reads the shipped table, then the user's, then the workspace's. A file that is
// absent, unreadable or malformed contributes nothing: a broken workspace file
// must not remove the servers the shipped one names.
config_load :: proc(workspace: string, allocator := context.allocator) -> Config {
    cfg := Config {
        servers   = make([dynamic]Server_Config, allocator),
        problems  = make([dynamic]Config_Problem, allocator),
        workspace = strings.clone(workspace, allocator),
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
    for problem in cfg.problems {
        log.warnf("lsp config: %s", config_problem_text(problem, context.temp_allocator))
    }
    return cfg
}

config_destroy :: proc(cfg: ^Config) {
    for &server in cfg.servers {
        server_config_destroy(&server, cfg.allocator)
    }
    delete(cfg.servers)
    cfg.servers = nil
    for problem in cfg.problems {
        delete(problem.file, cfg.allocator)
        delete(problem.id, cfg.allocator)
        delete(problem.message, cfg.allocator)
    }
    delete(cfg.problems)
    cfg.problems = nil
    delete(cfg.workspace, cfg.allocator)
    cfg.workspace = ""
}

// One problem as a line: "<file> · <id>: <message>", each part left out when it
// is empty.
config_problem_text :: proc(problem: Config_Problem, allocator := context.allocator) -> string {
    switch {
    case problem.file != "" && problem.id != "":
        return fmt.aprintf("%s · %s: %s", problem.file, problem.id, problem.message, allocator = allocator)
    case problem.file != "":
        return fmt.aprintf("%s: %s", problem.file, problem.message, allocator = allocator)
    case problem.id != "":
        return fmt.aprintf("%s: %s", problem.id, problem.message, allocator = allocator)
    }
    return strings.clone(problem.message, allocator)
}

// Records a complaint. Every string is cloned, so the caller may pass text from
// the temp allocator.
@(private)
config_report :: proc(cfg: ^Config, file, id, message: string) {
    append(
        &cfg.problems,
        Config_Problem {
            file = strings.clone(file, cfg.allocator),
            id = strings.clone(id, cfg.allocator),
            message = strings.clone(message, cfg.allocator),
        },
    )
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
        // A file that is not there is the normal case — only the shipped table
        // must exist. One that is there and will not open is worth a word.
        if os.exists(path) {
            config_report(cfg, path, "", fmt.tprintf("could not be read (%v)", rerr))
        }
        return
    }
    config_merge_text(cfg, string(data), path)
}

// Merges the `servers` array of one file into the table, keyed on `id`: a known
// id overlays field by field, a new id is appended. Only a key that is present
// replaces a field, so a workspace file states the one thing it changes. An
// unknown key is reported and kept, not dropped, so the file can still carry
// settings a later version acts on.
@(private)
config_merge_text :: proc(cfg: ^Config, text: string, path := "") {
    if strings.trim_space(text) == "" {
        return
    }
    value, perr := json.parse(transmute([]u8)text, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
    if perr != .None {
        config_report(cfg, path, "", fmt.tprintf("is not valid JSON (%v)", perr))
        return
    }
    root, rok := value.(json.Object)
    if !rok {
        config_report(cfg, path, "", "must be a JSON object")
        return
    }
    entries, has_key := root["servers"]
    if !has_key {
        config_report(cfg, path, "", `has no "servers" array`)
        return
    }
    list, lok := entries.(json.Array)
    if !lok {
        config_report(cfg, path, "", `"servers" must be an array`)
        return
    }

    for item, index in list {
        entry, eok := item.(json.Object)
        if !eok {
            config_report(cfg, path, "", fmt.tprintf("entry #%d is not an object", index + 1))
            continue
        }
        id, iok := entry["id"].(json.String)
        if !iok || id == "" {
            config_report(cfg, path, "", fmt.tprintf(`entry #%d has no "id"`, index + 1))
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
        server_overlay(cfg, &cfg.servers[at], entry, path)
    }
}

// What to call this server in the interface: its `name`, or its id when the
// config states none.
server_display_name :: proc(server: ^Server_Config) -> string {
    return server.name != "" ? server.name : server.id
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
// keeps it listed in Settings and turnable back on. What survives then has its
// ${...} variables expanded, which is the last step before anything reads a
// path out of the table.
@(private)
config_finish :: proc(cfg: ^Config) {
    kept := 0
    for &server in cfg.servers {
        if len(server.command) == 0 {
            config_report(cfg, "", server.id, "names no command and was dropped")
            server_config_destroy(&server, cfg.allocator)
            continue
        }
        cfg.servers[kept] = server
        kept += 1
    }
    resize(&cfg.servers, kept)

    for &server in cfg.servers {
        for &arg in server.command {
            arg = config_expand(cfg, server.id, "command", arg)
        }
        if server.cwd != "" {
            server.cwd = config_expand(cfg, server.id, "cwd", server.cwd)
        }
        for &entry in server.env {
            entry = config_expand(cfg, server.id, "env", entry)
        }
    }
}

// Replaces every ${...} in `text` and frees the original. A name nothing answers
// to is left as written and reported, so a typo shows as an unresolved path
// instead of an empty one.
@(private)
config_expand :: proc(cfg: ^Config, id, field, text: string) -> string {
    if !strings.contains(text, "${") {
        return text
    }
    b := strings.builder_make(context.temp_allocator)
    rest := text
    for {
        open := strings.index(rest, "${")
        if open < 0 {
            strings.write_string(&b, rest)
            break
        }
        strings.write_string(&b, rest[:open])
        close := strings.index(rest[open:], "}")
        if close < 0 {
            strings.write_string(&b, rest[open:])
            break
        }
        // The whole token, braces included. It goes through fmt as an argument
        // and never as format text: "${...}" is fmt's own named-argument syntax.
        token := rest[open:open + close + 1]
        if value, known := config_variable(cfg, rest[open + 2:open + close]); known {
            strings.write_string(&b, value)
        } else {
            strings.write_string(&b, token)
            config_report(cfg, "", id, fmt.tprintf("%s names %s, which has no value here", field, token))
        }
        rest = rest[open + close + 1:]
    }
    expanded := strings.clone(strings.to_string(b), cfg.allocator)
    delete(text, cfg.allocator)
    return expanded
}

// The value of one ${...} name. Not-ok covers all three ways a name can go
// unanswered: it is not a variable, the environment does not set it, or no
// folder is open.
@(private)
config_variable :: proc(cfg: ^Config, name: string) -> (string, bool) {
    switch {
    case name == "workspace":
        return cfg.workspace, cfg.workspace != ""
    case name == "userHome":
        home := config_home()
        return home, home != ""
    case strings.has_prefix(name, "env:"):
        value := os.get_env(name[4:], context.temp_allocator)
        return value, value != ""
    }
    return "", false
}

// The user's home directory. Windows spells it USERPROFILE, POSIX HOME.
@(private)
config_home :: proc() -> string {
    when ODIN_OS == .Windows {
        if home := os.get_env("USERPROFILE", context.temp_allocator); home != "" {
            return home
        }
    }
    return os.get_env("HOME", context.temp_allocator)
}

// The keys an entry may hold. A key outside this list is reported once and left
// alone, so a file written for a later version still loads here.
@(private)
KNOWN_KEYS :: [?]string {
    "id",
    "name",
    "extensions",
    "command",
    "root_markers",
    "env",
    "cwd",
    "initialization_options",
    "init_options",
    "settings",
    "features",
    "enabled",
    "override",
    "install",
    "docs_url",
    "setup_command",
}

// Applies one file's entry onto a server, replacing only the fields it names. A
// key of the wrong type is reported and leaves the field as it was.
@(private)
server_overlay :: proc(cfg: ^Config, server: ^Server_Config, entry: json.Object, path: string) {
    alloc := cfg.allocator
    id := server.id

    for key in entry {
        known := false
        for candidate in KNOWN_KEYS {
            if key == candidate {
                known = true
                break
            }
        }
        if !known {
            config_report(cfg, path, id, fmt.tprintf("unknown key %q", key))
        }
    }

    if value, has := entry["name"]; has {
        if text, ok := value.(json.String); ok {
            delete(server.name, alloc)
            server.name = strings.clone(string(text), alloc)
        } else {
            config_report(cfg, path, id, `"name" must be a string`)
        }
    }
    if value, has := entry["extensions"]; has {
        if arr, ok := value.(json.Array); ok {
            strings_free(server.extensions, alloc)
            server.extensions = extension_list(arr, alloc)
        } else {
            config_report(cfg, path, id, `"extensions" must be an array of strings`)
        }
    }
    if value, has := entry["command"]; has {
        if arr, ok := value.(json.Array); ok {
            strings_free(server.command, alloc)
            server.command = string_list(arr, alloc)
        } else {
            config_report(cfg, path, id, `"command" must be an array of strings`)
        }
    }
    if value, has := entry["root_markers"]; has {
        if arr, ok := value.(json.Array); ok {
            strings_free(server.root_markers, alloc)
            server.root_markers = string_list(arr, alloc)
        } else {
            config_report(cfg, path, id, `"root_markers" must be an array of strings`)
        }
    }
    if value, has := entry["env"]; has {
        if obj, ok := value.(json.Object); ok {
            strings_free(server.env, alloc)
            server.env = env_list(obj, alloc)
        } else {
            config_report(cfg, path, id, `"env" must be an object of strings`)
        }
    }
    if value, has := entry["cwd"]; has {
        if text, ok := value.(json.String); ok {
            delete(server.cwd, alloc)
            server.cwd = strings.clone(string(text), alloc)
        } else {
            config_report(cfg, path, id, `"cwd" must be a string`)
        }
    }
    if value, has := entry["docs_url"]; has {
        if text, ok := value.(json.String); ok {
            delete(server.docs_url, alloc)
            server.docs_url = strings.clone(string(text), alloc)
        } else {
            config_report(cfg, path, id, `"docs_url" must be a string`)
        }
    }
    if value, has := entry["setup_command"]; has {
        if text, ok := value.(json.String); ok {
            delete(server.setup_command, alloc)
            server.setup_command = strings.clone(string(text), alloc)
        } else {
            config_report(cfg, path, id, `"setup_command" must be a string`)
        }
    }
    if value, has := entry["install"]; has {
        if obj, ok := value.(json.Object); ok {
            delete(server.install, alloc)
            server.install = install_command(obj, alloc)
        } else {
            config_report(cfg, path, id, `"install" must be an object keyed by platform`)
        }
    }
    // `init_options` is the spelling the documentation carried for a while; both
    // reach the same field.
    for key in ([?]string{"initialization_options", "init_options"}) {
        if value, ok := entry[key]; ok {
            delete(server.init_options, alloc)
            server.init_options = json_text(value, alloc)
        }
    }
    if value, ok := entry["settings"]; ok {
        delete(server.settings, alloc)
        server.settings = json_text(value, alloc)
    }
    if value, has := entry["features"]; has {
        obj, ok := value.(json.Object)
        if !ok {
            config_report(cfg, path, id, `"features" must be an object of booleans`)
        }
        for name, allowed_value in obj {
            allowed, bok := allowed_value.(json.Boolean)
            if !bok {
                config_report(cfg, path, id, fmt.tprintf("feature %q must be true or false", name))
                continue
            }
            kind, kok := lang.feature_from_name(name)
            if !kok {
                config_report(cfg, path, id, fmt.tprintf("unknown feature %q", name))
                continue
            }
            if allowed {
                server.features += {kind}
            } else {
                server.features -= {kind}
            }
        }
    }
    if value, has := entry["enabled"]; has {
        if flag, ok := value.(json.Boolean); ok {
            server.enabled = bool(flag)
        } else {
            config_report(cfg, path, id, `"enabled" must be true or false`)
        }
    }
    if value, has := entry["override"]; has {
        if flag, ok := value.(json.Boolean); ok {
            server.override = bool(flag)
        } else {
            config_report(cfg, path, id, `"override" must be true or false`)
        }
    }
}

// The platform key `install` is read under. An entry that names no key for this
// platform falls back to "any".
@(private)
INSTALL_KEY :: "windows" when ODIN_OS == .Windows else "darwin" when ODIN_OS == .Darwin else "linux"

// The install command for this platform, chosen at parse time so the host gets
// one opaque string and makes no platform decision of its own.
@(private)
install_command :: proc(obj: json.Object, alloc: runtime.Allocator) -> string {
    for key in ([?]string{INSTALL_KEY, "any"}) {
        if text, ok := obj[key].(json.String); ok && text != "" {
            return strings.clone(string(text), alloc)
        }
    }
    return ""
}

@(private)
server_config_destroy :: proc(server: ^Server_Config, alloc: runtime.Allocator) {
    delete(server.id, alloc)
    delete(server.name, alloc)
    delete(server.cwd, alloc)
    delete(server.init_options, alloc)
    delete(server.settings, alloc)
    delete(server.install, alloc)
    delete(server.docs_url, alloc)
    delete(server.setup_command, alloc)
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

// A copy of a string list that shares nothing with it, for a caller that must
// outlive the Config the list came from.
@(private)
strings_clone :: proc(list: []string, alloc: runtime.Allocator) -> []string {
    if len(list) == 0 {
        return nil
    }
    out := make([]string, len(list), alloc)
    for text, index in list {
        out[index] = strings.clone(text, alloc)
    }
    return out
}

@(private)
strings_free :: proc(list: []string, alloc: runtime.Allocator) {
    for text in list {
        delete(text, alloc)
    }
    delete(list, alloc)
}
