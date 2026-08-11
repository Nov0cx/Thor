package plugin

import "core:strings"
import "core:testing"

// Loads the real plugins/zls-setup/plugin.lua against a fake host:
// zls-status reports found/not-found correctly, then zls-install (missing
// case, macOS) confirms and lands the brew install command in tasks.json.
// zls has no Linux installer, so both tests use OSes it does support.
@(test)
test_zls_setup_status_and_install :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("darwin")
    defer destroy_fake_env(&env)

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, supports(&m, ".odin"), "the rest of the bundled plugins still loaded")

    env.path_bins["zls"] = "/usr/local/bin/zls"
    testing.expect(t, manager_run_command(&m, "zls-status"), "zls-status ran")
    found := env.docs[resolved(".thor/zls-status.md")]
    testing.expect(t, strings.contains(found, "found: `/usr/local/bin/zls`"), "reported as found")

    delete_key(&env.path_bins, "zls")
    testing.expect(t, manager_run_command(&m, "zls-status"), "zls-status ran again")
    missing := env.docs[resolved(".thor/zls-status.md")]
    testing.expect(t, strings.contains(missing, "not found on PATH"), "reported as missing")

    testing.expect(t, manager_run_command(&m, "zls-install"), "zls-install ran")
    manager_dialog_confirm(&m)

    tasks_json, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "zls-install wrote tasks.json")
    testing.expect(t, strings.contains(tasks_json, "brew install zls"),
        "the macOS install command landed in the task")
    testing.expect(t, strings.contains(tasks_json, "Install zls (Zig)"), "the task is named after the server")
}

// On Windows the winget installer applies instead, and a pre-existing task
// must survive the rewrite.
@(test)
test_zls_setup_install_preserves_existing_tasks :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("windows")
    defer destroy_fake_env(&env)
    env.files[resolved(".thor/tasks.json")] = strings.clone(`{
    "tasks": [
        { "name": "run", "command": "odin run build.odin -file -- run" }
    ]
}
`)

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "zls-install"), "zls-install ran")
    manager_dialog_confirm(&m)

    tasks_json := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, `"run"`) && strings.contains(tasks_json, "odin run build.odin"),
        "the pre-existing task survived")
    testing.expect(t, strings.contains(tasks_json, "winget install -e --id zigtools.zls"),
        "the new task used the Windows installer")
}
