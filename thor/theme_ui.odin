package thor

import "core:os"
import "core:strings"
import rl "vendor:raylib"

import "../setting"
import "../ui"
import "../widgets"

// The Theme window (widgets.Theme_Editor), opened by the "Theme Colors" row of
// the Settings modal: one row per color role of the active palette, each opening
// the color picker, plus the rows that generate a whole palette from two seeds.
// The picker previews onto the running editor and only writes on OK, always into
// user/themes — assets/themes is replaced by every build and by every update.

// The Appearance row that opens the window.
THEME_EDITOR_SETTING :: "theme_editor"

// One color role's row. Prefixed like the plugin and backend rows, so one Choice
// handler tells them apart.
@(private = "file")
THEME_COLOR_PREFIX :: "theme_color:"
// A row that acts instead of naming a role (the generator's seeds and its button).
@(private = "file")
THEME_ACTION_PREFIX :: "theme_action:"

@(private)
thor_theme_color_id :: proc(key: string) -> string {
    return strings.concatenate({THEME_COLOR_PREFIX, key}, context.temp_allocator)
}

@(private)
thor_theme_color_key :: proc(id: string) -> (string, bool) {
    if !strings.has_prefix(id, THEME_COLOR_PREFIX) {
        return "", false
    }
    return id[len(THEME_COLOR_PREFIX):], true
}

@(private)
thor_theme_action_id :: proc(name: string) -> string {
    return strings.concatenate({THEME_ACTION_PREFIX, name}, context.temp_allocator)
}

@(private)
thor_theme_action_name :: proc(id: string) -> (string, bool) {
    if !strings.has_prefix(id, THEME_ACTION_PREFIX) {
        return "", false
    }
    return id[len(THEME_ACTION_PREFIX):], true
}

// Fold group per color group. Stable, since it keys the view's collapsed map.
@(private = "file")
THEME_GROUP_IDS := [ui.Theme_Color_Group]string {
    .Surfaces = "theme.surfaces",
    .Text     = "theme.text",
    .Status   = "theme.status",
    .Syntax   = "theme.syntax",
}

@(private = "file")
THEME_MODE_LABELS := [?]string {"Dark", "Light"}

// Puts the generator seeds back on the active theme. Called at startup and after a
// theme switch, so the Generate rows always open on something sensible.
thor_reset_theme_seeds :: proc(thor: ^Thor) {
    thor.theme_seed_background = thor.theme.background
    thor.theme_seed_accent = thor.theme.accent_color
    thor.theme_seed_dark = ui.color_on(thor.theme.background) == ui.COLOR_ON_LIGHT
}

// Fills the window: the generator first, then every color role under a fold group
// of its own. Driven by ui.THEME_COLORS, so it needs no key list.
thor_populate_theme_editor :: proc(thor: ^Thor) {
    editor := thor.theme_editor
    widgets.theme_editor_clear(editor)
    widgets.theme_editor_set_title(editor, thor.theme.name)

    widgets.theme_editor_begin_group(editor, "theme.generate", "Generate From Colors", collapsed = true)
    widgets.theme_editor_add_action(editor, "mode", "Mode", THEME_MODE_LABELS[thor.theme_seed_dark ? 0 : 1])
    widgets.theme_editor_add_color(
        editor, "seed_background", "Background Seed",
        ui.color_to_hex(thor.theme_seed_background), thor.theme_seed_background,
    )
    widgets.theme_editor_add_color(
        editor, "seed_accent", "Accent Seed", ui.color_to_hex(thor.theme_seed_accent), thor.theme_seed_accent,
    )
    widgets.theme_editor_add_action(editor, "generate", "Save Generated Theme", "Name it...")
    widgets.theme_editor_end_group(editor)

    group := ui.Theme_Color_Group.Surfaces
    open_group := false
    for entry, i in ui.THEME_COLORS {
        if i == 0 || entry.group != group {
            if open_group {
                widgets.theme_editor_end_group(editor)
            }
            group = entry.group
            widgets.theme_editor_begin_group(
                editor, THEME_GROUP_IDS[group], ui.THEME_GROUP_LABELS[group], collapsed = group != .Surfaces,
            )
            open_group = true
        }
        color := ui.theme_color_at(&thor.theme, i)^
        widgets.theme_editor_add_color(editor, entry.key, entry.key, ui.color_to_hex(color), color)
    }
    if open_group {
        widgets.theme_editor_end_group(editor)
    }
}

// Settings > Appearance > Theme Colors: opens the window over the modal.
thor_open_theme_editor :: proc(thor: ^Thor) {
    thor_populate_theme_editor(thor)
    widgets.theme_editor_open(thor.theme_editor, &thor.ui_context)
}

// Rebuilds the rows when the window is up, so a committed color refreshes its
// swatch and hex.
@(private = "file")
thor_refresh_theme_editor :: proc(thor: ^Thor) {
    if widgets.theme_editor_is_open(thor.theme_editor) {
        thor_populate_theme_editor(thor)
    }
}

