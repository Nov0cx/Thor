package thor

import "core:os"
import "core:testing"
import "core:time"

import "../textedit"
import "../ui"
import "../widgets"

// Exercises the async load -> edit -> save -> close pipeline headlessly:
// only the editor widget is real, no window or GL is needed. Run from the
// repository root: odin test thor
@(test)
test_async_file_roundtrip :: proc(t: ^testing.T) {
    TEST_PATH :: "thor_roundtrip.tmp"
    ORIGINAL :: "hello\nworld\n"

    write_err := os.write_entire_file(TEST_PATH, ORIGINAL)
    testing.expect(t, write_err == nil, "could not create test file")
    defer os.remove(TEST_PATH)

    thor := new(Thor)
    defer free(thor)
    thor.active_file = ui.make_signal(-1)
    thor.open_files = make([dynamic]^Open_File)
    thor.zombie_files = make([dynamic]^Open_File)
    thor.finished_loads = make([dynamic]^Load_Job)
    thor.finished_saves = make([dynamic]^Save_Job)
    thor.pane_file = {-1, -1}
    thor.editor = widgets.editor_create("test-editor")
    thor.editor2 = widgets.editor_create("test-editor2")
    // thor_update_files picks the view for the active file, so the image, model
    // and markdown views have to exist even though nothing draws them here.
    thor.editor_split_row = widgets.stack_create("test-editor-split-row", .Horizontal)
    thor.image_view = widgets.image_view_create("test-image-view")
    thor.model_view = widgets.model_view_create("test-model-view")
    thor.markdown_view = widgets.markdown_view_create("test-markdown-view")
    thor.markdown_view2 = widgets.markdown_view_create("test-markdown-view2")
    defer {
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
    }

    // Open: spawns the mmap loader thread and activates the tab.
    thor_open_file(thor, TEST_PATH)
    testing.expect_value(t, len(thor.open_files), 1)
    file := thor.open_files[0]
    testing.expect_value(t, file.name, "thor_roundtrip.tmp")
    testing.expect(t, thor.editor.state == nil, "editor must not borrow a still-loading buffer")

    for _ in 0 ..< 500 {
        thor_update_files(thor)
        if file.loaded || file.load_failed {
            break
        }
        time.sleep(2 * time.Millisecond)
    }
    testing.expect(t, file.loaded, "load did not complete")
    testing.expect(t, !file.load_failed, "load failed")
    testing.expect_value(t, textedit.text(&file.state), ORIGINAL)
    testing.expect(t, thor.editor.state == &file.state, "editor not pointed at loaded buffer")

    // Edit and save explicitly (the autosave path shares thor_save_file).
    textedit.insert_text(&file.state, "edit: ")
    testing.expect(t, file.state.revision != file.saved_revision, "edit did not dirty the buffer")

    thor_save_file(thor, file)
    testing.expect(t, file.saving, "save did not start")
    thor_drain_io(thor)
    testing.expect(t, !file.saving, "save still marked in flight")
    testing.expect_value(t, file.saved_revision, file.state.revision)

    saved, read_err := os.read_entire_file(TEST_PATH, context.temp_allocator)
    testing.expect(t, read_err == nil, "could not read back saved file")
    testing.expect_value(t, string(saved), "edit: " + ORIGINAL)

    // Opening the same path again must reuse the tab.
    thor_open_file(thor, TEST_PATH)
    testing.expect_value(t, len(thor.open_files), 1)

    // Close: frees the record once no I/O is pending.
    thor_close_file(thor, 0)
    testing.expect_value(t, len(thor.open_files), 0)
    testing.expect_value(t, len(thor.zombie_files), 0)
    testing.expect(t, thor.editor.state == nil, "editor still borrows a closed buffer")
    testing.expect_value(t, ui.signal_get(&thor.active_file), -1)
}

