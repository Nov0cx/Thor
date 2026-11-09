package thor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../editview"
import "../textedit"

// A fixture name no other run of the tests can collide with. Windows keeps the
// name of a removed directory unusable while a handle on it is still open, thus
// a run that reuses the name the last run removed can fail to create it.
@(private)
test_fixture_name :: proc(name: string) -> string {
    return fmt.tprintf("%s_%d", name, os.get_pid())
}

// thor_recent_workspaces / thor_record_recent_workspace persist to
// sessions/recent.json, the same file a real run uses, so the test backs up
// and restores whatever is there and only ever records folders it created
// itself. Run from the repository root: odin test thor
@(test)
test_recent_workspaces :: proc(t: ^testing.T) {
    backup, backup_err := os.read_entire_file(RECENT_WORKSPACES_FILE, context.temp_allocator)
    had_backup := backup_err == nil
    defer {
        if had_backup {
            _ = os.write_entire_file(RECENT_WORKSPACES_FILE, backup)
        } else {
            _ = os.remove(RECENT_WORKSPACES_FILE)
        }
    }

    dir_a := test_fixture_name("thor_recent_test_a")
    dir_b := test_fixture_name("thor_recent_test_b")
    testing.expect(t, os.make_directory(dir_a) == nil, "could not create test dir")
    testing.expect(t, os.make_directory(dir_b) == nil, "could not create test dir")
    // thor_delete_tree, not os.remove: the removal loses the same race the
    // creation does, and a fixture left behind is never reused under this name.
    defer _ = thor_delete_tree(dir_a)
    defer _ = thor_delete_tree(dir_b)

    thor_record_recent_workspace(dir_a)
    thor_record_recent_workspace(dir_b)
    order := thor_recent_workspaces(context.temp_allocator)
    testing.expect(t, len(order) >= 2, "expected at least two recorded workspaces")
    testing.expect(t, strings.equal_fold(order[0], dir_b), "most recently recorded must lead")
    testing.expect(t, strings.equal_fold(order[1], dir_a), "second most recent must follow")

    // Re-recording an existing entry moves it to the front instead of duplicating it.
    thor_record_recent_workspace(dir_a)
    deduped := thor_recent_workspaces(context.temp_allocator)
    testing.expect(t, strings.equal_fold(deduped[0], dir_a), "re-recorded entry must move to the front")
    dup_count := 0
    for p in deduped {
        if strings.equal_fold(p, dir_a) {
            dup_count += 1
        }
    }
    testing.expect_value(t, dup_count, 1)

    // A folder that no longer exists is dropped from the list.
    _ = os.remove(dir_b)
    pruned := thor_recent_workspaces(context.temp_allocator)
    for p in pruned {
        testing.expect(t, !strings.equal_fold(p, dir_b), "a deleted folder must not be listed")
    }

    // The list never grows past the cap.
    cap_dirs: [RECENT_WORKSPACES_MAX + 1]string
    for i in 0 ..< len(cap_dirs) {
        cap_dirs[i] = test_fixture_name(fmt.tprintf("thor_recent_test_cap_%d", i))
        testing.expect(t, os.make_directory(cap_dirs[i]) == nil, "could not create test dir")
        thor_record_recent_workspace(cap_dirs[i])
    }
    defer for dir in cap_dirs {
        _ = thor_delete_tree(dir)
    }
    capped := thor_recent_workspaces(context.temp_allocator)
    testing.expect(t, len(capped) <= RECENT_WORKSPACES_MAX, "recent workspaces must stay capped")
    testing.expect(
        t,
        strings.equal_fold(capped[0], cap_dirs[len(cap_dirs) - 1]),
        "the most recently recorded folder must still lead",
    )
}

// A folder saved into a session (an older build let one open) is dropped on
// restore, and the saved tab positions move with it. Writes and removes its own
// session file. Run from the repository root: odin test thor
@(test)
test_restore_drops_a_directory :: proc(t: ^testing.T) {
    workspace := test_fixture_name("thor_session_dir_test")
    sub := fmt.tprintf("%s/sub", workspace)
    note := fmt.tprintf("%s/note.txt", workspace)

    testing.expect(t, os.make_directory(workspace) == nil, "could not create test workspace")
    defer os.remove(workspace)
    testing.expect(t, os.make_directory(sub) == nil, "could not create test dir")
    defer os.remove(sub)
    testing.expect(
        t,
        os.write_entire_file(note, transmute([]u8)string("note\n")) == nil,
        "could not create test file",
    )
    defer os.remove(note)

    if !os.is_dir("sessions") {
        testing.expect(t, os.make_directory("sessions") == nil, "could not create sessions dir")
    }
    // Written by hand: the on-disk Session shape is file-private to session.odin.
    // The folder comes first, so the saved active tab is position 1.
    data := fmt.tprintf(
        `{{"workspace":%q,"open_files":[%q,%q],"active_file":1,"split_second_file":-1}}`,
        workspace,
        sub,
        note,
    )
    path := strings.concatenate(
        {"sessions/", thor_path_key(workspace), ".json"},
        context.temp_allocator,
    )
    testing.expect(
        t,
        os.write_entire_file(path, transmute([]u8)data) == nil,
        "could not write the test session",
    )
    defer os.remove(path)

    thor := new(Thor)
    defer free(thor)
    defer for &editor in thor.editors {editview.editor_destroy(&editor)}
    thor.active_file = make_signal(-1)
    thor.open_files = make([dynamic]^Open_File)
    thor.zombie_files = make([dynamic]^Open_File)
    thor.pane_file = -1
    thor.workspace_dir = workspace
    defer {
        delete(thor.status_message)
        delete(thor.open_files)
        delete(thor.zombie_files)
    }

    thor_restore_session(thor)
    testing.expect_value(t, len(thor.open_files), 1)
    testing.expect_value(t, thor.open_files[0].name, "note.txt")
    // Position 1 in the saved list is position 0 in the restored one.
    testing.expect_value(t, signal_get(&thor.active_file), 0)

    thor_drain_io(thor)
    thor_close_file(thor, 0)
    testing.expect_value(t, len(thor.open_files), 0)
}

