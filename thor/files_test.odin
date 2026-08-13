package thor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../textedit"
import "../ui"
import "../watch"
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
    // thor_update_editor_view also swaps the welcome page in when there is no
    // workspace, which this headless Thor never sets.
    thor.welcome_panel = widgets.panel_create("test-welcome-panel", {})
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
        widgets.panel_destroy(&thor.welcome_panel.widget)
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

// Line-ending detection and CRLF collapsing now run on the load worker
// (load_worker), not the reap on the main thread; this exercises that path
// through the same async open/pump cycle as test_async_file_roundtrip,
// rather than calling thor_detect_line_ending/thor_to_buffer_text directly.
@(test)
test_async_load_prepares_crlf_text :: proc(t: ^testing.T) {
    TEST_PATH :: "thor_crlf_roundtrip.tmp"
    ORIGINAL :: "hello\r\nworld\r\n"

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
    thor.editor_split_row = widgets.stack_create("test-editor-split-row", .Horizontal)
    thor.image_view = widgets.image_view_create("test-image-view")
    thor.model_view = widgets.model_view_create("test-model-view")
    thor.markdown_view = widgets.markdown_view_create("test-markdown-view")
    thor.markdown_view2 = widgets.markdown_view_create("test-markdown-view2")
    thor.welcome_panel = widgets.panel_create("test-welcome-panel", {})
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
        widgets.panel_destroy(&thor.welcome_panel.widget)
    }

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
    testing.expect_value(t, textedit.text(&file.state), "hello\nworld\n")

    thor_close_file(thor, 0)
}

// `loaded` never becomes true for an image or a model (both bypass the text
// pipeline), so a tab-info computation that reads `loading` off `!loaded`
// alone would spin forever on either. thor_tab_info must go through
// thor_file_ready instead, which also counts texture_loaded/model_loaded.
@(test)
test_image_tab_is_not_stuck_loading :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    file := new(Open_File)
    defer free(file)
    file.name = "photo.png"
    file.is_image = true
    append(&thor.open_files, file)

    info := thor_tab_info(thor, 0)
    testing.expect(t, info.loading, "an image whose texture has not landed yet must read as loading")

    file.texture_loaded = true
    info = thor_tab_info(thor, 0)
    testing.expect(t, !info.loading, "an image tab with a loaded texture must not read as loading")

    file.texture_loaded = false
    file.load_failed = true
    info = thor_tab_info(thor, 0)
    testing.expect(t, !info.loading, "a failed load must not read as loading")
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
    crlf_pair, crlf_pair_allocated := thor_to_buffer_text("a\r\nb\r\n")
    testing.expect_value(t, crlf_pair, "a\nb\n")
    testing.expect(t, crlf_pair_allocated, "collapsing a CRLF must report allocated = true")
    mixed, mixed_allocated := thor_to_buffer_text("a\nb\r\nc\n")
    testing.expect_value(t, mixed, "a\nb\nc\n")
    testing.expect(t, mixed_allocated)
    plain, plain_allocated := thor_to_buffer_text("a\nb\n")
    testing.expect_value(t, plain, "a\nb\n")
    testing.expect(t, !plain_allocated, "a plain LF file needs no collapsing, so it must not be copied")
    empty, empty_allocated := thor_to_buffer_text("")
    testing.expect_value(t, empty, "")
    testing.expect(t, !empty_allocated)

    // Back out to disk.
    lf := thor_to_disk_text("a\nb\n", .LF, context.temp_allocator)
    testing.expect_value(t, lf, "a\nb\n")
    crlf := thor_to_disk_text("a\nb\n", .CRLF, context.temp_allocator)
    testing.expect_value(t, crlf, "a\r\nb\r\n")
    // A CRLF file with no newline at all still yields an owned string.
    bare := thor_to_disk_text("solo", .CRLF, context.temp_allocator)
    testing.expect_value(t, bare, "solo")

    // A CRLF file survives a load/save round trip byte for byte.
    buffer_text, _ := thor_to_buffer_text("a\r\nb\r\n")
    round := thor_to_disk_text(buffer_text, .CRLF, context.temp_allocator)
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

