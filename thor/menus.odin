package thor

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

import ui "../vendor/loom/loom"
import "../editview"
// Points both editor panes at the shared context menu. Called once at startup;
// every other menu is opened straight from the view that owns the click.
thor_wire_menus :: proc(thor: ^Thor) {
    editview.editor_set_on_context_menu(&thor.editor, thor_editor_context_menu, thor)
    editview.editor_set_on_context_menu(&thor.editor2, thor_editor_context_menu, thor)
}

// Remembers the directory a New File/Folder prompt will create into.
@(private = "file")
thor_set_menu_target :: proc(thor: ^Thor, dir: string) {
    delete(thor.menu_target_dir)
    thor.menu_target_dir = strings.clone(dir)
}

// Accelerators for the undo/redo rows. Literals, not thor_action_shortcut: that
// answers from the temp allocator and a menu holds its items across frames. The
// editor hardcodes these keys (widgets/editor.odin), so they are also the truth
// whatever settings/keybinds.json says.
@(private = "file")
UNDO_SHORTCUT :: "Ctrl+Z"
@(private = "file")
REDO_SHORTCUT :: "Ctrl+Y"

thor_editor_context_menu :: proc(data: rawptr, position: ui.Vec2) {
    thor := cast(^Thor) data
    // The right-click focused its pane before this callback, but menu_open takes
    // focus next, so the frame's own thor_sync_active_pane would never see it.
    thor_sync_active_pane(thor)
    has_file := thor_active_open_file(thor) != nil

    thor_menu_clear(thor)
    thor_menu_add(thor, "Undo", thor_cmd_undo, thor, thor_can_undo(thor), UNDO_SHORTCUT)
    thor_menu_add(thor, "Redo", thor_cmd_redo, thor, thor_can_redo(thor), REDO_SHORTCUT)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Cut", thor_menu_cut, thor, has_file)
    thor_menu_add(thor, "Copy", thor_menu_copy, thor, has_file)
    thor_menu_add(thor, "Paste", thor_menu_paste, thor, has_file)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Select All", thor_cmd_select_all, thor, has_file)
    thor_menu_open(thor, position)
}

thor_console_context_menu :: proc(data: rawptr, position: ui.Vec2) {
    thor := cast(^Thor) data
    term := thor_active_terminal(thor)
    has_selection := term != nil && thor_console_has_selection(&term.console)
    thor_menu_clear(thor)
    thor_menu_add(thor, "Copy", thor_menu_console_copy_selection, thor, has_selection)
    thor_menu_add(thor, "Copy All", thor_menu_console_copy, thor)
    thor_menu_add(thor, "Paste", thor_menu_console_paste, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Clear", thor_menu_console_clear, thor)
    thor_menu_add(thor, "Restart Shell", thor_menu_terminal_restart, thor, term != nil)
    thor_menu_add(thor, "New Terminal", thor_cmd_new_terminal, thor)
    thor_menu_add(thor, "Close Terminal", thor_cmd_close_terminal, thor, term != nil)
    thor_menu_open(thor, position)
}

@(private = "file")
thor_menu_terminal_restart :: proc(data: rawptr) {
    if term := thor_active_terminal(cast(^Thor) data); term != nil {
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
    on_folder := has_selection && os.is_dir(clicked)

    thor_menu_clear(thor)
    thor_menu_add(thor, "New File", thor_menu_new_file, thor)
    thor_menu_add(thor, "New Folder", thor_menu_new_folder, thor)
    if on_folder {
        thor_menu_add_separator(thor)
        thor_menu_add(thor, "Open in New Window", thor_menu_open_new_window, thor)
    }
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Rename", thor_menu_rename, thor, has_selection)
    thor_menu_add(thor, "Reveal in File Explorer", thor_menu_explorer_reveal, thor, has_selection)
    thor_menu_add(thor, "Copy Path", thor_menu_explorer_copy_path, thor, has_selection)
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
    thor_menu_add(thor, "Close", thor_menu_close_tab, thor)
    thor_menu_add(thor, "Close Others", thor_menu_close_other_tabs, thor, len(thor.open_files) > 1)
    thor_menu_add(thor, "Close All", thor_cmd_close_all, thor)
    thor_menu_open(thor, position)
}

thor_terminal_tab_context_menu :: proc(thor: ^Thor, index: int, position: ui.Vec2) {
    if index < 0 {
        return
    }
    thor.menu_target_terminal = index

    thor_menu_clear(thor)
    thor_menu_add(thor, "Close", thor_menu_close_terminal, thor)
    thor_menu_add(thor, "Close All", thor_cmd_close_all_terminals, thor)
    thor_menu_open(thor, position)
}

@(private = "file")
thor_menu_close_tab :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_close_file(thor, thor.menu_target_tab)
}

// Closes every tab except the one the context menu targeted. Closes from the
// tail first so the target's own index never shifts under it.
@(private = "file")
thor_menu_close_other_tabs :: proc(data: rawptr) {
    thor := cast(^Thor) data
    keep := thor.menu_target_tab
    if keep < 0 || keep >= len(thor.open_files) {
        return
    }
    for len(thor.open_files) > keep + 1 {
        thor_close_file(thor, len(thor.open_files) - 1)
    }
    for keep > 0 {
        thor_close_file(thor, 0)
        keep -= 1
    }
}

@(private = "file")
thor_menu_close_terminal :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_terminal_close(thor, thor.menu_target_terminal)
}

