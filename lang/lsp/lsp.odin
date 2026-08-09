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
        notify = notify,
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

// M4 answers nothing: the request kinds are mapped in M5. Starting the server
// here is what makes a request path need no host hook at all.
@(private)
resolve :: proc(data: rawptr, req: ^lang.Request, res: ^lang.Result) {
    c := cast(^Client)data
    s, found := client_server_for(c, req.ext)
    if !found {
        return
    }
    server_ensure_started(s, req.path)
    res.ok = false
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
            return s, true
        }
    }
    return nil, false
}
