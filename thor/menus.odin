package thor

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

import "../ui"
import "../widgets"

// Attaches the right-click context menus and the top-bar dropdown openers.
// Called once during startup after the widget tree is built.
thor_wire_menus :: proc(thor: ^Thor) {
    widgets.editor_set_on_context_menu(thor.editor, thor_editor_context_menu, thor)
    widgets.editor_set_on_context_menu(thor.editor2, thor_editor_context_menu, thor)
    widgets.tree_set_on_context_menu(thor.tree, thor_explorer_context_menu, thor)
    widgets.tree_set_on_delete(thor.tree, thor_tree_delete, thor)
    widgets.tree_set_on_move(thor.tree, thor_tree_move, thor)
    widgets.tree_set_on_drag_out(thor.tree, thor_tree_drag_out, thor)
    widgets.tabbar_set_on_context_menu(thor.tabbar, thor_tab_context_menu, thor)
    widgets.tabstrip_set_on_context_menu(thor.terminal_tabs, thor_terminal_tab_context_menu, thor)

    widgets.button_set_on_click(thor.menu_file_button, thor_open_file_menu, thor)
    widgets.button_set_on_click(thor.menu_edit_button, thor_open_edit_menu, thor)
    widgets.button_set_on_click(thor.menu_view_button, thor_open_view_menu, thor)
    widgets.button_set_on_click(thor.menu_help_button, thor_open_help_menu, thor)
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

thor_editor_context_menu :: proc(data: rawptr, position: rl.Vector2) {
    thor := cast(^Thor) data
    // The right-click focused its pane before this callback, but menu_open takes
    // focus next, so the frame's own thor_sync_active_pane would never see it.
    thor_sync_active_pane(thor)
    has_file := thor_active_open_file(thor) != nil

    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Undo", thor_cmd_undo, thor, thor_can_undo(thor), UNDO_SHORTCUT)
    widgets.menu_add(thor.menu, "Redo", thor_cmd_redo, thor, thor_can_redo(thor), REDO_SHORTCUT)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Cut", thor_menu_cut, thor, has_file)
    widgets.menu_add(thor.menu, "Copy", thor_menu_copy, thor, has_file)
    widgets.menu_add(thor.menu, "Paste", thor_menu_paste, thor, has_file)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Select All", thor_cmd_select_all, thor, has_file)
    widgets.menu_open(thor.menu, &thor.ui_context, position)
}

thor_console_context_menu :: proc(data: rawptr, position: rl.Vector2) {
    thor := cast(^Thor) data
    term := thor_active_terminal(thor)
    has_selection := term != nil && widgets.console_has_selection(term.console)
    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Copy", thor_menu_console_copy_selection, thor, has_selection)
    widgets.menu_add(thor.menu, "Copy All", thor_menu_console_copy, thor)
    widgets.menu_add(thor.menu, "Paste", thor_menu_console_paste, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Clear", thor_menu_console_clear, thor)
    widgets.menu_add(thor.menu, "Restart Shell", thor_menu_terminal_restart, thor, term != nil)
    widgets.menu_add(thor.menu, "New Terminal", thor_cmd_new_terminal, thor)
    widgets.menu_add(thor.menu, "Close Terminal", thor_cmd_close_terminal, thor, term != nil)
    widgets.menu_open(thor.menu, &thor.ui_context, position)
}

@(private = "file")
thor_menu_terminal_restart :: proc(data: rawptr) {
    if term := thor_active_terminal(cast(^Thor) data); term != nil {
        thor_terminal_restart(term)
    }
}

thor_explorer_context_menu :: proc(data: rawptr, position: rl.Vector2) {
    thor := cast(^Thor) data

    // Create into the clicked folder, the clicked file's folder, or (empty
    // space) the workspace root.
    target := thor.workspace_dir
    if path := widgets.tree_path_at(thor.tree, position); path != "" {
        if os.is_dir(path) {
            target = path
        } else {
            target = filepath.dir(path) // borrowed substring of path
        }
    }
    thor_set_menu_target(thor, target)

    // A right-click selects the row first (see tree_handle_event), so Rename and
    // the other selection actions read thor.tree.selected_path.
    clicked := widgets.tree_path_at(thor.tree, position)
    has_selection := clicked != ""
    on_folder := has_selection && os.is_dir(clicked)

    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "New File", thor_menu_new_file, thor)
    widgets.menu_add(thor.menu, "New Folder", thor_menu_new_folder, thor)
    if on_folder {
        widgets.menu_add_separator(thor.menu)
        widgets.menu_add(thor.menu, "Open in New Window", thor_menu_open_new_window, thor)
    }
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Rename", thor_menu_rename, thor, has_selection)
    widgets.menu_add(thor.menu, "Reveal in File Explorer", thor_menu_explorer_reveal, thor, has_selection)
    widgets.menu_add(thor.menu, "Copy Path", thor_menu_explorer_copy_path, thor, has_selection)
    widgets.menu_add(thor.menu, "Delete", thor_menu_explorer_delete, thor, has_selection)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Refresh", thor_menu_explorer_refresh, thor)
    widgets.menu_open(thor.menu, &thor.ui_context, position)
}

thor_tab_context_menu :: proc(data: rawptr, position: rl.Vector2) {
    thor := cast(^Thor) data
    index := widgets.tabbar_tab_at(thor.tabbar, position)
    if index < 0 {
        return
    }
    thor.menu_target_tab = index

    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Close", thor_menu_close_tab, thor)
    widgets.menu_add(thor.menu, "Close Others", thor_menu_close_other_tabs, thor, len(thor.open_files) > 1)
    widgets.menu_add(thor.menu, "Close All", thor_cmd_close_all, thor)
    widgets.menu_open(thor.menu, &thor.ui_context, position)
}

thor_terminal_tab_context_menu :: proc(data: rawptr, position: rl.Vector2) {
    thor := cast(^Thor) data
    index := widgets.tabstrip_tab_at(thor.terminal_tabs, position)
    if index < 0 {
        return
    }
    thor.menu_target_terminal = index

    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Close", thor_menu_close_terminal, thor)
    widgets.menu_add(thor.menu, "Close All", thor_cmd_close_all_terminals, thor)
    widgets.menu_open(thor.menu, &thor.ui_context, position)
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

thor_menu_cut :: proc(data: rawptr) {widgets.editor_cut(thor_active_editor(cast(^Thor) data))}
thor_menu_copy :: proc(data: rawptr) {widgets.editor_copy(thor_active_editor(cast(^Thor) data))}
thor_menu_paste :: proc(data: rawptr) {widgets.editor_paste(thor_active_editor(cast(^Thor) data))}

thor_menu_console_clear :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.console != nil {
        widgets.console_clear(thor.console)
    }
}

thor_menu_console_copy :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.console != nil {
        widgets.console_copy_all(thor.console)
    }
}

