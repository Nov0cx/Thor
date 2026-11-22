package lsp

import "core:encoding/json"
import "core:strings"
import "core:sync"

import lang ".."

// The kinds a server may register after the handshake. Completion, semantic tokens
// and on-type formatting stay static: their options (triggers, legend) are read once.
@(private)
DYNAMIC_KINDS :: bit_set[lang.Request_Kind]{
    .Definition,
    .Type_Definition,
    .Hover,
    .Package_Doc,
    .Document_Symbols,
    .Workspace_Symbols,
    .References,
    .Signature_Help,
    .Rename,
    .Code_Actions,
    .Inlay_Hints,
    .Document_Highlight,
    .Format,
    .Format_Range,
    .Execute_Command,
    .Declaration,
}

@(private)
WATCHED_FILES :: "workspace/didChangeWatchedFiles"

// One registration a server made, kept until it unregisters or the connection ends.
@(private)
Registration :: struct {
    id:       string, // owned
    kinds:    bit_set[lang.Request_Kind],
    watchers: [dynamic]File_Watcher, // owned
}

// One glob of a didChangeWatchedFiles registration.
@(private)
File_Watcher :: struct {
    base:    string, // owned; "/" separators; "" matches the whole path
    pattern: string, // owned
    kinds:   bit_set[lang.File_Change_Kind],
}

// One change queued for workspace/didChangeWatchedFiles.
@(private)
Watched_Change :: struct {
    path: string, // owned
    kind: lang.File_Change_Kind,
}

// The kinds a registration for `method` turns on.
@(private)
method_kinds :: proc(method: string) -> bit_set[lang.Request_Kind] {
    kinds: bit_set[lang.Request_Kind]
    for name, kind in METHODS {
        if name != "" && name == method && kind in DYNAMIC_KINDS {
            kinds += {kind}
        }
    }
    return kinds
}

// Conn_Answers.register: applies registerCapability or unregisterCapability. Reader thread.
@(private)
server_register :: proc(data: rawptr, params: json.Value, unregister: bool) {
    s          := cast(^Server)data
    object, ok := params.(json.Object)
    if !ok {
        return
    }
    // The protocol spells the unregister array "unregisterations".
    list, lok := object[unregister ? "unregisterations" : "registrations"].(json.Array)
    if !lok {
        return
    }
    sync.lock(&s.reg_mutex)
    defer sync.unlock(&s.reg_mutex)
    for item in list {
        entry, eok := item.(json.Object)
        if !eok {
            continue
        }
        id, iok     := entry["id"].(json.String)
        method, mok := entry["method"].(json.String)
        if !iok || !mok {
            continue
        }
        registration_remove(s, string(id))
        if unregister {
            continue
        }
        reg := Registration{kinds = method_kinds(string(method))}
        if string(method) == WATCHED_FILES {
            reg.watchers = make([dynamic]File_Watcher, s.allocator)
            if options, ook := entry["registerOptions"].(json.Object); ook {
                decode_watchers(s, &reg, options["watchers"])
            }
        }
        if reg.kinds == {} && len(reg.watchers) == 0 {
            delete(reg.watchers)
            continue
        }
        reg.id = strings.clone(string(id), s.allocator)
        append(&s.registrations, reg)
    }
    registration_publish(s)
}

// Reads the `watchers` array of a didChangeWatchedFiles registration.
@(private = "file")
decode_watchers :: proc(s: ^Server, reg: ^Registration, value: json.Value) {
    list, ok := value.(json.Array)
    if !ok {
        return
    }
    for item in list {
        entry, eok := item.(json.Object)
        if !eok {
            continue
        }
        base, pattern: string
        switch glob in entry["globPattern"] {
        case json.String:
            pattern = string(glob)
        case json.Object:
            text, tok := glob["pattern"].(json.String)
            if !tok {
                continue
            }
            pattern = string(text)
            uri: string
            #partial switch b in glob["baseUri"] {
            case json.String:
                uri = string(b)
            case json.Object:
                if u, uok := b["uri"].(json.String); uok {
                    uri = string(u)
                }
            }
            path, pok := uri_to_path(uri, context.temp_allocator)
            if !pok {
                continue
            }
            base = strings.trim_right(glob_path(path), "/")
        case json.Null, json.Integer, json.Float, json.Boolean, json.Array:
            continue
        }
        kinds := bit_set[lang.File_Change_Kind]{.Created, .Changed, .Deleted}
        if mask, mok := entry["kind"].(json.Integer); mok {
            kinds = transmute(bit_set[lang.File_Change_Kind])u8(mask & 7)
        }
        if pattern == "" || kinds == {} {
            continue
        }
        append(&reg.watchers, File_Watcher{base = strings.clone(base, s.allocator), pattern = strings.clone(pattern, s.allocator), kinds = kinds})
    }
}

