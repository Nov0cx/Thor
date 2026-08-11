package plugin

import "core:strings"
import "core:testing"

// Loads the real plugins/clangd-setup/plugin.lua against a fake host:
// clangd-status reports found/not-found correctly, then clangd-install
// (missing case) confirms and lands the install command in tasks.json.
@(test)
test_clangd_setup_status_and_install :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("windows")
    defer destroy_fake_env(&env)

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, supports(&m, ".odin"), "the rest of the bundled plugins still loaded")

    env.path_bins["clangd"] = `C:\llvm\bin\clangd.exe`
    testing.expect(t, manager_run_command(&m, "clangd-status"), "clangd-status ran")
    found := env.docs[resolved(".thor/clangd-status.md")]
    testing.expect(t, strings.contains(found, "found: `C:\\llvm\\bin\\clangd.exe`"), "reported as found")

    delete_key(&env.path_bins, "clangd")
    testing.expect(t, manager_run_command(&m, "clangd-status"), "clangd-status ran again")
    missing := env.docs[resolved(".thor/clangd-status.md")]
    testing.expect(t, strings.contains(missing, "not found on PATH"), "reported as missing")

    testing.expect(t, manager_run_command(&m, "clangd-install"), "clangd-install ran")
    manager_dialog_confirm(&m)

    tasks_json, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "clangd-install wrote tasks.json")
    testing.expect(t, strings.contains(tasks_json, "winget install -e --id LLVM.LLVM"),
        "the install command landed in the task, not run through thor.exec")
    testing.expect(t, strings.contains(tasks_json, "Install clangd (C / C++)"), "the task is named after the server")
}

// The JSON round trip must not clobber a task the user already has.
@(test)
test_clangd_setup_install_preserves_existing_tasks :: proc(t: ^testing.T) {
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
    testing.expect(t, manager_run_command(&m, "clangd-install"), "clangd-install ran")
    manager_dialog_confirm(&m)

    tasks_json := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, `"run"`) && strings.contains(tasks_json, "odin run build.odin"),
        "the pre-existing task survived")
    testing.expect(t, strings.contains(tasks_json, "sudo apt-get update && sudo apt-get install -y clangd"),
        "the new task used the Linux installer")
}

// A workspace that already has compile_commands.json, or a .clangd that
// already names a database, is left alone entirely.
@(test)
test_clangd_configure_already_present_is_noop :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("linux")
    defer destroy_fake_env(&env)
    env.files[resolved("compile_commands.json")] = strings.clone("[]\n")

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran")

    _, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, !has_tasks, "no task was added")
    _, has_clangd := env.files[resolved(".clangd")]
    testing.expect(t, !has_clangd, "no .clangd was written")
    testing.expect(t, strings.contains(env.printed[len(env.printed) - 1], "already"),
        "reported that the workspace is already configured")
}

// CMake: a task is added to configure the build, and a .clangd redirect is
// written since clangd's own root-marker walk never looks inside build/.
@(test)
test_clangd_configure_cmake_adds_task_and_dot_clangd :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("linux")
    defer destroy_fake_env(&env)
    env.files[resolved("CMakeLists.txt")] = strings.clone("cmake_minimum_required(VERSION 3.20)\n")

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran")

    tasks_json, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "a task was added")
    testing.expect(t, strings.contains(tasks_json, "cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON"),
        "the task configures CMake with compile commands export")

    dot_clangd, has_clangd := env.files[resolved(".clangd")]
    testing.expect(t, has_clangd, ".clangd was written")
    testing.expect(t, strings.contains(dot_clangd, "CompilationDatabase: build"), ".clangd points at build/")
}

// An existing .clangd (for any other reason) is never clobbered, even though
// the CMake task is still added.
@(test)
test_clangd_configure_cmake_leaves_existing_dot_clangd_alone :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("linux")
    defer destroy_fake_env(&env)
    env.files[resolved("CMakeLists.txt")] = strings.clone("cmake_minimum_required(VERSION 3.20)\n")
    env.files[resolved(".clangd")] = strings.clone("CompileFlags:\n  Add: [-Wall]\n")

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran")

    _, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "the CMake task is still added")

    dot_clangd := env.files[resolved(".clangd")]
    testing.expect(t, dot_clangd == "CompileFlags:\n  Add: [-Wall]\n", "the existing .clangd was left untouched")
}

// Bazel (bzlmod): the hedron extractor snippet is confirmed and written into
// MODULE.bazel and a root BUILD.bazel, then a task is added to run it.
@(test)
test_clangd_configure_bazel_writes_snippet_and_task :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("linux")
    defer destroy_fake_env(&env)
    env.files[resolved("MODULE.bazel")] = strings.clone("module(name = \"my_project\")\n")

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran")
    manager_dialog_confirm(&m)

    module_text := env.files[resolved("MODULE.bazel")]
    testing.expect(t, strings.contains(module_text, "hedron_compile_commands"), "MODULE.bazel now references hedron's extractor")

    build_text, has_build := env.files[resolved("BUILD.bazel")]
    testing.expect(t, has_build, "BUILD.bazel was created")
    testing.expect(t, strings.contains(build_text, "hedron_compile_commands//:refresh_compile_commands.bzl"),
        "BUILD.bazel loads the refresh rule")
    testing.expect(t, strings.contains(build_text, `name = "refresh_compile_commands"`), "BUILD.bazel defines the target")

    tasks_json, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, has_tasks, "a task was added")
    testing.expect(t, strings.contains(tasks_json, "bazel run //:refresh_compile_commands"), "the task runs the refresh target")
}

