package thor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"

import "../plugin"
import "../setting"
import ui "../vendor/loom/loom"

// Twelve files across two directory levels, walked with a cap of 5, must stop
// at exactly 5 and report that the walk was cut short.
@(test)
test_collect_files_stops_at_the_cap :: proc(t: ^testing.T) {
    root :: "thor_collect_cap.tmp"
    sub, _ := filepath.join({root, "sub"}, context.temp_allocator)
    defer os.remove_all(root)

    testing.expect(t, os.make_directory(root) == nil, "could not create test root")
    testing.expect(t, os.make_directory(sub) == nil, "could not create test subdir")

    for i in 0 ..< 6 {
        path, _ := filepath.join({root, fmt.tprintf("a%d.tmp", i)}, context.temp_allocator)
        testing.expect(t, os.write_entire_file(path, "") == nil, "could not create test file")
    }
    for i in 0 ..< 6 {
        path, _ := filepath.join({sub, fmt.tprintf("b%d.tmp", i)}, context.temp_allocator)
        testing.expect(t, os.write_entire_file(path, "") == nil, "could not create test file")
    }

    files := thor_walk_workspace_files(root, context.temp_allocator, limit = 5, max_depth = 12)
    testing.expect_value(t, len(files), 5)
}

// A finished job built the way thor_refresh_file_index builds one, so the
// join, the free and the inflight count stay valid — matches the
// Shell_Detect_Job stub in terminal_test.odin.
@(private = "file")
file_index_stub_worker :: proc(job: ^File_Index_Job) {}

// A workspace switch while a walk is in flight makes it the wrong folder's
// list once it lands; the reap must throw it away rather than apply it,
// rather than replace an already-ready index with a stale one.
@(test)
test_file_index_reap_ignores_a_stale_workspace :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_dir = "current"

    job := new(File_Index_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.root = strings.clone("stale")
    append(&job.files, strings.clone("stale/a.odin"))
    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, file_index_stub_worker)

    thor_apply_file_index(thor, job)

    testing.expect(t, !thor.file_index_ready, "a stale walk must not become the ready index")
    testing.expect_value(t, len(thor.file_index), 0)
    testing.expect(t, !thor.file_index_inflight)
    testing.expect_value(t, thor.inflight_jobs, 0)
}

// A refresh requested while one is already running must not start a second
// walk; it coalesces into the dirty flag, picked up once the running one lands.
@(test)
test_file_index_refresh_coalesces :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_dir = "current"
    thor.file_index_inflight = true

    thor_refresh_file_index(thor)

    testing.expect(t, thor.file_index_dirty, "a refresh while one is running must coalesce into a dirty flag")
    testing.expect_value(t, thor.inflight_jobs, 0)
}

// Every palette command names a keybinds.lua action, and the shipped keybinds
// list each one, so the Settings keybinding list can bind any command.
@(test)
test_every_command_is_bindable :: proc(t: ^testing.T) {
    thor: Thor
    thor_palette_init(&thor)
    defer {
        thor_palette_clear_commands(&thor)
        thor_palette_destroy(&thor)
        delete(thor.app_binds)
    }
    thor_register_commands(&thor)

    shipped := setting.load(setting.GLOBAL_DIR)
    defer setting.destroy(&shipped)

    testing.expect(t, len(thor.palette.commands) > 0, "commands register")
    for command in thor.palette.commands {
        testing.expectf(t, command.action != "", "%q has no action name", command.title)
        testing.expectf(t, command.action in shipped.keybinds, "%q (%s) is not in settings/keybinds.lua", command.title, command.action)
    }
}

// A plugin command lands in the palette and the app binds with a plugin.<name>
// action, a name a built-in already has is left out, and a clear removes them.
@(test)
test_plugin_commands_are_bindable :: proc(t: ^testing.T) {
    thor: Thor
    thor_palette_init(&thor)
    plugin.manager_init(&thor.plugins)
    defer {
        thor_clear_plugin_commands(&thor)
        delete(thor.plugin_commands)
        plugin.manager_destroy(&thor.plugins)
        thor_palette_destroy(&thor)
        delete(thor.app_binds)
    }
    thor_register_commands(&thor)
    builtin := len(thor.palette.commands)

    source := `thor.on_command("lfs-pull", function() end) thor.on_command("tutorial", function() end)`
    testing.expect(t, plugin.manager_load_source(&thor.plugins, "git", "plugins/git", source, {}))
    thor_sync_plugin_commands(&thor)

    testing.expect_value(t, len(thor.palette.commands), builtin + 1)
    last := thor.palette.commands[len(thor.palette.commands) - 1]
    testing.expect_value(t, last.title, "Plugin: lfs-pull (git)")
    testing.expect_value(t, last.action, "plugin.lfs-pull")
    found := false
    for bind in thor.app_binds {
        found ||= bind.action == "plugin.lfs-pull"
    }
    testing.expect(t, found, "the command is an app bind")

    thor_clear_plugin_commands(&thor)
    testing.expect_value(t, len(thor.palette.commands), builtin)
}

// A focused terminal still lets the Open Settings chord through, and swallows other chords.
@(test)
test_terminal_lets_the_settings_chord_through :: proc(t: ^testing.T) {
    thor: Thor
    defer delete(thor.app_binds)
    thor.console_focused = true
    append(&thor.app_binds, App_Bind{action = "open_settings_gui", key = setting.Keybind{key = .Comma, mods = {.Ctrl}}})

    testing.expect(t, !thor_terminal_owns_key(&thor, ui.Key_Event{key = .Comma, mods = {.Ctrl}}), "the settings chord reaches the app")
    testing.expect(t, thor_terminal_owns_key(&thor, ui.Key_Event{key = .A, mods = {.Ctrl}}), "another chord belongs to the shell")
    testing.expect(t, thor_terminal_owns_key(&thor, ui.Key_Event{key = .Comma}), "a bare comma belongs to the shell")
}

// The title bar button names the install step, and the percent follows the bytes on disk.
@(test)
test_update_button_shows_the_install_step :: proc(t: ^testing.T) {
    job := Update_Job{}
    thor: Thor
    thor.update_state = .Installing
    thor.update_job = &job
    thor.update_size = 200

    label, _, shown := thor_update_button_state(&thor)
    testing.expect(t, shown, "the button shows while installing")
    testing.expect_value(t, label, "Downloading...")

    thor.update_bytes = 50
    job.phase = .Downloading
    testing.expect_value(t, thor_update_percent(&thor), 25)
    label, _, _ = thor_update_button_state(&thor)
    testing.expect_value(t, label, "Downloading 25%")

    thor.update_bytes = 900
    testing.expect_value(t, thor_update_percent(&thor), 100)

    job.phase = .Verifying
    label, _, _ = thor_update_button_state(&thor)
    testing.expect_value(t, label, "Verifying...")
    job.phase = .Extracting
    label, _, _ = thor_update_button_state(&thor)
    testing.expect_value(t, label, "Installing...")
}
