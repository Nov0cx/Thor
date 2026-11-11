// The subprocess LSP backend: the optional sibling of the in-client Odin engine
// behind the same lang.Backend seam. One Client holds the merged server table and
// one Server per configured entry, each started only when a file it claims is
// touched.
//
// Nothing above this package learns that a server exists: positions cross the
// edge as byte offsets over LF-collapsed source, and a server that never starts
// is a backend that claims nothing.
package lsp

import "base:runtime"
import "core:slice"
import "core:strings"

import lang ".."

Client :: struct {
    config:    Config,           // owned
    servers:   [dynamic]^Server, // owned; one per configured entry, built once
    workspace: string,           // owned
    poll_next: int,              // round-robin cursor into servers; main thread only
    // Must be the Manager's allocator, which owns what a pushed result carries.
    allocator: runtime.Allocator,
}

// Reads the server table and builds an idle server for each entry. No process is
// started here: a server that is never asked for costs one struct.
// `trust_workspace` lets `<workspace>/.thor/lsp.lua` join the table.
client_create :: proc(workspace: string, trust_workspace: bool, allocator := context.allocator) -> ^Client {
    c := new(Client, allocator)
    c.allocator = allocator
    c.workspace = strings.clone(workspace, allocator)
    c.config = config_load(workspace, trust_workspace, allocator)
    c.servers = make([dynamic]^Server, allocator)
    for &entry in c.config.servers {
        append(&c.servers, server_create(&entry, workspace, allocator))
    }
    return c
}

// Wraps the client as a lang.Backend for lang.manager_register.
client_backend :: proc(c: ^Client) -> lang.Backend {
    return lang.Backend{
        data = c,
        name = "lsp",
        handles = handles,
        resolve = resolve,
        destroy = client_destroy,
        supports = supports,
        poll = poll,
        notify = notify,
        on_type_trigger = on_type_trigger,
        gate_ids = gate_ids,
        set_gate = set_gate,
        gate_defaults = gate_defaults,
    }
}

@(private)
gate_ids :: proc(data: rawptr, allocator: runtime.Allocator) -> []string {
    return client_server_ids(cast(^Client)data, allocator)
}

@(private)
set_gate :: proc(data: rawptr, id: string, enabled: bool, features: bit_set[lang.Request_Kind]) -> bool {
    c := cast(^Client)data
    if !client_set_server_enabled(c, id, enabled) {
        return false
    }
    client_set_server_features(c, id, features)
    return true
}

@(private)
gate_defaults :: proc(data: rawptr, id: string) -> (enabled: bool, features: bit_set[lang.Request_Kind], ok: bool) {
    return client_server_defaults(cast(^Client)data, id)
}

// True when the config gives a server `ext` outright, ahead of an in-client
// engine. The host asks this once, at init, to decide registration order — the
// only place the precedence between the two backends is decided.
client_overrides :: proc(c: ^Client, ext: string) -> bool {
    server, found := config_server_for(&c.config, ext)
    return found && server.override
}

// True when a configured server claims `ext` and has not given up. Main thread,
// no lock: the table and the server list are built once in client_create, and
// only `state` moves after that.
@(private)
handles :: proc(data: rawptr, ext: string) -> bool {
    c          := cast(^Client)data
    servers, n := client_servers_for(c, ext)
    for s in servers[:n] {
        if server_state(s) != .Failed {
            return true
        }
    }
    return false
}

// Whether the claimed server answers `kind`. Three gates are AND-ed here: the
// per-server `features` of the config, the server's own advertised capabilities,
// and its state. The Manager's own gate is the fourth, above this.
@(private)
supports :: proc(data: rawptr, ext: string, kind: lang.Request_Kind) -> bool {
    c          := cast(^Client)data
    servers, n := client_servers_for(c, ext)
    for s in servers[:n] {
        if server_supports(s, kind) {
            return true
        }
    }
    return false
}

// Answers one request, starting the server if this is the first file to need it.
// Starting here is what makes a request path need no host hook at all. Runs on a
// pool worker and blocks: a start and a round trip both wait on a pipe.
@(private)
resolve :: proc(data: rawptr, req: ^lang.Request, res: ^lang.Result) {
    c          := cast(^Client)data
    servers, n := client_servers_for(c, req.ext)
    links      := make([dynamic]lang.Link, context.temp_allocator)
    for s in servers[:n] {
        id := link_id(s)
        if !origin_names(req.backend, id) {
            continue
        }
        append(&links, lang.Link{id = id, data = s, resolve = resolve_server})
    }
    if len(links) > 0 {
        lang.resolve_links(links[:], req, res)
    }
}

// One server's share of a request: starts it when this is the first file to need it.
@(private)
resolve_server :: proc(data: rawptr, req: ^lang.Request, res: ^lang.Result) {
    s := cast(^Server)data
    if server_ensure_started(s, req) {
        request_answer(s, req, res)
    }
}