// Removes the registration `id`. The caller holds reg_mutex.
@(private = "file")
registration_remove :: proc(s: ^Server, id: string) {
    for &reg, index in s.registrations {
        if reg.id == id {
            registration_destroy(s, &reg)
            ordered_remove(&s.registrations, index)
            return
        }
    }
}

@(private = "file")
registration_destroy :: proc(s: ^Server, reg: ^Registration) {
    delete(reg.id, s.allocator)
    for w in reg.watchers {
        delete(w.base, s.allocator)
        delete(w.pattern, s.allocator)
    }
    delete(reg.watchers)
}

// Stores the union of the registered kinds where server_supports reads it. The caller holds reg_mutex.
@(private = "file")
registration_publish :: proc(s: ^Server) {
    kinds: bit_set[lang.Request_Kind]
    watching := false
    for reg in s.registrations {
        kinds += reg.kinds
        watching ||= len(reg.watchers) > 0
    }
    sync.atomic_store(&s.dyn_kinds, kinds)
    sync.atomic_store(&s.watching, watching)
}

// Drops every registration. A new connection starts with none.
@(private)
server_registrations_clear :: proc(s: ^Server) {
    sync.lock(&s.reg_mutex)
    for &reg in s.registrations {
        registration_destroy(s, &reg)
    }
    clear(&s.registrations)
    registration_publish(s)
    sync.unlock(&s.reg_mutex)

    sync.lock(&s.out_mutex)
    watched_changes_drop(s)
    sync.unlock(&s.out_mutex)
}

// Frees the queued watched-file changes. The caller holds out_mutex.
@(private)
watched_changes_drop :: proc(s: ^Server) {
    for change in s.watched {
        delete(change.path, s.allocator)
    }
    clear(&s.watched)
}

// Queues each change a registered watcher matches. Main thread, must not block.
@(private)
server_files_changed :: proc(s: ^Server, changes: []lang.File_Change) {
    if server_state(s) != .Ready || !sync.atomic_load(&s.watching) {
        return
    }
    matched   := make([dynamic]Watched_Change, context.temp_allocator)
    workspace := strings.trim_right(glob_path(s.workspace), "/")
    sync.lock(&s.reg_mutex)
    for change in changes {
        path := glob_path(change.path)
        if watchers_match(s.registrations[:], path, workspace, change.kind) {
            append(&matched, Watched_Change{path = strings.clone(change.path, s.allocator), kind = change.kind})
        }
    }
    sync.unlock(&s.reg_mutex)
    if len(matched) == 0 {
        return
    }
    sync.lock(&s.out_mutex)
    append(&s.watched, ..matched[:])
    sync.unlock(&s.out_mutex)
    sync.sema_post(&s.wake)
}

// True when a watcher of `regs` matches `path` for `kind`. A pattern with no base is
// tried on the whole path, then on the path below the workspace.
@(private)
watchers_match :: proc(regs: []Registration, path, workspace: string, kind: lang.File_Change_Kind) -> bool {
    for reg in regs {
        for w in reg.watchers {
            if kind not_in w.kinds {
                continue
            }
            if w.base != "" {
                if rel, ok := path_below(path, w.base); ok && glob_match(w.pattern, rel) {
                    return true
                }
                continue
            }
            if glob_match(w.pattern, path) {
                return true
            }
            if rel, ok := path_below(path, workspace); ok && glob_match(w.pattern, rel) {
                return true
            }
        }
    }
    return false
}

// `path` relative to `base`, both with "/" separators.
@(private = "file")
path_below :: proc(path, base: string) -> (string, bool) {
    if base == "" || len(path) <= len(base) + 1 || path[len(base)] != '/' {
        return "", false
    }
    head := path[:len(base)]
    when ODIN_OS == .Windows {
        if !strings.equal_fold(head, base) {
            return "", false
        }
    } else {
        if head != base {
            return "", false
        }
    }
    return path[len(base) + 1:], true
}

// Sends the queued changes as one workspace/didChangeWatchedFiles. Pump thread.
@(private)
server_send_watched :: proc(s: ^Server) {
    sync.lock(&s.out_mutex)
    if len(s.watched) == 0 {
        sync.unlock(&s.out_mutex)
        return
    }
    pending := make([]Watched_Change, len(s.watched), context.temp_allocator)
    copy(pending, s.watched[:])
    clear(&s.watched)
    sync.unlock(&s.out_mutex)

    out := make([dynamic]u8, context.temp_allocator)
    append(&out, `{"changes":[`)
    for change, index in pending {
        if index > 0 {
            append(&out, ",")
        }
        append(&out, `{"uri":`)
        write_quoted(&out, uri_from_path(change.path, context.temp_allocator))
        append(&out, `,"type":`)
        switch change.kind {
        case .Created:
            append(&out, "1")
        case .Changed:
            append(&out, "2")
        case .Deleted:
            append(&out, "3")
        }
        append(&out, "}")
        delete(change.path, s.allocator)
    }
    append(&out, "]}")
    conn_notify(s.conn, WATCHED_FILES, string(out[:]))
}
