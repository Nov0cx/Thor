package thor

import "core:log"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../setting"
import "../textedit"
import "../ui"
import "../widgets"

// Applies the configurable settings to the live widgets. Called at startup and
// on reload, so both paths stay in sync.
thor_apply_settings :: proc(thor: ^Thor) {
    if kb, ok := setting.keybind(&thor.config, "toggle_line_comment"); ok {
        thor.editor.comment_keybind = kb
    }
    if kb, ok := setting.keybind(&thor.config, "command_palette"); ok {
        thor.command_palette_key = kb
    } else {
        thor.command_palette_key = setting.Keybind {key = .PERIOD, ctrl = true}
    }
    if kb, ok := setting.keybind(&thor.config, "quick_open"); ok {
        thor.quick_open_key = kb
    } else {
        thor.quick_open_key = setting.Keybind {key = .TAB, ctrl = true}
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
    if kb, ok := setting.keybind(&thor.config, "focus_editor"); ok {
        thor.focus_editor_key = kb
    } else {
        thor.focus_editor_key = setting.Keybind {key = .E, ctrl = true, shift = true}
    }
    if kb, ok := setting.keybind(&thor.config, "focus_explorer"); ok {
        thor.focus_explorer_key = kb
    } else {
        thor.focus_explorer_key = setting.Keybind {key = .B, ctrl = true, shift = true}
    }
    if kb, ok := setting.keybind(&thor.config, "focus_terminal"); ok {
        thor.focus_terminal_key = kb
    } else {
        thor.focus_terminal_key = setting.Keybind {key = .T, ctrl = true, shift = true}
    }
    if kb, ok := setting.keybind(&thor.config, "trim_trailing_whitespace"); ok {
        thor.trim_whitespace_key = kb
    } else {
        thor.trim_whitespace_key = setting.Keybind {key = .W, ctrl = true, shift = true}
    }
    if kb, ok := setting.keybind(&thor.config, "align_at_char"); ok {
        thor.align_char_key = kb
    } else {
        thor.align_char_key = setting.Keybind {key = .A, ctrl = true, shift = true}
    }
    if kb, ok := setting.keybind(&thor.config, "goto_line"); ok {
        thor.goto_line_key = kb
    } else {
        thor.goto_line_key = setting.Keybind {key = .G, ctrl = true}
    }
    if kb, ok := setting.keybind(&thor.config, "goto_definition"); ok {
        thor.goto_def_key = kb
    } else {
        thor.goto_def_key = setting.Keybind {key = .ENTER, alt = true}
    }
    if kb, ok := setting.keybind(&thor.config, "goto_symbol"); ok {
        thor.goto_symbol_key = kb
    } else {
        thor.goto_symbol_key = setting.Keybind {key = .O, ctrl = true, shift = true}
    }
    if kb, ok := setting.keybind(&thor.config, "goto_workspace_symbol"); ok {
        thor.goto_workspace_symbol_key = kb
    } else {
        thor.goto_workspace_symbol_key = setting.Keybind {key = .T, ctrl = true}
    }
    if kb, ok := setting.keybind(&thor.config, "find_references"); ok {
        thor.find_references_key = kb
    } else {
        thor.find_references_key = setting.Keybind {key = .F10}
    }
    if kb, ok := setting.keybind(&thor.config, "signature_help"); ok {
        thor.signature_help_key = kb
    } else {
        thor.signature_help_key = setting.Keybind {key = .SPACE, ctrl = true, shift = true}
    }
    if kb, ok := setting.keybind(&thor.config, "last_file"); ok {
        thor.last_file_key = kb
    } else {
        thor.last_file_key = setting.Keybind {key = .E, ctrl = true}
    }
    if kb, ok := setting.keybind(&thor.config, "toggle_split"); ok {
        thor.split_key = kb
    } else {
        thor.split_key = setting.Keybind {}
    }

    // Resolve each bindable app command's chord from config; an absent or empty
    // entry leaves it unbound (KEY_NULL), so it stays key-less until the user sets one.
    for &bind in thor.app_binds {
        if kb, ok := setting.keybind(&thor.config, bind.action); ok {
            bind.key = kb
        } else {
            bind.key = setting.Keybind {}
        }
    }

    widgets.editor_set_font_size(thor.editor, cast(i32) setting.font_size(&thor.config))
    widgets.editor_set_font_size(thor.editor2, cast(i32) setting.font_size(&thor.config))
    textedit.set_tab_width(setting.tab_width(&thor.config))
}

thor_reload_settings :: proc(thor: ^Thor) {
    setting.destroy(&thor.config)
    thor_load_config(thor, thor.workspace_dir)
    thor_apply_settings(thor)
}

// Directory holding a workspace's config, i.e. <workspace>/.thor.
thor_workspace_config_dir :: proc(workspace_dir: string, allocator := context.temp_allocator) -> string {
    return strings.concatenate({workspace_dir, "/.thor"}, allocator)
}

// Loads the global settings/ config, then overlays the workspace's .thor/ config
// when initialized (recorded in workspace_initialized). Shared by startup and reload.
thor_load_config :: proc(thor: ^Thor, workspace_dir: string) {
    thor.config = setting.load("settings")
    cfg_dir := thor_workspace_config_dir(workspace_dir)
    thor.workspace_initialized = os.is_dir(cfg_dir)
    if thor.workspace_initialized {
        setting.load_overlay(&thor.config, cfg_dir)
    }
}

// Starter contents for a new .thor/settings.json: the current defaults, so the
// file is a ready-to-edit template.
@(private = "file")
WORKSPACE_SETTINGS_TEMPLATE :: "{\n    \"tab_width\": 4,\n    \"font_size\": 18,\n    \"autosave_delay_ms\": 1500\n}\n"

// Promotes the current folder to a workspace: creates <workspace>/.thor/ with a
// starter settings.json and reloads so the overlay applies immediately.
thor_cmd_init_workspace :: proc(data: rawptr) {
    thor := cast(^Thor) data
    cfg_dir := thor_workspace_config_dir(thor.workspace_dir)
    if !os.is_dir(cfg_dir) {
        if err := os.make_directory(cfg_dir); err != nil {
            log.errorf("Could not create workspace dir %q: %v", cfg_dir, err)
            return
        }
    }
    settings_path := strings.concatenate({cfg_dir, "/settings.json"}, context.temp_allocator)
    if !os.exists(settings_path) {
        if err := os.write_entire_file(settings_path, transmute([]u8) string(WORKSPACE_SETTINGS_TEMPLATE)); err != nil {
            log.errorf("Could not write %q: %v", settings_path, err)
        }
    }
    thor_reload_settings(thor)
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

// Quick-open: jumps straight into the palette's file search.
thor_quick_open :: proc(thor: ^Thor) {
    widgets.command_palette_open_files(thor.command_palette, &thor.ui_context)
}

// Chord label for a keybind action; "" when unbound (no shortcut shown).
@(private = "file")
thor_action_shortcut :: proc(thor: ^Thor, action: string) -> string {
    if kb, ok := setting.keybind(&thor.config, action); ok {
        return setting.keybind_to_string(kb, context.temp_allocator)
    }
    return ""
}

// A palette command that is also globally keybindable by its config action
// name. Only commands with no editor-local key belong here (see app_binds).
App_Bind :: struct {
    action: string, // config key; borrowed static literal
    key:    setting.Keybind,
    run:    proc(data: rawptr),
    data:   rawptr,
}

// Registers a palette command that can also be bound to a key. `action` is the
// keybinds.json name (shipped empty, so unbound until the user sets a chord).
@(private = "file")
thor_add_bindable_command :: proc(thor: ^Thor, title, action: string, run: proc(data: rawptr), data: rawptr) {
    widgets.command_palette_add(thor.command_palette, title, run, data, thor_action_shortcut(thor, action))
    append(&thor.app_binds, App_Bind {action = action, run = run, data = data})
}

// Runs the app command bound to this chord, if any. Called from thor_global_key
// after the built-in binds, so a user-set chord invokes an otherwise key-less
// command. Unbound entries (KEY_NULL) never match a real press.
thor_dispatch_app_bind :: proc(thor: ^Thor, event: ^ui.Event) -> bool {
    for bind in thor.app_binds {
        if bind.key.key != .KEY_NULL &&
           setting.keybind_matches(bind.key, event.key, event.ctrl, event.shift, event.alt) {
            if bind.run != nil {
                bind.run(bind.data)
            }
            return true
        }
    }
    return false
}

// Registers every palette command. Titles use a "Category: Action" convention
// so fuzzy search on the category works too.
thor_register_commands :: proc(thor: ^Thor) {
    p := thor.command_palette
    sc :: thor_action_shortcut

    widgets.command_palette_add(p, "View: Toggle Explorer", thor_cmd_toggle_explorer, thor, sc(thor, "toggle_explorer"))
    widgets.command_palette_add(p, "View: Toggle Console", thor_cmd_toggle_console, thor, sc(thor, "toggle_console"))
    widgets.command_palette_add(p, "View: Zoom In", thor_cmd_zoom_in, thor, sc(thor, "zoom_in"))
    widgets.command_palette_add(p, "View: Zoom Out", thor_cmd_zoom_out, thor, sc(thor, "zoom_out"))
    thor_add_bindable_command(thor, "View: Reset Zoom", "reset_zoom", thor_cmd_zoom_reset, thor)
    thor_add_bindable_command(thor, "View: Toggle Maximize", "toggle_maximize", thor_cmd_toggle_maximize, thor)
    widgets.command_palette_add(p, "View: Toggle Fullscreen", thor_cmd_toggle_fullscreen, thor, sc(thor, "toggle_fullscreen"))
    thor_add_bindable_command(thor, "View: Toggle Word Wrap", "toggle_word_wrap", thor_cmd_toggle_wrap, thor)
    widgets.command_palette_add(p, "View: Toggle Split Editor", thor_cmd_toggle_split, thor, sc(thor, "toggle_split"))
    widgets.command_palette_add(p, "View: Recenter", thor_cmd_recenter, thor, sc(thor, "recenter"))

    thor_add_bindable_command(thor, "File: New File", "new_file", thor_cmd_new_file, thor)
    thor_add_bindable_command(thor, "File: New Folder", "new_folder", thor_cmd_new_folder, thor)
    widgets.command_palette_add(p, "File: Save", thor_cmd_save, thor, sc(thor, "save"))
    thor_add_bindable_command(thor, "File: Save All", "save_all", thor_cmd_save_all, thor)
    thor_add_bindable_command(thor, "File: Rename File", "rename_file", thor_cmd_rename_file, thor)
    widgets.command_palette_add(p, "File: Close Tab", thor_cmd_close_tab, thor, sc(thor, "close_tab"))
    thor_add_bindable_command(thor, "File: Close All Tabs", "close_all_tabs", thor_cmd_close_all, thor)
    widgets.command_palette_add(p, "File: Next Tab", thor_cmd_next_tab, thor, sc(thor, "next_tab"))
    widgets.command_palette_add(p, "File: Previous Tab", thor_cmd_prev_tab, thor, sc(thor, "previous_tab"))
    widgets.command_palette_add(p, "File: Switch to Last File", thor_cmd_last_file, thor, sc(thor, "last_file"))
    thor_add_bindable_command(thor, "File: Copy Path", "copy_path", thor_cmd_copy_path, thor)
    thor_add_bindable_command(thor, "File: Reveal in File Explorer", "reveal_in_explorer", thor_cmd_reveal, thor)

    // Data is the palette itself: these switch it into another input mode.
    widgets.command_palette_add(p, "Go to File", widgets.command_palette_goto_file_command, p, sc(thor, "quick_open"))
    widgets.command_palette_add(p, "Go to Line", widgets.command_palette_goto_line_command, p, sc(thor, "goto_line"))

    widgets.command_palette_add(p, "Find", thor_cmd_find, thor, sc(thor, "find"))
    widgets.command_palette_add(p, "Replace", thor_cmd_replace, thor, sc(thor, "replace"))

    widgets.command_palette_add(p, "Edit: Toggle Line Comment", thor_cmd_toggle_comment, thor, sc(thor, "toggle_line_comment"))
    widgets.command_palette_add(p, "Edit: Select All", thor_cmd_select_all, thor, sc(thor, "select_all"))
    widgets.command_palette_add(p, "Edit: Duplicate Line", thor_cmd_duplicate_line, thor, sc(thor, "duplicate_line_down"))
    widgets.command_palette_add(p, "Edit: Delete Line", thor_cmd_delete_line, thor, sc(thor, "delete_line"))
    widgets.command_palette_add(p, "Edit: Join Lines", thor_cmd_join_lines, thor, sc(thor, "join_lines"))
    widgets.command_palette_add(p, "Edit: Move Line Up", thor_cmd_move_line_up, thor, sc(thor, "move_line_up"))
    widgets.command_palette_add(p, "Edit: Move Line Down", thor_cmd_move_line_down, thor, sc(thor, "move_line_down"))
    widgets.command_palette_add(p, "Edit: Uppercase", thor_cmd_uppercase, thor, sc(thor, "uppercase"))
    widgets.command_palette_add(p, "Edit: Lowercase", thor_cmd_lowercase, thor, sc(thor, "lowercase"))
    widgets.command_palette_add(p, "Edit: Capitalize", thor_cmd_capitalize, thor, sc(thor, "capitalize"))
    widgets.command_palette_add(p, "Edit: Trim Trailing Whitespace", thor_cmd_trim_whitespace, thor, sc(thor, "trim_trailing_whitespace"))
    widgets.command_palette_add(p, "Edit: Align at Character", thor_cmd_align_at_char, thor, sc(thor, "align_at_char"))

    widgets.command_palette_add(p, "Selection: Add Cursor Above", thor_cmd_add_cursor_above, thor, sc(thor, "add_cursor_above"))
    widgets.command_palette_add(p, "Selection: Add Cursor Below", thor_cmd_add_cursor_below, thor, sc(thor, "add_cursor_below"))
    widgets.command_palette_add(p, "Go to Matching Bracket", thor_cmd_matching_bracket, thor, sc(thor, "matching_bracket"))
    widgets.command_palette_add(p, "Go to Symbol in File", thor_cmd_goto_symbol, thor, sc(thor, "goto_symbol"))
    widgets.command_palette_add(p, "Go to Symbol in Workspace", thor_cmd_goto_workspace_symbol, thor, sc(thor, "goto_workspace_symbol"))
    widgets.command_palette_add(p, "Find All References", thor_cmd_find_references, thor, sc(thor, "find_references"))
    widgets.command_palette_add(p, "Signature Help", thor_cmd_signature_help, thor, sc(thor, "signature_help"))

    thor_add_bindable_command(thor, "Fold: Toggle Fold", "toggle_fold", thor_cmd_toggle_fold, thor)
    thor_add_bindable_command(thor, "Fold: Fold All", "fold_all", thor_cmd_fold_all, thor)
    thor_add_bindable_command(thor, "Fold: Unfold All", "unfold_all", thor_cmd_unfold_all, thor)

    thor_add_bindable_command(thor, "Help: Tutorial", "tutorial", thor_cmd_tutorial, thor)
    thor_add_bindable_command(thor, "Settings: Open Keybinds", "open_keybinds", thor_cmd_open_keybinds, thor)
    thor_add_bindable_command(thor, "Settings: Open Comments", "open_comments", thor_cmd_open_comments, thor)
    thor_add_bindable_command(thor, "Settings: Open General Settings", "open_settings", thor_cmd_open_settings, thor)
    thor_add_bindable_command(thor, "Settings: Add Font", "add_font", thor_cmd_add_font, thor)
    thor_add_bindable_command(thor, "Settings: Reload", "reload_settings", thor_cmd_reload_settings, thor)
    thor_add_bindable_command(thor, "Workspace: Initialize", "init_workspace", thor_cmd_init_workspace, thor)
    thor_add_bindable_command(thor, "Preferences: New Theme", "new_theme", thor_cmd_new_theme, thor)
    thor_add_bindable_command(thor, "Preferences: Change Theme", "change_theme", thor_cmd_change_theme, thor)
    thor_add_bindable_command(thor, "Preferences: Change Font", "change_font", thor_cmd_change_font, thor)
}

thor_cmd_toggle_explorer :: proc(data: rawptr) {thor_toggle_explorer(data, nil, nil)}
thor_cmd_toggle_console :: proc(data: rawptr) {thor_toggle_console(data, nil, nil)}
thor_cmd_toggle_maximize :: proc(data: rawptr) {thor_toggle_maximize(data, nil, nil)}
thor_cmd_toggle_fullscreen :: proc(data: rawptr) {thor_toggle_fullscreen(cast(^Thor) data)}
thor_cmd_toggle_wrap :: proc(data: rawptr) {widgets.editor_toggle_wrap((cast(^Thor) data).editor)}
thor_cmd_toggle_split :: proc(data: rawptr) {thor_toggle_split(cast(^Thor) data)}
thor_cmd_find :: proc(data: rawptr) {thor_open_find(cast(^Thor) data, false)}
thor_cmd_replace :: proc(data: rawptr) {thor_open_find(cast(^Thor) data, true)}
thor_cmd_save :: proc(data: rawptr) {thor_request_save(data)}

// Zoom commands drive both panes so a command-triggered zoom keeps the split in
// sync (ctrl+scroll still zooms only the hovered pane).
thor_cmd_zoom_in :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.editor_zoom(thor.editor, 1)
    widgets.editor_zoom(thor.editor2, 1)
}
thor_cmd_zoom_out :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.editor_zoom(thor.editor, -1)
    widgets.editor_zoom(thor.editor2, -1)
}

