package thor

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
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
    if kb, ok := setting.keybind(&thor.config, "format_document"); ok {
        thor.format_key = kb
    } else {
        thor.format_key = setting.Keybind {key = .L, ctrl = true, alt = true}
    }
    if kb, ok := setting.keybind(&thor.config, "format_selection"); ok {
        thor.format_selection_key = kb
    } else {
        thor.format_selection_key = setting.Keybind {key = .L, ctrl = true, alt = true, shift = true}
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
        thor.goto_workspace_symbol_key = setting.Keybind {key = .Q, ctrl = true}
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
    if kb, ok := setting.keybind(&thor.config, "package_doc"); ok {
        thor.package_doc_key = kb
    } else {
        thor.package_doc_key = setting.Keybind {key = .F3}
    }
    if kb, ok := setting.keybind(&thor.config, "code_actions"); ok {
        thor.code_actions_key = kb
    } else {
        thor.code_actions_key = setting.Keybind {key = .U, ctrl = true, shift = true}
    }
    // Ctrl+Alt+Left/Right, not the browsers' plain Alt+Left/Right: those two are
    // already line_start / line_end.
    if kb, ok := setting.keybind(&thor.config, "jump_back"); ok {
        thor.jump_back_key = kb
    } else {
        thor.jump_back_key = setting.Keybind {key = .LEFT, ctrl = true, alt = true}
    }
    if kb, ok := setting.keybind(&thor.config, "jump_forward"); ok {
        thor.jump_forward_key = kb
    } else {
        thor.jump_forward_key = setting.Keybind {key = .RIGHT, ctrl = true, alt = true}
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
    if kb, ok := setting.keybind(&thor.config, "close_tab"); ok {
        thor.close_tab_key = kb
    } else {
        thor.close_tab_key = setting.Keybind {key = .W, ctrl = true}
    }
    if kb, ok := setting.keybind(&thor.config, "next_tab"); ok {
        thor.next_tab_key = kb
    } else {
        thor.next_tab_key = setting.Keybind {key = .PAGE_DOWN, ctrl = true}
    }
    if kb, ok := setting.keybind(&thor.config, "previous_tab"); ok {
        thor.previous_tab_key = kb
    } else {
        thor.previous_tab_key = setting.Keybind {key = .PAGE_UP, ctrl = true}
    }
    if kb, ok := setting.keybind(&thor.config, "toggle_explorer"); ok {
        thor.toggle_explorer_key = kb
    } else {
        thor.toggle_explorer_key = setting.Keybind {key = .B, ctrl = true}
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
    textedit.set_default_tab_width(setting.tab_width(&thor.config))
    ui.shape_set_tab_width(setting.tab_width(&thor.config))
    ui.shape_set_ligatures(setting.ligatures(&thor.config))
    thor_apply_language_settings(thor)
}

// Reloads the config from disk and re-applies it live: keybinds, sizes, the
// workspace tasks, and — when their setting changed — the active theme and text
// font. Also rebaselines
// the auto-reload watcher and refreshes the Settings modal if it is open. Shared
// by the reload command, the Settings modal, and the file-change poll loop.
thor_reload_settings :: proc(thor: ^Thor) {
    old_theme := strings.clone(thor.config.general.theme, context.temp_allocator)
    old_font := strings.clone(thor.config.general.font, context.temp_allocator)
    old_icon_pack := strings.clone(thor.config.general.icon_pack, context.temp_allocator)
    old_file_icon_pack := strings.clone(thor.config.general.file_icon_pack, context.temp_allocator)

    setting.destroy(&thor.config)
    thor_load_config(thor, thor.workspace_dir)

    if thor.config.general.theme != old_theme {
        thor_load_active_theme(thor)
        thor_apply_theme(thor)
    }
    if thor.config.general.font != old_font && thor.config.general.font != "" {
        if !ui.text_set_default_family(thor.config.general.font) {
            log.warnf("Configured font %q is not available; using the default", thor.config.general.font)
        }
    }
    if thor.config.general.icon_pack != old_icon_pack && thor.config.general.icon_pack != "" {
        if !ui.icon_set_active_pack(PRIMARY_ICON_PACK_GROUP, thor.config.general.icon_pack) {
            log.warnf("Configured icon pack %q is not available; using the default", thor.config.general.icon_pack)
        }
    }
    if thor.config.general.file_icon_pack != old_file_icon_pack && thor.config.general.file_icon_pack != "" {
        if !ui.icon_set_active_pack(FILE_ICON_PACK_GROUP, thor.config.general.file_icon_pack) {
            log.warnf("Configured file icon pack %q is not available; using the default", thor.config.general.file_icon_pack)
        }
    }

    thor_apply_settings(thor)
    thor_load_tasks(thor)
    thor_settings_mark_clean(thor)
    if widgets.settings_view_is_open(thor.settings_view) {
        thor_populate_settings_view(thor)
    }
}

// Directory holding a workspace's config, i.e. <workspace>/.thor.
thor_workspace_config_dir :: proc(workspace_dir: string, allocator := context.temp_allocator) -> string {
    return strings.concatenate({workspace_dir, "/.thor"}, allocator)
}

// Path a GUI-driven change writes to. While the Settings modal is open, its
// General/Workspace tab picks the file explicitly; otherwise (a command bound
// directly to a shortcut or the palette) the workspace .thor/ overlay wins
// when initialized, since it is what actually takes effect, else the global
// settings/ file.
thor_active_settings_path :: proc(thor: ^Thor) -> string {
    if widgets.settings_view_is_open(thor.settings_view) {
        if widgets.settings_view_scope(thor.settings_view) == .Workspace {
            return strings.concatenate({thor_workspace_config_dir(thor.workspace_dir), "/settings.json"}, context.temp_allocator)
        }
        return "settings/settings.json"
    }
    if thor.workspace_initialized {
        return strings.concatenate({thor_workspace_config_dir(thor.workspace_dir), "/settings.json"}, context.temp_allocator)
    }
    return "settings/settings.json"
}

thor_active_keybinds_path :: proc(thor: ^Thor) -> string {
    if widgets.settings_view_is_open(thor.settings_view) {
        if widgets.settings_view_scope(thor.settings_view) == .Workspace {
            return strings.concatenate({thor_workspace_config_dir(thor.workspace_dir), "/keybinds.json"}, context.temp_allocator)
        }
        return "settings/keybinds.json"
    }
    if thor.workspace_initialized {
        return strings.concatenate({thor_workspace_config_dir(thor.workspace_dir), "/keybinds.json"}, context.temp_allocator)
    }
    return "settings/keybinds.json"
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
// keybinds.json name; most ship empty, so they stay unbound until the user sets
// a chord.
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
    thor_add_bindable_command(thor, "View: Toggle Whitespace", "toggle_whitespace", thor_cmd_toggle_whitespace, thor)
    widgets.command_palette_add(p, "View: Toggle Split Editor", thor_cmd_toggle_split, thor, sc(thor, "toggle_split"))
    thor_add_bindable_command(thor, "View: Toggle Markdown Preview", "toggle_markdown_preview", thor_cmd_toggle_markdown_preview, thor)
    widgets.command_palette_add(p, "View: Recenter", thor_cmd_recenter, thor, sc(thor, "recenter"))

    thor_add_bindable_command(thor, "Terminal: New Terminal", "new_terminal", thor_cmd_new_terminal, thor)
    thor_add_bindable_command(thor, "Terminal: Close Terminal", "close_terminal", thor_cmd_close_terminal, thor)
    thor_add_bindable_command(thor, "Terminal: Next Terminal", "next_terminal", thor_cmd_next_terminal, thor)
    thor_add_bindable_command(thor, "Terminal: Restart Shell", "restart_shell", thor_cmd_restart_shell, thor)
    thor_add_bindable_command(thor, "Terminal: Select Shell", "select_shell", thor_cmd_select_shell, thor)

    thor_add_bindable_command(thor, "File: Open File", "open_file", thor_cmd_open_file, thor)
    thor_add_bindable_command(thor, "File: Open Folder", "open_folder", thor_cmd_open_folder, thor)
    thor_add_bindable_command(thor, "File: Open Folder in New Window", "open_folder_new_window", thor_cmd_open_folder_new_window, thor)
    thor_add_bindable_command(thor, "File: New File", "new_file", thor_cmd_new_file, thor)
    thor_add_bindable_command(thor, "File: New Folder", "new_folder", thor_cmd_new_folder, thor)
    widgets.command_palette_add(p, "File: Save", thor_cmd_save, thor, sc(thor, "save"))
    thor_add_bindable_command(thor, "File: Save All", "save_all", thor_cmd_save_all, thor)
    thor_add_bindable_command(thor, "File: Rename File", "rename_file", thor_cmd_rename_file, thor)
    thor_add_bindable_command(thor, "File: Reload from Disk", "reload_from_disk", thor_cmd_reload_from_disk, thor)
    widgets.command_palette_add(p, "File: Close Tab", thor_cmd_close_tab, thor, sc(thor, "close_tab"))
    thor_add_bindable_command(thor, "File: Close All Tabs", "close_all_tabs", thor_cmd_close_all, thor)
    thor_add_bindable_command(thor, "File: Close Workspace", "close_workspace", thor_cmd_close_workspace, thor)
    widgets.command_palette_add(p, "File: Next Tab", thor_cmd_next_tab, thor, sc(thor, "next_tab"))
    widgets.command_palette_add(p, "File: Previous Tab", thor_cmd_prev_tab, thor, sc(thor, "previous_tab"))
    widgets.command_palette_add(p, "File: Switch to Last File", thor_cmd_last_file, thor, sc(thor, "last_file"))
    thor_add_bindable_command(thor, "File: Use LF Line Endings", "line_endings_lf", thor_cmd_line_endings_lf, thor)
    thor_add_bindable_command(thor, "File: Use CRLF Line Endings", "line_endings_crlf", thor_cmd_line_endings_crlf, thor)
    thor_add_bindable_command(thor, "File: Show Indentation", "show_indentation", thor_cmd_show_indentation, thor)
    thor_add_bindable_command(thor, "File: Copy Path", "copy_path", thor_cmd_copy_path, thor)
    thor_add_bindable_command(thor, "File: Reveal in File Explorer", "reveal_in_explorer", thor_cmd_reveal, thor)

    // Data is the palette itself: these switch it into another input mode.
    widgets.command_palette_add(p, "Go to File", widgets.command_palette_goto_file_command, p, sc(thor, "quick_open"))
    widgets.command_palette_add(p, "Go to Line", widgets.command_palette_goto_line_command, p, sc(thor, "goto_line"))

    widgets.command_palette_add(p, "Find", thor_cmd_find, thor, sc(thor, "find"))
    widgets.command_palette_add(p, "Replace", thor_cmd_replace, thor, sc(thor, "replace"))

    // Undo/redo have editor-local keys, so plain palette entries rather than
    // thor_add_bindable_command.
    widgets.command_palette_add(p, "Edit: Undo", thor_cmd_undo, thor, sc(thor, "undo"))
    widgets.command_palette_add(p, "Edit: Redo", thor_cmd_redo, thor, sc(thor, "redo"))
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
    widgets.command_palette_add(p, "Edit: Format Document", thor_cmd_format_document, thor, sc(thor, "format_document"))
    widgets.command_palette_add(p, "Edit: Format Selection", thor_cmd_format_selection, thor, sc(thor, "format_selection"))
    widgets.command_palette_add(p, "Edit: Align at Character", thor_cmd_align_at_char, thor, sc(thor, "align_at_char"))

    widgets.command_palette_add(p, "Selection: Add Cursor Above", thor_cmd_add_cursor_above, thor, sc(thor, "add_cursor_above"))
    widgets.command_palette_add(p, "Selection: Add Cursor Below", thor_cmd_add_cursor_below, thor, sc(thor, "add_cursor_below"))
    widgets.command_palette_add(p, "Go to Matching Bracket", thor_cmd_matching_bracket, thor, sc(thor, "matching_bracket"))
    widgets.command_palette_add(p, "Go to Symbol in File", thor_cmd_goto_symbol, thor, sc(thor, "goto_symbol"))
    widgets.command_palette_add(p, "Go to Symbol in Workspace", thor_cmd_goto_workspace_symbol, thor, sc(thor, "goto_workspace_symbol"))
    widgets.command_palette_add(p, "Go Back", thor_cmd_jump_back, thor, sc(thor, "jump_back"))
    widgets.command_palette_add(p, "Go Forward", thor_cmd_jump_forward, thor, sc(thor, "jump_forward"))
    widgets.command_palette_add(p, "Find All References", thor_cmd_find_references, thor, sc(thor, "find_references"))
    widgets.command_palette_add(p, "Signature Help", thor_cmd_signature_help, thor, sc(thor, "signature_help"))
    widgets.command_palette_add(p, "Show Package Documentation", thor_cmd_package_doc, thor, sc(thor, "package_doc"))
    widgets.command_palette_add(p, "Rename Symbol", thor_cmd_rename_symbol, thor, sc(thor, "replace"))
    widgets.command_palette_add(p, "Code Actions", thor_cmd_code_actions, thor, sc(thor, "code_actions"))

    thor_add_bindable_command(thor, "Fold: Toggle Fold", "toggle_fold", thor_cmd_toggle_fold, thor)
    thor_add_bindable_command(thor, "Fold: Fold All", "fold_all", thor_cmd_fold_all, thor)
    thor_add_bindable_command(thor, "Fold: Unfold All", "unfold_all", thor_cmd_unfold_all, thor)

    thor_add_bindable_command(thor, "Tasks: Run Selected Task", "run_selected_task", thor_cmd_run_active_task, thor)
    thor_add_bindable_command(thor, "Tasks: Run Task", "run_task", thor_cmd_run_task, thor)
    thor_add_bindable_command(thor, "Tasks: Add Task", "add_task", thor_cmd_add_task, thor)
    thor_add_bindable_command(thor, "Tasks: Remove Task", "remove_task", thor_cmd_remove_task, thor)
    thor_add_bindable_command(thor, "Tasks: Edit Tasks (JSON)", "edit_tasks", thor_cmd_edit_tasks, thor)

    thor_add_bindable_command(thor, "Help: Tutorial", "tutorial", thor_cmd_tutorial, thor)
    thor_add_bindable_command(thor, "Help: Documentation", "docs", thor_cmd_docs, thor)
    thor_add_bindable_command(thor, "Help: Documentation Page", "docs_page", thor_cmd_docs_page, thor)
    thor_add_bindable_command(thor, "Help: Documentation in Browser", "docs_browser", thor_cmd_docs_browser, thor)
    thor_add_bindable_command(thor, "Settings: Open Settings GUI", "open_settings_gui", thor_cmd_open_settings_gui, thor)
    thor_add_bindable_command(thor, "Settings: Open Keybinds", "open_keybinds", thor_cmd_open_keybinds, thor)
    thor_add_bindable_command(thor, "Settings: Open Comments", "open_comments", thor_cmd_open_comments, thor)
    thor_add_bindable_command(thor, "Settings: Open General Settings", "open_settings", thor_cmd_open_settings, thor)
    thor_add_bindable_command(thor, "Settings: Add Font", "add_font", thor_cmd_add_font, thor)
    thor_add_bindable_command(thor, "Settings: Reload", "reload_settings", thor_cmd_reload_settings, thor)
    thor_add_bindable_command(thor, "Workspace: Initialize", "init_workspace", thor_cmd_init_workspace, thor)
    thor_add_bindable_command(thor, "Preferences: New Theme", "new_theme", thor_cmd_new_theme, thor)
    thor_add_bindable_command(thor, "Preferences: Change Theme", "change_theme", thor_cmd_change_theme, thor)
    thor_add_bindable_command(thor, "Preferences: Change Font", "change_font", thor_cmd_change_font, thor)
    thor_add_bindable_command(thor, "Preferences: Change Icon Pack", "change_icon_pack", thor_cmd_change_icon_pack, thor)
    thor_add_bindable_command(thor, "Preferences: Change File Icon Pack", "change_file_icon_pack", thor_cmd_change_file_icon_pack, thor)
    thor_add_bindable_command(thor, "Preferences: Ligatures", "change_ligatures", thor_cmd_change_ligatures, thor)
}

thor_cmd_toggle_explorer :: proc(data: rawptr) {thor_toggle_explorer(data, nil, nil)}
thor_cmd_toggle_console :: proc(data: rawptr) {thor_toggle_console(data, nil, nil)}
thor_cmd_toggle_maximize :: proc(data: rawptr) {thor_toggle_maximize(data, nil, nil)}
thor_cmd_toggle_fullscreen :: proc(data: rawptr) {thor_toggle_fullscreen(cast(^Thor) data)}
thor_cmd_toggle_wrap :: proc(data: rawptr) {widgets.editor_toggle_wrap((cast(^Thor) data).editor)}

// Both panes, so a split does not end up with one pane marking indentation and
// the other not.
thor_cmd_toggle_whitespace :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.editor_toggle_whitespace(thor.editor)
    widgets.editor_toggle_whitespace(thor.editor2)
}
thor_cmd_toggle_split :: proc(data: rawptr) {thor_toggle_split(cast(^Thor) data)}

// Flips the rendered markdown preview. Only visibly does anything while a
// markdown file is active (thor_update_editor_view gates the swap).
thor_cmd_toggle_markdown_preview :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor.markdown_preview = !thor.markdown_preview
    thor_update_editor_view(thor)
}
thor_cmd_find :: proc(data: rawptr) {thor_open_find(cast(^Thor) data, false)}
thor_cmd_replace :: proc(data: rawptr) {thor_open_find(cast(^Thor) data, true)}
thor_cmd_save :: proc(data: rawptr) {thor_request_save(data)}

