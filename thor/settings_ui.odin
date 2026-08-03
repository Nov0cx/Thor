package thor

import "core:slice"
import rl "vendor:raylib"

import "../setting"
import "../ui"
import "../widgets"

// Wires and drives the Settings modal (widgets.Settings_View). The widget draws
// and edits the rows; this file owns the settings knowledge: it builds the rows
// from the live config and persists each change, letting the auto-reload path
// re-apply it.

// Opens the Settings modal, (re)building its rows from the current config.
thor_open_settings_view :: proc(thor: ^Thor) {
    thor_populate_settings_view(thor)
    widgets.settings_view_open(thor.settings_view, &thor.ui_context)
}

thor_cmd_open_settings_gui :: proc(data: rawptr) {
    thor_open_settings_view(cast(^Thor) data)
}

// Rebuilds every row from the live config. Called on open and after any change
// reloads, so the displayed values always match settings.json / keybinds.json.
thor_populate_settings_view :: proc(thor: ^Thor) {
    view := thor.settings_view
    widgets.settings_view_clear(view)

    widgets.settings_view_add_header(view, "EDITOR")
    widgets.settings_view_add_number(view, "tab_width", "Tab Width", setting.tab_width(&thor.config), 1, 16, 1)
    widgets.settings_view_add_number(view, "font_size", "Font Size", setting.font_size(&thor.config), 8, 48, 1)
    widgets.settings_view_add_number(view, "autosave_delay_ms", "Autosave Delay (ms)", setting.autosave_delay_ms(&thor.config), 0, 10000, 250)

    widgets.settings_view_add_header(view, "APPEARANCE")
    theme := setting.theme_name(&thor.config)
    if theme == "" {
        theme = DEFAULT_THEME
    }
    widgets.settings_view_add_choice(view, "theme", "Theme", theme)
    widgets.settings_view_add_choice(view, "font", "Font", ui.text_default_family())
    icon_pack := setting.icon_pack_name(&thor.config)
    if icon_pack == "" {
        icon_pack = ui.icon_active_pack(PRIMARY_ICON_PACK_GROUP)
    }
    widgets.settings_view_add_choice(view, "icon_pack", "Icon Pack", icon_pack)
    file_icon_pack := setting.file_icon_pack_name(&thor.config)
    if file_icon_pack == "" {
        file_icon_pack = ui.icon_active_pack(FILE_ICON_PACK_GROUP)
    }
    widgets.settings_view_add_choice(view, "file_icon_pack", "File Icon Pack", file_icon_pack)

    widgets.settings_view_add_header(view, "WINDOWS")
    widgets.settings_view_add_choice(view, "open_folder_in", "Open Folder In", thor_open_folder_in_label(&thor.config))

    widgets.settings_view_add_header(view, "KEYBINDINGS")
    actions := make([dynamic]string, context.temp_allocator)
    for action in thor.config.keybinds {
        append(&actions, action)
    }
    slice.sort(actions[:])
    for action in actions {
        kb := thor.config.keybinds[action]
        chord := setting.keybind_to_string(kb, context.temp_allocator)
        widgets.settings_view_add_keybind(view, action, action, chord)
    }
}

// Persists a nudged number to the active config layer, then reloads so it
// applies live (and refreshes the modal's rows).
thor_on_setting_number :: proc(data: rawptr, id: string, value: int) {
    thor := cast(^Thor) data
    setting.persist_int(thor_active_settings_path(thor), id, value)
    thor_reload_settings(thor)
}

// A choice row opens the matching live-preview picker (theme or font); its commit
// persists and reloads on its own.
thor_on_setting_choice :: proc(data: rawptr, id: string) {
    thor := cast(^Thor) data
    switch id {
    case "theme":
        thor_cmd_change_theme(thor)
    case "font":
        thor_cmd_change_font(thor)
    case "icon_pack":
        thor_cmd_change_icon_pack(thor)
    case "file_icon_pack":
        thor_cmd_change_file_icon_pack(thor)
    case "open_folder_in":
        thor_cmd_change_open_folder_in(thor)
    }
}

// Picker rows for open_folder_in, in Open_Folder_In order.
@(private = "file")
OPEN_FOLDER_IN_LABELS := [?]string {"Ask", "This Window", "New Window"}

// The current open_folder_in setting as its picker row.
thor_open_folder_in_label :: proc(config: ^setting.Settings) -> string {
    return OPEN_FOLDER_IN_LABELS[cast(int) setting.open_folder_in(config)]
}

// Settings row: choose where an opened folder goes. Nothing to preview — the
// choice only takes effect the next time a folder is opened.
thor_cmd_change_open_folder_in :: proc(thor: ^Thor) {
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Open Folder In",
        OPEN_FOLDER_IN_LABELS[:], thor_open_folder_in_label(&thor.config),
        thor_open_folder_in_preview, thor_open_folder_in_commit, thor,
    )
}

thor_open_folder_in_preview :: proc(_: rawptr, _: string) {}

thor_open_folder_in_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    picked := setting.Open_Folder_In.Ask
    for label, index in OPEN_FOLDER_IN_LABELS {
        if label == choice {
            picked = cast(setting.Open_Folder_In) index
            break
        }
    }
    thor_persist_open_folder_in(thor, picked)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
}

// Persists a captured (or cleared) chord to keybinds.json, then reloads so the
// binding takes effect immediately.
thor_on_setting_keybind :: proc(data: rawptr, id: string, key: rl.KeyboardKey, ctrl, shift, alt: bool) {
    thor := cast(^Thor) data
    kb := setting.Keybind {key = key, ctrl = ctrl, shift = shift, alt = alt}
    spec := setting.keybind_spec(kb, context.temp_allocator)
    setting.persist_keybind(thor_active_keybinds_path(thor), id, spec)
    thor_reload_settings(thor)
}