// A watcher reload keeps each cursor at its line and column, and the pane keeps
// its scroll offset, so text added above the caret does not move the view.
@(test)
test_reload_keeps_cursor_and_view :: proc(t: ^testing.T) {
    TEST_PATH :: "thor_reload.tmp"

    write_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("alpha\nbeta\ngamma\n"))
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

    // "beta" selected, from its line start to its line end.
    textedit.select_range(&file.state, 6, 10)
    thor.editor.scroll_y = 120

    rewrite_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("inserted\nalpha\nbeta\ngamma\n"))
    testing.expect(t, rewrite_err == nil, "could not rewrite test file")

    thor_reload_file(thor, file)
    testing.expect(t, file.reloading, "reload did not start")
    thor_drain_io(thor)
    testing.expect(t, !file.reloading, "reload still marked in flight")
    testing.expect_value(t, textedit.text(&file.state), "inserted\nalpha\nbeta\ngamma\n")

    // The selection moved down with the line it holds, still "beta".
    cursor := textedit.primary_cursor(&file.state)
    testing.expect_value(t, cursor.anchor, 15)
    testing.expect_value(t, cursor.caret, 19)
    testing.expect_value(t, thor.editor.scroll_y, 120)
    // A reload leaves the buffer clean.
    testing.expect_value(t, file.saved_revision, file.state.revision)

    // Truncated to a prefix of itself: a cursor inside the cut lands on its end.
    truncate_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("inserted\n"))
    testing.expect(t, truncate_err == nil, "could not truncate test file")

    thor_reload_file(thor, file)
    thor_drain_io(thor)
    testing.expect_value(t, textedit.text(&file.state), "inserted\n")
    cursor = textedit.primary_cursor(&file.state)
    testing.expect_value(t, cursor.caret, 9)
    testing.expect_value(t, cursor.anchor, 9)

    thor_close_file(thor, 0)
}

// A reload reads a file another program still holds open for writing — what an
// external editor's save looks like from here.
@(test)
test_reload_reads_file_held_by_a_writer :: proc(t: ^testing.T) {
    TEST_PATH :: "thor_held.tmp"

    write_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("one\ntwo\n"))
    testing.expect(t, write_err == nil, "could not create test file")
    defer os.remove(TEST_PATH)

    thor := test_make_thor()
    defer test_free_thor(thor)

    thor_open_file(thor, TEST_PATH)
    file := thor.open_files[0]
    thor_drain_io(thor)
    testing.expect(t, file.loaded, "load did not complete")

    handle, open_err := os.open(TEST_PATH, os.O_WRONLY)
    testing.expect(t, open_err == nil, "could not open the file as a second writer")
    // Same length, so no truncation is needed to overwrite in place.
    _, rewrite_err := os.write_at(handle, transmute([]u8) string("six\nten\n"), 0)
    testing.expect(t, rewrite_err == nil, "could not rewrite through the second writer")

    thor_reload_file(thor, file)
    thor_drain_io(thor)
    testing.expect_value(t, textedit.text(&file.state), "six\nten\n")

    os.close(handle)
    thor_close_file(thor, 0)
}

// A change arriving while a reload reads is not dropped: one save fires several
// watcher events, and the first read can land before the last write.
@(test)
test_reload_during_read_is_retried :: proc(t: ^testing.T) {
    TEST_PATH :: "thor_retry.tmp"

    write_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("first\n"))
    testing.expect(t, write_err == nil, "could not create test file")
    defer os.remove(TEST_PATH)

    thor := test_make_thor()
    defer test_free_thor(thor)

    thor_open_file(thor, TEST_PATH)
    file := thor.open_files[0]
    thor_drain_io(thor)
    testing.expect(t, file.loaded, "load did not complete")

    thor_reload_file(thor, file)
    testing.expect(t, file.reloading, "reload did not start")

    final_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("second\n"))
    testing.expect(t, final_err == nil, "could not rewrite test file")
    thor_reload_file(thor, file)
    testing.expect(t, file.reload_pending, "the change during the read was dropped")

    thor_drain_io(thor)
    testing.expect(t, !file.reload_pending, "retry never ran")
    testing.expect_value(t, textedit.text(&file.state), "second\n")

    thor_close_file(thor, 0)
}