thor_cmd_line_endings_lf :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_set_line_ending(thor, thor_active_open_file(thor), .LF)
}
thor_cmd_line_endings_crlf :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_set_line_ending(thor, thor_active_open_file(thor), .CRLF)
}

// Reports the indentation the active file uses, with the count of the lines that
// disagree so a mixed file is visible.
thor_cmd_show_indentation :: proc(data: rawptr) {
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }

    info := textedit.detect_indent(&file.state)
    message: string
    switch info.style {
    case .Unknown:
        message = "Indentation: no indented line"
    case .Spaces:
        message = fmt.tprintf("Indentation: spaces (width %d), %d lines", info.width, info.space_lines)
        if info.tab_lines > 0 {
            message = fmt.tprintf("%s, %d with tabs", message, info.tab_lines)
        }
    case .Tabs:
        message = fmt.tprintf("Indentation: tabs, %d lines", info.tab_lines)
        if info.space_lines > 0 {
            message = fmt.tprintf("%s, %d with spaces", message, info.space_lines)
        }
    }
    thor_flash_status(thor, message)
}

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

// Undo takes back a cross-file edit set first, the way ctrl + z does (see
// thor_global_key), then falls back to the focused buffer's own history.
thor_cmd_undo :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor_undo_last_edits(thor) {
        return
    }
    if s := thor_edit_state(data); s != nil {
        textedit.undo(s)
        widgets.editor_scroll_to_caret(thor_pane_editor(thor, thor.active_pane))
    }
}

