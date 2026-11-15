package thor

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

import "../editview"
import "../lang"
import "../textedit"
import ui "../vendor/loom/loom"
// Points both editor panes at the shared context menu. Called once at startup;
// every other menu is opened straight from the view that owns the click.
thor_wire_menus :: proc(thor: ^Thor) {
    for &editor in thor.editors {
        editview.editor_set_on_context_menu(&editor, thor_editor_context_menu, thor)
    }
}

// Remembers the directory a New File/Folder prompt will create into.
@(private = "file")
thor_set_menu_target :: proc(thor: ^Thor, dir: string) {
    delete(thor.menu_target_dir)
    thor.menu_target_dir = strings.clone(dir)
}

thor_editor_context_menu :: proc(data: rawptr, position: ui.Vec2) {
    thor := cast(^Thor)data
    // The right-click focused its pane before this callback, but menu_open takes
    // focus next, so the frame's own thor_sync_active_pane would never see it.
    thor_sync_active_pane(thor)
    file     := thor_active_open_file(thor)
    has_file := file != nil

    // Format Selection formats the whole document when there is no selection.
    format_selection := thor_menu_lang_allows(thor, .Format)
    if file != nil && textedit.has_selection(textedit.primary_cursor(&file.state)) {
        format_selection = thor_menu_lang_allows(thor, .Format_Range)
    }

    thor_menu_clear(thor)
    thor_menu_add(thor, "Go to definition", thor_cmd_goto_definition, thor, thor_menu_lang_allows(thor, .Definition), action = "goto_definition")
    thor_menu_add(
        thor,
        "Go to type definition",
        thor_cmd_goto_type_definition,
        thor,
        thor_menu_lang_allows(thor, .Type_Definition),
        action = "goto_type_definition",
    )
    thor_menu_add(thor, "Peek definition", thor_cmd_peek_definition, thor, thor_menu_lang_allows(thor, .Definition), action = "peek_definition")
    thor_menu_add(thor, "Find references", thor_cmd_find_references, thor, thor_menu_lang_allows(thor, .References), action = "find_references")
    thor_menu_add(thor, "Go to implementations", thor_cmd_implementations, thor, thor_menu_lang_allows(thor, .Implementations), action = "goto_implementations")
    thor_menu_add(thor, "Show incoming calls", thor_cmd_incoming_calls, thor, thor_menu_lang_allows(thor, .Call_Hierarchy), action = "incoming_calls")
    thor_menu_add(thor, "Show outgoing calls", thor_cmd_outgoing_calls, thor, thor_menu_lang_allows(thor, .Call_Hierarchy), action = "outgoing_calls")
    thor_menu_add(thor, "Show supertypes", thor_cmd_supertypes, thor, thor_menu_lang_allows(thor, .Type_Hierarchy), action = "supertypes")
    thor_menu_add(thor, "Show subtypes", thor_cmd_subtypes, thor, thor_menu_lang_allows(thor, .Type_Hierarchy), action = "subtypes")
    thor_menu_add(thor, "Rename symbol", thor_cmd_rename_symbol, thor, thor_menu_lang_allows(thor, .Rename), action = "replace")
    thor_menu_add(thor, "Code actions", thor_cmd_code_actions, thor, thor_menu_lang_allows(thor, .Code_Actions), action = "code_actions")
    thor_menu_add(thor, "Signature help", thor_cmd_signature_help, thor, thor_menu_lang_allows(thor, .Signature_Help), action = "signature_help")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Format document", thor_cmd_format_document, thor, thor_menu_lang_allows(thor, .Format), action = "format_document")
    thor_menu_add(thor, "Format selection", thor_cmd_format_selection, thor, format_selection, action = "format_selection")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Go to symbol in file", thor_cmd_goto_symbol, thor, thor_menu_lang_allows(thor, .Document_Symbols), action = "goto_symbol")
    thor_menu_add(thor, "Package documentation", thor_cmd_package_doc, thor, thor_menu_lang_allows(thor, .Package_Doc), action = "package_doc")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Undo", thor_cmd_undo, thor, thor_can_undo(thor), action = "undo")
    thor_menu_add(thor, "Redo", thor_cmd_redo, thor, thor_can_redo(thor), action = "redo")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Cut", thor_menu_cut, thor, has_file, action = "cut")
    thor_menu_add(thor, "Copy", thor_menu_copy, thor, has_file, action = "copy")
    thor_menu_add(thor, "Paste", thor_menu_paste, thor, has_file, action = "paste")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Select all", thor_cmd_select_all, thor, has_file, action = "select_all")
    thor_menu_open(thor, position)
}

