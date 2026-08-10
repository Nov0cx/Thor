package plugin

import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// A fake host for exercising plugins/lsp-setup/plugin.lua without a real
// shell or disk: `path_bins` answers `where`/`command -v`, `files` stands in
// for the workspace and is what thor.read/thor.write touch.
@(private = "file")
Fake_Env :: struct {
    os_kind:   string, // "windows", "darwin" or "linux"
    path_bins: map[string]string,
    files:     map[string]string,
    docs:      map[string]string,
    printed:   [dynamic]string,
}

// Every branch returns a context.allocator-owned string: api_exec frees the
// result with the manager's allocator regardless of what allocated it, so a
// temp_allocator or literal return here is a mismatched free.
@(private = "file")
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
@(private = "file")
fake_workspace :: proc(host: rawptr) -> string {
    return `C:\fake\workspace`
}

// The absolute path resolve_path (sandbox.odin) computes for `rel` under the
// fake workspace — the key fake_read/fake_write/fake_doc actually see.
@(private = "file")
resolved :: proc(rel: string) -> string {
    full, _ := filepath.join({fake_workspace(nil), rel}, context.temp_allocator)
    clean, err := filepath.abs(full, context.temp_allocator)
    if err != nil {
        clean, _ = filepath.clean(full, context.temp_allocator)
    }
    return clean
}

@(private = "file")
fake_read :: proc(host: rawptr, path: string) -> string {
    env := cast(^Fake_Env) host
    if v, ok := env.files[path]; ok {
        return strings.clone(v)
    }
    return strings.clone("")
}

@(private = "file")
fake_write :: proc(host: rawptr, path: string, text: string) {
    env := cast(^Fake_Env) host
    if old, ok := env.files[path]; ok {
        delete(old)
    }
    env.files[path] = strings.clone(text)
}

@(private = "file")
fake_doc :: proc(host: rawptr, path: string, text: string, focus: bool) {
    env := cast(^Fake_Env) host
    if old, ok := env.docs[path]; ok {
        delete(old)
    }
    env.docs[path] = strings.clone(text)
}

@(private = "file")
fake_print :: proc(host: rawptr, text: string) {
    env := cast(^Fake_Env) host
    append(&env.printed, strings.clone(text))
}

@(private = "file")
fake_pick :: proc(host: rawptr, label: string, items: []string) {
    // The test resolves the pick itself via manager_dialog_text.
}

// Loads the real plugins/lsp-setup/plugin.lua against a fake host, runs
// lsp-status and checks the report names both an installed and a missing
// server, then runs lsp-install, answers its picker, and checks the install
// command landed in tasks.json rather than being run directly — the plugin
// call budget cannot survive a real installer, only shell.Session (a task
// run from the console) can.
@(test)
test_lsp_setup_status_and_install :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env: Fake_Env
    env.os_kind = "windows"
    env.path_bins = make(map[string]string)
    env.files = make(map[string]string)
    env.docs = make(map[string]string)
    env.printed = make([dynamic]string)
    defer {
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
    env.path_bins["clangd"] = `C:\llvm\bin\clangd.exe`

    manager_set_host(&m, Host {
        data      = &env,
        exec      = fake_exec,
        read      = fake_read,
        write     = fake_write,
        doc       = fake_doc,
        print     = fake_print,
        pick      = fake_pick,
        workspace = fake_workspace,
    })

    manager_load(&m)
    testing.expect(t, supports(&m, ".odin"), "the rest of the bundled plugins still loaded")

    testing.expect(t, manager_run_command(&m, "lsp-status"), "lsp-status ran")
    status, has_status := env.docs[resolved(".thor/lsp-status.md")]
    testing.expect(t, has_status, "lsp-status wrote a report")
    testing.expect(t, strings.contains(status, "found: `C:\\llvm\\bin\\clangd.exe`"), "clangd reported as found")
    testing.expect(t, strings.contains(status, "rust-analyzer (Rust)") && strings.contains(status, "not found on PATH"),
        "a missing server is reported")

    testing.expect(t, manager_run_command(&m, "lsp-install"), "lsp-install ran")
    manager_dialog_text(&m, "rust-analyzer (Rust)")

    tasks_json, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "lsp-install wrote tasks.json")
    testing.expect(t, strings.contains(tasks_json, "rustup component add rust-analyzer"),
        "the install command landed in the task, not run through thor.exec")
    testing.expect(t, strings.contains(tasks_json, "Install rust-analyzer (Rust)"), "the task is named after the server")
}

// The JSON round trip must not clobber a task the user already has: adding a
// second install task on top of an existing tasks.json keeps the first entry
// intact instead of losing it to a naive rewrite.
@(test)
test_lsp_setup_install_preserves_existing_tasks :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env: Fake_Env
    env.os_kind = "linux"
    env.path_bins = make(map[string]string)
    env.files = make(map[string]string)
    env.docs = make(map[string]string)
    env.printed = make([dynamic]string)
    defer {
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
    env.files[resolved(".thor/tasks.json")] = strings.clone(`{
    "tasks": [
        { "name": "run", "command": "odin run build.odin -file -- run" }
    ]
}
`)

    manager_set_host(&m, Host {
        data      = &env,
        exec      = fake_exec,
        read      = fake_read,
        write     = fake_write,
        doc       = fake_doc,
        print     = fake_print,
        pick      = fake_pick,
        workspace = fake_workspace,
    })

    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "lsp-install"), "lsp-install ran")
    manager_dialog_text(&m, "gopls (Go)")

    tasks_json := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, `"run"`) && strings.contains(tasks_json, "odin run build.odin"),
        "the pre-existing task survived")
    testing.expect(t, strings.contains(tasks_json, "go install golang.org/x/tools/gopls@latest"),
        "the new task was appended")
}