thor_menu_cut :: proc(data: rawptr) {editview.editor_cut(thor_active_editor(cast(^Thor) data))}
thor_menu_copy :: proc(data: rawptr) {editview.editor_copy(thor_active_editor(cast(^Thor) data))}
thor_menu_paste :: proc(data: rawptr) {editview.editor_paste(thor_active_editor(cast(^Thor) data))}

thor_menu_console_clear :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor_active_console(thor) != nil {
        thor_console_clear(thor_active_console(thor))
    }
}

thor_menu_console_copy :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor_active_console(thor) != nil {
        thor_console_copy_all(thor_active_console(thor))
    }
}

thor_menu_console_copy_selection :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor_active_console(thor) != nil {
        thor_console_copy(thor_active_console(thor))
    }
}

thor_menu_console_paste :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor_active_console(thor) != nil {
        thor_console_paste(thor_active_console(thor))
    }
}

// Open the shared name prompt into menu_target (the right-clicked directory).
// Command-palette entries reset the target to the workspace root first.
thor_menu_new_file :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_palette_prompt(thor, "New file name", thor_prompt_new_file, thor)
}

thor_menu_new_folder :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_palette_prompt(thor, "New folder name", thor_prompt_new_folder, thor)
}

thor_menu_explorer_refresh :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_explorer_refresh(thor)
    thor_refresh_git_status(thor)
}

// Explorer right-click Rename: the right-clicked row is the current selection.
thor_menu_rename :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_begin_rename(thor, thor_explorer_selected(thor))
}

// Explorer right-click Delete: acts on the right-clicked row, or on the whole
// selection when that row is part of one.
thor_menu_explorer_delete :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_tree_delete(thor, thor_explorer_selected(thor))
}

// Explorer right-click on a folder: open it in its own window, leaving this one
// on the current workspace. Skips the this-window/new-window prompt — the entry
// already says which it is.
thor_menu_open_new_window :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_new_window_for(thor, thor_explorer_selected(thor))
}

thor_menu_explorer_reveal :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if !thor_reveal_path(thor_explorer_selected(thor)) {
        thor_flash_status(thor, "Could not open the file explorer", true)
    }
}

thor_menu_explorer_copy_path :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor_explorer_selected(thor) != "" {
        rl.SetClipboardText(strings.clone_to_cstring(thor_explorer_selected(thor), context.temp_allocator))
    }
}


// Command-palette / top-bar entry points: create relative to the workspace
// root (the explorer right-click sets a more specific target itself).
thor_cmd_new_file :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_set_menu_target(thor, thor.workspace_dir)
    thor_menu_new_file(data)
}

thor_cmd_new_folder :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_set_menu_target(thor, thor.workspace_dir)
    thor_menu_new_folder(data)
}