// Re-running clangd-configure once hedron is already wired in must not
// prompt again or duplicate either file's content.
@(test)
test_clangd_configure_bazel_is_idempotent :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("linux")
    defer destroy_fake_env(&env)
    env.files[resolved("MODULE.bazel")] = strings.clone("module(name = \"my_project\")\n")

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "first clangd-configure ran")
    manager_dialog_confirm(&m)

    module_after_first := strings.clone(env.files[resolved("MODULE.bazel")], context.temp_allocator)
    build_after_first := strings.clone(env.files[resolved("BUILD.bazel")], context.temp_allocator)

    testing.expect(t, manager_run_command(&m, "clangd-configure"), "second clangd-configure ran")
    testing.expect(t, m.dialog.ref == NOREF, "the second run did not open a confirm dialog")

    testing.expect(t, env.files[resolved("MODULE.bazel")] == module_after_first, "MODULE.bazel is unchanged by the second run")
    testing.expect(t, env.files[resolved("BUILD.bazel")] == build_after_first, "BUILD.bazel is unchanged by the second run")
}

// A legacy WORKSPACE with no MODULE.bazel only gets a hint — this plugin
// automates bzlmod alone, never the WORKSPACE-based setup.
@(test)
test_clangd_configure_bazel_legacy_workspace_only_hints :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("linux")
    defer destroy_fake_env(&env)
    env.files[resolved("WORKSPACE")] = strings.clone("workspace(name = \"my_project\")\n")

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran")

    _, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, !has_tasks, "no task was added")
    testing.expect(t, strings.contains(env.printed[len(env.printed) - 1], "WORKSPACE"),
        "the hint mentions the legacy WORKSPACE setup")
}

// Make on POSIX: bear runs the build directly when present; when it is not,
// the plugin offers (and, once confirmed, adds) a task to install it first.
@(test)
test_clangd_configure_make_posix :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("linux")
    defer destroy_fake_env(&env)
    env.files[resolved("Makefile")] = strings.clone("all:\n\tcc -c main.c\n")

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)

    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran without bear")
    manager_dialog_confirm(&m)
    tasks_json := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, "Install bear") && strings.contains(tasks_json, "apt-get"),
        "a bear-install task was added when bear is missing")

    env.path_bins["bear"] = "/usr/bin/bear"
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran with bear")
    tasks_json = env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, "bear -- make"), "the make task was added once bear is on PATH")
}

// Make on Windows: compiledb runs the build directly when present; when it
// is not, the plugin offers a task to install it via pip first.
@(test)
test_clangd_configure_make_windows :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("windows")
    defer destroy_fake_env(&env)
    env.files[resolved("Makefile")] = strings.clone("all:\n\tcl /c main.c\n")

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)

    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran without compiledb")
    manager_dialog_confirm(&m)
    tasks_json := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, "Install compiledb") && strings.contains(tasks_json, "pip install compiledb"),
        "a compiledb-install task was added when compiledb is missing")

    env.path_bins["compiledb"] = `C:\Python\Scripts\compiledb.exe`
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran with compiledb")
    tasks_json = env.files[resolved(".thor/tasks.json")]
    testing.expect(t, strings.contains(tasks_json, "compiledb make"), "the make task was added once compiledb is on PATH")
}

// A bare build.sh with no known build system only gets a hint to re-run it
// through bear — never a task, since running an arbitrary script is not
// something this plugin should do on its own.
@(test)
test_clangd_configure_bare_script_posix_hint_only :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("linux")
    defer destroy_fake_env(&env)
    env.files[resolved("build.sh")] = strings.clone("#!/bin/sh\ncc -c main.c\n")

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran")

    _, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, !has_tasks, "no task was added for a bare script")
    testing.expect(t, strings.contains(env.printed[len(env.printed) - 1], "bear -- ./build.sh"),
        "the hint suggests wrapping the script with bear")
}

// A bare build.bat on Windows has no bear equivalent, so it only explains
// that automation is not possible here.
@(test)
test_clangd_configure_bare_script_windows_hint_only :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("windows")
    defer destroy_fake_env(&env)
    env.files[resolved("build.bat")] = strings.clone("cl /c main.c\n")

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran")

    _, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, !has_tasks, "no task was added for a bare script")
    testing.expect(t, strings.contains(env.printed[len(env.printed) - 1], "no bear equivalent on Windows"),
        "the hint explains there is no automatic option")
}

// Nothing recognisable at the workspace root: a plain, honest no-op.
@(test)
test_clangd_configure_nothing_found :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    env := make_fake_env("linux")
    defer destroy_fake_env(&env)

    manager_set_host(&m, fake_host(&env))
    manager_load(&m)
    testing.expect(t, manager_run_command(&m, "clangd-configure"), "clangd-configure ran")

    _, has_tasks := env.files[resolved(".thor/tasks.json")]
    testing.expect(t, !has_tasks, "no task was added")
    testing.expect(t, strings.contains(env.printed[len(env.printed) - 1], "nothing to configure"),
        "reported that nothing was found")
}