thor_cmd_zoom_reset :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.editor_set_font_size(thor.editor, cast(i32) setting.font_size(&thor.config))
    widgets.editor_set_font_size(thor.editor2, cast(i32) setting.font_size(&thor.config))
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
thor_cmd_goto_symbol :: proc(data: rawptr) {thor_goto_symbol(cast(^Thor) data)}
thor_cmd_goto_workspace_symbol :: proc(data: rawptr) {thor_goto_workspace_symbol(cast(^Thor) data)}
thor_cmd_find_references :: proc(data: rawptr) {thor_find_references(cast(^Thor) data)}
thor_cmd_signature_help :: proc(data: rawptr) {thor_signature_help(cast(^Thor) data)}
thor_cmd_join_lines :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.join_lines(s)}}
thor_cmd_uppercase :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.transform_case(s, .Upper)}}
thor_cmd_lowercase :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.transform_case(s, .Lower)}}
thor_cmd_capitalize :: proc(data: rawptr) {if s := thor_edit_state(data); s != nil {textedit.transform_case(s, .Title)}}
// Prompts for a character, then aligns the first occurrence of it on each
// selected line into the same column (e.g. line up a block of `=` assignments).
thor_cmd_align_at_char :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.command_palette_prompt(thor.command_palette, &thor.ui_context, "Align on character", thor_prompt_align_at_char, thor)
}

