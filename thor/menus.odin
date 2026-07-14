package thor

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
    widgets.console_set_on_context_menu(thor.console, thor_console_context_menu, thor)
    widgets.tree_set_on_context_menu(thor.tree, thor_explorer_context_menu, thor)
    widgets.tree_set_on_delete(thor.tree, thor_tree_delete, thor)

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

// ---------------------------------------------------------------------------
// Context menus
// ---------------------------------------------------------------------------

thor_editor_context_menu :: proc(data: rawptr, position: rl.Vector2) {
    thor := cast(^Thor) data
    has_file := thor_active_open_file(thor) != nil

    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Cut", thor_menu_cut, thor, has_file)
    widgets.menu_add(thor.menu, "Copy", thor_menu_copy, thor, has_file)
    widgets.menu_add(thor.menu, "Paste", thor_menu_paste, thor, has_file)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Select All", thor_cmd_select_all, thor, has_file)
    widgets.menu_open(thor.menu, &thor.ui_context, position)
}

thor_console_context_menu :: proc(data: rawptr, position: rl.Vector2) {
    thor := cast(^Thor) data
    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Copy All", thor_menu_console_copy, thor)
    widgets.menu_add(thor.menu, "Paste", thor_menu_console_paste, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Clear", thor_menu_console_clear, thor)
    widgets.menu_open(thor.menu, &thor.ui_context, position)
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

    has_selection := widgets.tree_path_at(thor.tree, position) != ""

    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "New File", thor_menu_new_file, thor)
    widgets.menu_add(thor.menu, "New Folder", thor_menu_new_folder, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Reveal in File Explorer", thor_menu_explorer_reveal, thor, has_selection)
    widgets.menu_add(thor.menu, "Copy Path", thor_menu_explorer_copy_path, thor, has_selection)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Refresh", thor_menu_explorer_refresh, thor)
    widgets.menu_open(thor.menu, &thor.ui_context, position)
}

// ---------------------------------------------------------------------------
// Editor menu actions
// ---------------------------------------------------------------------------

thor_menu_cut :: proc(data: rawptr) {widgets.editor_cut((cast(^Thor) data).editor)}
thor_menu_copy :: proc(data: rawptr) {widgets.editor_copy((cast(^Thor) data).editor)}
thor_menu_paste :: proc(data: rawptr) {widgets.editor_paste((cast(^Thor) data).editor)}

// ---------------------------------------------------------------------------
// Console menu actions
// ---------------------------------------------------------------------------

thor_menu_console_clear :: proc(data: rawptr) {widgets.console_clear((cast(^Thor) data).console)}

thor_menu_console_copy :: proc(data: rawptr) {
    thor := cast(^Thor) data
    text := widgets.console_text(thor.console)
    if text != "" {
        rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
    }
}

thor_menu_console_paste :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if clip := rl.GetClipboardText(); clip != nil {
        widgets.console_input_append(thor.console, string(clip))
    }
}

// ---------------------------------------------------------------------------
// Explorer menu actions
// ---------------------------------------------------------------------------

// menu_target holds the right-clicked path's directory; these open the shared
// name prompt into it. Command-palette entries reset the target to the
// workspace root first (see thor_cmd_new_file / thor_cmd_new_folder).
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

thor_menu_explorer_reveal :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_reveal_path(thor.tree.selected_path)
}

thor_menu_explorer_copy_path :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.tree.selected_path != "" {
        rl.SetClipboardText(strings.clone_to_cstring(thor.tree.selected_path, context.temp_allocator))
    }
}

// ---------------------------------------------------------------------------
// New File / New Folder prompt handlers
// ---------------------------------------------------------------------------

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

thor_prompt_new_file :: proc(data: rawptr, name: string) {
    thor := cast(^Thor) data
    path, _ := filepath.join({thor.menu_target_dir, name}, context.temp_allocator)
    if !os.exists(path) {
        _ = os.write_entire_file(path, []byte{})
        widgets.tree_refresh(thor.tree)
        thor_refresh_git_status(thor)
    }
    thor_open_file(thor, path)
}

thor_prompt_new_folder :: proc(data: rawptr, name: string) {
    thor := cast(^Thor) data
    path, _ := filepath.join({thor.menu_target_dir, name}, context.temp_allocator)
    if !os.exists(path) {
        os.make_directory(path)
        widgets.tree_refresh(thor.tree)
    }
}

// ---------------------------------------------------------------------------
// Top-bar dropdown menus
// ---------------------------------------------------------------------------

// Opens `menu` just below `button` (a top-bar menu button).
@(private = "file")
thor_open_dropdown :: proc(thor: ^Thor, button: ^widgets.Button) {
    anchor := rl.Vector2 {button.bounds.x, button.bounds.y + button.bounds.height}
    widgets.menu_open(thor.menu, &thor.ui_context, anchor)
}

thor_open_file_menu :: proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget) {
    thor := cast(^Thor) data
    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "New File", thor_cmd_new_file, thor)
    widgets.menu_add(thor.menu, "New Folder", thor_cmd_new_folder, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Save", thor_cmd_save, thor)
    widgets.menu_add(thor.menu, "Save All", thor_cmd_save_all, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Close Tab", thor_cmd_close_tab, thor)
    widgets.menu_add(thor.menu, "Close All Tabs", thor_cmd_close_all, thor)
    thor_open_dropdown(thor, thor.menu_file_button)
}

thor_open_edit_menu :: proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget) {
    thor := cast(^Thor) data
    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Select All", thor_cmd_select_all, thor)
    widgets.menu_add(thor.menu, "Toggle Line Comment", thor_cmd_toggle_comment, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Duplicate Line", thor_cmd_duplicate_line, thor)
    widgets.menu_add(thor.menu, "Delete Line", thor_cmd_delete_line, thor)
    widgets.menu_add(thor.menu, "Move Line Up", thor_cmd_move_line_up, thor)
    widgets.menu_add(thor.menu, "Move Line Down", thor_cmd_move_line_down, thor)
    widgets.menu_add(thor.menu, "Trim Trailing Whitespace", thor_cmd_trim_whitespace, thor)
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
    widgets.menu_add(thor.menu, "Toggle Fullscreen", thor_cmd_toggle_fullscreen, thor)
    thor_open_dropdown(thor, thor.menu_view_button)
}

thor_open_help_menu :: proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget) {
    thor := cast(^Thor) data
    widgets.menu_clear(thor.menu)
    widgets.menu_add(thor.menu, "Tutorial", thor_cmd_tutorial, thor)
    widgets.menu_add(thor.menu, "Command Palette", thor_cmd_command_palette, thor)
    widgets.menu_add_separator(thor.menu)
    widgets.menu_add(thor.menu, "Open Keybinds", thor_cmd_open_keybinds, thor)
    widgets.menu_add(thor.menu, "Open Settings", thor_cmd_open_settings, thor)
    thor_open_dropdown(thor, thor.menu_help_button)
}
