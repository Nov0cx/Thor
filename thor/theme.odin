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

    widgets.dialog_set_colors(thor.dialog, t.white_black_color, t.highlight, t.notifications, t.border)

    widgets.command_palette_set_colors(
        thor.command_palette,
        t.second_background, t.accent_color, t.background, t.white_black_color, t.gray_color, selected, t.accent_color,
    )
    widgets.select_dialog_set_colors(
        thor.select_dialog,
        t.second_background, t.accent_color, t.highlight, t.white_black_color, t.gray_color, selected, t.accent_color,
    )
    widgets.find_replace_set_colors(
        thor.find_replace,
        t.second_background, t.accent_color, t.background, t.white_black_color, t.gray_color, t.buttons, t.accent_color,
    )
    widgets.menu_set_colors(
        thor.menu,
        t.second_background, t.accent_color, t.white_black_color, t.gray_color, selected, t.border,
    )

    widgets.tree_set_colors(
        thor.tree,
        t.foreground, t.white_black_color, t.blue_color, t.gray_color, t.tree, t.selection_background, t.second_background,
    )
    widgets.tree_set_git_colors(thor.tree, t.yellow_color, t.green_color, t.red_color, t.orange_color, t.purple_color)

    widgets.tabbar_set_colors(
        thor.tabbar,
        t.foreground, t.white_black_color, t.active, t.buttons, t.background, t.tree, t.accent_color,
    )

    for editor in ([]^widgets.Editor {thor.editor, thor.editor2}) {
        widgets.editor_set_colors(
            editor,
            t.white_black_color, t.gray_color, t.background, t.second_background, t.border, t.border, t.accent_color,
        )
    }

    widgets.image_view_set_colors(thor.image_view, t.background, t.second_background, t.buttons, t.white_black_color)
    widgets.console_set_colors(thor.console, t.foreground, t.accent_color, t.second_background, t.accent_color)
    widgets.statusbar_set_colors(thor.statusbar, t.foreground, t.gray_color, t.buttons, t.accent_color, t.error_color)

    // Buttons. The Git top-bar button is a plugin button, recolored in the
    // plugin_buttons loop below, not here.
    for b in ([]^widgets.Button {
        thor.menu_file_button, thor.menu_edit_button, thor.menu_view_button, thor.menu_help_button,
    }) {
        thor_theme_menu_button(thor, b)
    }
    thor_theme_window_button(thor, thor.minimize_button, t.highlight)
    thor_theme_window_button(thor, thor.maximize_button, t.highlight)
    thor_theme_window_button(thor, thor.close_button, t.red_color)
    thor_theme_icon_button(thor, thor.explorer_toggle_button, t.highlight)
    thor_theme_icon_button(thor, thor.explorer_restore_button, t.buttons)
    thor_theme_icon_button(thor, thor.console_toggle_button, t.highlight)
    thor_theme_icon_button(thor, thor.console_restore_button, t.buttons)
    for pb in thor.plugin_buttons {
        if pb.button != nil {
            thor_theme_menu_button(thor, pb.button)
        }
    }
    widgets.button_set_colors(thor.dialog_console_button, t.white_black_color, t.blue_color, t.cyan_color, t.active, t.border)

    // Theme-colored labels.
    widgets.label_set_text_color(thor.top_title_label, t.accent_color)
    widgets.label_set_text_color(thor.explorer_title_label, t.white_black_color)
    widgets.label_set_text_color(thor.console_title_label, t.white_black_color)
    widgets.label_set_text_color(thor.dialog_text_label, t.white_black_color)

    // Syntax spans bake in theme colors, so recolor every open file.
    for file in thor.open_files {
        thor_update_highlights(thor, file)
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
    setting.persist_string("settings/settings.json", "theme", choice)
    delete(thor.config.general.theme)
    thor.config.general.theme = strings.clone(choice)
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
    setting.persist_string("settings/settings.json", "font", choice)
    delete(thor.config.general.font)
    thor.config.general.font = strings.clone(choice)
}