// Reports whether a backend serves `kind` for the active file. False with no file open.
thor_menu_lang_allows :: proc(thor: ^Thor, kind: lang.Request_Kind) -> bool {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return false
    }
    return lang.manager_allows(&thor.lang_manager, thor_lang_key(thor, file.name), kind)
}

thor_console_context_menu :: proc(data: rawptr, position: ui.Vec2) {
    thor          := cast(^Thor)data
    term          := thor_active_terminal(thor)
    has_selection := term != nil && thor_console_has_selection(&term.console)
    thor_menu_clear(thor)
    thor_menu_add(thor, "Copy", thor_menu_console_copy_selection, thor, has_selection)
    thor_menu_add(thor, "Copy all", thor_menu_console_copy, thor)
    thor_menu_add(thor, "Paste", thor_menu_console_paste, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Clear", thor_menu_console_clear, thor)
    thor_menu_add(thor, "Restart shell", thor_menu_terminal_restart, thor, term != nil, action = "restart_shell")
    thor_menu_add(thor, "New terminal", thor_cmd_new_terminal, thor, action = "new_terminal")
    thor_menu_add(thor, "Close terminal", thor_cmd_close_terminal, thor, term != nil, action = "close_terminal")
    thor_menu_open(thor, position)
}

@(private = "file")
thor_menu_terminal_restart :: proc(data: rawptr) {
    if term := thor_active_terminal(cast(^Thor)data); term != nil {
        thor_terminal_restart(term)
    }
}

thor_explorer_context_menu :: proc(thor: ^Thor, clicked: string, position: ui.Vec2) {
    // Create into the clicked folder, the clicked file's folder, or (empty
    // space) the workspace root.
    target := thor.workspace_dir
    if clicked != "" {
        target = os.is_dir(clicked) ? clicked : filepath.dir(clicked) // borrowed
    }
    thor_set_menu_target(thor, target)

    // The right-click selected the row first, so Rename and the other selection
    // actions read the explorer's caret row.
    has_selection := clicked != ""
    on_folder     := has_selection && os.is_dir(clicked)

    thor_menu_clear(thor)
    thor_menu_add(thor, "New file", thor_menu_new_file, thor, action = "new_file")
    thor_menu_add(thor, "New folder", thor_menu_new_folder, thor, action = "new_folder")
    if on_folder {
        thor_menu_add_separator(thor)
        thor_menu_add(thor, "Open in new window", thor_menu_open_new_window, thor)
    } else if has_selection {
        thor_menu_add_separator(thor)
        thor_menu_add(thor, "Open to the side", thor_menu_open_to_side, thor)
        thor_menu_add(thor, "Open in pane...", thor_menu_open_in_pane, thor)
    }
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Rename", thor_menu_rename, thor, has_selection, action = "rename_file")
    thor_menu_add(thor, "Reveal in File Explorer", thor_menu_explorer_reveal, thor, has_selection, action = "reveal_in_explorer")
    thor_menu_add(thor, "Copy path", thor_menu_explorer_copy_path, thor, has_selection, action = "copy_path")
    thor_menu_add(thor, "Delete", thor_menu_explorer_delete, thor, has_selection)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Refresh", thor_menu_explorer_refresh, thor)
    thor_menu_open(thor, position)
}

thor_tab_context_menu :: proc(thor: ^Thor, index: int, position: ui.Vec2) {
    if index < 0 {
        return
    }
    thor.menu_target_tab = index

    thor_menu_clear(thor)
    thor_menu_add(thor, "Close", thor_menu_close_tab, thor, action = "close_tab")
    thor_menu_add(thor, "Close others", thor_menu_close_other_tabs, thor, len(thor.open_files) > 1)
    thor_menu_add(thor, "Close all", thor_cmd_close_all, thor, action = "close_all_tabs")
    thor_menu_open(thor, position)
}

thor_terminal_tab_context_menu :: proc(thor: ^Thor, index: int, position: ui.Vec2) {
    if index < 0 {
        return
    }
    thor.menu_target_terminal = index

    thor_menu_clear(thor)
    thor_menu_add(thor, "Close", thor_menu_close_terminal, thor, action = "close_terminal")
    thor_menu_add(thor, "Close all", thor_cmd_close_all_terminals, thor)
    thor_menu_open(thor, position)
}

@(private = "file")
thor_menu_close_tab :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_request_close_file(thor, thor.menu_target_tab)
}

