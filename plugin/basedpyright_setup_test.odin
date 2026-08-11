package plugin

import "core:strings"
import "core:testing"

// Loads the real plugins/basedpyright-setup/plugin.lua against a fake host:
// basedpyright-status reports found/not-found correctly (checked against
// basedpyright-langserver, not the package name), then basedpyright-install
// (missing case, Windows) confirms and lands the Windows-specific install
// command in tasks.json.
@(test)
test_basedpyright_setup_status_and_install :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("windows")
    defer destroy_fake_env(&env)

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, supports(&m, ".odin"), "the rest of the bundled plugins still loaded")

    env.path_bins["basedpyright-langserver"] = `C:\Python\Scripts\basedpyright-langserver.exe`
    testing.expect(t, manager_run_command(&m, "basedpyright-status"), "basedpyright-status ran")
    found := env.docs[resolved(".thor/basedpyright-status.md")]
    testing.expect(t, strings.contains(found, "found: `C:\\Python\\Scripts\\basedpyright-langserver.exe`"), "reported as found")

    delete_key(&env.path_bins, "basedpyright-langserver")
    testing.expect(t, manager_run_command(&m, "basedpyright-status"), "basedpyright-status ran again")
    missing := env.docs[resolved(".thor/basedpyright-status.md")]
    testing.expect(t, strings.contains(missing, "not found on PATH"), "reported as missing")

    testing.expect(t, manager_run_command(&m, "basedpyright-install"), "basedpyright-install ran")
    manager_dialog_confirm(&m)

    tasks_json, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "basedpyright-install wrote tasks.json")
    testing.expect(t, strings.contains(tasks_json, "python -m pip install -U basedpyright"),
        "the Windows install command landed in the task")
    testing.expect(t, strings.contains(tasks_json, "Install basedpyright (Python)"), "the task is named after the server")
}

// On a non-Windows OS the "any" installer applies instead, and a
// pre-existing task must survive the rewrite.
@(test)
test_basedpyright_setup_install_preserves_existing_tasks :: proc(t: ^testing.T) {
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
    testing.expect(t, manager_run_command(&m, "basedpyright-install"), "basedpyright-install ran")
    manager_dialog_confirm(&m)

    tasks_json := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, `"run"`) && strings.contains(tasks_json, "odin run build.odin"),
        "the pre-existing task survived")
    testing.expect(t, strings.contains(tasks_json, "python3 -m pip install -U basedpyright"),
        "the new task used the non-Windows installer")
}
