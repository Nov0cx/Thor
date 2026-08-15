package thor

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

import "../input"
import "../lang"
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

// Rebuilds every row from the config for the view's current scope. Called on
// open, on a scope switch and after any change reloads, so the displayed
// values always match what is actually on disk for that scope. General reads a
// fresh settings/ + user/ snapshot without the workspace overlay (thor.config
// has that folded in); Workspace reads the live merged thor.config.
thor_populate_settings_view :: proc(thor: ^Thor) {
    view := thor.settings_view
    widgets.settings_view_clear(view)
    widgets.settings_view_set_workspace_available(view, thor.workspace_initialized)

    scope := widgets.settings_view_scope(view)
    if scope == .Workspace && !thor.workspace_initialized {
        return
    }

    owns_snapshot := scope == .General
    general_snapshot: setting.Settings
    config: ^setting.Settings
    if owns_snapshot {
        general_snapshot = setting.load(setting.GLOBAL_DIR)
        setting.load_overlay(&general_snapshot, setting.USER_DIR)
        config = &general_snapshot
    } else {
        config = &thor.config
    }
    defer if owns_snapshot {
        setting.destroy(&general_snapshot)
    }

    widgets.settings_view_begin_category(view, "editor", "Editor", "adjustments")
    widgets.settings_view_add_number(view, "tab_width", "Tab Width", setting.tab_width(config), 1, 16, 1)
    widgets.settings_view_add_number(view, "font_size", "Font Size", setting.font_size(config), 8, 48, 1)
    widgets.settings_view_add_number(view, "autosave_delay_ms", "Autosave Delay (ms)", setting.autosave_delay_ms(config), 0, 10000, 250)

    widgets.settings_view_begin_category(view, "appearance", "Appearance", "palette")
    theme := setting.theme_name(config)
    if theme == "" {
        theme = DEFAULT_THEME
    }
    widgets.settings_view_add_choice(view, "theme", "Theme", theme)
    widgets.settings_view_add_choice(view, THEME_EDITOR_SETTING, "Theme Colors", "Edit...")
    widgets.settings_view_add_choice(view, "font", "Font", ui.text_default_family())
    icon_pack := setting.icon_pack_name(config)
    if icon_pack == "" {
        icon_pack = ui.icon_active_pack(PRIMARY_ICON_PACK_GROUP)
    }
    widgets.settings_view_add_choice(view, "icon_pack", "Icon Pack", icon_pack)
    file_icon_pack := setting.file_icon_pack_name(config)
    if file_icon_pack == "" {
        file_icon_pack = ui.icon_active_pack(FILE_ICON_PACK_GROUP)
    }
    widgets.settings_view_add_choice(view, "file_icon_pack", "File Icon Pack", file_icon_pack)
    widgets.settings_view_add_choice(view, "ligatures", "Ligatures", thor_ligatures_label(config))
    widgets.settings_view_add_choice(view, "tooltips", "Tooltips", thor_on_off_label(setting.tooltips(config)))
    widgets.settings_view_add_choice(view, "tip_of_the_day", "Tip of the Day", thor_on_off_label(setting.tip_of_the_day(config)))
    widgets.settings_view_add_choice(view, "format_on_save", "Format on Save", thor_on_off_label(setting.format_on_save(config)))
    widgets.settings_view_add_choice(view, "format_on_type", "Format on Type", thor_on_off_label(setting.format_on_type(config)))

    widgets.settings_view_begin_category(view, "windows", "Windows", "window")
    widgets.settings_view_add_choice(view, "open_folder_in", "Open Folder In", thor_open_folder_in_label(config))

    widgets.settings_view_begin_category(view, "terminal", "Terminal", "terminal-2")
    widgets.settings_view_add_choice(view, "default_shell", "Default Shell", thor_default_shell_label(thor, config))

    widgets.settings_view_begin_category(view, "updates", "Updates", "download")
    widgets.settings_view_add_choice(view, "check_for_updates", "Check for Updates", thor_on_off_label(setting.check_for_updates(config)))

    // The Odin analyzer's rows, only while the master switch is on: off, none of
    // them does anything, and a screenful of dead rows reads as a screenful of
    // broken ones. Every other backend is a language server, which the Language
    // Servers category owns (thor/lsp_ui.odin) so its state and setup have room.
    widgets.settings_view_begin_category(view, "language", "Language", "brain")
    language_on := setting.language_enabled(config)
    widgets.settings_view_add_choice(view, setting.LANGUAGE_SETTING, "Language Intelligence", thor_on_off_label(language_on))
    if language_on {
        odin_on, odin_features := thor_backend_gate(thor, config, ODIN_BACKEND_ID)
        widgets.settings_view_add_choice(
            view, thor_language_backend_id(ODIN_BACKEND_ID), "Odin Analyzer", thor_on_off_label(odin_on),
        )
        if odin_on {
            widgets.settings_view_begin_group(
                view, thor_language_backend_feature_group(ODIN_BACKEND_ID), "Odin Analyzer Features", collapsed = true,
            )
            for kind in lang.Request_Kind {
                widgets.settings_view_add_choice(
                    view,
                    thor_language_backend_feature_id(ODIN_BACKEND_ID, kind),
                    LANGUAGE_FEATURE_LABELS[kind],
                    thor_on_off_label(kind in odin_features),
                )
            }
            widgets.settings_view_end_group(view)
        }
        thor_populate_lsp_category(thor)
    }

    // Bundled plugins only where they want a permission: the language plugins
    // want none, and listing three dozen "nothing to allow" rows would bury the
    // ones that do. A workspace plugin is always listed — it is code the opened
    // folder carries, so it is answered for even when it asks for nothing.
    // General-only: plugin grants carry their own workspace-vs-bundled split
    // (sessions/plugin-grants.json's workspaces array), unrelated to this
    // settings-file overlay, so a Workspace tab copy would misrepresent it.
    if scope == .General {
        states := thor_plugin_permission_states(thor)
        if len(states) > 0 {
            widgets.settings_view_begin_category(view, "plugins", "Plugins", "puzzle")
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
    }

    widgets.settings_view_begin_category(view, "keybindings", "Keybindings", "keyboard")
    actions := make([dynamic]string, context.temp_allocator)
    for action in config.keybinds {
        append(&actions, action)
    }
    slice.sort(actions[:])
    for action in actions {
        kb := config.keybinds[action]
        chord := setting.keybind_to_string(kb, context.temp_allocator)
        widgets.settings_view_add_keybind(view, action, action, chord)
    }
}

// Fired when the header's General/Workspace tab is switched; the widget has
// already updated view.scope, so a plain repopulate picks up the new source.
thor_on_settings_scope_change :: proc(data: rawptr, scope: widgets.Settings_Scope) {
    thor_populate_settings_view(cast(^Thor) data)
}

// Persists a nudged number to the active config layer, then reloads so it
// applies live (and refreshes the modal's rows).
thor_on_setting_number :: proc(data: rawptr, id: string, value: int) {
    thor := cast(^Thor) data
    if !setting.persist_int(thor_active_settings_path(thor), id, value) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return
    }
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
    if backend_id, kind, is_backend_feature := thor_language_backend_feature_name(id); is_backend_feature {
        thor_cmd_change_language_backend_feature(thor, backend_id, kind)
        return
    }
    if backend_id, is_backend := thor_language_backend_name(id); is_backend {
        thor_cmd_change_language_backend(thor, backend_id)
        return
    }
    if id == THEME_EDITOR_SETTING {
        thor_open_theme_editor(thor)
        return
    }
    if id == setting.LANGUAGE_SETTING {
        thor_cmd_change_language_master(thor)
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
    case "ligatures":
        thor_cmd_change_ligatures(thor)
    case "tooltips":
        thor_cmd_change_tooltips(thor)
    case "tip_of_the_day":
        thor_cmd_change_tip_of_the_day(thor)
    case "format_on_save":
        thor_cmd_change_format_on_save(thor)
    case "format_on_type":
        thor_cmd_change_format_on_type(thor)
    case "open_folder_in":
        thor_cmd_change_open_folder_in(thor)
    case "default_shell":
        thor_cmd_select_shell(thor)
    case "check_for_updates":
        thor_cmd_change_check_for_updates(thor)
    }
}

