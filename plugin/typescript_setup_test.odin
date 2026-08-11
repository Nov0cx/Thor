package plugin

import "core:strings"
import "core:testing"

// Loads the real plugins/typescript-setup/plugin.lua against a fake host:
// typescript-status reports found/not-found correctly, then
// typescript-install (missing case) confirms and lands the install command
// in tasks.json.
@(test)
test_typescript_setup_status_and_install :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("windows")
    defer destroy_fake_env(&env)

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, supports(&m, ".odin"), "the rest of the bundled plugins still loaded")

    env.path_bins["typescript-language-server"] = `C:\npm\typescript-language-server.cmd`
    testing.expect(t, manager_run_command(&m, "typescript-status"), "typescript-status ran")
    found := env.docs[resolved(".thor/typescript-status.md")]
    testing.expect(t, strings.contains(found, "found: `C:\\npm\\typescript-language-server.cmd`"), "reported as found")

    delete_key(&env.path_bins, "typescript-language-server")
    testing.expect(t, manager_run_command(&m, "typescript-status"), "typescript-status ran again")
    missing := env.docs[resolved(".thor/typescript-status.md")]
    testing.expect(t, strings.contains(missing, "not found on PATH"), "reported as missing")

    testing.expect(t, manager_run_command(&m, "typescript-install"), "typescript-install ran")
    manager_dialog_confirm(&m)

    tasks_json, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "typescript-install wrote tasks.json")
    testing.expect(t, strings.contains(tasks_json, "npm install -g typescript-language-server typescript"),
        "the install command landed in the task, not run through thor.exec")
    testing.expect(t, strings.contains(tasks_json, "Install typescript-language-server (TS / JS)"), "the task is named after the server")
}

// The JSON round trip must not clobber a task the user already has.
@(test)
test_typescript_setup_install_preserves_existing_tasks :: proc(t: ^testing.T) {
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
    testing.expect(t, manager_run_command(&m, "typescript-install"), "typescript-install ran")
    manager_dialog_confirm(&m)

    tasks_json := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, `"run"`) && strings.contains(tasks_json, "odin run build.odin"),
        "the pre-existing task survived")
    testing.expect(t, strings.contains(tasks_json, "npm install -g typescript-language-server typescript"),
        "the new task was appended")
}
