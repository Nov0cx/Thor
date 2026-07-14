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
}

// Session file for a workspace: sessions/<sanitized-abs-path>.json. The path is
// lowercased (Windows is case-insensitive) with separators and colon mapped to '-'.
@(private = "file")
thor_session_file :: proc(workspace_dir: string, allocator := context.temp_allocator) -> string {
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

// Writes the current open files and panel layout to this workspace's session
// file. Called on shutdown, before any open-file state is torn down.
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
