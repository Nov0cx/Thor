// The theme window's behaviour: the draft, its save paths, the generator and the
// theme commands. thor/theme_editor.odin declares the window.
//
// An edit changes thor.theme, the draft, and the whole editor shows it at once.
// Nothing is written until Save; Revert puts back `saved`, the palette on disk.
// Every write goes to user/themes — assets/themes is replaced by every build and
// by every update.
package thor

import "core:os"
import "core:strings"
import rl "vendor:raylib"

import "../setting"
import "../theme"
import ui "../vendor/loom/loom"

// The Appearance row that opens the window.
THEME_EDITOR_SETTING :: "theme_editor"

THEME_MODE_LABELS := [?]string{"Dark", "Light"}

// The answers to the unsaved-changes question.
@(private = "file")
THEME_UNSAVED_CHOICES := [?]string{"Save", "Discard", "Cancel"}

// What runs once the unsaved-changes question is answered.
Theme_Pending :: enum {
    None,
    Close,
    Switch,
    Open_File,
}

// Puts the generator seeds back on the active theme. Called at startup and after a
// theme switch, so the Generate tab always opens on something sensible.
thor_reset_theme_seeds :: proc(thor: ^Thor) {
    thor.theme_seed_background = thor.theme.background
    thor.theme_seed_accent = thor.theme.accent_color
    thor.theme_seed_dark = theme.color_on(thor.theme.background) == theme.COLOR_ON_LIGHT
}

// The theme the settings name, or the default.
thor_theme_configured_name :: proc(thor: ^Thor) -> string {
    name := setting.theme_name(&thor.config)
    return name == "" ? DEFAULT_THEME : name
}

// Makes the configured theme and the palette on screen the clean state of the draft.
thor_theme_editor_rebaseline :: proc(thor: ^Thor) {
    e    := &thor.theme_editor
    file := strings.clone(thor_theme_configured_name(thor))
    delete(e.file)
    e.file = file
    theme.destroy(&e.saved)
    e.saved = theme.clone(thor.theme)
    e.generated = false
}

// Whether the draft differs from the file it came from.
thor_theme_dirty :: proc(thor: ^Thor) -> bool {
    e := &thor.theme_editor
    return e.generated || !theme.equal(thor.theme, e.saved)
}

// Follows a theme switch made while the window is open (the theme picker, Save
// As, Delete). A generated draft and an open picker keep their state.
thor_theme_editor_sync :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    if e.generated || thor.select_open {
        return
    }
    if e.file != thor_theme_configured_name(thor) {
        thor_theme_editor_rebaseline(thor)
        thor_reset_theme_seeds(thor)
        thor_theme_generate_refresh(thor)
    }
}

// Shows a message in the window footer and in the status bar.
thor_theme_note :: proc(thor: ^Thor, message: string, is_error := false) {
    e    := &thor.theme_editor
    text := strings.clone(message)
    delete(e.note)
    e.note = text
    e.note_error = is_error
    thor_flash_status(thor, message, is_error)
}

// Opens the window on the configured theme. Opening an open window changes nothing.
thor_open_theme_editor :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    if !thor.theme_editor_open {
        e.return_focus = thor.focus_owner
        e.pending = .None
        delete(e.note)
        e.note = ""
        thor_theme_editor_rebaseline(thor)
        thor_theme_generate_refresh(thor)
        if e.selected < 0 || e.selected >= len(theme.COLORS) {
            e.selected = 0
        }
    }
    thor.theme_editor_open = true
}

thor_theme_editor_is_open :: proc(thor: ^Thor) -> bool {
    return thor.theme_editor_open
}

// Closes the window at once; the caller has settled the draft.
@(private = "file")
thor_theme_editor_close :: proc(thor: ^Thor) {
    thor.theme_editor_open = false
    if thor.theme_editor.return_focus != "" {
        thor.focus_request = thor.theme_editor.return_focus
    }
}

// Closes the window, asking first when the draft has unsaved changes.
thor_theme_request_close :: proc(thor: ^Thor) {
    thor_theme_resolve_then(thor, .Close)
}

// Runs `next` now when the draft is clean, else after the user saves or discards.
thor_theme_resolve_then :: proc(thor: ^Thor, next: Theme_Pending) {
    thor.theme_editor.pending = next
    if !thor_theme_dirty(thor) {
        thor_theme_run_pending(thor)
        return
    }
    thor_palette_pick(thor, "Unsaved theme changes", THEME_UNSAVED_CHOICES[:], thor_theme_unsaved_answer, thor)
}

@(private = "file")
thor_theme_unsaved_answer :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor)data
    switch choice {
    case "Save":
        // A generated draft asks for a name first; its prompt runs the pending step.
        if thor_theme_save(thor) {
            thor_theme_run_pending(thor)
        }
    case "Discard":
        thor_theme_discard(thor)
        thor_theme_run_pending(thor)
    case:
        thor.theme_editor.pending = .None
    }
}

