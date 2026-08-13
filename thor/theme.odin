package thor

import "core:log"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

import "../setting"
import "../ui"
import "../widgets"

// Built-in theme used when none is configured or the configured one fails to load.
DEFAULT_THEME :: "mjolnir"

// Loads the theme named in settings (falling back to the default) into
// thor.theme. Called once at startup, before the widgets are built.
thor_load_active_theme :: proc(thor: ^Thor) {
    name := setting.theme_name(&thor.config)
    if name == "" {
        name = DEFAULT_THEME
    }
    thor_load_theme_by_name(thor, name)
}

// Replaces thor.theme with the theme file assets/themes/<name>.json, freeing the
// previous one. Falls back to the built-in default when the file is unreadable.
thor_load_theme_by_name :: proc(thor: ^Thor, name: string) {
    path := strings.concatenate({"assets/themes/", name, ".json"}, context.temp_allocator)
    theme, ok := ui.theme_load(path)
    if !ok && name != DEFAULT_THEME {
        log.warnf("Theme %q failed to load; using %q", name, DEFAULT_THEME)
        ui.theme_destroy(&theme)
        default_path := strings.concatenate({"assets/themes/", DEFAULT_THEME, ".json"}, context.temp_allocator)
        // theme_load returns the built-in theme and logs on failure, so the
        // fallback always lands on a complete palette.
        theme, _ = ui.theme_load(default_path)
    }

    ui.theme_destroy(&thor.theme)
    thor.theme = theme
    log.infof("Loaded theme: %s", thor.theme.name)
}

// Theme names available under assets/themes/ (base names, no extension), sorted.
thor_available_themes :: proc(allocator := context.temp_allocator) -> []string {
    matches, err := filepath.glob("assets/themes/*.json", context.temp_allocator)
    if err != nil {
        return {}
    }
    names := make([dynamic]string, allocator)
    for path in matches {
        base := filepath.base(path)
        append(&names, strings.clone(strings.trim_suffix(base, ".json"), allocator))
    }
    return names[:]
}

// Installed themes as parallel (display name, file base) slices: `labels` are the
// human names from each theme's "name" field, `files` the base names used to load
// and persist them. Aligned by index.
thor_available_theme_choices :: proc(allocator := context.temp_allocator) -> (labels, files: []string) {
    files = thor_available_themes(allocator)
    names := make([dynamic]string, allocator)
    for file in files {
        path := strings.concatenate({"assets/themes/", file, ".json"}, context.temp_allocator)
        theme, _ := ui.theme_load(path)
        append(&names, strings.clone(theme.name, allocator))
        ui.theme_destroy(&theme)
    }
    return names[:], files
}