// The seed rows the generator owns; every other row names a color role.
@(private = "file")
thor_is_theme_seed :: proc(key: string) -> bool {
    return key == "seed_background" || key == "seed_accent"
}

// A color row of the window was clicked: the generator's seeds go to the seed
// callbacks, every other row edits that role of the palette.
thor_on_theme_editor_color :: proc(data: rawptr, key: string) {
    thor := cast(^Thor) data
    if thor_is_theme_seed(key) {
        seed := key == "seed_background" ? thor.theme_seed_background : thor.theme_seed_accent
        label := key == "seed_background" ? "Background Seed" : "Accent Seed"
        widgets.color_picker_open(
            thor.color_picker, &thor.ui_context, label, thor_theme_action_id(key), seed,
            thor_theme_seed_preview, thor_theme_seed_commit, thor_theme_seed_cancel, thor,
        )
        return
    }
    thor_open_theme_color(thor, key)
}

// An action row of the window was clicked.
thor_on_theme_editor_action :: proc(data: rawptr, action: string) {
    thor_run_theme_action(cast(^Thor) data, action)
}

// Opens the picker over one color role, remembering the value it had so a cancel
// can put it back.
@(private = "file")
thor_open_theme_color :: proc(thor: ^Thor, key: string) {
    field := ui.theme_color_ptr(&thor.theme, key)
    if field == nil {
        return
    }
    delete(thor.theme_edit_key)
    thor.theme_edit_key = strings.clone(key)
    thor.theme_edit_original = field^
    widgets.color_picker_open(
        thor.color_picker, &thor.ui_context, key, thor_theme_color_id(key), field^,
        thor_theme_color_preview, thor_theme_color_commit, thor_theme_color_cancel, thor,
    )
}

// Writes `color` into the palette and pushes it onto the widgets. A syntax role
// also marks the open files stale, since its color is baked into their spans;
// every other role reaches the screen through a widget's cached color, and
// re-highlighting every buffer per drag frame would not pay for itself.
@(private = "file")
thor_theme_color_apply :: proc(thor: ^Thor, key: string, color: rl.Color) {
    field := ui.theme_color_ptr(&thor.theme, key)
    if field == nil {
        return
    }
    field^ = color
    thor_apply_theme_widgets(thor)
    if thor_theme_color_group(key) == .Syntax {
        for file in thor.open_files {
            file.highlighted = false
        }
    }
}

@(private = "file")
thor_theme_color_group :: proc(key: string) -> ui.Theme_Color_Group {
    for entry in ui.THEME_COLORS {
        if entry.key == key {
            return entry.group
        }
    }
    return .Surfaces
}

thor_theme_color_preview :: proc(data: rawptr, id: string, color: rl.Color) {
    thor := cast(^Thor) data
    key, ok := thor_theme_color_key(id)
    if !ok {
        return
    }
    thor_theme_color_apply(thor, key, color)
}

// OK: persists the whole palette into user/themes, then applies it in full so the
// syntax spans recolor.
//
// thor_reload_settings is deliberately not on this path: it only re-applies a
// theme when the theme *name* changed, and editing the active theme changes no
// settings key at all.
thor_theme_color_commit :: proc(data: rawptr, id: string, color: rl.Color) {
    thor := cast(^Thor) data
    key, ok := thor_theme_color_key(id)
    if !ok {
        return
    }

    path := thor_theme_ensure_writable(thor)
    if path == "" {
        thor_theme_color_cancel(thor, id)
        return
    }

    thor_theme_color_apply(thor, key, color)
    if !ui.theme_save(thor.theme, path) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        thor_theme_color_cancel(thor, id)
        return
    }

    thor_apply_theme(thor)
    thor_settings_mark_clean(thor)
    thor_refresh_theme_editor(thor)
}

thor_theme_color_cancel :: proc(data: rawptr, id: string) {
    thor := cast(^Thor) data
    key, ok := thor_theme_color_key(id)
    if !ok {
        return
    }
    thor_theme_color_apply(thor, key, thor.theme_edit_original)
    thor_apply_theme(thor)
    thor_refresh_theme_editor(thor)
}

// Where an edit to the active theme goes. A shipped theme is copied into
// user/themes on the first edit: assets/themes is replaced by every build and by
// every update, and the user layer shadows it by base name, so the copy takes over
// with no change to the `theme` setting. Returns the path, or "" when the copy
// failed.
@(private = "file")
thor_theme_ensure_writable :: proc(thor: ^Thor) -> string {
    // A generated preview belongs to no file yet, and writing it under the
    // configured name would replace a theme the user never meant to touch.
    if thor.theme_preview_generated {
        thor_flash_status(thor, "Save the generated theme before editing its colors", is_error = true)
        return ""
    }
    name := setting.theme_name(&thor.config)
    if name == "" {
        name = DEFAULT_THEME
    }
    path := thor_user_theme_path(name)
    if os.exists(path) {
        return path
    }
    if !ui.theme_save(thor.theme, path) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return ""
    }
    thor_flash_status(thor, "Saved an editable copy to user/themes")
    return path
}

