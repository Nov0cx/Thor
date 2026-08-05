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

import "../setting"
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

// Opens a path from outside the editor: a directory goes through the
// this-window/new-window choice, a file opens as a tab.
thor_open_path :: proc(thor: ^Thor, path: string) {
    if os.is_dir(path) {
        thor_open_folder_request(thor, path)
    } else {
        thor_open_file(thor, path)
    }
}

// The picker rows, in order. Indices line up with Open_Folder_Choice.
@(private = "file")
OPEN_FOLDER_CHOICES := [?]string {
    "This Window",
    "New Window",
    "Always This Window",
    "Always New Window",
}

@(private = "file")
Open_Folder_Choice :: enum {
    This_Window,
    New_Window,
    Always_This_Window,
    Always_New_Window,
}

// Entry point for every user-driven folder open — the File menu, the palette, a
// dropped folder. Settles the cases that need no choice (the folder is already
// showing here, or another window holds it) and otherwise obeys open_folder_in,
// prompting when it says "ask". Direct calls to thor_open_folder skip all of
// this and replace the workspace outright.
thor_open_folder_request :: proc(thor: ^Thor, dir: string) {
    resolved := dir
    if abs, err := filepath.abs(dir, context.temp_allocator); err == nil {
        resolved = abs
    }
    if !os.is_dir(resolved) {
        thor_flash_status(thor, "Not a folder", true)
        return
    }
    if strings.equal_fold(resolved, thor.workspace_dir) {
        thor_flash_status(thor, "Already open in this window")
        return
    }
    // A folder open in another window is raised rather than opened twice: two
    // processes on one folder would fight over its session file.
    if hwnd, taken := thor_workspace_window(resolved); taken {
        thor_focus_window(hwnd)
        thor_flash_status(thor, fmt.tprintf("%s is already open in another window", filepath.base(resolved)))
        return
    }

    switch setting.open_folder_in(&thor.config) {
    case .Same:
        thor_open_folder(thor, resolved)
    case .New:
        thor_open_folder_in_new_window(thor, resolved)
    case .Ask:
        thor_prompt_open_folder(thor, resolved)
    }
}

// Opens the four-row picker for a folder that is free to go either way. The
// folder and the title are parked on Thor: the pick lands on a later frame.
@(private = "file")
thor_prompt_open_folder :: proc(thor: ^Thor, dir: string) {
    thor_clear_pending_open_folder(thor)
    thor.pending_open_folder = strings.clone(dir)
    thor.open_folder_prompt = fmt.aprintf("Open %s in", filepath.base(dir))

    widgets.command_palette_pick(
        thor.command_palette,
        &thor.ui_context,
        thor.open_folder_prompt,
        OPEN_FOLDER_CHOICES[:],
        thor_pick_open_folder,
        thor,
    )
}

// A row was picked. The two "Always" rows persist the choice first, then do the
// same thing their plain counterparts do.
@(private = "file")
thor_pick_open_folder :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    defer thor_clear_pending_open_folder(thor)

    if thor.pending_open_folder == "" {
        return
    }
    // Resolve the row before acting: opening a folder drains I/O, which frees
    // the temp allocator `choice` lives in.
    picked: Open_Folder_Choice
    found := false
    for label, index in OPEN_FOLDER_CHOICES {
        if label == choice {
            picked = cast(Open_Folder_Choice) index
            found = true
            break
        }
    }
    if !found {
        return
    }

    switch picked {
    case .Always_This_Window:
        thor_persist_open_folder_in(thor, .Same)
        fallthrough
    case .This_Window:
        thor_open_folder(thor, thor.pending_open_folder)
    case .Always_New_Window:
        thor_persist_open_folder_in(thor, .New)
        fallthrough
    case .New_Window:
        thor_open_folder_in_new_window(thor, thor.pending_open_folder)
    }
}

// Launches a second window on `dir`, reporting failure in the status bar rather
// than leaving the pick looking like it did nothing.
@(private = "file")
thor_open_folder_in_new_window :: proc(thor: ^Thor, dir: string) {
    if thor_spawn_window(dir) {
        thor_flash_status(thor, fmt.tprintf("Opened %s in a new window", filepath.base(dir)))
    } else {
        thor_flash_status(thor, "Could not start a new window", true)
    }
}

// Records a "don't ask again" choice. It goes to the global settings, never the
// workspace .thor/ overlay: which window a folder opens in is a personal
// preference, not something a checked-in workspace config imposes on everyone.
// Updates the live config in place rather than reloading — the caller is about
// to open a folder, which reloads anyway.
thor_persist_open_folder_in :: proc(thor: ^Thor, choice: setting.Open_Folder_In) {
    value := setting.open_folder_in_value(choice)
    setting.persist_string("settings/settings.json", "open_folder_in", value)
    delete(thor.config.general.open_folder_in)
    thor.config.general.open_folder_in = strings.clone(value)
    thor_settings_mark_clean(thor)
}