// Reapplies thor.theme to every widget that caches a color. The draw loop reads
// thor.theme directly for the window clear, so those update for free; this walks
// the widget tree for everything that was colored at build time. Mirrors the
// color assignments in build.odin, so the two must stay in step.
thor_apply_theme :: proc(thor: ^Thor) {
    t := thor.theme
    selected := rl.Color {t.accent_color.r, t.accent_color.g, t.accent_color.b, 40}

    widgets.panel_set_background(thor.root_panel, t.background)
    widgets.panel_set_background(thor.explorer_stub_panel, t.buttons)
    widgets.panel_set_background(thor.explorer_panel, t.second_background)
    widgets.panel_set_background(thor.editor_panel, t.background)
    widgets.panel_set_background(thor.console_panel, t.second_background)
    widgets.panel_set_background(thor.console_stub_panel, t.buttons)

    widgets.stack_set_background(thor.root_stack, t.border)
    widgets.stack_set_background(thor.workspace_row, t.border)
    widgets.stack_set_background(thor.explorer_stub_stack, t.buttons)
    widgets.stack_set_background(thor.explorer_stack, t.border)
    widgets.stack_set_background(thor.explorer_header, t.highlight)
    widgets.stack_set_background(thor.editor_column, t.border)
    widgets.stack_set_background(thor.console_stack, t.border)
    widgets.stack_set_background(thor.console_header, t.highlight)
    widgets.stack_set_background(thor.console_stub_stack, t.buttons)
    widgets.stack_set_background(thor.editor_split_row, t.border)

    widgets.titlebar_set_background(thor.top_bar, t.buttons)

    widgets.splitter_set_colors(thor.explorer_splitter, t.border, t.highlight, t.accent_color)
    widgets.splitter_set_colors(thor.console_splitter, t.border, t.highlight, t.accent_color)
    widgets.splitter_set_colors(thor.editor_split_splitter, t.border, t.highlight, t.accent_color)

    widgets.command_palette_set_colors(
        thor.command_palette,
        t.second_background, t.accent_color, t.background, t.primary_text_color, t.muted_color, selected, t.accent_color,
    )
    widgets.select_dialog_set_colors(
        thor.select_dialog,
        t.second_background, t.accent_color, t.highlight, t.primary_text_color, t.muted_color, selected, t.accent_color,
    )
    widgets.settings_view_set_colors(
        thor.settings_view,
        t.second_background, t.highlight, t.highlight, t.background, t.primary_text_color, t.muted_color, t.accent_color,
        selected,
    )
    widgets.find_replace_set_colors(
        thor.find_replace,
        t.second_background, t.accent_color, t.background, t.primary_text_color, t.muted_color, t.buttons, t.accent_color,
    )
    widgets.menu_set_colors(
        thor.menu,
        t.second_background, t.accent_color, t.primary_text_color, t.muted_color, selected, t.border,
    )

    widgets.tree_set_colors(
        thor.tree,
        t.foreground, t.primary_text_color, t.info_color, t.muted_color, t.tree, t.selection_background,
        t.second_background, t.highlight,
    )
    widgets.tree_set_error_color(thor.tree, t.error_color)
    widgets.tree_set_git_colors(thor.tree, t.warning_color, t.success_color, t.danger_color, t.conflict_color, t.submodule_color)

    widgets.tabbar_set_colors(
        thor.tabbar,
        t.foreground, t.primary_text_color, t.active, t.buttons, t.background, t.tree, t.accent_color,
    )

    for editor in ([]^widgets.Editor {thor.editor, thor.editor2}) {
        widgets.editor_set_colors(
            editor,
            t.primary_text_color, t.muted_color, t.background, t.second_background, t.border, t.border, t.accent_color,
        )
        widgets.editor_set_diagnostic_colors(editor, t.error_color, t.warning_color)
    }

    widgets.image_view_set_colors(thor.image_view, t.background, t.second_background, t.buttons, t.primary_text_color)
    widgets.model_view_set_colors(
        thor.model_view,
        t.background, t.second_background, t.buttons, t.primary_text_color,
        t.second_background, t.highlight, t.accent_color,
    )
    widgets.markdown_view_set_colors(thor.markdown_view, t)
    widgets.markdown_view_set_colors(thor.markdown_view2, t)
    for term in thor.terminals {
        thor_terminal_apply_theme(thor, term)
    }
    thor_theme_terminal_tabs(thor)
    widgets.statusbar_set_colors(thor.statusbar, t.foreground, t.muted_color, t.buttons, t.accent_color, t.error_color)

    // Buttons. The Git top-bar button is a plugin button, recolored in the
    // plugin_buttons loop below, not here.
    for b in ([]^widgets.Button {
        thor.menu_file_button, thor.menu_edit_button, thor.menu_view_button, thor.menu_help_button,
    }) {
        thor_theme_menu_button(thor, b)
    }
    thor_theme_window_button(thor, thor.tasks_add_button, t.highlight)
    thor_theme_menu_button(thor, thor.tasks_select_button)
    // The run arrow keeps a green tint of its own; its hover stays neutral.
    thor_theme_window_button(thor, thor.tasks_run_button, t.highlight)
    thor.tasks_run_button.text_color = t.success_color
    thor_theme_window_button(thor, thor.minimize_button, t.highlight)
    thor_theme_window_button(thor, thor.maximize_button, t.highlight)
    thor_theme_window_button(thor, thor.close_button, t.danger_color)
    thor_theme_icon_button(thor, thor.explorer_toggle_button, t.highlight)
    thor_theme_icon_button(thor, thor.explorer_restore_button, t.buttons)
    thor_theme_icon_button(thor, thor.console_toggle_button, t.highlight)
    thor_theme_icon_button(thor, thor.console_restore_button, t.buttons)
    for pb in thor.plugin_buttons {
        if pb.button != nil {
            thor_theme_menu_button(thor, pb.button)
        }
    }
    // Theme-colored labels.
    widgets.label_set_text_color(thor.explorer_title_label, t.primary_text_color)

    // Syntax spans bake in theme colors, so every open file needs new ones. Only
    // mark them stale: the per-frame pane pass recolors the files on screen with
    // a window to scope to, and one off screen costs nothing until it is shown.
    for file in thor.open_files {
        file.highlighted = false
    }
}