@(private = "file")
thor_theme_run_pending :: proc(thor: ^Thor) {
    next := thor.theme_editor.pending
    thor.theme_editor.pending = .None
    switch next {
    case .None:
    case .Close:
        thor_theme_editor_close(thor)
    case .Switch:
        thor_cmd_change_theme(thor)
    case .Open_File:
        thor_theme_open_file_now(thor)
    }
}

// Drops the draft and loads the configured theme again.
thor_theme_discard :: proc(thor: ^Thor) {
    thor_load_theme_by_name(thor, thor_theme_configured_name(thor))
    thor_apply_theme(thor)
    thor_theme_editor_rebaseline(thor)
}

// Puts the saved palette back on screen.
thor_theme_revert :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    if !thor_theme_dirty(thor) {
        thor_theme_note(thor, "No unsaved theme changes")
        return
    }
    theme.destroy(&thor.theme)
    thor.theme = theme.clone(e.saved)
    e.generated = false
    thor_apply_theme(thor)
    thor_theme_note(thor, "Reverted to the saved theme")
}

// Writes the draft to user/themes under its file name. A generated draft has no
// file yet, so it opens the name prompt and returns false.
thor_theme_save :: proc(thor: ^Thor) -> bool {
    e := &thor.theme_editor
    if e.generated {
        thor_theme_save_as_prompt(thor, thor.theme.name)
        return false
    }
    path    := thor_user_theme_path(e.file)
    shadows := !os.exists(path) && thor_theme_is_shipped(e.file)
    if !theme.save(thor.theme, path) {
        thor_theme_note(thor, "Could not write the theme file", is_error = true)
        return false
    }
    theme.destroy(&e.saved)
    e.saved = theme.clone(thor.theme)
    if shadows {
        thor_theme_note(thor, strings.concatenate({"Saved ", path, ". It overrides the shipped theme"}, context.temp_allocator))
    } else {
        thor_theme_note(thor, strings.concatenate({"Saved ", path}, context.temp_allocator))
    }
    return true
}

// Asks for a theme name; the draft is saved under it as a new user theme.
thor_theme_save_as_prompt :: proc(thor: ^Thor, initial: string) {
    thor_palette_prompt(thor, "Theme name", thor_theme_save_as_confirm, thor, initial)
}

// Name prompt accepted: writes the draft as a new theme and makes it the
// configured one.
thor_theme_save_as_confirm :: proc(data: rawptr, name: string) {
    thor    := cast(^Thor)data
    e       := &thor.theme_editor
    trimmed := strings.trim_space(name)
    if trimmed == "" {
        return
    }
    file := thor_theme_slug(trimmed)
    if file == "" {
        thor_theme_note(thor, "That theme name has no usable characters", is_error = true)
        return
    }
    path := thor_user_theme_path(file)
    if os.exists(path) || thor_theme_is_shipped(file) {
        thor_theme_note(thor, "A theme with that name already exists", is_error = true)
        return
    }

    renamed := strings.clone(trimmed)
    delete(thor.theme.name)
    thor.theme.name = renamed
    if !theme.save(thor.theme, path) {
        thor_theme_note(thor, "Could not write the theme file", is_error = true)
        return
    }
    e.generated = false
    // The theme name changed, so the reload loads the new file.
    thor_persist_string_setting(thor, "theme", file)
    if thor_theme_configured_name(thor) != file {
        // The setting did not land; the new file stays, the screen goes back.
        thor_theme_discard(thor)
        return
    }
    thor_theme_editor_rebaseline(thor)
    thor_theme_note(thor, strings.concatenate({"Saved ", path}, context.temp_allocator))
    thor_theme_run_pending(thor)
}

// Whether assets/themes ships a theme of this file name.
thor_theme_is_shipped :: proc(file: string) -> bool {
    return os.exists(strings.concatenate({SHIPPED_THEME_DIR, "/", file, THEME_EXT}, context.temp_allocator))
}

// Whether user/themes holds a theme of this file name.
thor_theme_is_user :: proc(file: string) -> bool {
    return os.exists(thor_user_theme_path(file))
}

// Removes a theme the user made and switches to the default theme.
thor_theme_delete :: proc(thor: ^Thor) {
    file := thor.theme_editor.file
    if !thor_theme_is_user(file) || thor_theme_is_shipped(file) {
        thor_theme_note(thor, "Only a theme you made can be deleted", is_error = true)
        return
    }
    message := strings.concatenate({"Delete the theme \"", thor.theme_editor.saved.name, "\"?"}, context.temp_allocator)
    thor_palette_confirm(thor, message, thor_theme_delete_confirm, thor)
}