// The dock layout rides the session file and waits for the next arrange: the
// space only exists inside a frame, and a restore runs outside one. A restore
// always drops what the outgoing workspace left, so a folder with no saved
// layout comes up on the default one rather than the folder's before it.
@(test)
test_restore_hands_the_dock_layout_on :: proc(t: ^testing.T) {
    workspace := test_fixture_name("thor_session_dock_test")
    LAYOUT :: `[dock.main]
root = n0
n0.kind = tabs
n0.tabs = Explorer
`

    testing.expect(t, os.make_directory(workspace) == nil, "could not create test workspace")
    defer os.remove(workspace)
    if !os.is_dir("sessions") {
        testing.expect(t, os.make_directory("sessions") == nil, "could not create sessions dir")
    }

    // Written by hand: the on-disk Session shape is file-private to session.odin.
    escaped, _ := strings.replace_all(LAYOUT, "\n", "\\n", context.temp_allocator)
    data := fmt.tprintf(
        `{{"workspace":%q,"open_files":[],"active_file":-1,"split_second_file":-1,"dock_layout":"%s"}}`,
        workspace,
        escaped,
    )
    path := strings.concatenate(
        {"sessions/", thor_path_key(workspace), ".json"},
        context.temp_allocator,
    )
    testing.expect(
        t,
        os.write_entire_file(path, transmute([]u8)data) == nil,
        "could not write the test session",
    )
    defer os.remove(path)

    thor := new(Thor)
    defer free(thor)
    defer for &editor in thor.editors {editview.editor_destroy(&editor)}
    thor.active_file = make_signal(-1)
    thor.open_files = make([dynamic]^Open_File)
    thor.zombie_files = make([dynamic]^Open_File)
    thor.pane_file = -1
    thor.workspace_dir = workspace
    defer {
        delete(thor.dock_layout)
        delete(thor.status_message)
        delete(thor.open_files)
        delete(thor.zombie_files)
    }

    // What a workspace arranged earlier in the run leaves behind.
    thor.dock_seeded = true

    thor_restore_session(thor)
    testing.expect_value(t, thor.dock_layout, LAYOUT)
    testing.expect(t, !thor.dock_seeded, "the layout is applied by the next arrange, not here")

    // A workspace with no session file of its own drops it rather than keeping
    // the one on screen, which the next save would write over its session.
    thor.dock_seeded = true
    thor.workspace_dir = "thor_session_dock_missing"
    thor_restore_session(thor)
    testing.expect_value(t, thor.dock_layout, "")
    testing.expect(t, !thor.dock_seeded, "a missing session still re-arranges the dock")
    thor.workspace_dir = workspace
}

// A restore puts the caret on its saved line and column and the view on its top
// line, and a position past the end of a file that shrank lands on the last line.
@(test)
test_apply_file_view_clamps :: proc(t: ^testing.T) {
    file := new(Open_File)
    defer free(file)
    textedit.init(&file.state)
    defer textedit.destroy(&file.state)
    textedit.set_text(&file.state, "alpha\nbeta\ngamma")

    file.restore, file.restore_pending = File_View{line = 1, col = 2, top_line = 1}, true
    thor_apply_file_view(file)
    testing.expect(t, !file.restore_pending, "the restore must be spent")
    testing.expect_value(t, textedit.primary_cursor(&file.state).caret, 8)
    testing.expect_value(t, file.view_top, 6)

    file.restore, file.restore_pending = File_View{line = 99, col = 99, top_line = 99}, true
    thor_apply_file_view(file)
    testing.expect_value(t, textedit.primary_cursor(&file.state).caret, 16)
    testing.expect_value(t, file.view_top, 11)

    file.restore, file.restore_pending = File_View{line = 0, col = 99, top_line = 0}, true
    thor_apply_file_view(file)
    testing.expect_value(t, textedit.primary_cursor(&file.state).caret, 5)
}

// A buffer from BIG_FILE_BYTES up is large; one under it, or one still loading, is not.
@(test)
test_big_file_threshold :: proc(t: ^testing.T) {
    file := new(Open_File)
    defer free(file)
    textedit.init(&file.state)
    defer textedit.destroy(&file.state)

    file.loaded = true
    textedit.set_text(&file.state, "small\n")
    testing.expect(t, !thor_big_file(file))

    big, _ := strings.repeat("0123456789abcdef\n", BIG_FILE_BYTES / 17 + 1)
    defer delete(big)
    textedit.set_text(&file.state, big)
    testing.expect(t, thor_big_file(file))

    file.loaded = false
    testing.expect(t, !thor_big_file(file), "a file still loading has no size to judge")
}