// The origin a server's offers carry: "lsp:<server id>".
@(private)
link_id :: proc(s: ^Server) -> string {
    return strings.concatenate({"lsp:", s.config.id}, context.temp_allocator)
}

// True when `origin` (Request.backend) lets the server `link` answer: no origin, the
// backend as a whole, or that server.
@(private)
origin_names :: proc(origin, link: string) -> bool {
    return origin == "" || origin == "lsp" || origin == link
}

// Takes the next result a server produced without being asked. Main thread,
// called once per frame until it answers false. Starts from poll_next rather
// than always from servers[0], so a chatty server cannot starve the others of
// the Manager's per-backend poll budget.
@(private)
poll :: proc(data: rawptr, res: ^lang.Result) -> bool {
    c := cast(^Client)data
    if len(c.servers) == 0 {
        return false
    }
    start := c.poll_next % len(c.servers)
    for offset in 0 ..< len(c.servers) {
        index := (start + offset) % len(c.servers)
        s     := c.servers[index]
        if !server_admin_enabled(s) {
            continue
        }
        if server_poll(s, res) {
            c.poll_next = index + 1
            return true
        }
    }
    return false
}

// True when typing `char` in a file of `ext` should trigger on-type
// formatting. The server must be .Ready — caps.on_type_triggers is only
// decoded once the handshake lands — and answer Format_On_Type; `char` must be
// one of its advertised trigger characters.
@(private)
on_type_trigger :: proc(data: rawptr, ext: string, char: string) -> bool {
    c          := cast(^Client)data
    servers, n := client_servers_for(c, ext)
    for s in servers[:n] {
        if server_state(s) != .Ready || !server_supports(s, .Format_On_Type) {
            continue
        }
        for trigger in s.caps.on_type_triggers {
            if trigger == char {
                return true
            }
        }
    }
    return false
}

// Main thread, must not block: the owning server queues the event and its pump
// sends it.
@(private)
notify :: proc(data: rawptr, event: lang.Doc_Event, path, ext, source: string, revision: u64) {
    c          := cast(^Client)data
    servers, n := client_servers_for(c, ext)
    for s in servers[:n] {
        server_notify(s, event, path, source, revision)
    }
    if event == .Closed {
        client_close_on_disabled(c, path, ext, servers[:n])
    }
}

// Sends a close to each started server that claims `ext` but is turned off. It
// can hold the file from before it was turned off; `served` already got the event.
@(private)
client_close_on_disabled :: proc(c: ^Client, path, ext: string, served: []^Server) {
    if ext == "" {
        return
    }
    for s in c.servers {
        if slice.contains(served, s) || server_admin_enabled(s) || !server_claims(s.config, ext) {
            continue
        }
        if strings.equal_fold(ext, ".odin") && !s.config.override {
            continue
        }
        if server_state(s) == .Idle {
            continue
        }
        server_notify(s, .Closed, path, "", 0)
    }
}

// Runs with no worker in flight: manager_destroy drains the pool before it calls
// a backend's destroy.
@(private)
client_destroy :: proc(data: rawptr) {
    c := cast(^Client)data
    for s in c.servers {
        server_stop(s)
        server_destroy(s)
    }
    delete(c.servers)
    config_destroy(&c.config)
    delete(c.workspace, c.allocator)
    free(c, c.allocator)
}

// Every enabled server configured for the routing key `ext`, in config order, up to
// lang.MAX_CHAIN. They all mirror the document and answer together; see lang.MERGE_KINDS.
// The routing key — an extension (".c") or a
// bare file name ("Makefile"). `.odin` is served in-client, so a server is
// given it only where the config says so outright — belt and braces, since
// registration order already decides it, and a server started for a language it
// will never be asked about costs memory for nothing.
@(private)
client_servers_for :: proc(c: ^Client, ext: string) -> (found: [lang.MAX_CHAIN]^Server, n: int) {
    if ext == "" {
        return
    }
    for s in c.servers {
        if n == lang.MAX_CHAIN {
            break
        }
        if !server_claims(s.config, ext) {
            continue
        }
        // A server takes .odin only by an explicit override.
        if strings.equal_fold(ext, ".odin") && !s.config.override {
            continue
        }
        // A disabled claimant stays out; the others still answer.
        if !server_admin_enabled(s) {
            continue
        }
        found[n] = s
        n += 1
    }
    return
}

// What the config files got wrong, for the settings UI to show. Read-only and
// owned by the Client's Config, so it dies with the Client.
client_diagnostics :: proc(c: ^Client) -> []Config_Problem {
    if c == nil {
        return nil
    }
    return c.config.problems[:]
}

