package thor

// The welcome page: shown in place of the editor while thor.workspace_dir is
// "". Reachable at startup (no CLI path, no last session) or via "Close
// Workspace", which tears a workspace down without replacing it.

import "core:log"
import "core:path/filepath"
import "core:strings"

import "../ui"
import "../widgets"

// Boxed click data for one recent-workspace row: the button callback only
// carries one rawptr, so the row's path rides along with the owning Thor.
Welcome_Recent_Entry :: struct {
    thor: ^Thor,
    path: string, // owned
}

// Tears down the current workspace and returns to the welcome page: the
// teardown half of thor_open_folder, without opening a replacement. A later
// bare launch goes back to the welcome page too, since the last-workspace
// record is cleared at the end.
thor_close_workspace :: proc(thor: ^Thor) {
    thor_unregister_window(thor.workspace_dir)

    thor_cmd_save_all(thor)
    thor_drain_io(thor)
    thor_save_session(thor)
    thor_shutdown_watcher(thor)

    for len(thor.open_files) > 0 {
        thor_close_file(thor, 0)
    }
    thor_drain_io(thor)
    thor_set_active_file(thor, -1)
    thor_clear_git_status(thor)
    thor_clear_file_index(thor)
    thor.pending_goto_active = false
    delete(thor.pending_goto_path)
    thor.pending_goto_path = ""
    thor_clear_jump_list(thor)
    thor_clear_tasks(thor)
    thor_sync_task_selector(thor)

    delete(thor.workspace_dir)
    delete(thor.workspace_prefix)
    delete(thor.git_branch)
    delete(thor.git_prefix)
    thor.workspace_dir = ""
    thor.workspace_prefix = ""
    thor.git_branch = ""
    thor.git_prefix = ""
    // thor_refresh_file_index no-ops on the empty workspace, which is right
    // for the welcome page — there is nothing to index.

    // The workspace's .thor/ overlay and plugins no longer apply.
    thor_reload_settings(thor)
    thor_reload_plugins(thor)

    widgets.tree_set_root(thor.tree, "")
    // The palette holds the prefix by reference and the old one was just freed.
    widgets.command_palette_set_navigation(
        thor.command_palette,
        thor_palette_list_files,
        thor_palette_open_file,
        thor_palette_goto_line,
        thor.workspace_prefix,
        thor,
    )

    thor_welcome_refresh_recent(thor)
    thor_apply_layout_state(thor) // hides explorer/console, shows the welcome page
    thor_record_last_workspace("") // a bare launch later goes to the welcome page

    log.infof("Closed workspace")
}

// File menu / palette: close the current workspace, if any.
thor_cmd_close_workspace :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if thor.workspace_dir == "" {
        return
    }
    thor_close_workspace(thor)
}

// Welcome page: pick a folder to open as the workspace.
thor_welcome_open_folder :: proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget) {
    thor_cmd_open_folder(data)
}

// Welcome page: pick a file anywhere on disk and make its folder the
// workspace, mirroring the CLI single-file launch case.
thor_welcome_open_file :: proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget) {
    thor := cast(^Thor) data
    if path, ok := thor_pick_file("Open File", ""); ok {
        defer delete(path)
        thor_open_folder(thor, filepath.dir(path))
        thor_open_file(thor, path)
    }
}

// Welcome page: open a row from the recent-workspaces list.
thor_welcome_open_recent :: proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget) {
    entry := cast(^Welcome_Recent_Entry) data
    thor_open_folder_request(entry.thor, entry.path)
}

// Frees the recent-row click data (owned paths and the boxed entries), without
// touching the row widgets. Shared by a refresh (which destroys the widgets
// itself, in step with the entries) and shutdown (where ui.context_destroy
// already destroys the widget tree, so only the entries are left to free).
thor_welcome_clear_recent_entries :: proc(thor: ^Thor) {
    for entry in thor.welcome_recent_entries {
        delete(entry.path)
        free(entry)
    }
    clear(&thor.welcome_recent_entries)
}

// Rebuilds the recent-workspaces list: destroys the previous rows and their
// click data, then appends one button per thor_recent_workspaces() entry.
// Called once at startup (thor_build_content) and again after closing a
// workspace, so the list always reflects the folder just left.
thor_welcome_refresh_recent :: proc(thor: ^Thor) {
    child := thor.welcome_recent_stack.first_child
    for child != nil {
        next := child.next_sibling
        ui.context_forget(&thor.ui_context, child)
        ui.widget_remove_child(child)
        ui.widget_destroy_tree(child)
        child = next
    }
    thor_welcome_clear_recent_entries(thor)

    for path in thor_recent_workspaces(context.temp_allocator) {
        entry := new(Welcome_Recent_Entry)
        entry.thor = thor
        entry.path = strings.clone(path)
        append(&thor.welcome_recent_entries, entry)

        row := widgets.button_create("welcome-recent-row", filepath.base(entry.path))
        widgets.button_set_colors(row, thor.theme.primary_text_color, thor.theme.buttons, thor.theme.highlight, thor.theme.active, thor.theme.border)
        widgets.button_set_on_click(row, thor_welcome_open_recent, entry)
        row.min_size = {0, 36}
        widgets.append_child(&thor.welcome_recent_stack.widget, &row.widget)
    }
}
