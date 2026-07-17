package thor

import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

import "../plugin"
import "../setting"
import "../textedit"
import "../ui"
import "../widgets"

// One row of a plugin dropdown (see thor.menu). A separator carries no command.
Plugin_Menu_Item :: struct {
    thor:      ^Thor,
    label:     string, // owned; the menu borrows it as its text
    command:   string, // owned
    separator: bool,
}

// A top-bar button a plugin added via thor.button (flat, runs `command`) or
// thor.menu (a dropdown built from `entries`, in which case `command` is empty).
Plugin_Top_Button :: struct {
    thor:    ^Thor,
    label:   string, // owned; the button borrows it as its text
    command: string, // owned
    entries: [dynamic]Plugin_Menu_Item, // owned; empty for a flat button
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

// thor.workspace(): the absolute path of the open workspace directory.
thor_plugin_workspace :: proc(host: rawptr) -> string {
    thor := cast(^Thor) host
    return thor.workspace_dir
}

// thor.active_path(): absolute path of the file in the active tab, or "" when
// no file is open (empty maps to nil in Lua).
thor_plugin_active_path :: proc(host: rawptr) -> string {
    thor := cast(^Thor) host
    index := ui.signal_get(&thor.active_file)
    if index < 0 || index >= len(thor.open_files) {
        return ""
    }
    return thor.open_files[index].path
}

// thor.read(path): the buffer text for `path`. Prefers the live in-memory buffer
// (so a plugin sees unsaved edits, e.g. a commit message being typed) and falls
// back to disk. The result is owned by the caller (see plugin.Read_Proc).
thor_plugin_read :: proc(host: rawptr, path: string) -> string {
    thor := cast(^Thor) host

    canonical := path
    if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
        canonical = abs
    }
    for file in thor.open_files {
        if file.path == canonical && file.loaded {
            return textedit.text(&file.state, context.allocator)
        }
    }
    if data, err2 := os.read_entire_file(canonical, context.allocator); err2 == nil {
        return string(data)
    }
    return strings.clone("")
}

// thor.write(path, text): writes `text` to disk without opening or touching any
// tab. Used by plugins for scratch files (e.g. a commit message passed to
// `git commit -F`). Creates the parent directory like thor.doc does.
thor_plugin_write :: proc(host: rawptr, path: string, text: string) {
    if dir := filepath.dir(path); dir != "" && dir != "." && !os.exists(dir) {
        os.make_directory(dir)
    }
    _ = os.write_entire_file(path, transmute([]byte) text)
}

// thor.refresh_git(): recompute the tree's git-status colouring after a plugin
// changed the working tree.
thor_plugin_refresh_git :: proc(host: rawptr) {
    thor := cast(^Thor) host
    thor_refresh_git_status(thor)
}

// Creates a top-bar button labelled `label`, linked in just after Help (or the
// previous plugin button), and records it for theming and teardown.
@(private = "file")
thor_plugin_add_button :: proc(thor: ^Thor, label: string) -> ^Plugin_Top_Button {
    pb := new(Plugin_Top_Button)
    pb.thor = thor
    pb.label = strings.clone(label)
    append(&thor.plugin_buttons, pb)

    button := thor_create_menu_button(thor, "plugin-button", pb.label)
    pb.button = button

    if thor.top_bar_plugin_anchor != nil {
        ui.widget_insert_after(thor.top_bar_plugin_anchor, &button.widget)
    } else {
        widgets.append_child(&thor.top_bar.widget, &button.widget)
    }
    thor.top_bar_plugin_anchor = &button.widget
    return pb
}

// thor.button(label, command): adds a flat top-bar button, just after Help,
// that runs the named plugin command when clicked.
thor_plugin_button :: proc(host: rawptr, label: string, command: string) {
    thor := cast(^Thor) host
    pb := thor_plugin_add_button(thor, label)
    pb.command = strings.clone(command)
    widgets.button_set_on_click(pb.button, thor_plugin_button_click, pb)
}