// Everything a status view says about one server. Every string and slice comes
// from `allocator` and is the caller's: a workspace change frees the whole
// Config, so nothing here may be held across a reload.
Server_Status :: struct {
    id:              string,
    name:            string,
    state:           Server_State,
    extensions:      []string,
    filenames:       []string,
    command:         []string,
    exe:             string, // the program as resolved on PATH, "" when absent
    installed:       bool,
    root:            string, // "" until the server started once
    restarts:        int,
    last_error:      string, // "" while it never failed
    latched:         bool,   // on hold after repeated deadline misses
    enabled:         bool,
    features:        bit_set[lang.Request_Kind],
    install_command: string, // already chosen for this platform
    docs_url:        string,
    setup_command:   string,
    shared_with:     string, // the other enabled entries that claim its first key, ", " apart
}

// One server's status by id. `probe` false leaves `exe`/`installed` unset, for a
// caller that keeps the PATH lookup itself: it walks every PATH directory, and a
// table of dozens of servers must not repeat that on every redraw.
client_server_status :: proc(c: ^Client, id: string, allocator := context.temp_allocator, probe := true) -> (Server_Status, bool) {
    if c == nil {
        return {}, false
    }
    for s in c.servers {
        if s.config.id != id {
            continue
        }
        status := Server_Status{
            id = strings.clone(s.config.id, allocator),
            name = strings.clone(server_display_name(s.config), allocator),
            state = server_state(s),
            extensions = strings_clone(s.config.extensions, allocator),
            filenames = strings_clone(s.config.filenames, allocator),
            command = strings_clone(s.config.command, allocator),
            root = server_root_copy(s, allocator),
            restarts = server_restarts(s),
            last_error = server_last_error(s, allocator),
            latched = server_latched(s),
            enabled = server_admin_enabled(s),
            features = server_admin_features(s),
            install_command = strings.clone(s.config.install, allocator),
            docs_url = strings.clone(s.config.docs_url, allocator),
            setup_command = strings.clone(s.config.setup_command, allocator),
        }
        if probe && len(s.config.command) > 0 {
            status.exe, status.installed = executable_find(s.config.command[0], s.workspace, allocator)
        }
        // The first key it claims, file names first, is the one asked about.
        first := len(s.config.filenames) > 0 ? s.config.filenames[0] : ""
        if first == "" && len(s.config.extensions) > 0 {
            first = s.config.extensions[0]
        }
        if first != "" {
            status.shared_with = client_key_sharers(c, first, id, allocator)
        }
        return status, true
    }
    return {}, false
}

// The ids of the enabled servers other than `self` that answer for `key`, ", " apart,
// so a language served by several says so. "" when none does.
client_key_sharers :: proc(c: ^Client, key, self: string, allocator := context.temp_allocator) -> string {
    servers, n := client_servers_for(c, key)
    ids        := make([dynamic]string, context.temp_allocator)
    for s in servers[:n] {
        if s.config.id != self {
            append(&ids, s.config.id)
        }
    }
    return strings.join(ids[:], ", ", allocator)
}

// The configured id of every server in the table, for a caller (the settings UI,
// thor_apply_language_settings) that needs to enumerate them without reaching
// into Client.config.servers directly.
client_server_ids :: proc(c: ^Client, allocator := context.temp_allocator) -> []string {
    if len(c.servers) == 0 {
        return nil
    }
    out := make([]string, len(c.servers), allocator)
    for s, i in c.servers {
        out[i] = s.config.id
    }
    return out
}

// The admin gate `id` starts at, as its lsp.lua entry states it. What the
// settings fall back to for a backend they say nothing about, so a server turned
// off in lsp.lua reads as off in Settings instead of on.
client_server_defaults :: proc(c: ^Client, id: string) -> (enabled: bool, features: bit_set[lang.Request_Kind], ok: bool) {
    if c == nil {
        return true, lang.FEATURES_ALL, false
    }
    for s in c.servers {
        if s.config.id == id {
            return s.config.enabled, s.config.features, true
        }
    }
    return true, lang.FEATURES_ALL, false
}

// Settings-driven on/off for one configured server, by id. False when no server
// has that id. A disabled server answers nothing (client_servers_for) and its
// pushes are skipped (poll) — the process itself is left running idle until the
// workspace reloads or the app exits.
client_set_server_enabled :: proc(c: ^Client, id: string, enabled: bool) -> bool {
    for s in c.servers {
        if s.config.id == id {
            server_set_admin_enabled(s, enabled)
            return true
        }
    }
    return false
}

// Stops one configured server and puts it back to idle, so the next document
// event starts it again. False when no server has that id. The caller must have
// drained the Manager first — server_restart stops a pump a worker could still
// be talking to.
client_restart_server :: proc(c: ^Client, id: string) -> bool {
    if c == nil {
        return false
    }
    for s in c.servers {
        if s.config.id == id {
            server_restart(s)
            return true
        }
    }
    return false
}

// Settings-driven per-kind gate for one configured server, by id. False when
// no server has that id. ANDed with the server's own lsp.lua features.
client_set_server_features :: proc(c: ^Client, id: string, features: bit_set[lang.Request_Kind]) -> bool {
    for s in c.servers {
        if s.config.id == id {
            server_set_admin_features(s, features)
            return true
        }
    }
    return false
}