thor_menu_console_copy_selection :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.console != nil {
        widgets.console_copy(thor.console)
    }
}

thor_menu_console_paste :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.console != nil {
        widgets.console_paste(thor.console)
    }
}

// Open the shared name prompt into menu_target (the right-clicked directory).
// Command-palette entries reset the target to the workspace root first.
thor_menu_new_file :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.command_palette_prompt(thor.command_palette, &thor.ui_context, "New file name", thor_prompt_new_file, thor)
}

thor_menu_new_folder :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.command_palette_prompt(thor.command_palette, &thor.ui_context, "New folder name", thor_prompt_new_folder, thor)
}

thor_menu_explorer_refresh :: proc(data: rawptr) {
    thor := cast(^Thor) data
    widgets.tree_refresh(thor.tree)
    thor_refresh_git_status(thor)
}

// Explorer right-click Rename: the right-clicked row is the current selection.
thor_menu_rename :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_begin_rename(thor, thor.tree.selected_path)
}

// Explorer right-click Delete: acts on the right-clicked row, or on the whole
// selection when that row is part of one.
thor_menu_explorer_delete :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_tree_delete(thor, thor.tree.selected_path)
}

// Explorer right-click on a folder: open it in its own window, leaving this one
// on the current workspace. Skips the this-window/new-window prompt — the entry
// already says which it is.
thor_menu_open_new_window :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_new_window_for(thor, thor.tree.selected_path)
}

thor_menu_explorer_reveal :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if !thor_reveal_path(thor.tree.selected_path) {
        thor_flash_status(thor, "Could not open the file explorer", true)
    }
}

thor_menu_explorer_copy_path :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.tree.selected_path != "" {
        rl.SetClipboardText(strings.clone_to_cstring(thor.tree.selected_path, context.temp_allocator))
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
    if thor.ui_context.focused == &thor.tree.widget && thor.tree.selected_path != "" {
        thor_begin_rename(thor, thor.tree.selected_path)
        return
    }
    if file := thor_active_open_file(thor); file != nil {
        thor_begin_rename(thor, file.path)
    }
}

thor_prompt_new_file :: proc(data: rawptr, name: string) {
    thor := cast(^Thor) data
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
        widgets.tree_refresh(thor.tree)
        thor_refresh_git_status(thor)
    }
    thor_open_file(thor, path)
}

thor_prompt_new_folder :: proc(data: rawptr, name: string) {
    thor := cast(^Thor) data
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
        widgets.tree_refresh(thor.tree)
    }
}