// thor.menu(label, entries): adds a top-bar dropdown button that opens a menu of
// the given rows (each running its command) when clicked, like File/Edit/Help.
thor_plugin_menu :: proc(host: rawptr, label: string, entries: []plugin.Menu_Entry) {
    thor := cast(^Thor) host
    pb := thor_plugin_add_button(thor, label)
    pb.entries = make([dynamic]Plugin_Menu_Item, 0, len(entries))
    for e in entries {
        append(&pb.entries, Plugin_Menu_Item {
            thor      = thor,
            label     = strings.clone(e.label),
            command   = strings.clone(e.command),
            separator = e.separator,
        })
    }
    widgets.button_set_on_click(pb.button, thor_plugin_menu_open, pb)
}

// Click handler for a flat plugin button; runs its command.
thor_plugin_button_click :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    pb := cast(^Plugin_Top_Button) data
    plugin.manager_run_command(&pb.thor.plugins, pb.command)
}

// Click handler for a dropdown plugin button; builds the shared menu from the
// button's entries and opens it just below the button.
thor_plugin_menu_open :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    pb := cast(^Plugin_Top_Button) data
    thor := pb.thor
    widgets.menu_clear(thor.menu)
    for &entry in pb.entries {
        if entry.separator {
            widgets.menu_add_separator(thor.menu)
        } else {
            widgets.menu_add(thor.menu, entry.label, thor_plugin_menu_item_click, &entry)
        }
    }
    anchor := rl.Vector2 {pb.button.bounds.x, pb.button.bounds.y + pb.button.bounds.height}
    widgets.menu_open(thor.menu, &thor.ui_context, anchor)
}

// Runs the command behind a chosen dropdown row.
thor_plugin_menu_item_click :: proc(data: rawptr) {
    item := cast(^Plugin_Menu_Item) data
    plugin.manager_run_command(&item.thor.plugins, item.command)
}

// thor.prompt(label, fn): opens the single-line prompt; the entered text is
// handed back to the plugin (plugin.manager_dialog_text).
thor_plugin_prompt :: proc(host: rawptr, label: string) {
    thor := cast(^Thor) host
    widgets.command_palette_prompt(thor.command_palette, &thor.ui_context, label, thor_plugin_dialog_text, thor)
}

// thor.pick(label, items, fn): opens the fuzzy picker; the chosen item is handed
// back to the plugin (plugin.manager_dialog_text).
thor_plugin_pick :: proc(host: rawptr, label: string, items: []string) {
    thor := cast(^Thor) host
    widgets.command_palette_pick(thor.command_palette, &thor.ui_context, label, items, thor_plugin_dialog_text, thor)
}

// thor.confirm(message, fn): opens the yes/no confirmation; a confirm is handed
// back to the plugin (plugin.manager_dialog_confirm).
thor_plugin_confirm :: proc(host: rawptr, message: string) {
    thor := cast(^Thor) host
    widgets.command_palette_confirm(thor.command_palette, &thor.ui_context, message, thor_plugin_dialog_confirm, thor)
}

// Shared submit trampoline for prompt/pick: forwards the text into the plugin VM.
thor_plugin_dialog_text :: proc(data: rawptr, text: string) {
    thor := cast(^Thor) data
    plugin.manager_dialog_text(&thor.plugins, text)
}

// Confirm trampoline: fires the pending confirm callback in the plugin VM.
thor_plugin_dialog_confirm :: proc(data: rawptr) {
    thor := cast(^Thor) data
    plugin.manager_dialog_confirm(&thor.plugins)
}

// Help -> Tutorial: starts the interactive tutorial plugin
// (plugins/tutorial/plugin.lua).
thor_cmd_tutorial :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if !plugin.manager_run_command(&thor.plugins, "tutorial") {
        thor_plugin_print(thor, "\nThe tutorial plugin is not installed (plugins/tutorial/plugin.lua).\n")
    }
}
