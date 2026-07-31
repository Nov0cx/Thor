package thor

// Opening folders and files from outside the editor: the launch path argument,
// the File menu pickers and drag-and-drop all land here. Switching folders
// rebuilds everything that is workspace-scoped — the config overlay, the
// explorer root, git status, the file watcher and the per-workspace session.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

import "../ui"
import "../widgets"

// Splits a launch argument into the workspace folder (owned) and the file to
// open (owned, "" for a folder argument): a file's folder becomes the
// workspace, "." the launch directory. A path that does not exist falls back to
// the launch directory.
thor_startup_target :: proc(arg: string) -> (workspace: string, file: string) {
    target := arg
    if abs, err := filepath.abs(arg, context.temp_allocator); err == nil {
        target = abs
    }
    switch {
    case os.is_dir(target):
        return strings.clone(target), ""
    case os.is_file(target):
        return strings.clone(filepath.dir(target)), strings.clone(target)
    }

    log.warnf("Path %q does not exist; opening the launch directory instead", arg)
    cwd, cwd_err := os.get_working_directory(context.allocator)
    return cwd_err == nil ? cwd : strings.clone("."), ""
}

// Opens a path from outside the editor: a directory becomes the workspace, a
// file opens as a tab.
thor_open_path :: proc(thor: ^Thor, path: string) {
    if os.is_dir(path) {
        thor_open_folder(thor, path)
    } else {
        thor_open_file(thor, path)
    }
}

// Makes `dir` the workspace. The outgoing folder's dirty buffers and session are
// flushed first, then every workspace-scoped piece is repointed and the new
// folder's own session restored. A path that is not a directory is ignored.
thor_open_folder :: proc(thor: ^Thor, dir: string) {
    resolved := dir
    if abs, err := filepath.abs(dir, context.temp_allocator); err == nil {
        resolved = abs
    }
    if !os.is_dir(resolved) {
        thor_flash_status(thor, "Not a folder", true)
        return
    }
    if strings.equal_fold(resolved, thor.workspace_dir) {
        return
    }
    // Owned: the flush below drains I/O, which frees the temp allocator that
    // `resolved` may still live in.
    target := strings.clone(resolved)
    defer delete(target)

    // Let the outgoing workspace go quiet before anything is swapped: a worker
    // thread must not outlive the state it points at.
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
    thor.pending_goto_active = false
    delete(thor.pending_goto_path)
    thor.pending_goto_path = ""
    thor_clear_jump_list(thor)

    delete(thor.workspace_dir)
    delete(thor.workspace_prefix)
    delete(thor.git_branch)
    thor.workspace_dir = strings.clone(target)
    thor.workspace_prefix = strings.concatenate({thor.workspace_dir, "\\"})
    thor.git_branch = thor_read_git_branch(thor.workspace_dir)

    // The new folder's .thor/ overlay can change theme, font and keybinds.
    thor_reload_settings(thor)

    widgets.tree_set_root(thor.tree, thor.workspace_dir)
    // The palette holds the prefix by reference and the old one was just freed.
    widgets.command_palette_set_navigation(
        thor.command_palette,
        thor_palette_list_files,
        thor_palette_open_file,
        thor_palette_goto_line,
        thor.workspace_prefix,
        thor,
    )

    thor_restore_session(thor)
    thor_apply_layout_state(thor)
    thor_apply_split(thor)
    if thor.split_visible {
        thor_bind_pane(thor, 1)
    }
    thor_refresh_git_status(thor)
    thor_init_watcher(thor)
    thor_record_last_workspace(thor.workspace_dir)
    log.infof("Opened workspace %s", thor.workspace_dir)
}

// Run-loop tick: what a drop from Explorer means depends on where it landed.
// Over the file tree it copies into the hovered folder; anywhere else a file
// opens as a tab and a folder becomes the workspace. A path that already sits in
// the hovered folder has nothing to copy and falls back to opening, so a drop
// never comes up silently empty.
thor_poll_dropped_files :: proc(thor: ^Thor) {
    if !rl.IsFileDropped() {
        return
    }
    dropped := rl.LoadDroppedFiles()
    defer rl.UnloadDroppedFiles(dropped)

    // GLFW feeds the drop point through the cursor-position callback before it
    // fires the drop itself, so raylib's cursor is the release point here even
    // though the shell swallowed every mouse-move during the drag.
    dst_dir: string
    over_tree := false
    if ui.signal_get(&thor.explorer_visible) {
        dst_dir, over_tree = widgets.tree_drop_target_at(thor.tree, rl.GetMousePosition())
    }

    copied := 0
    for index in 0 ..< dropped.count {
        path := string(dropped.paths[index])

        if over_tree {
            switch thor_import_path(thor, path, dst_dir) {
            case .Copied:
                copied += 1
                continue
            case .Failed:
                continue // thor_import_path already flashed the reason
            case .Already_There:
                // Fall through and open it instead.
            }
        }

        if os.is_dir(path) {
            thor_open_folder(thor, path) // replaces the workspace; the rest of the drop is moot
            return
        }
        thor_open_file(thor, path)
    }

    if copied > 0 {
        widgets.tree_refresh(thor.tree)
        thor_refresh_git_status(thor)
        noun := copied == 1 ? "item" : "items"
        thor_flash_status(thor, fmt.tprintf("Copied %d %s into %s", copied, noun, filepath.base(dst_dir)))
    }
}

// File menu / palette: pick a folder to open as the workspace.
thor_cmd_open_folder :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if dir, ok := thor_pick_folder("Open Folder", thor.workspace_dir); ok {
        defer delete(dir)
        thor_open_folder(thor, dir)
    }
}

// File menu / palette: pick a file to open as a tab, from anywhere on disk.
thor_cmd_open_file :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if path, ok := thor_pick_file("Open File", thor.workspace_dir); ok {
        defer delete(path)
        thor_open_file(thor, path)
    }
}
