package thor

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"

import "../font"
import "../input"
import "../lang"
import "../plugin"
import "../setting"
import "../shell"
import ui "../vendor/loom/loom"
// Wires and drives the Settings modal. `settings_view.odin` draws and edits the
// rows; this file owns the settings knowledge: it builds the rows from the live
// config and persists each change, letting the auto-reload path re-apply it.

// Opens the Settings modal, (re)building its rows from the current config, on
// `category` when one is named. The open goes first: it resets the scope the
// populate reads.
thor_open_settings_view :: proc(thor: ^Thor, category := "") {
    thor_settings_open(thor)
    thor_populate_settings_view(thor)
    if category != "" {
        thor_settings_select_category(thor, category)
    }
}

thor_cmd_open_settings_gui :: proc(data: rawptr) {
    thor_open_settings_view(cast(^Thor)data)
}

// Rebuilds every row from the config for the view's current scope. Called on
// open, on a scope switch and after any change reloads, so the displayed
// values always match what is actually on disk for that scope. General reads a
// fresh settings/ + user/ snapshot without the workspace overlay (thor.config
// has that folded in); Workspace reads the live merged thor.config.
thor_populate_settings_view :: proc(thor: ^Thor) {
    view := &thor.settings
    thor_settings_clear(view)
    thor_settings_set_workspace_available(view, thor.workspace_initialized)

    scope := thor_settings_scope(view)
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

    thor_settings_begin_category(view, "editor", "Editor", "adjustments")
    thor_settings_add_number(view, "tab_width", "Tab Width", setting.tab_width(config), setting.TAB_WIDTH_MIN, setting.TAB_WIDTH_MAX, 1)
    thor_settings_add_number(view, "font_size", "Font Size", setting.font_size(config), setting.FONT_SIZE_MIN, setting.FONT_SIZE_MAX, 1)
    thor_settings_add_number(
        view,
        "autosave_delay_ms",
        "Autosave Delay (ms)",
        setting.autosave_delay_ms(config),
        setting.AUTOSAVE_DELAY_MIN,
        setting.AUTOSAVE_DELAY_MAX,
        250,
    )
    thor_settings_add_number(
        view,
        "peek_height",
        "Peek Definition Height (rows)",
        setting.peek_height(config),
        setting.PEEK_HEIGHT_MIN,
        setting.PEEK_HEIGHT_MAX,
        1,
    )
    thor_settings_add_toggle(view, "insert_spaces", "Insert Spaces", setting.insert_spaces(config))
    thor_settings_add_toggle(view, "detect_indentation", "Detect Indentation", setting.detect_indentation(config))
    thor_settings_add_toggle(view, "indent_guides", "Indent Guides", setting.indent_guides(config))
    thor_settings_add_toggle(view, "relative_line_numbers", "Relative Line Numbers", setting.relative_line_numbers(config))
    thor_settings_add_toggle(view, "format_on_save", "Format on Save", setting.format_on_save(config))
    thor_settings_add_toggle(view, "format_on_type", "Format on Type", setting.format_on_type(config))
    thor_settings_add_choice(view, "right_alt", "Right Alt Key", thor_right_alt_label(config))

    thor_settings_begin_category(view, "appearance", "Appearance", "palette")
    theme := setting.theme_name(config)
    if theme == "" {
        theme = DEFAULT_THEME
    }
    thor_settings_add_choice(view, "theme", "Theme", theme)
    thor_settings_add_action(view, THEME_EDITOR_SETTING, "Theme Colors", "Edit...")
    thor_settings_add_choice(view, "font", "Font", font.default_family())
    icon_pack := setting.icon_pack_name(config)
    if icon_pack == "" {
        icon_pack = font.icon_active_pack(PRIMARY_ICON_PACK_GROUP)
    }
    thor_settings_add_choice(view, "icon_pack", "Icon Pack", icon_pack)
    file_icon_pack := setting.file_icon_pack_name(config)
    if file_icon_pack == "" {
        file_icon_pack = font.icon_active_pack(FILE_ICON_PACK_GROUP)
    }
    thor_settings_add_choice(view, "file_icon_pack", "File Icon Pack", file_icon_pack)
    thor_settings_add_choice(view, "ligatures", "Ligatures", thor_ligatures_label(config))
    thor_settings_add_toggle(view, "tooltips", "Tooltips", setting.tooltips(config))

    thor_settings_begin_category(view, "windows", "Windows", "window")
    thor_settings_add_choice(view, "open_folder_in", "Open Folder In", thor_open_folder_in_label(config))
    thor_settings_add_choice(view, "pane_layout", "Editor Pane Layout", thor_pane_layout_label(config))
    thor_settings_add_toggle(view, "clipboard_history_save", "Save Clipboard History", setting.clipboard_history_save(config))
    thor_settings_add_toggle(view, "tip_of_the_day", "Tip of the Day", setting.tip_of_the_day(config))
    if thor_shell_menu_supported() {
        thor_settings_add_toggle(view, "shell_menu", "Explorer Menu Entry", thor_shell_menu_registered())
    }

    thor_settings_begin_category(view, "terminal", "Terminal", "terminal-2")
    thor_settings_add_choice(view, "default_shell", "Default Shell", thor_default_shell_label(thor, config))
    thor_settings_add_toggle(view, "terminal_clipboard", "Programs Set Clipboard", setting.terminal_clipboard(config))

    thor_settings_begin_category(view, "updates", "Updates", "download")
    thor_settings_add_toggle(view, "check_for_updates", "Check for Updates", setting.check_for_updates(config))
    if scope == .General {
        thor_populate_ext_category(thor, config)
    }

    // The Odin analyzer's rows, only while the master switch is on: off, none of
    // them does anything, and a screenful of dead rows reads as a screenful of
    // broken ones. Every other backend is a language server, which the Language
    // Servers category owns (thor/lsp_ui.odin) so its state and setup have room.
    thor_settings_begin_category(view, "language", "Language", "brain")
    language_on := setting.language_enabled(config)
    thor_settings_add_toggle(view, setting.LANGUAGE_SETTING, "Language Intelligence", language_on)
    if language_on {
        for id in lang.manager_gate_ids(&thor.lang_manager) {
            label := lang.manager_gate_label(&thor.lang_manager, id)
            if label == "" {
                continue
            }
            backend_on, backend_features := thor_backend_gate(thor, config, id)
            thor_settings_add_toggle(view, thor_language_backend_id(id), label, backend_on)
            if !backend_on {
                continue
            }
            thor_settings_begin_group(
                view,
                thor_language_backend_feature_group(id),
                strings.concatenate({label, " Features"}, context.temp_allocator),
                collapsed = true,
            )
            for kind in lang.Request_Kind {
                thor_settings_add_toggle(view, thor_language_backend_feature_id(id, kind), LANGUAGE_FEATURE_LABELS[kind], kind in backend_features)
            }
            thor_settings_end_group(view)
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
            thor_settings_begin_category(view, "plugins", "Plugins", "puzzle")
            thor_settings_add_info(view, "plugins_help", "Plugins that ask for a permission. The others always load.", "")
            for state in states {
                names := plugin.permission_names(state.perms, context.temp_allocator)
                wants := len(names) > 0 ? strings.join(names, ", ", context.temp_allocator) : "no permissions"
                label := fmt.tprintf("%s (%s)", state.id, wants)
                if state.source == .Workspace {
                    label = fmt.tprintf("%s — %s (%s)", state.id, WORKSPACE_PLUGIN_DIR, wants)
                }
                thor_settings_add_choice(view, thor_plugin_setting_id(state.source, state.id), label, state.allowed ? "Allowed" : "Blocked")
            }
        }
    }

    thor_settings_begin_category(view, "keybindings", "Keybindings", "keyboard")
    actions := make([dynamic]string, context.temp_allocator)
    for action in config.keybinds {
        append(&actions, action)
    }
    // Plugin commands have no shipped entry, so they list unbound until set.
    for action in thor_plugin_command_actions(thor) {
        if action not_in config.keybinds {
            append(&actions, action)
        }
    }
    Keybind_Entry :: struct {
        action, title: string,
    }
    entries := make([]Keybind_Entry, len(actions), context.temp_allocator)
    for action, i in actions {
        entries[i] = {action, thor_action_title(thor, action)}
    }
    slice.sort_by(entries, proc(a, b: Keybind_Entry) -> bool {
        return a.title < b.title
    })
    thor_settings_add_info(view, "keybind_help", "Click a shortcut, then press the new chord. Esc cancels.", "")
    for entry in entries {
        kb    := config.keybinds[entry.action] or_else {}
        chord := setting.keybind_to_string(kb, context.temp_allocator)
        thor_settings_add_keybind(view, entry.action, entry.title, chord)
    }
}

