package thor

import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import rl "vendor:raylib"

import "../setting"
import "../textedit"
import "../ui"
import "../widgets"

// Applies the configurable parts of the loaded settings to the live widgets.
// Called at startup and whenever settings are reloaded, so both paths stay in
// sync.
thor_apply_settings :: proc(thor: ^Thor) {
    if kb, ok := setting.keybind(&thor.config, "toggle_line_comment"); ok {
        thor.editor.comment_keybind = kb
    }
    if kb, ok := setting.keybind(&thor.config, "command_palette"); ok {
        thor.command_palette_key = kb
    } else {
        thor.command_palette_key = setting.Keybind {key = .PERIOD, ctrl = true}
    }
    if kb, ok := setting.keybind(&thor.config, "toggle_fullscreen"); ok {
        thor.fullscreen_key = kb
    } else {
        thor.fullscreen_key = setting.Keybind {key = .F12}
    }
    if kb, ok := setting.keybind(&thor.config, "toggle_console"); ok {
        thor.console_toggle_key = kb
    } else {
        thor.console_toggle_key = setting.Keybind {key = .T, ctrl = true}
    }
    if kb, ok := setting.keybind(&thor.config, "find"); ok {
        thor.find_key = kb
    } else {
        thor.find_key = setting.Keybind {key = .F, ctrl = true}
    }
    if kb, ok := setting.keybind(&thor.config, "replace"); ok {
        thor.replace_key = kb
    } else {
        thor.replace_key = setting.Keybind {key = .R, ctrl = true}
    }

    widgets.editor_set_font_size(thor.editor, cast(i32) setting.font_size(&thor.config))
    textedit.set_tab_width(setting.tab_width(&thor.config))
}

thor_reload_settings :: proc(thor: ^Thor) {
    setting.destroy(&thor.config)
    thor.config = setting.load("settings")
    thor_apply_settings(thor)
}

thor_open_find :: proc(thor: ^Thor, show_replace: bool) {
    widgets.find_replace_open(thor.find_replace, &thor.ui_context, thor.editor, show_replace)
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
    widgets.command_palette_add(p, "View: Toggle Word Wrap", thor_cmd_toggle_wrap, thor)

    widgets.command_palette_add(p, "File: Save", thor_cmd_save, thor)
    widgets.command_palette_add(p, "File: Save All", thor_cmd_save_all, thor)
    widgets.command_palette_add(p, "File: Close Tab", thor_cmd_close_tab, thor)
    widgets.command_palette_add(p, "File: Close All Tabs", thor_cmd_close_all, thor)
    widgets.command_palette_add(p, "File: Next Tab", thor_cmd_next_tab, thor)
    widgets.command_palette_add(p, "File: Previous Tab", thor_cmd_prev_tab, thor)
    widgets.command_palette_add(p, "File: Copy Path", thor_cmd_copy_path, thor)
    widgets.command_palette_add(p, "File: Reveal in File Explorer", thor_cmd_reveal, thor)

    // Data is the palette itself: these switch it into another input mode.
    widgets.command_palette_add(p, "Go to File", widgets.command_palette_goto_file_command, p)
    widgets.command_palette_add(p, "Go to Line", widgets.command_palette_goto_line_command, p)

    widgets.command_palette_add(p, "Find", thor_cmd_find, thor)
    widgets.command_palette_add(p, "Replace", thor_cmd_replace, thor)

    widgets.command_palette_add(p, "Edit: Toggle Line Comment", thor_cmd_toggle_comment, thor)
    widgets.command_palette_add(p, "Edit: Select All", thor_cmd_select_all, thor)
    widgets.command_palette_add(p, "Edit: Duplicate Line", thor_cmd_duplicate_line, thor)
    widgets.command_palette_add(p, "Edit: Delete Line", thor_cmd_delete_line, thor)
    widgets.command_palette_add(p, "Edit: Move Line Up", thor_cmd_move_line_up, thor)
    widgets.command_palette_add(p, "Edit: Move Line Down", thor_cmd_move_line_down, thor)
    widgets.command_palette_add(p, "Edit: Trim Trailing Whitespace", thor_cmd_trim_whitespace, thor)

    widgets.command_palette_add(p, "Selection: Add Cursor Above", thor_cmd_add_cursor_above, thor)
    widgets.command_palette_add(p, "Selection: Add Cursor Below", thor_cmd_add_cursor_below, thor)
    widgets.command_palette_add(p, "Go to Matching Bracket", thor_cmd_matching_bracket, thor)

    widgets.command_palette_add(p, "Settings: Open Keybinds", thor_cmd_open_keybinds, thor)
    widgets.command_palette_add(p, "Settings: Open Comments", thor_cmd_open_comments, thor)
    widgets.command_palette_add(p, "Settings: Open General Settings", thor_cmd_open_settings, thor)
    widgets.command_palette_add(p, "Settings: Add Font", thor_cmd_add_font, thor)
    widgets.command_palette_add(p, "Settings: Reload", thor_cmd_reload_settings, thor)
    widgets.command_palette_add(p, "Preferences: New Theme", thor_cmd_new_theme, thor)
}