// The configured shell as its picker row, or the shell that stands in for it.
@(private = "file")
thor_default_shell_label :: proc(thor: ^Thor, config: ^setting.Settings) -> string {
    if len(thor.shell_profiles) == 0 {
        return "None found"
    }
    if profile, ok := shell.profile_find(thor.shell_profiles, setting.default_shell(config)); ok {
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

// Picker rows for every on/off setting in the modal.
@(private = "file")
ON_OFF_LABELS := [?]string {"On", "Off"}

thor_on_off_label :: proc(on: bool) -> string {
    return on ? ON_OFF_LABELS[0] : ON_OFF_LABELS[1]
}

// Fold group holding the Odin analyzer's feature rows. One group per analyzer;
// the id only has to be stable, it is never persisted.
@(private = "file")
ODIN_ANALYZER_GROUP :: "language.odin"

// The in-client Odin analyzer's id in the per-backend admin gate
// (setting.LANGUAGE_BACKENDS_SETTING) — no lsp.json server is expected to use
// this id, so it can't collide with a configured server's own id.
ODIN_BACKEND_ID :: "odin"

// A backend's row id, prefixed like the plugin and feature rows so one Choice
// handler tells them apart.
@(private = "file")
LANGUAGE_BACKEND_PREFIX :: "language_backend:"

thor_language_backend_id :: proc(id: string) -> string {
    return strings.concatenate({LANGUAGE_BACKEND_PREFIX, id}, context.temp_allocator)
}

// The backend id a settings row id names, if it names one.
@(private = "file")
thor_language_backend_name :: proc(id: string) -> (string, bool) {
    if !strings.has_prefix(id, LANGUAGE_BACKEND_PREFIX) {
        return "", false
    }
    return id[len(LANGUAGE_BACKEND_PREFIX):], true
}

// The fold group holding one backend's own per-feature rows. Every configured
// backend gets one — a generalization of ODIN_ANALYZER_GROUP, which stays as
// the Odin analyzer's own group id so its persisted collapsed/expanded state
// survives this change.
thor_language_backend_feature_group :: proc(id: string) -> string {
    if id == ODIN_BACKEND_ID {
        return ODIN_ANALYZER_GROUP
    }
    return strings.concatenate({"language.backend.", id}, context.temp_allocator)
}

// A backend-feature row id, prefixed distinctly from a plain backend row so one
// Choice handler tells them apart — LANGUAGE_BACKEND_PREFIX is not a prefix of
// this one (an "_" follows "backend", not this string's terminating ":").
@(private = "file")
LANGUAGE_BACKEND_FEATURE_PREFIX :: "language_backend_feature:"

thor_language_backend_feature_id :: proc(backend_id: string, kind: lang.Request_Kind) -> string {
    return strings.concatenate({LANGUAGE_BACKEND_FEATURE_PREFIX, backend_id, ":", lang.feature_name(kind)}, context.temp_allocator)
}

// The backend id and feature kind a settings row id names, if it names one.
@(private = "file")
thor_language_backend_feature_name :: proc(id: string) -> (backend_id: string, kind: lang.Request_Kind, ok: bool) {
    if !strings.has_prefix(id, LANGUAGE_BACKEND_FEATURE_PREFIX) {
        return "", .Definition, false
    }
    rest := id[len(LANGUAGE_BACKEND_FEATURE_PREFIX):]
    colon := strings.index_byte(rest, ':')
    if colon < 0 {
        return "", .Definition, false
    }
    found_kind, kok := lang.feature_from_name(rest[colon + 1:])
    if !kok {
        return "", .Definition, false
    }
    return rest[:colon], found_kind, true
}

// Row labels for the language features, in Request_Kind order. The user-facing
// names of the commands each one serves, not the seam's kind names.
LANGUAGE_FEATURE_LABELS := [lang.Request_Kind]string {
    .Definition        = "Go to Definition",
    .Hover             = "Hover",
    .Document_Symbols  = "Document Symbols",
    .Workspace_Symbols = "Workspace Symbols",
    .References        = "Find References",
    .Signature_Help    = "Signature Help",
    .Completion        = "Completion",
    .Package_Doc       = "Package Documentation",
    .Rename            = "Rename Symbol",
    .Diagnostics       = "Diagnostics",
    .Code_Actions      = "Code Actions",
    .Semantic_Tokens   = "Semantic Highlighting",
    .Format            = "Format Document",
    .Format_Range      = "Format Selection",
    .Format_On_Type    = "Format On Type",
    .Execute_Command   = "Server Commands",
    .Progress          = "Progress Notifications",
    .Apply_Edit        = "Server-Applied Edits",
}

// Settings row: turn language intelligence on or off, whole-seam. Nothing to
// preview — the gate only shows in what the next request does. The per-kind
// gate underneath it (setting.language_features) has no UI of its own any
// more: a backend's own feature group (thor_cmd_change_language_backend_feature)
// is the precise version of the same idea, scoped to one backend instead of
// cutting across all of them at once.
@(private = "file")
thor_cmd_change_language_master :: proc(thor: ^Thor) {
    on := setting.language_enabled(&thor.config)
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Language Intelligence",
        ON_OFF_LABELS[:], thor_on_off_label(on),
        thor_language_master_preview, thor_language_master_commit, thor,
    )
}

@(private = "file")
thor_language_master_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_language_master_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    on := choice == ON_OFF_LABELS[0]
    if !setting.persist_nested_bool(thor_active_settings_path(thor), setting.LANGUAGE_SETTING, setting.LANGUAGE_ENABLED_KEY, on) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return
    }
    thor_reload_settings(thor)
}

