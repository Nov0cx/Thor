package plugin

import "core:strings"
import "core:testing"

// Loads the real plugins/lua-language-server-setup/plugin.lua against a
// fake host: lua-language-server-status reports found/not-found correctly,
// then lua-language-server-install (missing case, Windows) confirms and
// lands the winget install command in tasks.json.
@(test)
test_lua_language_server_setup_status_and_install :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("windows")
    defer destroy_fake_env(&env)

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, supports(&m, ".odin"), "the rest of the bundled plugins still loaded")

    env.path_bins["lua-language-server"] = `C:\tools\lua-language-server.exe`
    testing.expect(t, manager_run_command(&m, "lua-language-server-status"), "lua-language-server-status ran")
    found := env.docs[resolved(".thor/lua-language-server-status.md")]
    testing.expect(t, strings.contains(found, "found: `C:\\tools\\lua-language-server.exe`"), "reported as found")

    delete_key(&env.path_bins, "lua-language-server")
    testing.expect(t, manager_run_command(&m, "lua-language-server-status"), "lua-language-server-status ran again")
    missing := env.docs[resolved(".thor/lua-language-server-status.md")]
    testing.expect(t, strings.contains(missing, "not found on PATH"), "reported as missing")

    testing.expect(t, manager_run_command(&m, "lua-language-server-install"), "lua-language-server-install ran")
    manager_dialog_confirm(&m)

    tasks_json, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "lua-language-server-install wrote tasks.json")
    testing.expect(t, strings.contains(tasks_json, "winget install -e --id LuaLS.lua-language-server"),
        "the Windows install command landed in the task")
    testing.expect(t, strings.contains(tasks_json, "Install lua-language-server (Lua)"), "the task is named after the server")
}

// On Linux the apt installer applies instead, and a pre-existing task must
// survive the rewrite.
@(test)
test_lua_language_server_setup_install_preserves_existing_tasks :: proc(t: ^testing.T) {
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
    testing.expect(t, manager_run_command(&m, "lua-language-server-install"), "lua-language-server-install ran")
    manager_dialog_confirm(&m)

    tasks_json := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, `"run"`) && strings.contains(tasks_json, "odin run build.odin"),
        "the pre-existing task survived")
    testing.expect(t, strings.contains(tasks_json, "sudo apt-get update && sudo apt-get install -y lua-language-server"),
        "the new task used the Linux installer")
}