// A generator row was clicked.
@(private = "file")
thor_run_theme_action :: proc(thor: ^Thor, action: string) {
    switch action {
    case "mode":
        widgets.select_dialog_open(
            thor.select_dialog, &thor.ui_context, "Generator Mode",
            THEME_MODE_LABELS[:], THEME_MODE_LABELS[thor.theme_seed_dark ? 0 : 1],
            thor_theme_mode_preview, thor_theme_mode_commit, thor,
        )
    case "generate":
        widgets.command_palette_prompt(
            thor.command_palette, &thor.ui_context, "Theme name", thor_confirm_generate_theme, thor, "My Theme",
        )
    }
}

// Rebuilds the palette from the current seeds and applies it live, writing
// nothing. The generator is arithmetic alone, so a drag can run it per frame.
@(private = "file")
thor_theme_generate_preview :: proc(thor: ^Thor) {
    generated := ui.theme_generate("Generated", thor.theme_seed_background, thor.theme_seed_accent, thor.theme_seed_dark)
    ui.theme_destroy(&thor.theme)
    thor.theme = generated
    thor.theme_preview_generated = true
    thor_apply_theme(thor)
}

// Puts the configured theme back on screen, dropping the generated preview.
@(private = "file")
thor_theme_restore_configured :: proc(thor: ^Thor) {
    name := setting.theme_name(&thor.config)
    if name == "" {
        name = DEFAULT_THEME
    }
    thor_load_theme_by_name(thor, name)
    thor_apply_theme(thor)
}

@(private = "file")
thor_theme_mode_preview :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor.theme_seed_dark = choice == THEME_MODE_LABELS[0]
    thor_theme_generate_preview(thor)
}

@(private = "file")
thor_theme_mode_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    thor_theme_mode_preview(thor, choice)
    thor_refresh_theme_editor(thor)
}

@(private = "file")
thor_theme_seed_preview :: proc(data: rawptr, id: string, color: rl.Color) {
    thor := cast(^Thor) data
    thor_theme_set_seed(thor, id, color)
    thor_theme_generate_preview(thor)
}

@(private = "file")
thor_theme_seed_commit :: proc(data: rawptr, id: string, color: rl.Color) {
    thor := cast(^Thor) data
    thor_theme_seed_preview(thor, id, color)
    // The palette on screen is the generated one; it is saved by the Generate row,
    // not here, so only the rows need refreshing.
    thor_refresh_theme_editor(thor)
}

@(private = "file")
thor_theme_seed_cancel :: proc(data: rawptr, _: string) {
    thor := cast(^Thor) data
    thor_theme_restore_configured(thor)
    thor_refresh_theme_editor(thor)
}

@(private = "file")
thor_theme_set_seed :: proc(thor: ^Thor, id: string, color: rl.Color) {
    action, ok := thor_theme_action_name(id)
    if !ok {
        return
    }
    switch action {
    case "seed_background":
        thor.theme_seed_background = color
    case "seed_accent":
        thor.theme_seed_accent = color
    }
}

// Name prompt accepted: writes the generated palette to user/themes and makes it
// the configured theme.
thor_confirm_generate_theme :: proc(data: rawptr, name: string) {
    thor := cast(^Thor) data
    trimmed := strings.trim_space(name)
    if trimmed == "" {
        return
    }
    file := thor_theme_slug(trimmed)
    if file == "" {
        thor_flash_status(thor, "That theme name has no usable characters", is_error = true)
        return
    }

    path := thor_user_theme_path(file)
    if os.exists(path) {
        thor_flash_status(thor, "A theme with that name already exists", is_error = true)
        return
    }

    generated := ui.theme_generate(trimmed, thor.theme_seed_background, thor.theme_seed_accent, thor.theme_seed_dark)
    defer ui.theme_destroy(&generated)
    if !ui.theme_save(generated, path) {
        thor_flash_status(thor, SETTINGS_SAVE_FAILED, is_error = true)
        return
    }

    // The one theme path where thor_reload_settings does re-apply: the theme name
    // changed, which is what it compares.
    thor_persist_string_setting(thor, "theme", file)
    thor_refresh_theme_editor(thor)
}

// A theme name as its file base: lowercase, dashes for spaces, and nothing that
// could leave the themes directory — the name is free-form text going into a path.
@(private)
thor_theme_slug :: proc(name: string, allocator := context.temp_allocator) -> string {
    builder := strings.builder_make(allocator)
    for i in 0 ..< len(name) {
        switch c := name[i]; c {
        case 'a' ..= 'z', '0' ..= '9':
            strings.write_byte(&builder, c)
        case 'A' ..= 'Z':
            strings.write_byte(&builder, c + ('a' - 'A'))
        case ' ', '_', '-':
            // No leading or doubled dash, so ".." and "-" alone cannot come out.
            if strings.builder_len(builder) > 0 && strings.to_string(builder)[strings.builder_len(builder) - 1] != '-' {
                strings.write_byte(&builder, '-')
            }
        }
    }
    return strings.trim_suffix(strings.to_string(builder), "-")
}