@(private = "file")
thor_theme_delete_confirm :: proc(data: rawptr) {
    thor := cast(^Thor)data
    path := thor_user_theme_path(thor.theme_editor.file)
    if err := os.remove(path); err != nil {
        thor_theme_note(thor, "Could not delete the theme file", is_error = true)
        return
    }
    thor.theme_editor.generated = false
    thor_persist_string_setting(thor, "theme", DEFAULT_THEME)
    thor_theme_discard(thor)
    thor_theme_note(thor, strings.concatenate({"Deleted ", path}, context.temp_allocator))
}

// Removes the user copy of a shipped theme, so the shipped colors come back.
thor_theme_reset_shipped :: proc(thor: ^Thor) {
    file := thor.theme_editor.file
    if !thor_theme_is_user(file) || !thor_theme_is_shipped(file) {
        thor_theme_note(thor, "This theme has no changes to the shipped one", is_error = true)
        return
    }
    message := strings.concatenate({"Reset \"", thor.theme_editor.saved.name, "\" to the shipped colors?"}, context.temp_allocator)
    thor_palette_confirm(thor, message, thor_theme_reset_confirm, thor)
}

@(private = "file")
thor_theme_reset_confirm :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if err := os.remove(thor_user_theme_path(thor.theme_editor.file)); err != nil {
        thor_theme_note(thor, "Could not remove the theme copy", is_error = true)
        return
    }
    thor.theme_editor.generated = false
    thor_theme_discard(thor)
    thor_theme_note(thor, "Reset to the shipped theme")
}

// Opens the theme's file in the editor for hand editing. A shipped theme is
// copied to user/themes first, since assets/themes is replaced by every update.
thor_theme_open_file_now :: proc(thor: ^Thor) {
    file := thor.theme_editor_open ? thor.theme_editor.file : thor_theme_configured_name(thor)
    path := thor_user_theme_path(file)
    if !os.exists(path) {
        palette := thor.theme_editor_open ? thor.theme_editor.saved : thor.theme
        if !theme.save(palette, path) {
            thor_theme_note(thor, "Could not write the theme file", is_error = true)
            return
        }
    }
    if thor.theme_editor_open {
        thor_theme_editor_close(thor)
    }
    thor_open_file(thor, path)
}

// Writes `color` into role `index` of the draft. A syntax role also marks the
// open files stale, since its color is baked into their spans.
thor_theme_set_color :: proc(thor: ^Thor, index: int, color: ui.Color) {
    if index < 0 || index >= len(theme.COLORS) {
        return
    }
    theme.color_at(&thor.theme, index)^ = color
    if theme.COLORS[index].group == .Syntax {
        for file in thor.open_files {
            file.highlighted = false
        }
    }
}

// Opens the color picker over role `index` of the draft.
thor_theme_edit_color :: proc(thor: ^Thor, index: int) {
    if index < 0 || index >= len(theme.COLORS) {
        return
    }
    e := &thor.theme_editor
    e.selected = index
    e.edit_index = index
    e.edit_original = theme.color_at(&thor.theme, index)^
    entry := theme.COLORS[index]
    thor_color_picker_open(thor, entry.key, entry.role, e.edit_original, thor_theme_color_preview, thor_theme_color_commit, thor_theme_color_cancel, thor)
}

@(private = "file")
thor_theme_color_preview :: proc(data: rawptr, _: string, color: ui.Color) {
    thor := cast(^Thor)data
    thor_theme_set_color(thor, thor.theme_editor.edit_index, color)
}

@(private = "file")
thor_theme_color_commit :: proc(data: rawptr, _: string, color: ui.Color) {
    thor := cast(^Thor)data
    thor_theme_set_color(thor, thor.theme_editor.edit_index, color)
    thor_apply_theme(thor)
}

@(private = "file")
thor_theme_color_cancel :: proc(data: rawptr, _: string) {
    thor := cast(^Thor)data
    thor_theme_set_color(thor, thor.theme_editor.edit_index, thor.theme_editor.edit_original)
    thor_apply_theme(thor)
}

// Puts role `index` back to its saved color.
thor_theme_reset_color :: proc(thor: ^Thor, index: int) {
    if index < 0 || index >= len(theme.COLORS) {
        return
    }
    thor_theme_set_color(thor, index, theme.color_at(&thor.theme_editor.saved, index)^)
    thor_apply_theme(thor)
}

// Copies the hex of role `index` to the clipboard.
thor_theme_copy_color :: proc(thor: ^Thor, index: int) {
    if index < 0 || index >= len(theme.COLORS) {
        return
    }
    hex := theme.to_hex(theme.color_at(&thor.theme, index)^)
    rl.SetClipboardText(strings.clone_to_cstring(hex, context.temp_allocator))
    thor_theme_note(thor, strings.concatenate({"Copied ", hex}, context.temp_allocator))
}