// Menu-bar button coloring (File/Edit/View/Help/Git and plugin buttons).
thor_theme_menu_button :: proc(thor: ^Thor, button: ^widgets.Button) {
    widgets.button_set_colors(button, thor.theme.foreground, thor.theme.buttons, thor.theme.highlight, thor.theme.active, thor.theme.buttons)
    widgets.button_set_border_thickness(button, 0)
}

// Titlebar window control coloring; `hover` is the per-button tint.
thor_theme_window_button :: proc(thor: ^Thor, button: ^widgets.Button, hover: rl.Color) {
    widgets.button_set_colors(button, thor.theme.foreground, thor.theme.buttons, hover, thor.theme.active, thor.theme.buttons)
    widgets.button_set_border_thickness(button, 0)
}

// Flat panel collapse/restore icon-button coloring; `background` matches the
// container so only the hover state reads as a button.
thor_theme_icon_button :: proc(thor: ^Thor, button: ^widgets.Button, background: rl.Color) {
    widgets.button_set_colors(button, thor.theme.foreground, background, thor.theme.active, thor.theme.border, background)
    widgets.button_set_border_thickness(button, 0)
}

// Terminal tab strip coloring. The strip blends into the console header and the
// active tab takes the console body color, so the tab reads as the panel below it.
thor_theme_terminal_tabs :: proc(thor: ^Thor) {
    t := thor.theme
    widgets.tabstrip_set_colors(
        thor.terminal_tabs,
        t.muted_color, t.primary_text_color, t.highlight, t.second_background, t.tree, t.accent_color, t.error_color,
    )
}

// Preferences: Change Theme -> pick from the installed themes in a dialog that
// previews each one live as the selection moves.
thor_cmd_change_theme :: proc(data: rawptr) {
    thor := cast(^Thor) data
    labels, files := thor_available_theme_choices()
    if len(files) == 0 {
        thor_plugin_print(thor, "\nNo themes are installed.\n")
        return
    }
    current := setting.theme_name(&thor.config)
    if current == "" {
        current = DEFAULT_THEME
    }
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Change Theme", labels, current,
        thor_theme_preview, thor_theme_commit, thor, files,
    )
}

// Loads the theme and applies it live (no persistence): the dialog's preview.
thor_theme_preview :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_load_theme_by_name(thor, choice)
    thor_apply_theme(thor)
}

// Applies the chosen theme and persists it as the new default.
thor_theme_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_theme_preview(thor, choice)
    setting.persist_string(thor_active_settings_path(thor), "theme", choice)
    delete(thor.config.general.theme)
    thor.config.general.theme = strings.clone(choice)
    thor_settings_mark_clean(thor)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
}

// Preferences: Change Font -> pick from the registered text families in a dialog
// that previews each one live as the selection moves.
thor_cmd_change_font :: proc(data: rawptr) {
    thor := cast(^Thor) data
    families := ui.text_family_names()
    if len(families) == 0 {
        thor_plugin_print(thor, "\nNo font families are registered.\n")
        return
    }
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Change Font", families, ui.text_default_family(),
        thor_font_preview, thor_font_commit, thor,
    )
}

// Switches the default text font live (no persistence): the dialog's preview.
// Text is drawn through the default family everywhere, so it shows next frame.
thor_font_preview :: proc(_: rawptr, choice: string) {
    ui.text_set_default_family(choice)
}

// Applies the chosen font and persists it as the new default.
thor_font_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    if !ui.text_set_default_family(choice) {
        thor_plugin_print(thor, strings.concatenate({"\nFont ", choice, " is not available.\n"}, context.temp_allocator))
        return
    }
    setting.persist_string(thor_active_settings_path(thor), "font", choice)
    delete(thor.config.general.font)
    thor.config.general.font = strings.clone(choice)
    thor_settings_mark_clean(thor)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
}

// Picker rows for the ligatures setting.
@(private = "file")
LIGATURE_LABELS := [?]string {"On", "Off"}

// The ligatures setting as its picker row.
thor_ligatures_label :: proc(config: ^setting.Settings) -> string {
    return setting.ligatures(config) ? LIGATURE_LABELS[0] : LIGATURE_LABELS[1]
}

// Preferences: Ligatures -> draw the font's ligatures ("->" as one glyph), or
// the plain glyphs. Shaping runs per frame, so the choice shows at once.
thor_cmd_change_ligatures :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, "Ligatures",
        LIGATURE_LABELS[:], thor_ligatures_label(&thor.config),
        thor_ligatures_preview, thor_ligatures_commit, thor,
    )
}

// Switches ligatures live (no persistence): the dialog's preview.
thor_ligatures_preview :: proc(_: rawptr, choice: string) {
    ui.shape_set_ligatures(choice == LIGATURE_LABELS[0])
}