thor_prompt_align_at_char :: proc(data: rawptr, text: string) {
    if text == "" {
        return
    }
    target, _ := utf8.decode_rune_in_string(text)
    if s := thor_edit_state(data); s != nil {
        textedit.align_at_char(s, target)
    }
}

// Folding acts on the focused pane's editor (the one whose fold state the user
// sees), unlike zoom which drives both panes.
@(private = "file")
thor_focused_editor :: proc(thor: ^Thor) -> ^widgets.Editor {
    return thor.active_pane == 0 ? thor.editor : thor.editor2
}

thor_cmd_toggle_fold :: proc(data: rawptr) {widgets.editor_toggle_fold(thor_focused_editor(cast(^Thor) data))}
thor_cmd_fold_all :: proc(data: rawptr) {widgets.editor_fold_all(thor_focused_editor(cast(^Thor) data))}
thor_cmd_unfold_all :: proc(data: rawptr) {widgets.editor_unfold_all(thor_focused_editor(cast(^Thor) data))}

thor_cmd_recenter :: proc(data: rawptr) {widgets.editor_recenter((cast(^Thor) data).editor)}
thor_cmd_last_file :: proc(data: rawptr) {thor_flip_last_file(cast(^Thor) data)}

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
    thor_reveal_path(file.path)
}