// Settings row: the hover explanations. Nothing to preview — the dialog covers
// the controls they would appear over.
@(private = "file")
thor_cmd_change_tooltips :: proc(thor: ^Thor) {
    on := setting.tooltips(&thor.config)
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Tooltips",
        ON_OFF_LABELS[:], thor_on_off_label(on),
        thor_tooltips_preview, thor_tooltips_commit, thor,
    )
}

@(private = "file")
thor_tooltips_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_tooltips_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_persist_bool_setting(thor, "tooltips", choice == ON_OFF_LABELS[0])
}

// Settings row: the tip of the day. Off hides the welcome page card and keeps
// the card over the editor closed. Nothing to preview — the next start shows it.
@(private = "file")
thor_cmd_change_tip_of_the_day :: proc(thor: ^Thor) {
    on := setting.tip_of_the_day(&thor.config)
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Tip of the Day",
        ON_OFF_LABELS[:], thor_on_off_label(on),
        thor_tip_of_the_day_preview, thor_tip_of_the_day_commit, thor,
    )
}

@(private = "file")
thor_tip_of_the_day_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_tip_of_the_day_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_persist_bool_setting(thor, "tip_of_the_day", choice == ON_OFF_LABELS[0])
}

// Settings row: format the active buffer before every explicit save. Nothing
// to preview — the effect only shows on the next save.
@(private = "file")
thor_cmd_change_format_on_save :: proc(thor: ^Thor) {
    on := setting.format_on_save(&thor.config)
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Format on Save",
        ON_OFF_LABELS[:], thor_on_off_label(on),
        thor_format_on_save_preview, thor_format_on_save_commit, thor,
    )
}