thor_cmd_redo :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor_redo_last_edits(thor) {
        return
    }
    if s := thor_edit_state(data); s != nil {
        textedit.redo(s)
        widgets.editor_scroll_to_caret(thor_pane_editor(thor, thor.active_pane))
    }
}

// True when there is something to take back: a cross-file edit set, or the
// focused buffer's own history.
thor_can_undo :: proc(thor: ^Thor) -> bool {
    if len(thor.edit_undo) > 0 {
        return true
    }
    file := thor_active_open_file(thor)
    return file != nil && file.loaded && file.state.undo_stack.count > 0
}

thor_can_redo :: proc(thor: ^Thor) -> bool {
    if len(thor.edit_redo) > 0 {
        return true
    }
    file := thor_active_open_file(thor)
    return file != nil && file.loaded && len(file.state.redo_stack) > 0
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
thor_cmd_jump_back :: proc(data: rawptr) {thor_jump_back(cast(^Thor) data)}
thor_cmd_jump_forward :: proc(data: rawptr) {thor_jump_forward(cast(^Thor) data)}
thor_cmd_find_references :: proc(data: rawptr) {thor_find_references(cast(^Thor) data)}
thor_cmd_signature_help :: proc(data: rawptr) {thor_signature_help(cast(^Thor) data)}
thor_cmd_package_doc :: proc(data: rawptr) {thor_package_doc(cast(^Thor) data)}
thor_cmd_rename_symbol :: proc(data: rawptr) {_ = thor_rename_symbol(cast(^Thor) data)}
thor_cmd_code_actions :: proc(data: rawptr) {thor_code_actions(cast(^Thor) data)}
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

// Save All: files that don't need formatting save immediately; among files
// that do, only the first dispatches right away — .Format has one consumer
// slot like every other kind, so the rest wait in format_save_queue and are
// formatted and saved one at a time as thor_finish_pending_format_save pops it.
thor_cmd_save_all :: proc(data: rawptr) {
    thor := cast(^Thor) data
    formatting_started := thor.format_request_id != 0 || thor.format_save_pending
    for file in thor.open_files {
        if !file.loaded || file.closed || file.state.revision == file.saved_revision {
            continue
        }
        if formatting_started {
            append(&thor.format_save_queue, strings.clone(file.path))
            continue
        }
        thor_save_explicit(thor, file)
        formatting_started = thor.format_request_id != 0 || thor.format_save_pending
    }
}

// Re-reads the active file, for a disk change the watcher cannot see (a file
// outside the workspace) or a conflict prompt that was dismissed. Unsaved edits
// still raise that prompt rather than being dropped.
thor_cmd_reload_from_disk :: proc(data: rawptr) {
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil {
        return
    }
    file.disk_changed = false
    thor_reload_file(thor, file)
}

thor_cmd_copy_path :: proc(data: rawptr) {
    file := thor_active_open_file(cast(^Thor) data)
    if file == nil {
        return
    }
    rl.SetClipboardText(strings.clone_to_cstring(file.path, context.temp_allocator))
}

thor_cmd_reveal :: proc(data: rawptr) {
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil {
        return
    }
    if !thor_reveal_path(file.path) {
        thor_flash_status(thor, "Could not open the file explorer", true)
    }
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
        "Success Color": "",
        "Warning Color": "",
        "Info Color": "",
        "Danger Color": "",
        "Submodule Color": "",
        "Conflict Color": "",
        "Accent Secondary Color": "",
        "Muted Color": "",
        "Primary Text Color": "",
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
    thor := cast(^Thor) data
    dst :: "assets/themes/custom.json"
    if !os.exists(dst) {
        if err := os.write_entire_file(dst, EMPTY_THEME); err != nil {
            log.errorf("Could not create %q: %v", dst, err)
            thor_flash_status(thor, "Could not create theme file", is_error = true)
            return
        }
    }
    thor_open_file(thor, dst)
}

thor_cmd_open_keybinds :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "settings/keybinds.json")}
thor_cmd_open_comments :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "settings/comments.json")}
thor_cmd_open_settings :: proc(data: rawptr) {thor_open_file(cast(^Thor) data, "settings/settings.json")}
thor_cmd_reload_settings :: proc(data: rawptr) {thor_reload_settings(cast(^Thor) data)}