// Opens the OS file explorer with `path` selected.
thor_reveal_path :: proc(path: string) {
    if path == "" {
        return
    }
    native, _ := strings.replace_all(path, "/", "\\", context.temp_allocator)
    param := strings.concatenate({"/select,", native}, context.temp_allocator)
    win32.ShellExecuteW(nil, win32.utf8_to_wstring("open"), win32.utf8_to_wstring("explorer.exe"), win32.utf8_to_wstring(param), nil, win32.SW_SHOWNORMAL)
}

thor_cmd_command_palette :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.command_palette_open(thor.command_palette, &thor.ui_context)
}

thor_cmd_add_font :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "assets/fonts/fonts.json")}

@(private = "file")
EMPTY_THEME :: 
`{
    "name": "",
    "colors": {
        "Background": "",
        "Foreground": "",
        "Text": "",
        "Selection Background": "",
        "Selection Foreground": "",
        "Buttons": "",
        "Second Background": "",
        "Disabled": "",
        "Contrast": "",
        "Active": "",
        "Border": "",
        "Highlight": "",
        "Tree": "",
        "Notifications": "",
        "Accent Color": "",
        "Excluded Files Color": "",
        "Green Color": "",
        "Yellow Color": "",
        "Blue Color": "",
        "Red Color": "",
        "Purple Color": "",
        "Orange Color": "",
        "Cyan Color": "",
        "Gray Color": "",
        "White/Black Color": "",
        "Error Color": "",
        "Comments Color": "",
        "Variables Color": "",
        "Links Color": "",
        "Functions Color": "",
        "Keywords Color": "",
        "Tags Color": "",
        "Strings Color": "",
        "Operators Color": "",
        "Attributes Color": "",
        "Numbers Color": "",
        "Parameters Color": ""
    }
}`

thor_cmd_new_theme :: proc(data: rawptr) {
    dst :: "assets/themes/custom.json"
    if !os.exists(dst) {
        _ = os.write_entire_file(dst, EMPTY_THEME)
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