@(private = "file")
thor_format_on_save_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_format_on_save_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_persist_bool_setting(thor, "format_on_save", choice == ON_OFF_LABELS[0])
}

// Settings row: the background update check. Off leaves Help > Check for
// Updates working, which asks whatever this holds.
@(private = "file")
thor_cmd_change_check_for_updates :: proc(thor: ^Thor) {
    on := setting.check_for_updates(&thor.config)
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Check for Updates",
        ON_OFF_LABELS[:], thor_on_off_label(on),
        thor_check_for_updates_preview, thor_check_for_updates_commit, thor,
    )
}

@(private = "file")
thor_check_for_updates_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_check_for_updates_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_persist_bool_setting(thor, "check_for_updates", choice == ON_OFF_LABELS[0])
}

// Settings row: dispatch Format_On_Type as a trigger character is typed.
// Nothing to preview — the effect only shows on the next keystroke.
@(private = "file")
thor_cmd_change_format_on_type :: proc(thor: ^Thor) {
    on := setting.format_on_type(&thor.config)
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Format on Type",
        ON_OFF_LABELS[:], thor_on_off_label(on),
        thor_format_on_type_preview, thor_format_on_type_commit, thor,
    )
}

@(private = "file")
thor_format_on_type_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_format_on_type_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_persist_bool_setting(thor, "format_on_type", choice == ON_OFF_LABELS[0])
}