// The cached index once it has been warmed (thor_refresh_file_index); a
// synchronous walk before then, so the palette is never empty just because
// the async warm has not landed yet — the handful of frames after a folder
// opens, or the same window right after startup.
thor_palette_list_files :: proc(data: rawptr) -> []string {
    thor := cast(^Thor) data
    if thor.file_index_ready {
        return thor.file_index[:]
    }
    files := thor_walk_workspace_files(thor.workspace_dir, context.temp_allocator)
    return files[:]
}

@(private)
COLLECT_FILE_MAX :: 4000
@(private)
COLLECT_DEPTH_MAX :: 12

// Gathers file paths under root (skipping .git), capped so a huge tree can't
// stall the palette. Paths are cloned into allocator, so the result outlives
// the temp arena a worker thread would otherwise be bound by.
@(private)
thor_walk_workspace_files :: proc(
    root: string,
    allocator: runtime.Allocator,
    limit := COLLECT_FILE_MAX,
    max_depth := COLLECT_DEPTH_MAX,
) -> [dynamic]string {
    files := make([dynamic]string, allocator)
    thor_collect_files(root, &files, 0, limit, max_depth)
    return files
}

// Recursively appends file paths under dir into files. Returns false once the
// walk should stop entirely (the cap was hit); true means only this branch is
// done.
@(private = "file")
thor_collect_files :: proc(dir: string, files: ^[dynamic]string, depth: int, limit: int, max_depth: int) -> bool {
    if depth > max_depth {
        return true
    }

    handle, open_err := os.open(dir)
    if open_err != nil {
        return true
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.allocator)
    if read_err != nil {
        return true
    }
    defer os.file_info_slice_delete(infos, context.allocator)

    for info in infos {
        if info.name == ".git" {
            continue
        }
        if info.type == .Directory {
            if !thor_collect_files(info.fullpath, files, depth + 1, limit, max_depth) {
                return false
            }
        } else {
            append(files, strings.clone(info.fullpath, files.allocator))
            if len(files) >= limit {
                return false
            }
        }
    }
    return true
}