// Opens `menu` just below `button` (a top-bar menu button).
@(private = "file")
thor_open_dropdown :: proc(thor: ^Thor, button: ^widgets.Button) {
    anchor := rl.Vector2 {button.bounds.x, button.bounds.y + button.bounds.height}
    widgets.menu_open(thor.menu, &thor.ui_context, anchor)
}

thor_open_file_menu :: proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget) {
    thor := cast(^Thor) data
    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Open File...", thor_cmd_open_file, thor)
    widgets.menu_add(thor.menu, "Open Folder...", thor_cmd_open_folder, thor)
    widgets.menu_add(thor.menu, "Open Folder in New Window...", thor_cmd_open_folder_new_window, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "New File", thor_cmd_new_file, thor)
    widgets.menu_add(thor.menu, "New Folder", thor_cmd_new_folder, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Save", thor_cmd_save, thor)
    widgets.menu_add(thor.menu, "Save All", thor_cmd_save_all, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Rename File", thor_cmd_rename_file, thor, thor_active_open_file(thor) != nil)
    widgets.menu_add(thor.menu, "Close Tab", thor_cmd_close_tab, thor)
    widgets.menu_add(thor.menu, "Close All Tabs", thor_cmd_close_all, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Close Workspace", thor_cmd_close_workspace, thor, thor.workspace_dir != "")
    thor_open_dropdown(thor, thor.menu_file_button)
}

thor_open_edit_menu :: proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget) {
    thor := cast(^Thor) data
    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Undo", thor_cmd_undo, thor, thor_can_undo(thor), UNDO_SHORTCUT)
    widgets.menu_add(thor.menu, "Redo", thor_cmd_redo, thor, thor_can_redo(thor), REDO_SHORTCUT)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Select All", thor_cmd_select_all, thor)
    widgets.menu_add(thor.menu, "Toggle Line Comment", thor_cmd_toggle_comment, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Duplicate Line", thor_cmd_duplicate_line, thor)
    widgets.menu_add(thor.menu, "Delete Line", thor_cmd_delete_line, thor)
    widgets.menu_add(thor.menu, "Move Line Up", thor_cmd_move_line_up, thor)
    widgets.menu_add(thor.menu, "Move Line Down", thor_cmd_move_line_down, thor)
    widgets.menu_add(thor.menu, "Trim Trailing Whitespace", thor_cmd_trim_whitespace, thor)
    widgets.menu_add(thor.menu, "Format Document", thor_cmd_format_document, thor)
    widgets.menu_add(thor.menu, "Format Selection", thor_cmd_format_selection, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Find", thor_cmd_find, thor)
    widgets.menu_add(thor.menu, "Replace", thor_cmd_replace, thor)
    thor_open_dropdown(thor, thor.menu_edit_button)
}

thor_open_view_menu :: proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget) {
    thor := cast(^Thor) data
    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Toggle Explorer", thor_cmd_toggle_explorer, thor)
    widgets.menu_add(thor.menu, "Toggle Console", thor_cmd_toggle_console, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Zoom In", thor_cmd_zoom_in, thor)
    widgets.menu_add(thor.menu, "Zoom Out", thor_cmd_zoom_out, thor)
    widgets.menu_add(thor.menu, "Reset Zoom", thor_cmd_zoom_reset, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Toggle Word Wrap", thor_cmd_toggle_wrap, thor)
    widgets.menu_add(thor.menu, "Toggle Whitespace", thor_cmd_toggle_whitespace, thor)
    widgets.menu_add(thor.menu, "Toggle Split Editor", thor_cmd_toggle_split, thor)
    widgets.menu_add(thor.menu, "Toggle Fullscreen", thor_cmd_toggle_fullscreen, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Git", thor_cmd_open_git_view, thor)
    thor_open_dropdown(thor, thor.menu_view_button)
}

thor_open_help_menu :: proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget) {
    thor := cast(^Thor) data
    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Tutorial", thor_cmd_tutorial, thor)
    widgets.menu_add(thor.menu, "Command Palette", thor_cmd_command_palette, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Documentation", thor_cmd_docs, thor)
    widgets.menu_add(thor.menu, "Documentation Page...", thor_cmd_docs_page, thor)
    widgets.menu_add(thor.menu, "Documentation in Browser", thor_cmd_docs_browser, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Check for Updates", thor_cmd_check_for_updates, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Settings", thor_cmd_open_settings_gui, thor)
    widgets.menu_add(thor.menu, "Open Keybinds (JSON)", thor_cmd_open_keybinds, thor)
    widgets.menu_add(thor.menu, "Open Settings (JSON)", thor_cmd_open_settings, thor)
    thor_open_dropdown(thor, thor.menu_help_button)
}