// Applies the choice and persists it.
thor_ligatures_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    enabled := choice == LIGATURE_LABELS[0]
    ui.shape_set_ligatures(enabled)
    setting.persist_bool(thor_active_settings_path(thor), "ligatures", enabled)
    thor.config.general.ligatures = enabled
    thor_settings_mark_clean(thor)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
}

// Icon families sharing a pack group are alternatives for the same set of icon
// names. The primary group backs the unprefixed UI names (buttons, tabbar,
// statusbar, tree chevrons/folder); the file group backs the tree's `filetype-`
// names, one glyph per language.
PRIMARY_ICON_PACK_GROUP :: "primary"
FILE_ICON_PACK_GROUP :: "files"

// Pack each group falls back to when settings.json names none.
DEFAULT_ICON_PACK :: "material"
DEFAULT_FILE_ICON_PACK :: "mdi"

// Makes `configured` the active pack for `group`, falling back to `fallback`
// when it is unset or names a pack that did not register.
thor_activate_icon_pack :: proc(group, configured, fallback: string) {
    if configured != "" && ui.icon_set_active_pack(group, configured) {
        return
    }
    if configured != "" {
        log.warnf("Configured icon pack %q is not available; using %q", configured, fallback)
    }
    if !ui.icon_set_active_pack(group, fallback) {
        log.warnf("Default icon pack %q is not available for group %q", fallback, group)
    }
}

// Opens a live-preview picker over the packs installed in `group`. `current` is
// the configured pack, empty when unset — the active one is the default then.
@(private = "file")
thor_open_icon_pack_dialog :: proc(
    thor: ^Thor,
    group, title, current: string,
    preview, commit: widgets.Select_Choice_Proc,
) {
    labels, names := ui.icon_pack_choices(group)
    if len(names) == 0 {
        thor_plugin_print(thor, "\nNo icon packs are installed.\n")
        return
    }
    active := current
    if active == "" {
        active = ui.icon_active_pack(group)
    }
    widgets.select_dialog_open(
        thor.select_dialog, &thor.ui_context, title, labels, active,
        preview, commit, thor, names,
    )
}

// Applies `choice` to `group`, persists it under `key`, and writes it back into
// `stored` (the owned config field) so the settings view redraws with it.
@(private = "file")
thor_icon_pack_apply :: proc(thor: ^Thor, group, key, choice: string, stored: ^string) {
    if !ui.icon_set_active_pack(group, choice) {
        thor_plugin_print(thor, strings.concatenate({"\nIcon pack ", choice, " is not available.\n"}, context.temp_allocator))
        return
    }
    setting.persist_string(thor_active_settings_path(thor), key, choice)
    delete(stored^)
    stored^ = strings.clone(choice)
    thor_settings_mark_clean(thor)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
}

// Preferences: Change Icon Pack -> pick from the installed primary icon packs
// (e.g. Tabler Icons, Material Icons) in a dialog that previews each one live.
thor_cmd_change_icon_pack :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_open_icon_pack_dialog(
        thor, PRIMARY_ICON_PACK_GROUP, "Change Icon Pack", setting.icon_pack_name(&thor.config),
        thor_icon_pack_preview, thor_icon_pack_commit,
    )
}

// Switches the active icon pack live (no persistence): the dialog's preview.
// Icon names are resolved at draw time, so this shows next frame.
thor_icon_pack_preview :: proc(_: rawptr, choice: string) {
    ui.icon_set_active_pack(PRIMARY_ICON_PACK_GROUP, choice)
}

// Applies the chosen icon pack and persists it as the new default.
thor_icon_pack_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_icon_pack_apply(thor, PRIMARY_ICON_PACK_GROUP, "icon_pack", choice, &thor.config.general.icon_pack)
}

// Preferences: Change File Icon Pack -> pick which pack draws the file tree's
// per-language icons (e.g. Devicon brand logos, Material Design Icons).
thor_cmd_change_file_icon_pack :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_open_icon_pack_dialog(
        thor, FILE_ICON_PACK_GROUP, "Change File Icon Pack", setting.file_icon_pack_name(&thor.config),
        thor_file_icon_pack_preview, thor_file_icon_pack_commit,
    )
}

thor_file_icon_pack_preview :: proc(_: rawptr, choice: string) {
    ui.icon_set_active_pack(FILE_ICON_PACK_GROUP, choice)
}

thor_file_icon_pack_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_icon_pack_apply(thor, FILE_ICON_PACK_GROUP, "file_icon_pack", choice, &thor.config.general.file_icon_pack)
}
