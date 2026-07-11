package thor

import "core:os"

import "../settings"
import "../textedit"
import "../ui"
import "../widgets"

// Applies the configurable parts of the loaded settings to the live widgets.
// Called at startup and whenever settings are reloaded, so both paths stay in
// sync.
thor_apply_settings :: proc(thor: ^Thor) {
    if kb, ok := settings.keybind(&thor.config, "toggle_line_comment"); ok {
        thor.editor.comment_keybind = kb
    }
    if kb, ok := settings.keybind(&thor.config, "command_palette"); ok {
        thor.command_palette_key = kb
    } else {
        thor.command_palette_key = settings.Keybind {key = .PERIOD, ctrl = true}
    }
    if kb, ok := settings.keybind(&thor.config, "toggle_fullscreen"); ok {
        thor.fullscreen_key = kb
    } else {
        thor.fullscreen_key = settings.Keybind {key = .F12}
    }

    widgets.editor_set_font_size(thor.editor, cast(i32) settings.font_size(&thor.config))
    textedit.set_tab_width(settings.tab_width(&thor.config))
}

thor_reload_settings :: proc(thor: ^Thor) {
    settings.destroy(&thor.config)
    thor.config = settings.load("settings")
    thor_apply_settings(thor)
}

thor_toggle_command_palette :: proc(thor: ^Thor) {
    if widgets.command_palette_is_open(thor.command_palette) {
        widgets.command_palette_close(thor.command_palette, &thor.ui_context)
    } else {
        widgets.command_palette_open(thor.command_palette, &thor.ui_context)
    }
}

// Registers every command shown in the palette. Titles are grouped by a
// "Category: Action" convention so fuzzy search on the category works too.
thor_register_commands :: proc(thor: ^Thor) {
    p := thor.command_palette

    widgets.command_palette_add(p, "View: Toggle Explorer", thor_cmd_toggle_explorer, thor)
    widgets.command_palette_add(p, "View: Toggle Console", thor_cmd_toggle_console, thor)
    widgets.command_palette_add(p, "View: Zoom In", thor_cmd_zoom_in, thor)
    widgets.command_palette_add(p, "View: Zoom Out", thor_cmd_zoom_out, thor)
    widgets.command_palette_add(p, "View: Reset Zoom", thor_cmd_zoom_reset, thor)
    widgets.command_palette_add(p, "View: Toggle Maximize", thor_cmd_toggle_maximize, thor)
    widgets.command_palette_add(p, "View: Toggle Fullscreen", thor_cmd_toggle_fullscreen, thor)

    widgets.command_palette_add(p, "File: Save", thor_cmd_save, thor)
    widgets.command_palette_add(p, "File: Close Tab", thor_cmd_close_tab, thor)
    widgets.command_palette_add(p, "File: Close All Tabs", thor_cmd_close_all, thor)
    widgets.command_palette_add(p, "File: Next Tab", thor_cmd_next_tab, thor)
    widgets.command_palette_add(p, "File: Previous Tab", thor_cmd_prev_tab, thor)

    // Data is the palette itself: these switch it into another input mode.
    widgets.command_palette_add(p, "Go to File", widgets.command_palette_goto_file_command, p)
    widgets.command_palette_add(p, "Go to Line", widgets.command_palette_goto_line_command, p)

    widgets.command_palette_add(p, "Edit: Toggle Line Comment", thor_cmd_toggle_comment, thor)
    widgets.command_palette_add(p, "Settings: Open Keybinds", thor_cmd_open_keybinds, thor)
    widgets.command_palette_add(p, "Settings: Open Comments", thor_cmd_open_comments, thor)
    widgets.command_palette_add(p, "Settings: Open General Settings", thor_cmd_open_settings, thor)
    widgets.command_palette_add(p, "Settings: Reload", thor_cmd_reload_settings, thor)
}

// --- command handlers (proc(data: rawptr), data = ^Thor) -------------------

thor_cmd_toggle_explorer :: proc(data: rawptr) {thor_toggle_explorer(data, nil, nil)}
thor_cmd_toggle_console :: proc(data: rawptr) {thor_toggle_console(data, nil, nil)}
thor_cmd_toggle_maximize :: proc(data: rawptr) {thor_toggle_maximize(data, nil, nil)}
thor_cmd_toggle_fullscreen :: proc(data: rawptr) {thor_toggle_fullscreen(cast(^Thor) data)}
thor_cmd_save :: proc(data: rawptr) {thor_request_save(data)}

thor_cmd_zoom_in :: proc(data: rawptr) {widgets.editor_zoom((cast(^Thor) data).editor, 1)}
thor_cmd_zoom_out :: proc(data: rawptr) {widgets.editor_zoom((cast(^Thor) data).editor, -1)}

thor_cmd_zoom_reset :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.editor_set_font_size(thor.editor, cast(i32) settings.font_size(&thor.config))
}

thor_cmd_close_tab :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_close_file(thor, ui.signal_get(&thor.active_file))
}

thor_cmd_close_all :: proc(data: rawptr) {
    thor := cast(^Thor) data
    for len(thor.open_files) > 0 {
        thor_close_file(thor, 0)
    }
}

thor_cmd_next_tab :: proc(data: rawptr) {thor_cycle_tab(cast(^Thor) data, 1)}
thor_cmd_prev_tab :: proc(data: rawptr) {thor_cycle_tab(cast(^Thor) data, -1)}

thor_cmd_toggle_comment :: proc(data: rawptr) {
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    if prefix := settings.comment_prefix(&thor.config, file.name); prefix != "" {
        textedit.toggle_comment(&file.state, prefix)
    }
}

thor_cmd_open_keybinds :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "settings/keybinds.json")}
thor_cmd_open_comments :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "settings/comments.json")}
thor_cmd_open_settings :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "settings/settings.json")}
thor_cmd_reload_settings :: proc(data: rawptr) {thor_reload_settings(cast(^Thor) data)}

// --- palette navigation callbacks ------------------------------------------

thor_palette_list_files :: proc(data: rawptr) -> []string {
    thor := cast(^Thor) data
    files := make([dynamic]string, context.temp_allocator)
    thor_collect_files(thor.workspace_dir, &files, 0)
    return files[:]
}

// Recursively gathers file paths under dir (skipping .git), capped so a huge
// tree can't stall the palette.
@(private = "file")
thor_collect_files :: proc(dir: string, files: ^[dynamic]string, depth: int) {
    if len(files) >= 4000 || depth > 12 {
        return
    }

    handle, open_err := os.open(dir)
    if open_err != nil {
        return
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }

    for info in infos {
        if info.name == ".git" {
            continue
        }
        if info.type == .Directory {
            thor_collect_files(info.fullpath, files, depth + 1)
        } else {
            append(files, info.fullpath)
        }
    }
}

thor_palette_open_file :: proc(data: rawptr, path: string) {
    thor_open_file(cast(^Thor) data, path)
}

thor_palette_goto_line :: proc(data: rawptr, line: int) {
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    txt := textedit.text(&file.state)
    pos := textedit.line_start_of_index(txt, line - 1)
    textedit.set_single_cursor(&file.state, pos)
    widgets.editor_scroll_to_caret(thor.editor)
}