// Async quick-open file list: a worker walks the workspace tree once and
// hands the result back; the main thread swaps it in for the old one, the
// same shape as Git_Status_Job. file_index_inflight/dirty coalesce a burst of
// watcher activity into one more walk instead of one per event.
File_Index_Job :: struct {
    owner:     ^Thor,
    allocator: runtime.Allocator,
    worker:    ^thread.Thread,
    root:      string,          // owned snapshot of workspace_dir at launch
    files:     [dynamic]string, // owned, with the strings in it; moved onto Thor on reap
}

// How long a watcher-driven refresh must wait since the last one, so a build
// writing into the tree cannot keep a walk permanently running.
@(private)
FILE_INDEX_INTERVAL :: 5 * time.Second

// Spawns a walk unless one is already running (coalesced into a re-run once
// it lands) or the workspace is empty.
thor_refresh_file_index :: proc(thor: ^Thor) {
    if thor.workspace_dir == "" {
        return
    }
    if thor.file_index_inflight {
        thor.file_index_dirty = true
        return
    }
    thor.file_index_inflight = true
    thor.file_index_at = time.tick_now()

    job := new(File_Index_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.root = strings.clone(thor.workspace_dir, context.allocator)

    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, file_index_worker)
}

@(private = "file")
file_index_worker :: proc(job: ^File_Index_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    job.files = thor_walk_workspace_files(job.root, job.allocator)

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_file_index, job)
    sync.unlock(&job.owner.io_mutex)
}