// Persists a nudged number to the active config layer, then reloads so it
// applies live (and refreshes the modal's rows).
thor_on_setting_number :: proc(data: rawptr, id: string, value: int) {
    thor := cast(^Thor)data
    if err := setting.persist_int(thor_active_settings_path(thor), id, value); err != .None {
        thor_settings_save_failed(thor, thor_active_settings_path(thor), err)
        return
    }
    thor_reload_settings(thor)
}

// A choice row opens the matching live-preview picker (theme or font); its commit
// persists and reloads on its own.
thor_on_setting_choice :: proc(data: rawptr, id: string) {
    thor := cast(^Thor)data
    if plugin_id, source, is_plugin := thor_plugin_setting_name(id); is_plugin {
        thor_cmd_change_plugin_permission(thor, source, plugin_id)
        return
    }
    if thor_ext_on_setting_choice(thor, id) {
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
    case "open_folder_in":
        thor_cmd_change_open_folder_in(thor)
    case "pane_layout":
        thor_select_open(
            thor,
            "Editor Pane Layout",
            PANE_LAYOUT_LABELS[:],
            thor_pane_layout_label(&thor.config),
            thor_no_preview,
            thor_pane_layout_commit,
            thor,
        )
    case "right_alt":
        thor_cmd_change_right_alt(thor)
    case "default_shell":
        thor_cmd_select_shell(thor)
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
OPEN_FOLDER_IN_LABELS := [?]string{"Ask", "This Window", "New Window"}

// The current open_folder_in setting as its picker row.
thor_open_folder_in_label :: proc(config: ^setting.Settings) -> string {
    return OPEN_FOLDER_IN_LABELS[cast(int)setting.open_folder_in(config)]
}

// Settings row: choose where an opened folder goes. Nothing to preview — the
// choice only takes effect the next time a folder is opened.
thor_cmd_change_open_folder_in :: proc(thor: ^Thor) {
    thor_select_open(
        thor,
        "Open Folder In",
        OPEN_FOLDER_IN_LABELS[:],
        thor_open_folder_in_label(&thor.config),
        thor_open_folder_in_preview,
        thor_open_folder_in_commit,
        thor,
    )
}

thor_open_folder_in_preview :: proc(_: rawptr, _: string) {}

thor_open_folder_in_commit :: proc(data: rawptr, choice: string) {
    thor   := cast(^Thor)data
    picked := setting.Open_Folder_In.Ask
    for label, index in OPEN_FOLDER_IN_LABELS {
        if label == choice {
            picked = cast(setting.Open_Folder_In)index
            break
        }
    }
    thor_persist_open_folder_in(thor, picked)
    if thor_settings_is_open(thor) {
        thor_populate_settings_view(thor)
    }
}

// Picker rows for pane_layout: remember, then Pane_Layout order.
@(private = "file")
PANE_LAYOUT_LABELS := [1 + len(Pane_Layout)]string{
    "Remember per Folder",
    LAYOUT_TITLES[.Single],
    LAYOUT_TITLES[.Columns2],
    LAYOUT_TITLES[.Columns3],
    LAYOUT_TITLES[.Rows2],
    LAYOUT_TITLES[.Main_Stack],
    LAYOUT_TITLES[.Grid4],
    LAYOUT_TITLES[.Grid6],
}

// The current pane_layout setting as its picker row. An unknown name reads as remember.
thor_pane_layout_label :: proc(config: ^setting.Settings) -> string {
    if layout, ok := layout_from_name(setting.pane_layout(config)); ok {
        return LAYOUT_TITLES[layout]
    }
    return PANE_LAYOUT_LABELS[0]
}

// Saves the picked layout and, unless it is remember, switches to it now.
thor_pane_layout_commit :: proc(data: rawptr, choice: string) {
    thor  := cast(^Thor)data
    value := "remember"
    picked: Maybe(Pane_Layout)
    for title, layout in LAYOUT_TITLES {
        if title == choice {
            value = LAYOUT_NAMES[layout]
            picked = layout
        }
    }
    path := setting.USER_SETTINGS
    if err := setting.persist_string(path, "pane_layout", value); err != .None {
        thor_settings_save_failed(thor, path, err)
        return
    }
    delete(thor.config.general.pane_layout)
    thor.config.general.pane_layout = strings.clone(value)
    thor_settings_mark_clean(thor)
    if layout, ok := picked.?; ok {
        thor_set_layout(thor, layout)
    }
    if thor_settings_is_open(thor) {
        thor_populate_settings_view(thor)
    }
}

// Picker rows for right_alt, in Right_Alt order.
@(private = "file")
RIGHT_ALT_LABELS := [?]string{"Auto (Keyboard Layout)", "AltGr", "Alt"}

// The current right_alt setting as its picker row.
thor_right_alt_label :: proc(config: ^setting.Settings) -> string {
    return RIGHT_ALT_LABELS[cast(int)setting.right_alt(config)]
}

// Pushes the right_alt setting onto the input backend.
thor_apply_right_alt :: proc(thor: ^Thor) {
    switch setting.right_alt(&thor.config) {
    case .Auto:
        thor.backend.opts.right_alt = .Auto
    case .Alt_Gr:
        thor.backend.opts.right_alt = .Alt_Gr
    case .Alt:
        thor.backend.opts.right_alt = .Alt
    }
}

// Settings row: choose what Right Alt is.
thor_cmd_change_right_alt :: proc(thor: ^Thor) {
    thor_select_open(thor, "Right Alt", RIGHT_ALT_LABELS[:], thor_right_alt_label(&thor.config), thor_open_folder_in_preview, thor_right_alt_commit, thor)
}

thor_right_alt_commit :: proc(data: rawptr, choice: string) {
    thor   := cast(^Thor)data
    picked := setting.Right_Alt.Auto
    for label, index in RIGHT_ALT_LABELS {
        if label == choice {
            picked = cast(setting.Right_Alt)index
            break
        }
    }
    value := setting.right_alt_value(picked)
    path  := setting.USER_SETTINGS
    if err := setting.persist_string(path, "right_alt", value); err != .None {
        thor_settings_save_failed(thor, path, err)
        return
    }
    delete(thor.config.general.right_alt)
    thor.config.general.right_alt = strings.clone(value)
    thor_settings_mark_clean(thor)
    thor_apply_right_alt(thor)
    if thor_settings_is_open(thor) {
        thor_populate_settings_view(thor)
    }
}

// Fold group holding the Odin analyzer's feature rows. One group per analyzer;
// the id only has to be stable, it is never persisted.
@(private = "file")
ODIN_ANALYZER_GROUP :: "language.odin"

// The in-client Odin analyzer's id in the per-backend admin gate
// (setting.LANGUAGE_BACKENDS_SETTING) — no lsp.lua server is expected to use
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
    rest  := id[len(LANGUAGE_BACKEND_FEATURE_PREFIX):]
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
LANGUAGE_FEATURE_LABELS := [lang.Request_Kind]string{
    .Definition = "Go to Definition",
    .Type_Definition = "Go to Type Definition",
    .Hover = "Hover",
    .Document_Symbols = "Document Symbols",
    .Workspace_Symbols = "Workspace Symbols",
    .References = "Find References",
    .Signature_Help = "Signature Help",
    .Completion = "Completion",
    .Package_Doc = "Package Documentation",
    .Rename = "Rename Symbol",
    .Diagnostics = "Diagnostics",
    .Syntax_Diagnostics = "Live Syntax Errors",
    .Code_Actions = "Code Actions",
    .Semantic_Tokens = "Semantic Highlighting",
    .Inlay_Hints = "Inlay Hints",
    .Document_Highlight = "Highlight Uses",
    .Format = "Format Document",
    .Format_Range = "Format Selection",
    .Format_On_Type = "Format On Type",
    .Execute_Command = "Server Commands",
    .Resolve_Completion = "Completion Follow-Up Edits",
    .Resolve_Action = "Refactorings That Ask",
    .Call_Hierarchy = "Call Hierarchy",
    .Type_Hierarchy = "Type Hierarchy",
    .Implementations = "Go to Implementations",
    .Selection_Range = "Expand Selection",
    .Code_Lens = "Reference Counts",
    .Progress = "Progress Notifications",
    .Apply_Edit = "Server-Applied Edits",
    .Message = "Server Messages",
}

// Preview of a setting that shows nothing until it is committed.
thor_no_preview :: proc(_: rawptr, _: string) {}

// A switch row was flipped to `on`. Each write reloads, which re-applies the
// setting and refreshes the modal.
thor_on_setting_toggle :: proc(data: rawptr, id: string, on: bool) {
    thor := cast(^Thor)data
    if backend_id, kind, is_feature := thor_language_backend_feature_name(id); is_feature {
        thor_persist_backend_key(thor, backend_id, lang.feature_name(kind), on)
        return
    }
    if backend_id, is_backend := thor_language_backend_name(id); is_backend {
        thor_persist_backend_key(thor, backend_id, setting.LANGUAGE_ENABLED_KEY, on)
        return
    }
    switch id {
    case setting.LANGUAGE_SETTING:
        path := thor_active_settings_path(thor)
        if err := setting.persist_nested_bool(path, setting.LANGUAGE_SETTING, setting.LANGUAGE_ENABLED_KEY, on); err != .None {
            thor_settings_save_failed(thor, path, err)
            return
        }
        thor_reload_settings(thor)
    case "shell_menu":
        if on != thor_shell_menu_registered() {
            thor_cmd_toggle_shell_menu(thor)
        }
    case "indent_guides":
        for &editor in thor.editors {
            editor.indent_guides = on
        }
        thor_persist_bool_setting(thor, id, on)
    case "relative_line_numbers":
        for &editor in thor.editors {
            editor.relative_lines = on
        }
        thor_persist_bool_setting(thor, id, on)
    case "insert_spaces",
        "detect_indentation",
        "format_on_save",
        "format_on_type",
        "tooltips",
        "clipboard_history_save",
        "tip_of_the_day",
        "terminal_clipboard",
        "check_for_updates",
        "check_for_plugin_updates":
        thor_persist_bool_setting(thor, id, on)
    case:
        log.warnf("No handler for the settings switch %q", id)
    }
}

// Writes one boolean settings key to the active layer and reloads, which is what
// re-applies it and refreshes the modal. A write that did not land is reported
// and changes nothing, so the row keeps reading what is actually on disk.
@(private = "file")
thor_persist_bool_setting :: proc(thor: ^Thor, key: string, on: bool) {
    if err := setting.persist_bool(thor_active_settings_path(thor), key, on); err != .None {
        thor_settings_save_failed(thor, thor_active_settings_path(thor), err)
        return
    }
    thor_reload_settings(thor)
}

// Writes one key of a backend's language_backends entry to the active layer and
// reloads. `key` is either LANGUAGE_ENABLED_KEY or a feature name.
@(private = "file")
thor_persist_backend_key :: proc(thor: ^Thor, backend_id, key: string, on: bool) {
    path := thor_active_settings_path(thor)
    err  := setting.persist_double_nested_bool(path, setting.LANGUAGE_BACKENDS_SETTING, backend_id, key, on)
    if err != .None {
        thor_settings_save_failed(thor, path, err)
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
PLUGIN_PERMISSION_LABELS := [?]string{"Allowed", "Blocked"}

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
    thor_select_open(thor, "Plugin Permissions", PLUGIN_PERMISSION_LABELS[:], current, thor_plugin_permission_preview, thor_plugin_permission_commit, thor)
}

@(private = "file")
thor_plugin_permission_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_plugin_permission_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor)data
    if thor.plugin_setting_target == "" {
        return
    }
    thor_set_plugin_allowed(thor, thor.plugin_setting_source, thor.plugin_setting_target, choice == "Allowed")
    if thor_settings_is_open(thor) {
        thor_populate_settings_view(thor)
    }
}

// Persists a captured (or cleared) chord to keybinds.lua, then reloads so the
// binding takes effect immediately.
thor_on_setting_keybind :: proc(data: rawptr, id: string, key: ui.Key, mods: input.Modifiers) {
    thor := cast(^Thor)data
    kb   := setting.Keybind{key = key, mods = mods}
    spec := setting.keybind_spec(kb, context.temp_allocator)
    if err := setting.persist_keybind(thor_active_keybinds_path(thor), id, spec); err != .None {
        thor_settings_save_failed(thor, thor_active_keybinds_path(thor), err)
        return
    }
    thor_reload_settings(thor)
}