// Sets role `index` from a hex color on the clipboard. The "#" is optional.
thor_theme_paste_color :: proc(thor: ^Thor, index: int) {
    if index < 0 || index >= len(theme.COLORS) {
        return
    }
    text      := strings.trim_space(string(rl.GetClipboardText()))
    color, ok := thor_theme_parse_color(text)
    if !ok {
        thor_theme_note(thor, "The clipboard holds no #RRGGBB or #RRGGBBAA color", is_error = true)
        return
    }
    thor_theme_set_color(thor, index, color)
    thor_apply_theme(thor)
    thor_theme_note(thor, strings.concatenate({"Pasted ", theme.to_hex(color), " into ", theme.COLORS[index].key}, context.temp_allocator))
}

// A hex color with or without its "#".
thor_theme_parse_color :: proc(text: string) -> (ui.Color, bool) {
    if strings.has_prefix(text, "#") {
        return theme.parse_hex(text)
    }
    return theme.parse_hex(strings.concatenate({"#", text}, context.temp_allocator))
}

// Builds the generator's palette from the seeds; the Generate tab previews it.
thor_theme_generate_refresh :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    theme.destroy(&e.generated_theme)
    e.generated_theme = theme.generate("Generated Theme", thor.theme_seed_background, thor.theme_seed_accent, thor.theme_seed_dark)
}

// Sets the generator mode.
thor_theme_set_mode :: proc(thor: ^Thor, dark: bool) {
    thor.theme_seed_dark = dark
    thor_theme_generate_refresh(thor)
}

// Makes the generated palette the draft. It has no file, so Save asks for a name.
thor_theme_use_generated :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    theme.destroy(&thor.theme)
    thor.theme = theme.clone(e.generated_theme)
    e.generated = true
    e.tab = .Colors
    thor_apply_theme(thor)
    thor_theme_note(thor, "The generated palette is the draft. Save it under a new name to keep it")
}

// Opens the color picker over one generator seed.
thor_theme_edit_seed :: proc(thor: ^Thor, accent: bool) {
    e := &thor.theme_editor
    e.seed_accent = accent
    e.seed_original = accent ? thor.theme_seed_accent : thor.theme_seed_background
    thor_color_picker_open(
        thor,
        accent ? "Accent Seed" : "Background Seed",
        "seed",
        e.seed_original,
        thor_theme_seed_preview,
        thor_theme_seed_preview,
        thor_theme_seed_cancel,
        thor,
    )
}

@(private = "file")
thor_theme_seed_preview :: proc(data: rawptr, _: string, color: ui.Color) {
    thor := cast(^Thor)data
    if thor.theme_editor.seed_accent {
        thor.theme_seed_accent = color
    } else {
        thor.theme_seed_background = color
    }
    thor_theme_generate_refresh(thor)
}

@(private = "file")
thor_theme_seed_cancel :: proc(data: rawptr, id: string) {
    thor := cast(^Thor)data
    thor_theme_seed_preview(thor, id, thor.theme_editor.seed_original)
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

thor_cmd_theme_editor :: proc(data: rawptr) {
    thor_open_theme_editor(cast(^Thor)data)
}

thor_cmd_theme_save :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor.theme_editor.pending = .None
    if thor_theme_dirty(thor) {
        thor_theme_save(thor)
    } else {
        thor_theme_note(thor, "No unsaved theme changes")
    }
}

thor_cmd_theme_save_as :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor.theme_editor.pending = .None
    thor_theme_save_as_prompt(thor, thor.theme.name)
}

thor_cmd_theme_duplicate :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor.theme_editor.pending = .None
    thor_theme_save_as_prompt(thor, strings.concatenate({thor.theme.name, " Copy"}, context.temp_allocator))
}

thor_cmd_theme_revert :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor_theme_revert(thor)
}

thor_cmd_theme_delete :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor_theme_delete(thor)
}

thor_cmd_theme_reset :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor_theme_reset_shipped(thor)
}

thor_cmd_theme_open_file :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if thor.theme_editor_open {
        thor_theme_resolve_then(thor, .Open_File)
    } else {
        thor_theme_open_file_now(thor)
    }
}

thor_cmd_theme_switch :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor_theme_resolve_then(thor, .Switch)
}

thor_cmd_theme_generate :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor.theme_editor.tab = .Generate
}

thor_cmd_theme_use_generated :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor_theme_use_generated(thor)
}

thor_cmd_theme_edit_color :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor_theme_edit_color(thor, thor.theme_editor.selected)
}

thor_cmd_theme_reset_color :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor_theme_reset_color(thor, thor.theme_editor.selected)
}

thor_cmd_theme_copy_color :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor_theme_copy_color(thor, thor.theme_editor.selected)
}

thor_cmd_theme_paste_color :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_theme_editor(thor)
    thor_theme_paste_color(thor, thor.theme_editor.selected)
}