// Drains a finished walk (called from thor_process_io). A workspace switch
// while it ran makes it the wrong folder's list, so it is thrown away rather
// than applied.
thor_apply_file_index :: proc(thor: ^Thor, job: ^File_Index_Job) {
    thread.join(job.worker)
    thread.destroy(job.worker)

    if job.root != thor.workspace_dir {
        for f in job.files {
            delete(f, job.allocator)
        }
        delete(job.files)
    } else {
        thor_clear_file_index(thor)
        thor.file_index = job.files
        thor.file_index_ready = true
    }

    delete(job.root, job.allocator)
    free(job)
    thor.file_index_inflight = false
    thor.inflight_jobs -= 1

    // A refresh landed while this one was running: run once more.
    if thor.file_index_dirty {
        thor.file_index_dirty = false
        thor_refresh_file_index(thor)
    }
}

thor_clear_file_index :: proc(thor: ^Thor) {
    for f in thor.file_index {
        delete(f)
    }
    delete(thor.file_index)
    thor.file_index = nil
    thor.file_index_ready = false
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
    // Recorded like any other jump: this one stays inside the file, but a line
    // typed into the palette is still a place the caret was pulled away from.
    thor_jump_record(thor)
    pos := textedit.state_line_start(&file.state, line - 1)
    textedit.set_single_cursor(&file.state, pos)
    widgets.editor_center_on_caret(thor.editor)
}