// A disk change under a buffer with unsaved edits keeps the edits and raises the
// conflict prompt instead; the forced reload the prompt runs takes the disk bytes.
@(test)
test_reload_conflict_keeps_edits :: proc(t: ^testing.T) {
    TEST_PATH :: "thor_conflict.tmp"

    write_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("disk one\n"))
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

    textedit.insert_text(&file.state, "mine ")
    testing.expect(t, file.state.revision != file.saved_revision, "edit did not dirty the buffer")

    rewrite_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("disk two\n"))
    testing.expect(t, rewrite_err == nil, "could not rewrite test file")

    thor_reload_file(thor, file)
    thor_drain_io(thor)
    testing.expect_value(t, textedit.text(&file.state), "mine disk one\n")
    testing.expect(t, file.disk_changed, "conflict was not raised")
    testing.expect(t, thor.conflict_file == file, "prompt does not name the file")
    // A second event while the prompt is open must not queue another job.
    thor_reload_file(thor, file)
    testing.expect(t, !file.reloading, "a second reload started while the prompt was open")

    // What accepting the prompt does: the edits go, the disk bytes land.
    file.disk_changed = false
    thor.conflict_file = nil
    thor_reload_file(thor, file, force = true)
    thor_drain_io(thor)
    testing.expect_value(t, textedit.text(&file.state), "disk two\n")
    testing.expect_value(t, file.saved_revision, file.state.revision)

    thor_close_file(thor, 0)
}

// A save must not start while a reload is reading: the reload's read is
// unsynchronized against a concurrent write, so racing them could let a torn
// read land in the buffer once both jobs reap.
@(test)
test_save_skipped_during_reload :: proc(t: ^testing.T) {
    TEST_PATH :: "thor_save_race.tmp"

    write_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("disk one\n"))
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

    textedit.insert_text(&file.state, "mine ")
    testing.expect(t, file.state.revision != file.saved_revision, "edit did not dirty the buffer")

    rewrite_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("disk two\n"))
    testing.expect(t, rewrite_err == nil, "could not rewrite test file")

    thor_reload_file(thor, file)
    testing.expect(t, file.reloading, "reload did not start")
    inflight := thor.inflight_jobs

    thor_save_file(thor, file)
    testing.expect(t, !file.saving, "save started while a reload was in flight")
    testing.expect_value(t, thor.inflight_jobs, inflight)

    thor_drain_io(thor)
    testing.expect(t, !file.reloading, "reload never finished")
    testing.expect(t, file.disk_changed, "conflicting reload did not raise the prompt")

    thor_save_file(thor, file)
    testing.expect(t, file.saving, "save did not start once the reload cleared")
    thor_drain_io(thor)
    testing.expect_value(t, file.saved_revision, file.state.revision)

    saved, read_err := os.read_entire_file(TEST_PATH, context.temp_allocator)
    testing.expect(t, read_err == nil, "could not read back saved file")
    testing.expect_value(t, string(saved), "mine disk one\n")

    thor_close_file(thor, 0)
}

// An edit that ends at exactly what is on disk leaves a clean buffer, so the next
// disk change reloads instead of conflicting.
@(test)
test_reload_edits_matching_disk_clean_buffer :: proc(t: ^testing.T) {
    TEST_PATH :: "thor_match.tmp"

    write_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("same\n"))
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

    // Typed and undone: the revision moved on, the content did not.
    textedit.insert_text(&file.state, "x")
    textedit.undo(&file.state)
    testing.expect_value(t, textedit.text(&file.state), "same\n")
    testing.expect(t, file.state.revision != file.saved_revision, "undo did not leave a stale revision")

    thor_reload_file(thor, file)
    thor_drain_io(thor)
    testing.expect(t, !file.disk_changed, "matching content must not conflict")
    testing.expect_value(t, file.saved_revision, file.state.revision)

    thor_close_file(thor, 0)
}

// A unique path under the OS temp directory, with native separators. TEMP is
// Windows only; POSIX names it TMPDIR and leaves it unset on the CI runners.
@(private = "file")
files_test_temp_path :: proc(name: string) -> string {
    base := os.get_env("TEMP", context.temp_allocator)
    when ODIN_OS != .Windows {
        if base == "" {
            base = os.get_env("TMPDIR", context.temp_allocator)
        }
        if base == "" {
            base = "/tmp"
        }
    }
    base = strings.trim_right(base, "/\\")
    joined, _ := filepath.join({base, fmt.tprintf("%s_%d", name, time.now()._nsec)}, context.temp_allocator)
    return joined
}

