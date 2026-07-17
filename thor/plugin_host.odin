package thor

import "core:os"
import "core:path/filepath"
import "core:strings"

import "../plugin"
import "../setting"
import "../textedit"
import "../ui"
import "../widgets"

// A top-bar button a plugin added via thor.button; carries the command it runs.
Plugin_Top_Button :: struct {
    thor:    ^Thor,
    label:   string, // owned; the button borrows it as its text
    command: string, // owned
    button:  ^widgets.Button, // the top-bar button, kept so a theme change recolors it
}

// Host services handed to the plugin manager (see plugin.manager_set_host),
// so a Lua plugin can reach Thor without the plugin package depending on it.

// thor.print(text): append plugin output to the console, revealing it if hidden.
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

// thor.doc(path, text, focus): renders plugin text into an editor tab. Writes
// the file, and replaces an already-open buffer in place so a plugin can refresh
// a live view without reopening or stealing focus. `focus` reveals it first time.
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

// thor.exec(command): runs `command` in the workspace via cmd.exe and returns
// its combined output. Synchronous, so plugins should keep commands quick.
thor_plugin_exec :: proc(host: rawptr, command: string) -> string {
    thor := cast(^Thor) host
    return run_command(command, thor.workspace_dir)
}

// thor.button(label, command): adds a flat top-bar button, just after Help,
// that runs the named plugin command when clicked.
thor_plugin_button :: proc(host: rawptr, label: string, command: string) {
    thor := cast(^Thor) host

    pb := new(Plugin_Top_Button)
    pb.thor = thor
    pb.label = strings.clone(label)
    pb.command = strings.clone(command)
    append(&thor.plugin_buttons, pb)

    button := thor_create_menu_button(thor, "plugin-button", pb.label)
    pb.button = button
    widgets.button_set_on_click(button, thor_plugin_button_click, pb)

    if thor.top_bar_plugin_anchor != nil {
        ui.widget_insert_after(thor.top_bar_plugin_anchor, &button.widget)
    } else {
        widgets.append_child(&thor.top_bar.widget, &button.widget)
    }
    thor.top_bar_plugin_anchor = &button.widget
}

// Click handler shared by every plugin top-bar button; runs its command.
thor_plugin_button_click :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    pb := cast(^Plugin_Top_Button) data
    plugin.manager_run_command(&pb.thor.plugins, pb.command)
}

// Help -> Tutorial: starts the interactive tutorial plugin
// (plugins/tutorial/plugin.lua).
thor_cmd_tutorial :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if !plugin.manager_run_command(&thor.plugins, "tutorial") {
        thor_plugin_print(thor, "\nThe tutorial plugin is not installed (plugins/tutorial/plugin.lua).\n")
    }
}
