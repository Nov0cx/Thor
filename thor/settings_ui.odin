package thor

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

import "../plugin"
import "../setting"
import "../shell"
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

    widgets.settings_view_add_header(view, "TERMINAL")
    widgets.settings_view_add_choice(view, "default_shell", "Default Shell", thor_default_shell_label(thor))

    // Bundled plugins only where they want a permission: the language plugins
    // want none, and listing three dozen "nothing to allow" rows would bury the
    // ones that do. A workspace plugin is always listed — it is code the opened
    // folder carries, so it is answered for even when it asks for nothing.
    states := thor_plugin_permission_states(thor)
    if len(states) > 0 {
        widgets.settings_view_add_header(view, "PLUGIN PERMISSIONS")
        for state in states {
            names := plugin.permission_names(state.perms, context.temp_allocator)
            wants := len(names) > 0 ? strings.join(names, ", ", context.temp_allocator) : "no permissions"
            label := fmt.tprintf("%s (%s)", state.id, wants)
            if state.source == .Workspace {
                label = fmt.tprintf("%s — %s (%s)", state.id, WORKSPACE_PLUGIN_DIR, wants)
            }
            widgets.settings_view_add_choice(view, thor_plugin_setting_id(state.source, state.id), label, state.allowed ? "Allowed" : "Blocked")
        }
    }

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
    if plugin_id, source, is_plugin := thor_plugin_setting_name(id); is_plugin {
        thor_cmd_change_plugin_permission(thor, source, plugin_id)
        return
    }
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
    case "default_shell":
        thor_cmd_select_shell(thor)
    }
}

// The configured shell as its picker row, or the shell that stands in for it.
@(private = "file")
thor_default_shell_label :: proc(thor: ^Thor) -> string {
    if len(thor.shell_profiles) == 0 {
        return "None found"
    }
    if profile, ok := shell.profile_find(thor.shell_profiles, setting.default_shell(&thor.config)); ok {
        return profile.name
    }
    return thor.shell_profiles[0].name
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

// Settings row ids for plugin permissions are prefixed, so one Choice handler
// tells them from the fixed rows. The source rides in the prefix: one id can
// name a bundled plugin and a workspace plugin at the same time.
@(private = "file")
PLUGIN_SETTING_PREFIX :: "plugin:"

@(private = "file")
PLUGIN_WORKSPACE_PREFIX :: "plugin:workspace:"

@(private = "file")
thor_plugin_setting_id :: proc(source: Plugin_Source, plugin_id: string) -> string {
    prefix := source == .Workspace ? PLUGIN_WORKSPACE_PREFIX : PLUGIN_SETTING_PREFIX
    return strings.concatenate({prefix, plugin_id}, context.temp_allocator)
}

// The plugin a settings row id names, if it names one. The workspace prefix is
// tested first: it extends the bundled one, so the shorter test matches both.
@(private = "file")
thor_plugin_setting_name :: proc(id: string) -> (name: string, source: Plugin_Source, ok: bool) {
    if strings.has_prefix(id, PLUGIN_WORKSPACE_PREFIX) {
        return id[len(PLUGIN_WORKSPACE_PREFIX):], .Workspace, true
    }
    if strings.has_prefix(id, PLUGIN_SETTING_PREFIX) {
        return id[len(PLUGIN_SETTING_PREFIX):], .Bundled, true
    }
    return "", .Bundled, false
}

@(private = "file")
PLUGIN_PERMISSION_LABELS := [?]string {"Allowed", "Blocked"}

// Settings row: allow or block one plugin's permissions. Allowing a bundled
// plugin runs it at once and blocking a running one waits for a restart; either
// answer on a workspace plugin takes effect on the next frame.
@(private = "file")
thor_cmd_change_plugin_permission :: proc(thor: ^Thor, source: Plugin_Source, plugin_id: string) {
    current := "Blocked"
    for state in thor_plugin_permission_states(thor) {
        if state.source == source && state.id == plugin_id {
            current = state.allowed ? "Allowed" : "Blocked"
            break
        }
    }
    delete(thor.plugin_setting_target)
    thor.plugin_setting_target = strings.clone(plugin_id)
    thor.plugin_setting_source = source
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Plugin Permissions",
        PLUGIN_PERMISSION_LABELS[:], current,
        thor_plugin_permission_preview, thor_plugin_permission_commit, thor,
    )
}

@(private = "file")
thor_plugin_permission_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_plugin_permission_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    if thor.plugin_setting_target == "" {
        return
    }
    thor_set_plugin_allowed(thor, thor.plugin_setting_source, thor.plugin_setting_target, choice == "Allowed")
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