// The whole live-reload chain over a real directory: the watcher reports the
// external write, the subscriber routes it to the open file, and the reap lands
// the new bytes in the buffer.
@(test)
test_watcher_reloads_open_file :: proc(t: ^testing.T) {
    root := files_test_temp_path("thor_reload_test")
    if err := os.make_directory(root); err != nil {
        testing.fail_now(t, fmt.tprintf("could not create temp dir %q: %v", root, err))
    }
    defer os.remove(root)

    path, _ := filepath.join({root, "watched.txt"}, context.temp_allocator)
    write_err := os.write_entire_file(path, transmute([]u8) string("one\n"))
    testing.expect(t, write_err == nil, "could not create test file")
    defer os.remove(path)

    thor := test_make_thor()
    defer test_free_thor(thor)
    thor.workspace_dir = root

    thor_open_file(thor, path)
    file := thor.open_files[0]
    for _ in 0 ..< 500 {
        thor_update_files(thor)
        if file.loaded || file.load_failed {
            break
        }
        time.sleep(2 * time.Millisecond)
    }
    testing.expect(t, file.loaded, "load did not complete")

    thor_init_watcher(thor)
    defer thor_shutdown_watcher(thor)
    testing.expect(t, thor.watcher.running, "watcher did not start")

    // watcher_poll, not thor_poll_watcher: the explorer's tree refresh and the
    // git status probe need widgets and a repository this test has neither of.
    // The write is repeated because a change made before the watcher thread's
    // first read call is not queued, and the thread starts asynchronously.
    poll: for _ in 0 ..< 10 {
        rewrite_err := os.write_entire_file(path, transmute([]u8) string("one\ntwo\n"))
        testing.expect(t, rewrite_err == nil, "could not rewrite test file")
        for _ in 0 ..< 30 {
            watch.watcher_poll(&thor.watcher)
            thor_update_files(thor)
            if textedit.text(&file.state) == "one\ntwo\n" {
                break poll
            }
            time.sleep(15 * time.Millisecond)
        }
    }
    testing.expect_value(t, textedit.text(&file.state), "one\ntwo\n")

    // One write can produce several watcher events, so a second reload may still
    // be in flight. Its job owns a thread and a buffer, so it is reaped before
    // the editor goes away.
    for _ in 0 ..< 500 {
        if !file.reloading && !file.reload_pending {
            break
        }
        thor_update_files(thor)
        time.sleep(2 * time.Millisecond)
    }

    thor_close_file(thor, 0)
}

// Explorer delete and drag-drop import both walk whole directory trees, so they
// go to a worker instead of the frame loop. Covers the queue -> worker -> reap
// path, the collision check against a copy queued in the same batch, and that
// neither one finishes before the reap.
@(test)
test_async_file_ops :: proc(t: ^testing.T) {
    // Constants, not temp strings: thor_drain_io frees the temp allocator.
    ROOT :: "thor_fileops.tmp"
    SRC :: ROOT + "/src"
    NESTED :: SRC + "/nested"
    DST :: ROOT + "/dst"
    COPIED :: DST + "/src"

    os.remove_all(ROOT) // a previous run that died mid-test
    defer os.remove_all(ROOT)

    testing.expect(t, os.make_directory(ROOT) == nil, "could not create test root")
    testing.expect(t, os.make_directory(SRC) == nil, "could not create source dir")
    testing.expect(t, os.make_directory(NESTED) == nil, "could not create nested dir")
    testing.expect(t, os.make_directory(DST) == nil, "could not create destination dir")
    testing.expect(t, os.write_entire_file(SRC + "/a.txt", "alpha") == nil, "could not write a.txt")
    testing.expect(t, os.write_entire_file(NESTED + "/b.txt", "beta") == nil, "could not write b.txt")

    thor := test_make_thor()
    defer test_free_thor(thor)
    thor.tree = widgets.tree_create("test-tree", ROOT)
    defer widgets.tree_destroy(&thor.tree.widget)
    defer delete(thor.pending_delete_paths)

    // Import the folder, then the same folder again: the second collides with the
    // copy already queued, which is not on disk yet.
    imports: [dynamic]File_Op_Entry
    testing.expect_value(t, thor_queue_import(thor, &imports, SRC, DST), Import_Result.Queued)
    testing.expect_value(t, thor_queue_import(thor, &imports, SRC, DST), Import_Result.Failed)
    testing.expect_value(t, len(imports), 1)

    thor_start_file_op(thor, .Copy, imports, DST)
    testing.expect_value(t, thor.inflight_jobs, 1) // the copy left the main thread
    thor_drain_io(thor)
    testing.expect_value(t, thor.inflight_jobs, 0)

    top_data, top_err := os.read_entire_file(COPIED + "/a.txt", context.temp_allocator)
    nested_data, nested_err := os.read_entire_file(COPIED + "/nested/b.txt", context.temp_allocator)
    testing.expect(t, top_err == nil, "copied file missing")
    testing.expect(t, nested_err == nil, "copied nested file missing")
    testing.expect_value(t, string(top_data), "alpha")
    testing.expect_value(t, string(nested_data), "beta")
    testing.expect_value(t, thor.status_message, "Copied 1 item into dst")

    // Delete the copy back off disk through the confirmation callback.
    append(&thor.pending_delete_paths, strings.clone(COPIED))
    thor_confirm_delete(thor)
    testing.expect_value(t, thor.inflight_jobs, 1) // the delete left the main thread too
    testing.expect_value(t, len(thor.pending_delete_paths), 0)
    thor_drain_io(thor)
    testing.expect_value(t, thor.inflight_jobs, 0)

    testing.expect(t, !os.exists(COPIED), "deleted folder still on disk")
    testing.expect(t, os.exists(SRC), "delete reached the source folder")
    testing.expect_value(t, thor.status_message, "Deleted src")
}