thor_clear_pending_open_folder :: proc(thor: ^Thor) {
    delete(thor.pending_open_folder)
    delete(thor.open_folder_prompt)
    thor.pending_open_folder = ""
    thor.open_folder_prompt = ""
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

    // Give up the outgoing folder's claim before taking the new one, so it is
    // free for another window the moment we stop showing it.
    thor_unregister_window(thor.workspace_dir)

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
    // ... and .thor/plugins/ carries plugins of its own. Reloaded before the
    // session restores any file, since the languages a plugin registers decide
    // how those files colour, and before the outgoing folder's plugins can see
    // the new workspace through thor.workspace().
    thor_reload_plugins(thor)

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
    thor_register_window(thor)
    thor_record_last_workspace(thor.workspace_dir)
    log.infof("Opened workspace %s", thor.workspace_dir)
}

// raylib 6.0 lays FilePathList out as {count, capacity, paths}, but the
// vendor:raylib binding still declares raylib 5's {capacity, count, paths}, so
// `count` there reads the wrong word and a drop looks empty. Reinterpreting the
// returned value is the whole fix; the bytes handed back to UnloadDroppedFiles
// are untouched.
@(private = "file")
Dropped_Files :: struct {
    count:    u32,
    capacity: u32,
    paths:    [^]cstring,
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
    files := transmute(Dropped_Files) dropped

    // GLFW feeds the drop point through the cursor-position callback before it
    // fires the drop itself, so raylib's cursor is the release point here even
    // though the shell swallowed every mouse-move during the drag.
    dst_dir: string
    over_tree := false
    if ui.signal_get(&thor.explorer_visible) {
        dst_dir, over_tree = widgets.tree_drop_target_at(thor.tree, rl.GetMousePosition())
    }
    log.debugf("Dropped %d path(s) at %v, folder %q", files.count, rl.GetMousePosition(), dst_dir)

    imports: [dynamic]File_Op_Entry
    folder := ""
    for index in 0 ..< files.count {
        path := string(files.paths[index])

        if over_tree {
            switch thor_queue_import(thor, &imports, path, dst_dir) {
            case .Queued:
                continue
            case .Failed:
                continue // thor_queue_import already flashed the reason
            case .Already_There:
                // Fall through and open it instead.
            }
        }

        if os.is_dir(path) {
            folder = path
            break
        }
        thor_open_file(thor, path)
    }

    // The copies run whatever the folder prompt answers, so they start first.
    thor_start_file_op(thor, .Copy, imports, dst_dir)
    if folder != "" {
        // Asks which window it goes to; either way the rest of the drop is moot.
        thor_open_folder_request(thor, folder)
    }
}

// File menu / palette: pick a folder to open as the workspace, in this window or
// a new one.
thor_cmd_open_folder :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if dir, ok := thor_pick_folder("Open Folder", thor.workspace_dir); ok {
        defer delete(dir)
        thor_open_folder_request(thor, dir)
    }
}

// File menu / palette: pick a folder and open it in a new window, no prompt.
thor_cmd_open_folder_new_window :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if dir, ok := thor_pick_folder("Open Folder in New Window", thor.workspace_dir); ok {
        defer delete(dir)
        thor_new_window_for(thor, dir)
    }
}

// Opens `dir` in a new window, raising the window that already holds it instead
// of starting a duplicate. Shared by the explorer entry and the File menu.
thor_new_window_for :: proc(thor: ^Thor, dir: string) {
    resolved := dir
    if abs, err := filepath.abs(dir, context.temp_allocator); err == nil {
        resolved = abs
    }
    if !os.is_dir(resolved) {
        thor_flash_status(thor, "Not a folder", true)
        return
    }
    if strings.equal_fold(resolved, thor.workspace_dir) {
        thor_flash_status(thor, "Already open in this window")
        return
    }
    if hwnd, taken := thor_workspace_window(resolved); taken {
        thor_focus_window(hwnd)
        thor_flash_status(thor, fmt.tprintf("%s is already open in another window", filepath.base(resolved)))
        return
    }
    thor_open_folder_in_new_window(thor, resolved)
}

// File menu / palette: pick a file to open as a tab, from anywhere on disk.
thor_cmd_open_file :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if path, ok := thor_pick_file("Open File", thor.workspace_dir); ok {
        defer delete(path)
        thor_open_file(thor, path)
    }
}
