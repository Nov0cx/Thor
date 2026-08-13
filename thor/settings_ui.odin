package thor

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

import "../input"
import "../lang"
import "../lang/lsp"
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
// values always match what is actually on disk for that scope. General reads
// a fresh, unmerged settings/ snapshot (thor.config already has the workspace
// overlay folded in); Workspace reads the live merged thor.config.
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
        general_snapshot = setting.load("settings")
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
    widgets.settings_view_add_choice(view, "format_on_save", "Format on Save", thor_on_off_label(setting.format_on_save(config)))
    widgets.settings_view_add_choice(view, "format_on_type", "Format on Type", thor_on_off_label(setting.format_on_type(config)))

    widgets.settings_view_begin_category(view, "windows", "Windows", "window")
    widgets.settings_view_add_choice(view, "open_folder_in", "Open Folder In", thor_open_folder_in_label(config))

    widgets.settings_view_begin_category(view, "terminal", "Terminal", "terminal-2")
    widgets.settings_view_add_choice(view, "default_shell", "Default Shell", thor_default_shell_label(thor, config))

    widgets.settings_view_begin_category(view, "updates", "Updates", "download")
    widgets.settings_view_add_choice(view, "check_for_updates", "Check for Updates", thor_on_off_label(setting.check_for_updates(config)))

    // The backend rows, and each backend's own feature rows, only while the
    // master switch is on: off, none of them does anything, and a screenful of
    // dead rows reads as a screenful of broken ones.
    widgets.settings_view_begin_category(view, "language", "Language", "brain")
    language_on := setting.language_enabled(config)
    widgets.settings_view_add_choice(view, setting.LANGUAGE_SETTING, "Language Intelligence", thor_on_off_label(language_on))
    if language_on {
        backend_ids := make([dynamic]string, context.temp_allocator)
        append(&backend_ids, ODIN_BACKEND_ID)
        for id in lsp.client_server_ids(thor.lsp_client, context.temp_allocator) {
            append(&backend_ids, id)
        }

        widgets.settings_view_begin_group(view, LANGUAGE_BACKENDS_GROUP, "Language Servers", collapsed = true)
        for id in backend_ids {
            label := id == ODIN_BACKEND_ID ? "Odin Analyzer" : id
            widgets.settings_view_add_choice(view, thor_language_backend_id(id), label, thor_on_off_label(setting.backend_enabled(config, id)))
        }
        widgets.settings_view_end_group(view)

        // Each backend's own feature rows, folded under a group per backend —
        // shown only for a backend that is itself still on.
        for id in backend_ids {
            if !setting.backend_enabled(config, id) {
                continue
            }
            features := setting.backend_features(config, id)
            group_label := id == ODIN_BACKEND_ID ? "Odin Analyzer Features" : fmt.tprintf("%s Features", id)
            widgets.settings_view_begin_group(view, thor_language_backend_feature_group(id), group_label, collapsed = true)
            for kind in lang.Request_Kind {
                widgets.settings_view_add_choice(
                    view,
                    thor_language_backend_feature_id(id, kind),
                    LANGUAGE_FEATURE_LABELS[kind],
                    thor_on_off_label(kind in features),
                )
            }
            widgets.settings_view_end_group(view)
        }
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
    if backend_id, kind, is_backend_feature := thor_language_backend_feature_name(id); is_backend_feature {
        thor_cmd_change_language_backend_feature(thor, backend_id, kind)
        return
    }
    if backend_id, is_backend := thor_language_backend_name(id); is_backend {
        thor_cmd_change_language_backend(thor, backend_id)
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

@(private = "file")
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

// Fold group holding one on/off row per backend — the Odin analyzer plus every
// configured LSP server.
@(private = "file")
LANGUAGE_BACKENDS_GROUP :: "language.backends"

// A backend's row id, prefixed like the plugin and feature rows so one Choice
// handler tells them apart.
@(private = "file")
LANGUAGE_BACKEND_PREFIX :: "language_backend:"

@(private = "file")
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
@(private = "file")
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

@(private = "file")
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
@(private = "file")
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
    setting.persist_nested_bool(thor_active_settings_path(thor), setting.LANGUAGE_SETTING, setting.LANGUAGE_ENABLED_KEY, on)
    thor.config.general.language_enabled = on
    thor_apply_language_settings(thor)
    thor_settings_mark_clean(thor)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
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
    on := choice == ON_OFF_LABELS[0]
    setting.persist_bool(thor_active_settings_path(thor), "format_on_save", on)
    thor.config.general.format_on_save = on
    thor_settings_mark_clean(thor)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
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
    on := choice == ON_OFF_LABELS[0]
    setting.persist_bool(thor_active_settings_path(thor), "check_for_updates", on)
    thor.config.general.check_for_updates = on
    thor_settings_mark_clean(thor)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
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
    on := choice == ON_OFF_LABELS[0]
    setting.persist_bool(thor_active_settings_path(thor), "format_on_type", on)
    thor.config.general.format_on_type = on
    thor_settings_mark_clean(thor)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
}

// Settings row: turn one backend (the Odin analyzer, or an lsp.json server) on
// or off. Nothing to preview — the gate only shows in what the next request
// does; an already-running LSP server process is left running idle rather than
// stopped, same as blocking a running plugin waits for a restart.
@(private = "file")
thor_cmd_change_language_backend :: proc(thor: ^Thor, backend_id: string) {
    delete(thor.language_backend_target)
    thor.language_backend_target = strings.clone(backend_id)
    on := setting.backend_enabled(&thor.config, backend_id)
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
    on := choice == ON_OFF_LABELS[0]
    setting.persist_double_nested_bool(thor_active_settings_path(thor), setting.LANGUAGE_BACKENDS_SETTING, thor.language_backend_target, setting.LANGUAGE_ENABLED_KEY, on)
    cfg, existed := thor.config.general.language_backends[thor.language_backend_target]
    if !existed {
        cfg = setting.Backend_Setting{enabled = true, features = lang.FEATURES_ALL}
    }
    cfg.enabled = on
    if existed {
        thor.config.general.language_backends[thor.language_backend_target] = cfg
    } else {
        thor.config.general.language_backends[strings.clone(thor.language_backend_target)] = cfg
    }
    thor_apply_language_settings(thor)
    thor_settings_mark_clean(thor)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
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
    on := setting.backend_feature_enabled(&thor.config, backend_id, kind)
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
    on := choice == ON_OFF_LABELS[0]
    kind := thor.language_backend_feature_kind
    setting.persist_double_nested_bool(thor_active_settings_path(thor), setting.LANGUAGE_BACKENDS_SETTING, thor.language_backend_target, lang.feature_name(kind), on)

    cfg, existed := thor.config.general.language_backends[thor.language_backend_target]
    if !existed {
        cfg = setting.Backend_Setting{enabled = true, features = lang.FEATURES_ALL}
    }
    if on {
        cfg.features += {kind}
    } else {
        cfg.features -= {kind}
    }
    if existed {
        thor.config.general.language_backends[thor.language_backend_target] = cfg
    } else {
        thor.config.general.language_backends[strings.clone(thor.language_backend_target)] = cfg
    }
    thor_apply_language_settings(thor)
    thor_settings_mark_clean(thor)
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
thor_on_setting_keybind :: proc(data: rawptr, id: string, key: rl.KeyboardKey, mods: input.Modifiers) {
    thor := cast(^Thor) data
    kb := setting.Keybind {key = key, mods = mods}
    spec := setting.keybind_spec(kb, context.temp_allocator)
    setting.persist_keybind(thor_active_keybinds_path(thor), id, spec)
    thor_reload_settings(thor)
}
