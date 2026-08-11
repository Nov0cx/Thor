package plugin

import "core:strings"
import "core:testing"

// Loads the real plugins/gopls-setup/plugin.lua against a fake host:
// gopls-status reports found/not-found correctly, then gopls-install
// (missing case) confirms and lands the install command in tasks.json
// rather than running it directly.
@(test)
test_gopls_setup_status_and_install :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("windows")
    defer destroy_fake_env(&env)

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, supports(&m, ".odin"), "the rest of the bundled plugins still loaded")

    env.path_bins["gopls"] = `C:\go\bin\gopls.exe`
    testing.expect(t, manager_run_command(&m, "gopls-status"), "gopls-status ran")
    found := env.docs[resolved(".thor/gopls-status.md")]
    testing.expect(t, strings.contains(found, "found: `C:\\go\\bin\\gopls.exe`"), "reported as found")

    delete_key(&env.path_bins, "gopls")
    testing.expect(t, manager_run_command(&m, "gopls-status"), "gopls-status ran again")
    missing := env.docs[resolved(".thor/gopls-status.md")]
    testing.expect(t, strings.contains(missing, "not found on PATH"), "reported as missing")

    testing.expect(t, manager_run_command(&m, "gopls-install"), "gopls-install ran")
    manager_dialog_confirm(&m)

    tasks_json, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "gopls-install wrote tasks.json")
    testing.expect(t, strings.contains(tasks_json, "go install golang.org/x/tools/gopls@latest"),
        "the install command landed in the task, not run through thor.exec")
    testing.expect(t, strings.contains(tasks_json, "Install gopls (Go)"), "the task is named after the server")
}

// The JSON round trip must not clobber a task the user already has.
@(test)
test_gopls_setup_install_preserves_existing_tasks :: proc(t: ^testing.T) {
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
    testing.expect(t, manager_run_command(&m, "gopls-install"), "gopls-install ran")
    manager_dialog_confirm(&m)

    tasks_json := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, `"run"`) && strings.contains(tasks_json, "odin run build.odin"),
        "the pre-existing task survived")
    testing.expect(t, strings.contains(tasks_json, "go install golang.org/x/tools/gopls@latest"),
        "the new task was appended")
}
