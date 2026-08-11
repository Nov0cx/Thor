package plugin

import "core:path/filepath"
import "core:strings"
import "core:time"

// Shared fake host for exercising the plugins/*-setup/plugin.lua family
// without a real shell or disk: `path_bins` answers `where`/`command -v`,
// `files` stands in for the workspace and is what thor.read/thor.write/
// thor.exists-style checks touch, `docs` is what thor.doc renders.
Fake_Env :: struct {
    os_kind:   string, // "windows", "darwin" or "linux"
    path_bins: map[string]string,
    files:     map[string]string,
    docs:      map[string]string,
    printed:   [dynamic]string,
}

make_fake_env :: proc(os_kind: string) -> Fake_Env {
    return Fake_Env {
        os_kind   = os_kind,
        path_bins = make(map[string]string),
        files     = make(map[string]string),
        docs      = make(map[string]string),
        printed   = make([dynamic]string),
    }
}

destroy_fake_env :: proc(env: ^Fake_Env) {
    delete(env.path_bins)
    for _, v in env.files {
        delete(v)
    }
    delete(env.files)
    for _, v in env.docs {
        delete(v)
    }
    delete(env.docs)
    for s in env.printed {
        delete(s)
    }
    delete(env.printed)
}

// Every branch returns a context.allocator-owned string: api_exec frees the
// result with the manager's allocator regardless of what allocated it, so a
// temp_allocator or literal return here is a mismatched free.
fake_exec :: proc(host: rawptr, command: string, timeout: time.Duration) -> string {
    env := cast(^Fake_Env) host
    switch {
    case command == "echo %OS%":
        return strings.clone(env.os_kind == "windows" ? "Windows_NT\r\n" : "%OS%\n")
    case command == "uname -s":
        switch env.os_kind {
        case "darwin": return strings.clone("Darwin\n")
        case "linux":  return strings.clone("Linux\n")
        case:          return strings.clone("")
        }
    case strings.has_prefix(command, "where "):
        bin := strings.trim_suffix(strings.trim_prefix(command, "where "), " 2>nul")
        if path, ok := env.path_bins[bin]; ok {
            return strings.concatenate({path, "\r\n"})
        }
        return strings.clone("")
    case strings.has_prefix(command, "command -v "):
        bin := strings.trim_suffix(strings.trim_prefix(command, "command -v "), " 2>/dev/null")
        if path, ok := env.path_bins[bin]; ok {
            return strings.concatenate({path, "\n"})
        }
        return strings.clone("")
    }
    return strings.clone("")
}

// thor.doc/thor.write/thor.read all resolve their path against the workspace
// root first (see resolve_path in sandbox.odin); without this, every one of
// them silently no-ops instead of reaching the fake file map.
fake_workspace :: proc(host: rawptr) -> string {
    return `C:\fake\workspace`
}

// The absolute path resolve_path (sandbox.odin) computes for `rel` under the
// fake workspace — the key fake_read/fake_write/fake_doc actually see.
resolved :: proc(rel: string) -> string {
    full, _ := filepath.join({fake_workspace(nil), rel}, context.temp_allocator)
    clean, err := filepath.abs(full, context.temp_allocator)
    if err != nil {
        clean, _ = filepath.clean(full, context.temp_allocator)
    }
    return clean
}

fake_read :: proc(host: rawptr, path: string) -> string {
    env := cast(^Fake_Env) host
    if v, ok := env.files[path]; ok {
        return strings.clone(v)
    }
    return strings.clone("")
}

fake_write :: proc(host: rawptr, path: string, text: string) {
    env := cast(^Fake_Env) host
    if old, ok := env.files[path]; ok {
        delete(old)
    }
    env.files[path] = strings.clone(text)
}

fake_doc :: proc(host: rawptr, path: string, text: string, focus: bool) {
    env := cast(^Fake_Env) host
    if old, ok := env.docs[path]; ok {
        delete(old)
    }
    env.docs[path] = strings.clone(text)
}

fake_print :: proc(host: rawptr, text: string) {
    env := cast(^Fake_Env) host
    append(&env.printed, strings.clone(text))
}

fake_pick :: proc(host: rawptr, label: string, items: []string) {
    // The test resolves the pick itself via manager_dialog_text.
}

fake_confirm :: proc(host: rawptr, message: string) {
    // The test resolves the confirm itself via manager_dialog_confirm.
}

// The Host every *-setup plugin test wires up; every fake_* proc reads or
// writes through `env`.
fake_host :: proc(env: ^Fake_Env) -> Host {
    return Host {
        data      = env,
        exec      = fake_exec,
        read      = fake_read,
        write     = fake_write,
        doc       = fake_doc,
        print     = fake_print,
        pick      = fake_pick,
        confirm   = fake_confirm,
        workspace = fake_workspace,
    }
}