// Top-bar File menu / command palette / F2: rename the explorer's selection when
// the tree is focused, otherwise the active tab's file.
thor_cmd_rename_file :: proc(data: rawptr) {
    thor := cast(^Thor) data
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
    thor := cast(^Thor) data
    name := strings.trim_space(name)
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
    thor := cast(^Thor) data
    name := strings.trim_space(name)
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
    thor := cast(^Thor) data
    thor_menu_clear(thor)
    thor_menu_add(thor, "Open File...", thor_cmd_open_file, thor)
    thor_menu_add(thor, "Open Folder...", thor_cmd_open_folder, thor)
    thor_menu_add(thor, "Open Folder in New Window...", thor_cmd_open_folder_new_window, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "New File", thor_cmd_new_file, thor)
    thor_menu_add(thor, "New Folder", thor_cmd_new_folder, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Save", thor_cmd_save, thor)
    thor_menu_add(thor, "Save All", thor_cmd_save_all, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Rename File", thor_cmd_rename_file, thor, thor_active_open_file(thor) != nil)
    thor_menu_add(thor, "Close Tab", thor_cmd_close_tab, thor)
    thor_menu_add(thor, "Close All Tabs", thor_cmd_close_all, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Close Workspace", thor_cmd_close_workspace, thor, thor.workspace_dir != "")
    thor_menu_open(thor, thor.menu_anchor)
}

thor_open_edit_menu :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_menu_clear(thor)
    thor_menu_add(thor, "Undo", thor_cmd_undo, thor, thor_can_undo(thor), UNDO_SHORTCUT)
    thor_menu_add(thor, "Redo", thor_cmd_redo, thor, thor_can_redo(thor), REDO_SHORTCUT)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Select All", thor_cmd_select_all, thor)
    thor_menu_add(thor, "Toggle Line Comment", thor_cmd_toggle_comment, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Duplicate Line", thor_cmd_duplicate_line, thor)
    thor_menu_add(thor, "Delete Line", thor_cmd_delete_line, thor)
    thor_menu_add(thor, "Move Line Up", thor_cmd_move_line_up, thor)
    thor_menu_add(thor, "Move Line Down", thor_cmd_move_line_down, thor)
    thor_menu_add(thor, "Trim Trailing Whitespace", thor_cmd_trim_whitespace, thor)
    thor_menu_add(thor, "Format Document", thor_cmd_format_document, thor)
    thor_menu_add(thor, "Format Selection", thor_cmd_format_selection, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Find", thor_cmd_find, thor)
    thor_menu_add(thor, "Replace", thor_cmd_replace, thor)
    thor_menu_open(thor, thor.menu_anchor)
}

thor_open_view_menu :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_menu_clear(thor)
    thor_menu_add(thor, "Toggle Explorer", thor_cmd_toggle_explorer, thor)
    thor_menu_add(thor, "Toggle Console", thor_cmd_toggle_console, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Zoom In", thor_cmd_zoom_in, thor)
    thor_menu_add(thor, "Zoom Out", thor_cmd_zoom_out, thor)
    thor_menu_add(thor, "Reset Zoom", thor_cmd_zoom_reset, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Toggle Word Wrap", thor_cmd_toggle_wrap, thor)
    thor_menu_add(thor, "Toggle Whitespace", thor_cmd_toggle_whitespace, thor)
    thor_menu_add(thor, "Toggle Split Editor", thor_cmd_toggle_split, thor)
    thor_menu_add(thor, "Toggle Fullscreen", thor_cmd_toggle_fullscreen, thor)
    thor_menu_open(thor, thor.menu_anchor)
}

thor_open_git_menu :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_menu_clear(thor)
    thor_menu_add(thor, "Changes", thor_cmd_open_git_view, thor)
    thor_menu_add(thor, "History", thor_cmd_open_git_history, thor)
    thor_menu_add(thor, "Branches", thor_cmd_open_git_branches, thor)
    thor_menu_open(thor, thor.menu_anchor)
}

thor_open_help_menu :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_menu_clear(thor)
    thor_menu_add(thor, "Tutorial", thor_cmd_tutorial, thor)
    thor_menu_add(thor, "Command Palette", thor_cmd_command_palette, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Documentation", thor_cmd_docs, thor)
    thor_menu_add(thor, "Documentation Page...", thor_cmd_docs_page, thor)
    thor_menu_add(thor, "Documentation in Browser", thor_cmd_docs_browser, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Check for Updates", thor_cmd_check_for_updates, thor)
    thor_menu_add_separator(thor)
    thor_menu_add(thor, "Settings", thor_cmd_open_settings_gui, thor)
    thor_menu_add(thor, "Language Servers", thor_cmd_open_language_servers, thor)
    thor_menu_add(thor, "Open Keybinds (JSON)", thor_cmd_open_keybinds, thor)
    thor_menu_add(thor, "Open Settings (JSON)", thor_cmd_open_settings, thor)
    thor_menu_open(thor, thor.menu_anchor)
}
