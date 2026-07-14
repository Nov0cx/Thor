package thor

import "core:os"
import "core:path/filepath"

import "../plugin"
import "../setting"
import "../textedit"
import "../ui"
import "../widgets"

// Host services handed to the plugin manager (see plugin.manager_set_host).
// These let a Lua plugin print to the console and read the live keybinds without
// the plugin package depending on Thor.

// thor.print(text): append plugin output to the console, revealing it if hidden
// so the user actually sees interactive feedback (e.g. the tutorial).
thor_plugin_print :: proc(host: rawptr, text: string) {
    thor := cast(^Thor) host
    if thor.console == nil {
        return
    }
    widgets.console_append(thor.console, text)
    if !ui.signal_get(&thor.console_visible) {
        ui.signal_set(&thor.console_visible, true)
        thor_apply_layout_state(thor)
    }
}

// thor.keybind(action): the chord currently bound to `action` in keybinds.json,
// formatted for display, so plugins present the user's real shortcuts.
thor_plugin_keybind :: proc(host: rawptr, action: string) -> (string, bool) {
    thor := cast(^Thor) host
    if kb, ok := setting.keybind(&thor.config, action); ok {
        if s := setting.keybind_to_string(kb, context.temp_allocator); s != "" {
            return s, true
        }
    }
    return "", false
}

// thor.doc(path, text, focus): renders plugin-authored text into an editor tab.
// The file is written to disk (so it can be saved and reloaded like any other),
// and if a tab for it is already open its buffer is replaced in place, so a
// plugin can refresh a live view (the tutorial marks challenges done as you play)
// without reopening the tab or stealing focus. `focus` reveals it the first time.
thor_plugin_doc :: proc(host: rawptr, path: string, text: string, focus: bool) {
    thor := cast(^Thor) host

    // write_entire_file does not create parent directories.
    if dir := filepath.dir(path); dir != "" && dir != "." && !os.exists(dir) {
        os.make_directory(dir)
    }
    if werr := os.write_entire_file(path, transmute([]byte) text); werr != nil {
        return
    }

    canonical := path
    if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
        canonical = abs
    }
    for file, index in thor.open_files {
        if file.path == canonical {
            if file.loaded {
                // Replace the buffer to match what we just wrote and keep it
                // marked clean, so the refresh doesn't trigger an autosave.
                textedit.set_text(&file.state, text)
                file.saved_revision = file.state.revision
            }
            if focus {
                thor_set_active_file(thor, index)
                thor.ui_context.focused = &thor.editor.widget
            }
            return
        }
    }

    thor_open_file(thor, path)
}

// Help -> Tutorial: starts the interactive tutorial plugin. It opens a tutorial
// document that explains every action and challenges you to perform each bound
// shortcut, advancing as you do; see plugins/tutorial/plugin.lua.
thor_cmd_tutorial :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if !plugin.manager_run_command(&thor.plugins, "tutorial") {
        thor_plugin_print(thor, "\nThe tutorial plugin is not installed (plugins/tutorial/plugin.lua).\n")
    }
}
