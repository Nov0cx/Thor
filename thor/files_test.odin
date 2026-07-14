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
    defer {
        delete(thor.open_files)
        delete(thor.zombie_files)
        delete(thor.finished_loads)
        delete(thor.finished_saves)
        widgets.editor_destroy(&thor.editor.widget)
        widgets.editor_destroy(&thor.editor2.widget)
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