thor_cmd_toggle_explorer :: proc(data: rawptr) {thor_toggle_explorer(data, nil, nil)}
thor_cmd_toggle_console :: proc(data: rawptr) {thor_toggle_console(data, nil, nil)}
thor_cmd_toggle_maximize :: proc(data: rawptr) {thor_toggle_maximize(data, nil, nil)}
thor_cmd_toggle_fullscreen :: proc(data: rawptr) {thor_toggle_fullscreen(cast(^Thor) data)}
thor_cmd_toggle_wrap :: proc(data: rawptr) {widgets.editor_toggle_wrap((cast(^Thor) data).editor)}
thor_cmd_find :: proc(data: rawptr) {thor_open_find(cast(^Thor) data, false)}
thor_cmd_replace :: proc(data: rawptr) {thor_open_find(cast(^Thor) data, true)}
thor_cmd_save :: proc(data: rawptr) {thor_request_save(data)}

thor_cmd_zoom_in :: proc(data: rawptr) {widgets.editor_zoom((cast(^Thor) data).editor, 1)}
thor_cmd_zoom_out :: proc(data: rawptr) {widgets.editor_zoom((cast(^Thor) data).editor, -1)}

thor_cmd_zoom_reset :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.editor_set_font_size(thor.editor, cast(i32) setting.font_size(&thor.config))
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
    if prefix := setting.comment_prefix(&thor.config, file.name); prefix != "" {
        textedit.toggle_comment(&file.state, prefix)
    }
}

// Editor commands operate on the active file's buffer; they no-op when no file
// is focused so the palette entries are always safe to invoke.
@(private = "file")
thor_edit_state :: proc(data: rawptr) -> ^textedit.State {
    file := thor_active_open_file(cast(^Thor) data)
    if file == nil || !file.loaded {
        return nil
    }
    return &file.state
}

thor_cmd_select_all :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.select_all(s)}}
thor_cmd_duplicate_line :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.duplicate_lines(s, 1)}}
thor_cmd_delete_line :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.delete_lines(s)}}
thor_cmd_move_line_up :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.move_lines(s, -1)}}
thor_cmd_move_line_down :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.move_lines(s, 1)}}
thor_cmd_trim_whitespace :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.trim_trailing_whitespace(s)}}
thor_cmd_add_cursor_above :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.add_cursor_vertical(s, -1)}}
thor_cmd_add_cursor_below :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.add_cursor_vertical(s, 1)}}
thor_cmd_matching_bracket :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.move_to_matching_bracket(s, false)}}

thor_cmd_save_all :: proc(data: rawptr) {
    thor := cast(^Thor) data
    for file in thor.open_files {
        thor_save_file(thor, file)
    }
}

thor_cmd_copy_path :: proc(data: rawptr) {
    file := thor_active_open_file(cast(^Thor) data)
    if file == nil {
        return
    }
    rl.SetClipboardText(strings.clone_to_cstring(file.path, context.temp_allocator))
}

thor_cmd_reveal :: proc(data: rawptr) {
    file := thor_active_open_file(cast(^Thor) data)
    if file == nil {
        return
    }
    native, _ := strings.replace_all(file.path, "/", "\\", context.temp_allocator)
    param := strings.concatenate({"/select,", native}, context.temp_allocator)
    win32.ShellExecuteW(nil, win32.utf8_to_wstring("open"), win32.utf8_to_wstring("explorer.exe"), win32.utf8_to_wstring(param), nil, win32.SW_SHOWNORMAL)
}

thor_cmd_add_font :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "assets/fonts/fonts.json")}

// Seeds a new theme file from the default palette (once) and opens it to edit.
thor_cmd_new_theme :: proc(data: rawptr) {
    dst :: "assets/themes/custom.json"
    if !os.exists(dst) {
        if src, rerr := os.read_entire_file_from_path("assets/themes/material-deep-ocean.json", context.temp_allocator); rerr == nil {
            _ = os.write_entire_file(dst, src)
        }
    }
    thor_open_file(cast(^Thor) data, dst)
}

thor_cmd_open_keybinds :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "settings/keybinds.json")}
thor_cmd_open_comments :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "settings/comments.json")}
thor_cmd_open_settings :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "settings/settings.json")}
thor_cmd_reload_settings :: proc(data: rawptr) {thor_reload_settings(cast(^Thor) data)}

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