// Closes every tab except the one the context menu targeted. Closes from the
// tail first so the target's own index never shifts under it.
@(private = "file")
thor_menu_close_other_tabs :: proc(data: rawptr) {
    thor := cast(^Thor)data
    keep := thor.menu_target_tab
    if keep < 0 || keep >= len(thor.open_files) {
        return
    }
    // Last first, so an index stays good when a tab before it stays open.
    for index := len(thor.open_files) - 1; index >= 0; index -= 1 {
        if index != keep {
            thor_request_close_file(thor, index, ask = false)
        }
    }
}

@(private = "file")
thor_menu_close_terminal :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_terminal_close(thor, thor.menu_target_terminal)
}

thor_menu_cut   :: proc(data: rawptr) {
    editview.editor_cut(thor_active_editor(cast(^Thor)data))
}
thor_menu_copy  :: proc(data: rawptr) {
    editview.editor_copy(thor_active_editor(cast(^Thor)data))
}
thor_menu_paste :: proc(data: rawptr) {
    editview.editor_paste(thor_active_editor(cast(^Thor)data))
}

thor_menu_console_clear :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if thor_active_console(thor) != nil {
        thor_console_clear(thor_active_console(thor))
    }
}

thor_menu_console_copy :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if thor_active_console(thor) != nil {
        thor_console_copy_all(thor_active_console(thor))
    }
}

thor_menu_console_copy_selection :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if thor_active_console(thor) != nil {
        thor_console_copy(thor_active_console(thor))
    }
}

thor_menu_console_paste :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if thor_active_console(thor) != nil {
        thor_console_paste(thor_active_console(thor))
    }
}

// Open the shared name prompt into menu_target (the right-clicked directory).
// Command-palette entries reset the target to the workspace root first.
thor_menu_new_file :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_palette_prompt(thor, "New file name", thor_prompt_new_file, thor)
}

thor_menu_new_folder :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_palette_prompt(thor, "New folder name", thor_prompt_new_folder, thor)
}

thor_menu_explorer_refresh :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_explorer_refresh(thor)
    thor_refresh_git_status(thor)
}

// Explorer right-click Rename: the right-clicked row is the current selection.
thor_menu_rename :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_begin_rename(thor, thor_explorer_selected(thor))
}

// Explorer right-click Delete: acts on the right-clicked row, or on the whole
// selection when that row is part of one.
thor_menu_explorer_delete :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_tree_delete(thor, thor_explorer_selected(thor))
}

// Explorer right-click on a folder: open it in its own window, leaving this one
// on the current workspace. Skips the this-window/new-window prompt — the entry
// already says which it is.
thor_menu_open_new_window :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_new_window_for(thor, thor_explorer_selected(thor))
}

thor_menu_open_to_side :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_open_file_in_pane(thor, thor_explorer_selected(thor), thor_side_pane(thor))
}

thor_menu_open_in_pane :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_pane_pick_begin(thor, thor_explorer_selected(thor))
}

thor_menu_explorer_reveal :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if !thor_reveal_path(thor_explorer_selected(thor)) {
        thor_flash_status(thor, "Could not open the file explorer", true)
    }
}

thor_menu_explorer_copy_path :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if thor_explorer_selected(thor) != "" {
        rl.SetClipboardText(strings.clone_to_cstring(thor_explorer_selected(thor), context.temp_allocator))
    }
}


// Folder a keyboard or palette create lands in: beside the explorer's selection
// when the tree has the focus, else the workspace root.
@(private = "file")
thor_create_target :: proc(thor: ^Thor) -> string {
    selected := thor_explorer_selected(thor)
    if thor.focus_owner != "explorer" || selected == "" {
        return thor.workspace_dir
    }
    return os.is_dir(selected) ? selected : filepath.dir(selected) // borrowed
}

// Command-palette / top-bar / keybind entry points (the explorer right-click
// sets its own target).
thor_cmd_new_file :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_set_menu_target(thor, thor_create_target(thor))
    thor_menu_new_file(data)
}

thor_cmd_new_folder :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_set_menu_target(thor, thor_create_target(thor))
    thor_menu_new_folder(data)
}

// Top-bar File menu / command palette / F2: rename the explorer's selection when
// the tree is focused, otherwise the active tab's file.
thor_cmd_rename_file :: proc(data: rawptr) {
    thor := cast(^Thor)data
    if thor.focus_owner == "explorer" && thor_explorer_selected(thor) != "" {
        thor_begin_rename(thor, thor_explorer_selected(thor))
        return
    }
    if file := thor_active_open_file(thor); file != nil {
        thor_begin_rename(thor, file.path)
    }
}