@(test)
test_line_ending_detect :: proc(t: ^testing.T) {
    testing.expect_value(t, thor_detect_line_ending("a\nb\n"), Line_Ending.LF)
    testing.expect_value(t, thor_detect_line_ending("a\r\nb\r\n"), Line_Ending.CRLF)
    // The first terminator decides; a mixed file is not left undecided.
    testing.expect_value(t, thor_detect_line_ending("a\nb\r\n"), Line_Ending.LF)
    testing.expect_value(t, thor_detect_line_ending("a\r\nb\n"), Line_Ending.CRLF)
    // No terminator at all, and a lone CR, are both LF.
    testing.expect_value(t, thor_detect_line_ending(""), Line_Ending.LF)
    testing.expect_value(t, thor_detect_line_ending("one line"), Line_Ending.LF)
    testing.expect_value(t, thor_detect_line_ending("a\rb"), Line_Ending.LF)
}

@(test)
test_line_ending_conversion :: proc(t: ^testing.T) {
    // Into the buffer: every CRLF collapses, whatever the file's ending, so no
    // stray CR survives in a mixed file.
    testing.expect_value(t, thor_to_buffer_text("a\r\nb\r\n"), "a\nb\n")
    testing.expect_value(t, thor_to_buffer_text("a\nb\r\nc\n"), "a\nb\nc\n")
    testing.expect_value(t, thor_to_buffer_text("a\nb\n"), "a\nb\n")
    testing.expect_value(t, thor_to_buffer_text(""), "")

    // Back out to disk.
    lf := thor_to_disk_text("a\nb\n", .LF, context.temp_allocator)
    testing.expect_value(t, lf, "a\nb\n")
    crlf := thor_to_disk_text("a\nb\n", .CRLF, context.temp_allocator)
    testing.expect_value(t, crlf, "a\r\nb\r\n")
    // A CRLF file with no newline at all still yields an owned string.
    bare := thor_to_disk_text("solo", .CRLF, context.temp_allocator)
    testing.expect_value(t, bare, "solo")

    // A CRLF file survives a load/save round trip byte for byte.
    round := thor_to_disk_text(thor_to_buffer_text("a\r\nb\r\n"), .CRLF, context.temp_allocator)
    testing.expect_value(t, round, "a\r\nb\r\n")
}

// A CRLF file keeps its endings across an edit and a save, and switching the
// mode converts the file on disk.
@(test)
test_crlf_file_roundtrip :: proc(t: ^testing.T) {
    TEST_PATH :: "thor_crlf.tmp"

    write_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("a\r\nb\r\n"))
    testing.expect(t, write_err == nil, "could not create test file")
    defer os.remove(TEST_PATH)

    thor := test_make_thor()
    defer test_free_thor(thor)

    thor_open_file(thor, TEST_PATH)
    file := thor.open_files[0]
    for _ in 0 ..< 500 {
        thor_update_files(thor)
        if file.loaded || file.load_failed {
            break
        }
        time.sleep(2 * time.Millisecond)
    }
    testing.expect(t, file.loaded, "load did not complete")
    testing.expect_value(t, file.line_ending, Line_Ending.CRLF)
    // The editing core only ever sees LF.
    testing.expect_value(t, textedit.text(&file.state), "a\nb\n")

    textedit.insert_text(&file.state, "x")
    thor_save_file(thor, file)
    thor_drain_io(thor)

    saved, read_err := os.read_entire_file(TEST_PATH, context.temp_allocator)
    testing.expect(t, read_err == nil, "could not read back saved file")
    testing.expect_value(t, string(saved), "xa\r\nb\r\n")

    // Switching to LF on a clean buffer rewrites the file at once.
    testing.expect_value(t, file.state.revision, file.saved_revision)
    thor_set_line_ending(thor, file, .LF)
    thor_drain_io(thor)
    testing.expect_value(t, file.line_ending, Line_Ending.LF)

    converted, conv_err := os.read_entire_file(TEST_PATH, context.temp_allocator)
    testing.expect(t, conv_err == nil, "could not read back converted file")
    testing.expect_value(t, string(converted), "xa\nb\n")

    thor_close_file(thor, 0)
}

// Headless Thor with just enough wired up for the file pipeline: no window and
// no GL, matching test_async_file_roundtrip's inline setup.
@(private = "file")
test_make_thor :: proc() -> ^Thor {
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
    return thor
}

@(private = "file")
test_free_thor :: proc(thor: ^Thor) {
    delete(thor.status_message)
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
    free(thor)
}
