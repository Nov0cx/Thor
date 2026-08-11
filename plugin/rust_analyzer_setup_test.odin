package plugin

import "core:strings"
import "core:testing"

// Loads the real plugins/rust-analyzer-setup/plugin.lua against a fake host:
// rust-analyzer-status reports found/not-found correctly, then
// rust-analyzer-install (missing case) confirms and lands the install
// command in tasks.json rather than running it directly — the plugin call
// budget cannot survive a real installer, only shell.Session (a task run
// from the console) can.
@(test)
test_rust_analyzer_setup_status_and_install :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("windows")
    defer destroy_fake_env(&env)

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, supports(&m, ".odin"), "the rest of the bundled plugins still loaded")

    env.path_bins["rust-analyzer"] = `C:\tools\rust-analyzer.exe`
    testing.expect(t, manager_run_command(&m, "rust-analyzer-status"), "rust-analyzer-status ran")
    found := env.docs[resolved(".thor/rust-analyzer-status.md")]
    testing.expect(t, strings.contains(found, "found: `C:\\tools\\rust-analyzer.exe`"), "reported as found")

    delete_key(&env.path_bins, "rust-analyzer")
    testing.expect(t, manager_run_command(&m, "rust-analyzer-status"), "rust-analyzer-status ran again")
    missing := env.docs[resolved(".thor/rust-analyzer-status.md")]
    testing.expect(t, strings.contains(missing, "not found on PATH"), "reported as missing")

    testing.expect(t, manager_run_command(&m, "rust-analyzer-install"), "rust-analyzer-install ran")
    manager_dialog_confirm(&m)

    tasks_json, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "rust-analyzer-install wrote tasks.json")
    testing.expect(t, strings.contains(tasks_json, "rustup component add rust-analyzer"),
        "the install command landed in the task, not run through thor.exec")
    testing.expect(t, strings.contains(tasks_json, "Install rust-analyzer (Rust)"), "the task is named after the server")
}

// The JSON round trip must not clobber a task the user already has: adding a
// second install task on top of an existing tasks.json keeps the first entry
// intact instead of losing it to a naive rewrite.
@(test)
test_rust_analyzer_setup_install_preserves_existing_tasks :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("linux")
    defer destroy_fake_env(&env)
    env.files[resolved(".thor/tasks.json")] = strings.clone(`{
    "tasks": [
        { "name": "run", "command": "odin run build.odin -file -- run" }
    ]
}
`)

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "rust-analyzer-install"), "rust-analyzer-install ran")
    manager_dialog_confirm(&m)

    tasks_json := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, `"run"`) && strings.contains(tasks_json, "odin run build.odin"),
        "the pre-existing task survived")
    testing.expect(t, strings.contains(tasks_json, "rustup component add rust-analyzer"),
        "the new task was appended")
}