// True when `name` names one new entry of a folder: the palette already refuses
// an empty prompt, the rest is what a join would turn into another directory.
@(private = "file")
thor_valid_entry_name :: proc(name: string) -> bool {
    if name == "" || name == "." || name == ".." {
        return false
    }
    return !strings.contains(name, "/") && !strings.contains(name, "\\")
}

thor_prompt_new_file :: proc(data: rawptr, name: string) {
    thor := cast(^Thor)data
    name := name
    name = strings.trim_space(name)
    if !thor_valid_entry_name(name) {
        thor_flash_status(thor, "Not a valid file name", is_error = true)
        return
    }
    path, join_err := filepath.join({thor.menu_target_dir, name}, context.temp_allocator)
    if join_err != nil {
        log.errorf("Could not build a path for %q: %v", name, join_err)
        thor_flash_status(thor, "Could not create file", is_error = true)
        return
    }
    if !os.exists(path) {
        if err := os.write_entire_file(path, []byte{}); err != nil {
            log.errorf("Could not create %q: %v", path, err)
            thor_flash_status(thor, "Could not create file", is_error = true)
            return
        }
        thor_explorer_refresh(thor)
        thor_refresh_git_status(thor)
    }
    thor_open_file(thor, path)
}

thor_prompt_new_folder :: proc(data: rawptr, name: string) {
    thor := cast(^Thor)data
    name := name
    name = strings.trim_space(name)
    if !thor_valid_entry_name(name) {
        thor_flash_status(thor, "Not a valid folder name", is_error = true)
        return
    }
    path, join_err := filepath.join({thor.menu_target_dir, name}, context.temp_allocator)
    if join_err != nil {
        log.errorf("Could not build a path for %q: %v", name, join_err)
        thor_flash_status(thor, "Could not create folder", is_error = true)
        return
    }
    if !os.exists(path) {
        if err := os.make_directory(path); err != nil {
            log.errorf("Could not create %q: %v", path, err)
            thor_flash_status(thor, "Could not create folder", is_error = true)
            return
        }
        thor_explorer_refresh(thor)
    }
}

thor_open_file_menu :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_menu_clear(thor)
    thor_menu_add(thor, "Open file...", thor_cmd_open_file, thor, action = "open_file")
    thor_menu_add(thor, "Open folder...", thor_cmd_open_folder, thor, action = "open_folder")
    thor_menu_add(thor, "Open folder in new window...", thor_cmd_open_folder_new_window, thor, action = "open_folder_new_window")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "New file", thor_cmd_new_file, thor, action = "new_file")
    thor_menu_add(thor, "New folder", thor_cmd_new_folder, thor, action = "new_folder")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Save", thor_cmd_save, thor, action = "save")
    thor_menu_add(thor, "Save all", thor_cmd_save_all, thor, action = "save_all")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Rename file", thor_cmd_rename_file, thor, thor_active_open_file(thor) != nil, action = "rename_file")
    thor_menu_add(thor, "Close tab", thor_cmd_close_tab, thor, action = "close_tab")
    thor_menu_add(thor, "Close all tabs", thor_cmd_close_all, thor, action = "close_all_tabs")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Settings", thor_cmd_open_settings_gui, thor, action = "open_settings_gui")
    thor_menu_add(thor, "Language servers", thor_cmd_open_language_servers, thor, action = "open_language_servers")
    thor_menu_add(thor, "Open settings file", thor_cmd_open_settings, thor, action = "open_settings")
    thor_menu_add(thor, "Open keybinds file", thor_cmd_open_keybinds, thor, action = "open_keybinds")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Close workspace", thor_cmd_close_workspace, thor, thor.workspace_dir != "", action = "close_workspace")
    thor_menu_open(thor, thor.menu_anchor)
}