// Writes one boolean settings key to the active layer and reloads, which is what
// re-applies it and refreshes the modal. A write that did not land is reported
// and changes nothing, so the row keeps reading what is actually on disk.
@(private = "file")
thor_persist_bool_setting :: proc(thor: ^Thor, key: string, on: bool) {
    if !setting.persist_bool(thor_active_settings_path(thor), key, on) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return
    }
    thor_reload_settings(thor)
}

// Settings row: turn one backend (the Odin analyzer, or an lsp.json server) on
// or off. Nothing to preview — the gate only shows in what the next request
// does; an already-running LSP server process is left running idle rather than
// stopped, same as blocking a running plugin waits for a restart.
@(private = "file")
thor_cmd_change_language_backend :: proc(thor: ^Thor, backend_id: string) {
    delete(thor.language_backend_target)
    thor.language_backend_target = strings.clone(backend_id)
    on, _ := thor_backend_gate(thor, &thor.config, backend_id)
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, backend_id,
        ON_OFF_LABELS[:], thor_on_off_label(on),
        thor_language_backend_preview, thor_language_backend_commit, thor,
    )
}

@(private = "file")
thor_language_backend_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_language_backend_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    if thor.language_backend_target == "" {
        return
    }
    thor_persist_backend_key(thor, setting.LANGUAGE_ENABLED_KEY, choice == ON_OFF_LABELS[0])
}

// Settings row: turn one feature on or off for one backend specifically (as
// opposed to the top-level Language Intelligence group, which gates that
// feature for every backend at once). Nothing to preview, same as every other
// on/off row here.
@(private = "file")
thor_cmd_change_language_backend_feature :: proc(thor: ^Thor, backend_id: string, kind: lang.Request_Kind) {
    delete(thor.language_backend_target)
    thor.language_backend_target = strings.clone(backend_id)
    thor.language_backend_feature_kind = kind
    _, features := thor_backend_gate(thor, &thor.config, backend_id)
    on := kind in features
    title := fmt.tprintf("%s — %s", backend_id, LANGUAGE_FEATURE_LABELS[kind])
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, title,
        ON_OFF_LABELS[:], thor_on_off_label(on),
        thor_language_backend_feature_preview, thor_language_backend_feature_commit, thor,
    )
}

@(private = "file")
thor_language_backend_feature_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_language_backend_feature_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    if thor.language_backend_target == "" {
        return
    }
    thor_persist_backend_key(thor, lang.feature_name(thor.language_backend_feature_kind), choice == ON_OFF_LABELS[0])
}

// Writes one key of the target backend's language_backends entry to the active
// layer and reloads. `key` is either LANGUAGE_ENABLED_KEY or a feature name —
// the two share a shape, and both need the reload to reach the seam.
@(private = "file")
thor_persist_backend_key :: proc(thor: ^Thor, key: string, on: bool) {
    ok := setting.persist_double_nested_bool(
        thor_active_settings_path(thor), setting.LANGUAGE_BACKENDS_SETTING,
        thor.language_backend_target, key, on,
    )
    if !ok {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return
    }
    thor_reload_settings(thor)
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
thor_on_setting_keybind :: proc(data: rawptr, id: string, key: rl.KeyboardKey, mods: input.Modifiers) {
    thor := cast(^Thor) data
    kb := setting.Keybind {key = key, mods = mods}
    spec := setting.keybind_spec(kb, context.temp_allocator)
    if !setting.persist_keybind(thor_active_keybinds_path(thor), id, spec) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return
    }
    thor_reload_settings(thor)
}
