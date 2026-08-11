package thor

// Per-workspace session state (open files, active tab, panel layout) persisted
// under <exe>/sessions/, keyed by absolute workspace path. The personal,
// ephemeral counterpart to the committable .thor/ config; no workspace init needed.

import "core:encoding/json"
import "core:fmt"
import "core:hash"
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

// Longest readable part a key keeps. The hash after it carries the identity, so
// a cut here only makes a name less readable, never ambiguous.
@(private = "file")
KEY_STEM_MAX :: 64

// A workspace path in its comparison form: lowercased on Windows (the only
// platform guaranteed case-insensitive), '/' separators, no trailing separator.
@(private = "file")
thor_normal_workspace :: proc(workspace_dir: string) -> string {
    cased := workspace_dir
    when ODIN_OS == .Windows {
        cased = strings.to_lower(workspace_dir, context.temp_allocator)
    }
    slashed, _ := strings.replace_all(cased, "\\", "/", context.temp_allocator)
    trimmed := strings.trim_right(slashed, "/")
    if trimmed == "" {
        return slashed // a root path is separators only
    }
    return trimmed
}

// A workspace path as one filename-safe component: a readable part plus a hash
// of the normalized path. The readable part alone cannot identify a folder —
// every unsafe character becomes '-', so "C:\foo-bar" and "C:\foo\bar" share it
// — thus the hash is what keeps two folders apart. Keys both the session files
// and the window records, so the two always agree on a folder.
thor_path_key :: proc(workspace_dir: string, allocator := context.temp_allocator) -> string {
    normal := thor_normal_workspace(workspace_dir)
    b := strings.builder_make(context.temp_allocator)
    for r in normal {
        if strings.builder_len(b) >= KEY_STEM_MAX {
            break
        }
        switch r {
        case 'a' ..= 'z', '0' ..= '9', '.', '_':
            strings.write_rune(&b, r)
        case:
            // Non-ASCII is a valid filename character on every target platform.
            strings.write_rune(&b, r >= 0x80 ? r : '-')
        }
    }
    return fmt.aprintf(
        "%s-%016x",
        strings.to_string(b),
        hash.fnv64a(transmute([]u8)normal),
        allocator = allocator,
    )
}

// Session file for a workspace: sessions/<path-key>.json.
@(private = "file")
thor_session_file :: proc(workspace_dir: string, allocator := context.temp_allocator) -> string {
    return strings.concatenate({"sessions/", thor_path_key(workspace_dir), ".json"}, allocator)
}

// The session file of the key that came before the hash: separators and the
// drive colon mapped to '-' and nothing else.
@(private = "file")
thor_legacy_session_file :: proc(workspace_dir: string, allocator := context.temp_allocator) -> string {
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
    return strings.concatenate({"sessions/", strings.to_string(b), ".json"}, allocator)
}

// Moves a session written under the old key onto the new name, so an upgrade
// keeps a workspace's open files. That key was ambiguous, so the file can hold
// another folder's session — the workspace it records settles it.
@(private = "file")
thor_migrate_legacy_session :: proc(workspace_dir: string) {
    path := thor_session_file(workspace_dir)
    legacy := thor_legacy_session_file(workspace_dir)
    if legacy == path || os.exists(path) || !os.exists(legacy) {
        return
    }
    data, read_err := os.read_entire_file(legacy, context.temp_allocator)
    if read_err != nil {
        return
    }
    session: Session
    if err := json.unmarshal(data, &session, allocator = context.temp_allocator); err != nil {
        return
    }
    if thor_normal_workspace(session.workspace) != thor_normal_workspace(workspace_dir) {
        return
    }
    if err := os.rename(legacy, path); err != nil {
        log.warnf("Could not move session %q to %q: %v", legacy, path, err)
    }
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

// Recently opened workspaces, most recent first, for the welcome page's
// picker. Lives next to the session files, i.e. relative to the exe directory.
RECENT_WORKSPACES_FILE :: "sessions/recent.json"
RECENT_WORKSPACES_MAX :: 10

// The recorded recent workspaces (owned clones), pruned of folders that no
// longer exist. Missing or malformed file is an empty list.
thor_recent_workspaces :: proc(allocator := context.allocator) -> []string {
    data, read_err := os.read_entire_file(RECENT_WORKSPACES_FILE, context.temp_allocator)
    if read_err != nil {
        return nil
    }
    paths: []string
    if err := json.unmarshal(data, &paths, allocator = context.temp_allocator); err != nil {
        log.warnf("Ignoring malformed %q: %v", RECENT_WORKSPACES_FILE, err)
        return nil
    }
    kept := make([dynamic]string, 0, len(paths), allocator)
    for p in paths {
        if os.is_dir(p) {
            append(&kept, strings.clone(p, allocator))
        }
    }
    return kept[:]
}

// Moves `workspace` to the front of the recent list, dropping any existing
// entry for the same folder and capping the list at RECENT_WORKSPACES_MAX.
// Called whenever a workspace becomes active.
thor_record_recent_workspace :: proc(workspace: string) {
    if workspace == "" {
        return
    }
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }
    existing := thor_recent_workspaces(context.temp_allocator)
    normal := thor_normal_workspace(workspace)
    kept := make([dynamic]string, 0, len(existing) + 1, context.temp_allocator)
    append(&kept, workspace)
    for p in existing {
        if thor_normal_workspace(p) == normal {
            continue
        }
        if len(kept) >= RECENT_WORKSPACES_MAX {
            continue
        }
        append(&kept, p)
    }
    data, err := json.marshal(kept[:], {pretty = true}, context.temp_allocator)
    if err != nil {
        log.errorf("Could not marshal recent workspaces: %v", err)
        return
    }
    if werr := os.write_entire_file(RECENT_WORKSPACES_FILE, data); werr != nil {
        log.errorf("Could not write %q: %v", RECENT_WORKSPACES_FILE, werr)
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
    if thor.workspace_dir == "" {
        return
    }
    thor_migrate_legacy_session(thor.workspace_dir)
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