thor_open_edit_menu :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_menu_clear(thor)
    thor_menu_add(thor, "Undo", thor_cmd_undo, thor, thor_can_undo(thor), action = "undo")
    thor_menu_add(thor, "Redo", thor_cmd_redo, thor, thor_can_redo(thor), action = "redo")
    has_file := thor_active_open_file(thor) != nil
    thor_menu_add(thor, "Undo history", thor_cmd_undo_history, thor, has_file, action = "undo_history")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Cut", thor_menu_cut, thor, has_file, action = "cut")
    thor_menu_add(thor, "Copy", thor_menu_copy, thor, has_file, action = "copy")
    thor_menu_add(thor, "Paste", thor_menu_paste, thor, has_file, action = "paste")
    thor_menu_add(thor, "Select all", thor_cmd_select_all, thor, action = "select_all")
    thor_menu_add(thor, "Toggle line comment", thor_cmd_toggle_comment, thor, action = "toggle_line_comment")
    thor_menu_add(thor, "Toggle block comment", thor_cmd_toggle_block_comment, thor, action = "toggle_block_comment")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Duplicate line", thor_cmd_duplicate_line, thor, action = "duplicate_line_down")
    thor_menu_add(thor, "Delete line", thor_cmd_delete_line, thor, action = "delete_line")
    thor_menu_add(thor, "Move line up", thor_cmd_move_line_up, thor, action = "move_line_up")
    thor_menu_add(thor, "Move line down", thor_cmd_move_line_down, thor, action = "move_line_down")
    thor_menu_add(thor, "Trim trailing whitespace", thor_cmd_trim_whitespace, thor, action = "trim_trailing_whitespace")
    thor_menu_add(thor, "Format document", thor_cmd_format_document, thor, action = "format_document")
    thor_menu_add(thor, "Format selection", thor_cmd_format_selection, thor, action = "format_selection")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Find", thor_cmd_find, thor, action = "find")
    thor_menu_add(thor, "Find in files", thor_cmd_find_in_files, thor, action = "find_in_files")
    thor_menu_add(thor, "Replace", thor_cmd_replace, thor, action = "replace")
    thor_menu_open(thor, thor.menu_anchor)
}

thor_open_view_menu :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_menu_clear(thor)
    thor_menu_add(thor, "Toggle explorer", thor_cmd_toggle_explorer, thor, action = "toggle_explorer")
    thor_menu_add(thor, "Toggle terminal", thor_cmd_toggle_console, thor, action = "toggle_console")
    thor_menu_add(thor, "Problems", thor_cmd_open_problems, thor, action = "open_problems")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Zoom in", thor_cmd_zoom_in, thor, action = "zoom_in")
    thor_menu_add(thor, "Zoom out", thor_cmd_zoom_out, thor, action = "zoom_out")
    thor_menu_add(thor, "Reset zoom", thor_cmd_zoom_reset, thor, action = "reset_zoom")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Toggle word wrap", thor_cmd_toggle_wrap, thor, action = "toggle_word_wrap")
    thor_menu_add(thor, "Toggle whitespace", thor_cmd_toggle_whitespace, thor, action = "toggle_whitespace")
    thor_menu_add(thor, "Toggle split editor", thor_cmd_toggle_split, thor, action = "toggle_split")
    thor_menu_add(thor, "Change language of file...", thor_cmd_change_language, thor, action = "change_language")
    thor_menu_add(thor, "Select build target...", thor_cmd_select_build_target, thor, action = "select_build_target")
    thor_menu_add(thor, "Pane layout...", thor_cmd_pick_layout, thor, action = "pick_layout")
    thor_menu_add(thor, "Open active file to the side", thor_cmd_open_to_side, thor, action = "open_to_side")
    thor_menu_add(thor, "Toggle fullscreen", thor_cmd_toggle_fullscreen, thor, action = "toggle_fullscreen")
    thor_menu_open(thor, thor.menu_anchor)
}

thor_open_git_menu :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_menu_clear(thor)
    thor_menu_add(thor, "Changes", thor_cmd_open_git_view, thor, action = "open_git_gui")
    thor_menu_add(thor, "History", thor_cmd_open_git_history, thor, action = "open_git_history")
    thor_menu_add(thor, "Branches", thor_cmd_open_git_branches, thor, action = "open_git_branches")
    thor_menu_open(thor, thor.menu_anchor)
}

thor_open_help_menu :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor_menu_clear(thor)
    thor_menu_add(thor, "Tutorial", thor_cmd_tutorial, thor, action = "tutorial")
    thor_menu_add(thor, "Command palette", thor_cmd_command_palette, thor, action = "command_palette")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Documentation", thor_cmd_docs, thor, action = "docs")
    thor_menu_add(thor, "Go to documentation page...", thor_cmd_docs_page, thor, action = "docs_page")
    thor_menu_add(thor, "Open documentation in browser", thor_cmd_docs_browser, thor, action = "docs_browser")
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "What's new", thor_cmd_whats_new, thor, action = "whats_new")
    thor_menu_add(thor, "Check for updates", thor_cmd_check_for_updates, thor, action = "check_for_updates")
    thor_menu_add(thor, "Check for plugin and theme updates", thor_cmd_check_for_plugin_updates, thor, action = "check_for_plugin_updates")
    thor_menu_open(thor, thor.menu_anchor)
}