// Tab labels are grouped by base name, so this covers the three cases the
// grouping keeps apart: a name that stands alone, a collision one segment
// settles, and one that needs a second segment.
@(test)
test_tab_labels_disambiguate :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    cases := [?]struct {
        path:  string,
        name:  string,
        label: string,
    } {
        {"D:/thor/thor/state.odin", "state.odin", "state.odin — thor/thor"},
        {"D:/thor/ui/state.odin", "state.odin", "state.odin — ui"},
        {"D:/thor/widgets/editor.odin", "editor.odin", "editor.odin"},
        {"D:/other/thor/state.odin", "state.odin", "state.odin — other/thor"},
    }
    for entry in cases {
        file := new(Open_File)
        file.path = entry.path
        file.name = entry.name
        append(&thor.open_files, file)
    }
    defer for file in thor.open_files {
        delete(file.tab_label)
        free(file)
    }

    thor_update_tab_labels(thor)
    for entry, i in cases {
        testing.expect_value(t, thor.open_files[i].tab_label, entry.label)
    }

    // A backslash path reads the same: the suffix is normalized to '/'.
    thor.open_files[0].path = "D:\\thor\\thor\\state.odin"
    thor_update_tab_labels(thor)
    testing.expect_value(t, thor.open_files[0].tab_label, "state.odin — thor/thor")
}

// A confirmed delete must not be undone by a save already writing the same file:
// the two run on separate workers, so the delete waits the save out first. The
// tab is closed for a folder delete too, or autosave would write the file back.
@(test)
test_delete_settles_an_inflight_save :: proc(t: ^testing.T) {
    ROOT :: "thor_delete_save.tmp"
    NESTED :: ROOT + "/nested"
    TEST_PATH :: NESTED + "/doomed.txt"

    os.remove_all(ROOT) // a previous run that died mid-test
    defer os.remove_all(ROOT)
    testing.expect(t, os.make_directory(ROOT) == nil, "could not create test root")
    testing.expect(t, os.make_directory(NESTED) == nil, "could not create nested dir")
    testing.expect(t, os.write_entire_file(TEST_PATH, transmute([]u8) string("disk\n")) == nil, "could not create test file")

    thor := test_make_thor()
    defer test_free_thor(thor)
    thor.tree = widgets.tree_create("test-tree", ROOT)
    defer widgets.tree_destroy(&thor.tree.widget)
    defer delete(thor.pending_delete_paths)

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

    textedit.insert_text(&file.state, "unsaved ")
    thor_save_file(thor, file)
    testing.expect(t, file.saving, "save did not start")

    // The folder, not the file: the tab still has to close, and the save under
    // it still has to settle.
    append(&thor.pending_delete_paths, strings.clone(NESTED))
    thor_confirm_delete(thor)
    testing.expect_value(t, len(thor.open_files), 0)
    // Only the delete is left in flight; the save was settled before it started.
    testing.expect_value(t, thor.inflight_jobs, 1)

    thor_drain_io(thor)
    testing.expect_value(t, thor.inflight_jobs, 0)
    testing.expect_value(t, len(thor.zombie_files), 0)
    testing.expect(t, !os.exists(TEST_PATH), "the save put the deleted file back")
    testing.expect(t, !os.exists(NESTED), "deleted folder still on disk")
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
    thor.finished_file_ops = make([dynamic]^File_Op_Job)
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
    // The disk-conflict prompt runs through the palette; creating it only allocates.
    thor.command_palette = widgets.command_palette_create("test-palette")
    return thor
}

@(private = "file")
test_free_thor :: proc(thor: ^Thor) {
    delete(thor.status_message)
    delete(thor.conflict_prompt)
    widgets.command_palette_destroy(&thor.command_palette.widget)
    delete(thor.open_files)
    delete(thor.zombie_files)
    delete(thor.finished_loads)
    delete(thor.finished_saves)
    delete(thor.finished_file_ops)
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
