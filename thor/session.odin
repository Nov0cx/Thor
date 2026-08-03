package thor

// Per-workspace session state (open files, active tab, panel layout) persisted
// under <exe>/sessions/, keyed by absolute workspace path. The personal,
// ephemeral counterpart to the committable .thor/ config; no workspace init needed.

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

import "../ui"

// On-disk shape of a session. Field names are the JSON keys.
@(private = "file")
Session :: struct {
    workspace:        string,
    open_files:       []string,
    active_file:      int,
    explorer_visible: bool,
    console_visible:  bool,
    explorer_width:   f32,
    console_height:   f32,
    window_maximized:  bool,
    split_visible:     bool,
    split_ratio:       f32,
    split_second_file: int,
    // Name of the task the titlebar selector shows; the tasks themselves are
    // committed with the workspace, which one you last picked is not.
    active_task:       string,
}

// A workspace path as one filename-safe component: lowercased (Windows is
// case-insensitive) with separators and the drive colon mapped to '-'. Keys both
// the session files and the window records, so the two always agree on a folder.
thor_path_key :: proc(workspace_dir: string, allocator := context.temp_allocator) -> string {
    lower := strings.to_lower(workspace_dir, context.temp_allocator)
    b := strings.builder_make(context.temp_allocator)
    for r in lower {
        switch r {
        case ':', '/', '\\':
            strings.write_rune(&b, '-')
        case:
            strings.write_rune(&b, r)
        }
    }
    return strings.clone(strings.to_string(b), allocator)
}

// Session file for a workspace: sessions/<path-key>.json.
@(private = "file")
thor_session_file :: proc(workspace_dir: string, allocator := context.temp_allocator) -> string {
    return strings.concatenate({"sessions/", thor_path_key(workspace_dir), ".json"}, allocator)
}

// Records the workspace of the most recent session, so a launch with no path
// argument reopens it. Lives next to the session files, i.e. relative to the
// exe directory.
@(private = "file")
LAST_WORKSPACE_FILE :: "sessions/last.txt"

// The workspace the last session ran in (owned), or "" when none is recorded or
// the folder is gone. Read at startup, after the CWD moved to the exe directory.
thor_last_workspace :: proc() -> string {
    data, read_err := os.read_entire_file(LAST_WORKSPACE_FILE, context.temp_allocator)
    if read_err != nil {
        return ""
    }
    path := strings.trim_space(string(data))
    if path == "" || !os.is_dir(path) {
        return ""
    }
    return strings.clone(path)
}

// Points the last-workspace record at `workspace`, so a bare launch reopens it.
// Written on every session save and right after a folder switch, so an unclean
// exit still comes back to the folder that was open.
thor_record_last_workspace :: proc(workspace: string) {
    if err := os.write_entire_file(LAST_WORKSPACE_FILE, transmute([]u8) workspace); err != nil {
        log.errorf("Could not write %q: %v", LAST_WORKSPACE_FILE, err)
    }
}

// Writes the current open files and panel layout to this workspace's session
// file, and points the last-workspace record at it. Called on shutdown, before
// any open-file state is torn down.
thor_save_session :: proc(thor: ^Thor) {
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }

    paths := make([dynamic]string, 0, len(thor.open_files), context.temp_allocator)
    for file in thor.open_files {
        append(&paths, file.path)
    }

    session := Session {
        workspace        = thor.workspace_dir,
        open_files       = paths[:],
        active_file      = thor.pane_file[0],
        explorer_visible = ui.signal_get(&thor.explorer_visible),
        console_visible  = ui.signal_get(&thor.console_visible),
        explorer_width   = thor.explorer_width,
        console_height   = thor.console_height,
        window_maximized  = thor.window_maximized,
        split_visible     = thor.split_visible,
        split_ratio       = thor.split_ratio,
        split_second_file = thor.pane_file[1],
        active_task       = thor.active_task_name,
    }

    data, err := json.marshal(session, {pretty = true}, context.temp_allocator)
    if err != nil {
        log.errorf("Could not marshal session: %v", err)
        return
    }
    path := thor_session_file(thor.workspace_dir)
    if werr := os.write_entire_file(path, data); werr != nil {
        log.errorf("Could not write session %q: %v", path, werr)
    }
    thor_record_last_workspace(thor.workspace_dir)
}

// Restores this workspace's session: panel layout, reopened files, and active
// tab. Missing or malformed is a no-op. Must run after the UI is built and
// before thor_apply_layout_state.
thor_restore_session :: proc(thor: ^Thor) {
    path := thor_session_file(thor.workspace_dir)
    data, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil {
        return
    }

    session: Session
    if err := json.unmarshal(data, &session, allocator = context.temp_allocator); err != nil {
        log.warnf("Ignoring malformed session %q: %v", path, err)
        return
    }

    // Layout first, so the panels come up sized and visible as saved. Guard the
    // sizes so a zeroed/absent field can't collapse a panel.
    if session.explorer_width > 0 {
        thor.explorer_width = session.explorer_width
    }
    if session.console_height > 0 {
        thor.console_height = session.console_height
    }
    ui.signal_set(&thor.explorer_visible, session.explorer_visible)
    ui.signal_set(&thor.console_visible, session.console_visible)
    thor.split_visible = session.split_visible
    if session.split_ratio > 0 {
        thor.split_ratio = clamp(session.split_ratio, 0.15, 0.85)
    }
    if session.window_maximized {
        rl.MaximizeWindow()
        thor.window_maximized = true
    }
    // Ignored when the task is gone from tasks.json; the selector falls back.
    thor_select_task(thor, session.active_task)

    // Reopen in saved order; each open sets itself active, so the saved active
    // tab is applied last.
    for p in session.open_files {
        thor_open_file(thor, p)
    }
    if session.active_file >= 0 && session.active_file < len(thor.open_files) {
        thor_set_active_file(thor, session.active_file)
    }
    // Pane 2's file (bound after the UI is up, in init). thor_toggle_split fills
    // it in later if it was left unset.
    if session.split_second_file >= 0 && session.split_second_file < len(thor.open_files) {
        thor.pane_file[1] = session.split_second_file
    }
}
