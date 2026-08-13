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
client_create :: proc(workspace: string, allocator := context.allocator) -> ^Client {
    c := new(Client, allocator)
    c.allocator = allocator
    c.workspace = strings.clone(workspace, allocator)
    c.config = config_load(workspace, allocator)
    c.servers = make([dynamic]^Server, allocator)
    for &entry in c.config.servers {
        append(&c.servers, server_create(&entry, workspace, allocator))
    }
    return c
}

// Wraps the client as a lang.Backend for lang.manager_register.
client_backend :: proc(c: ^Client) -> lang.Backend {
    return lang.Backend {
        data = c,
        name = "lsp",
        handles = handles,
        resolve = resolve,
        destroy = client_destroy,
        supports = supports,
        poll = poll,
        notify = notify,
        on_type_trigger = on_type_trigger,
    }
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
    c := cast(^Client)data
    s, found := client_server_for(c, ext)
    return found && server_state(s) != .Failed
}

// Whether the claimed server answers `kind`. Three gates are AND-ed here: the
// per-server `features` of the config, the server's own advertised capabilities,
// and its state. The Manager's own gate is the fourth, above this.
@(private)
supports :: proc(data: rawptr, ext: string, kind: lang.Request_Kind) -> bool {
    c := cast(^Client)data
    s, found := client_server_for(c, ext)
    return found && server_supports(s, kind)
}

// Answers one request, starting the server if this is the first file to need it.
// Starting here is what makes a request path need no host hook at all. Runs on a
// pool worker and blocks: a start and a round trip both wait on a pipe.
@(private)
resolve :: proc(data: rawptr, req: ^lang.Request, res: ^lang.Result) {
    c := cast(^Client)data
    s, found := client_server_for(c, req.ext)
    if !found || !server_ensure_started(s, req) {
        return
    }
    request_answer(s, req, res)
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
        s := c.servers[index]
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
    c := cast(^Client)data
    s, found := client_server_for(c, ext)
    if !found || server_state(s) != .Ready || !server_supports(s, .Format_On_Type) {
        return false
    }
    for trigger in s.caps.on_type_triggers {
        if trigger == char {
            return true
        }
    }
    return false
}

// Main thread, must not block: the owning server queues the event and its pump
// sends it.
@(private)
notify :: proc(data: rawptr, event: lang.Doc_Event, path, ext, source: string, revision: u64) {
    c := cast(^Client)data
    s, found := client_server_for(c, ext)
    if !found {
        return
    }
    server_notify(s, event, path, ext, source, revision)
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

// The server configured for `ext`. `.odin` is served in-client, so a server is
// given it only where the config says so outright — belt and braces, since
// registration order already decides it, and a server started for a language it
// will never be asked about costs memory for nothing.
@(private)
client_server_for :: proc(c: ^Client, ext: string) -> (^Server, bool) {
    if ext == "" {
        return nil, false
    }
    for s in c.servers {
        for candidate in s.config.extensions {
            if !strings.equal_fold(candidate, ext) {
                continue
            }
            if strings.equal_fold(ext, ".odin") && !s.config.override {
                return nil, false
            }
            // A disabled claimant does not consume the extension: turning one
            // off is how a later entry (a workspace file's own server) takes
            // the language over.
            if !server_admin_enabled(s) {
                break
            }
            return s, true
        }
    }
    return nil, false
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

// The admin gate `id` starts at, as its lsp.json entry states it. What the
// settings fall back to for a backend they say nothing about, so a server turned
// off in lsp.json reads as off in Settings instead of on.
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
// has that id. A disabled server answers nothing (client_server_for) and its
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

// Settings-driven per-kind gate for one configured server, by id. False when
// no server has that id. ANDed with the server's own lsp.json features.
client_set_server_features :: proc(c: ^Client, id: string, features: bit_set[lang.Request_Kind]) -> bool {
    for s in c.servers {
        if s.config.id == id {
            server_set_admin_features(s, features)
            return true
        }
    }
    return false
}
