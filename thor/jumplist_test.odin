package thor

import "core:os"
import "core:testing"
import "core:time"

import "../textedit"
import "../ui"
import "../widgets"

// Builds a headless Thor with the two panes and views thor_update_files needs,
// the same shape test_async_file_roundtrip uses. No window, no GL.
@(private = "file")
make_test_thor :: proc() -> ^Thor {
    thor := new(Thor)
    thor.active_file = ui.make_signal(-1)
    thor.open_files = make([dynamic]^Open_File)
    thor.zombie_files = make([dynamic]^Open_File)
    thor.finished_loads = make([dynamic]^Load_Job)
    thor.finished_saves = make([dynamic]^Save_Job)
    thor.pane_file = {-1, -1}
    thor.editor = widgets.editor_create("test-editor")
    thor.editor2 = widgets.editor_create("test-editor2")
    thor.editor_split_row = widgets.stack_create("test-editor-split-row", .Horizontal)
    thor.image_view = widgets.image_view_create("test-image-view")
    thor.model_view = widgets.model_view_create("test-model-view")
    thor.markdown_view = widgets.markdown_view_create("test-markdown-view")
    thor.markdown_view2 = widgets.markdown_view_create("test-markdown-view2")
    // thor_update_editor_view also swaps the welcome page in when there is no
    // workspace, which this headless Thor never sets.
    thor.welcome_panel = widgets.panel_create("test-welcome-panel", {})
    return thor
}

@(private = "file")
destroy_test_thor :: proc(thor: ^Thor) {
    for len(thor.open_files) > 0 {
        thor_close_file(thor, 0)
    }
    thor_drain_io(thor)
    thor_clear_jump_list(thor)
    delete(thor.jump_back)
    delete(thor.jump_forward)
    delete(thor.open_files)
    delete(thor.zombie_files)
    delete(thor.finished_loads)
    delete(thor.finished_saves)
    widgets.editor_destroy(&thor.editor.widget)
    widgets.editor_destroy(&thor.editor2.widget)
    widgets.stack_destroy(&thor.editor_split_row.widget)
    widgets.image_view_destroy(&thor.image_view.widget)
    widgets.model_view_destroy(&thor.model_view.widget)
    widgets.markdown_view_destroy(&thor.markdown_view.widget)
    widgets.markdown_view_destroy(&thor.markdown_view2.widget)
    widgets.panel_destroy(&thor.welcome_panel.widget)
    free(thor)
}

// Opens `path` and pumps the I/O reap until its buffer lands.
@(private = "file")
open_and_wait :: proc(t: ^testing.T, thor: ^Thor, path: string) -> ^Open_File {
    thor_open_file(thor, path)
    file := thor.open_files[len(thor.open_files) - 1]
    for _ in 0 ..< 500 {
        thor_update_files(thor)
        if file.loaded || file.load_failed {
            break
        }
        time.sleep(2 * time.Millisecond)
    }
    testing.expect(t, file.loaded, "load did not complete")
    return file
}

// The 1-based line the caret sits on in the active file.
@(private = "file")
caret_line :: proc(thor: ^Thor) -> int {
    file := thor_active_open_file(thor)
    if file == nil {
        return -1
    }
    caret := textedit.primary_cursor(&file.state).caret
    return textedit.line_index(textedit.text(&file.state), caret) + 1
}

// A cross-file jump remembers where it came from, Go Back returns there, and Go
// Forward replays the jump — including the file each end sits in.
@(test)
test_jump_list_back_and_forward :: proc(t: ^testing.T) {
    PATH_A :: "thor_jump_a.tmp"
    PATH_B :: "thor_jump_b.tmp"
    TEXT :: "one\ntwo\nthree\nfour\nfive\n"

    testing.expect(t, os.write_entire_file(PATH_A, TEXT) == nil, "could not create test file A")
    defer os.remove(PATH_A)
    testing.expect(t, os.write_entire_file(PATH_B, TEXT) == nil, "could not create test file B")
    defer os.remove(PATH_B)

    thor := make_test_thor()
    defer destroy_test_thor(thor)

    file_a := open_and_wait(t, thor, PATH_A)
    file_b := open_and_wait(t, thor, PATH_B)
    path_a := file_a.path

    // Park the caret on line 4 of B, the spot the jump will leave.
    textedit.set_single_cursor(&file_b.state, textedit.line_start_of_index(textedit.text(&file_b.state), 3))
    testing.expect_value(t, caret_line(thor), 4)

    thor_goto_file_line_col(thor, path_a, 2, 1)
    testing.expect(t, thor_active_open_file(thor) == file_a, "the jump did not land in the target file")
    testing.expect_value(t, caret_line(thor), 2)
    testing.expect_value(t, len(thor.jump_back), 1)
    testing.expect_value(t, len(thor.jump_forward), 0)

    thor_jump_back(thor)
    testing.expect(t, thor_active_open_file(thor) == file_b, "Go Back did not return to the origin file")
    testing.expect_value(t, caret_line(thor), 4)
    testing.expect_value(t, len(thor.jump_back), 0)
    // Where Go Back left is what Go Forward replays.
    testing.expect_value(t, len(thor.jump_forward), 1)

    thor_jump_forward(thor)
    testing.expect(t, thor_active_open_file(thor) == file_a, "Go Forward did not replay the jump")
    testing.expect_value(t, caret_line(thor), 2)
    testing.expect_value(t, len(thor.jump_back), 1)
    testing.expect_value(t, len(thor.jump_forward), 0)
}

// Arriving somewhere new ends the branch Go Forward would have replayed, and
// repeated jumps off one line leave one entry, not one per column.
@(test)
test_jump_list_records_once_per_line :: proc(t: ^testing.T) {
    PATH :: "thor_jump_c.tmp"
    TEXT :: "one\ntwo\nthree\nfour\nfive\n"

    testing.expect(t, os.write_entire_file(PATH, TEXT) == nil, "could not create test file")
    defer os.remove(PATH)

    thor := make_test_thor()
    defer destroy_test_thor(thor)

    file := open_and_wait(t, thor, PATH)
    path := file.path

    thor_goto_file_line_col(thor, path, 5, 1) // from line 1
    thor_goto_file_line_col(thor, path, 1, 1) // from line 5
    testing.expect_value(t, len(thor.jump_back), 2)

    thor_jump_back(thor)
    testing.expect_value(t, caret_line(thor), 5)
    testing.expect_value(t, len(thor.jump_forward), 1)

    // A fresh jump from here is a new branch: the forward trail is dropped.
    thor_goto_file_line_col(thor, path, 3, 1)
    testing.expect_value(t, len(thor.jump_forward), 0)
    testing.expect_value(t, len(thor.jump_back), 2)

    // Two more jumps off line 3 collapse: the caret never left the line between
    // them, and coming back to it twice is the same as coming back once.
    thor_goto_file_line_col(thor, path, 3, 3)
    thor_goto_file_line_col(thor, path, 3, 4)
    testing.expect_value(t, len(thor.jump_back), 3)
}
