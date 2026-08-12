package thor

import "core:testing"

import "../textedit"
import "../ui"

// An Open_File over `src`, loaded and saved. The caller destroys it.
@(private = "file")
indent_test_file :: proc(src: string) -> ^Open_File {
    file := new(Open_File)
    file.path = "D:/w/a.odin"
    file.loaded = true
    textedit.init(&file.state)
    textedit.set_text(&file.state, src)
    file.saved_revision = file.state.revision
    return file
}

@(private = "file")
indent_test_destroy :: proc(file: ^Open_File) {
    textedit.destroy(&file.state)
    free(file)
}

// The status bar used to claim spaces for every file. It reads the buffer now,
// so a tab-indented file says so.
@(test)
test_status_indent_follows_the_buffer :: proc(t: ^testing.T) {
    spaced := indent_test_file("func f() {\n    return 1\n}\n")
    defer indent_test_destroy(spaced)

    thor_refresh_indent(spaced)
    testing.expect(t, spaced.indent_ready, "the first ask scans")
    testing.expect_value(t, spaced.indent.style, textedit.Indent_Style.Spaces)
    testing.expect_value(t, spaced.indent.width, 4)

    tabbed := indent_test_file("func f() {\n\treturn 1\n}\n")
    defer indent_test_destroy(tabbed)

    thor_refresh_indent(tabbed)
    testing.expect_value(t, tabbed.indent.style, textedit.Indent_Style.Tabs)
}

// A two-space file reports two, not the global tab width.
@(test)
test_status_indent_reports_the_detected_width :: proc(t: ^testing.T) {
    file := indent_test_file("a:\n  b\n  c\n")
    defer indent_test_destroy(file)

    thor_refresh_indent(file)
    testing.expect_value(t, file.indent.style, textedit.Indent_Style.Spaces)
    testing.expect_value(t, file.indent.width, 2)
}

// The scan is cached: an unchanged buffer is never walked twice, which is what
// keeps a per-frame status bar off a whole-file scan.
@(test)
test_status_indent_caches_on_the_revision :: proc(t: ^testing.T) {
    file := indent_test_file("a:\n  b\n")
    defer indent_test_destroy(file)

    thor_refresh_indent(file)
    first := file.indent_revision

    // Nothing changed, so the recorded revision must not move.
    file.indent_time = -1000
    thor_refresh_indent(file)
    testing.expect_value(t, file.indent_revision, first)

    // An edit does move it, once the interval has passed. set_text is no use
    // here: it resets the revision to 0 rather than advancing it.
    textedit.replace_ranges(&file.state, []textedit.Replace{{start = 3, end = 3, text = "  "}})
    file.indent_time = -1000
    thor_refresh_indent(file)
    testing.expect(t, file.indent_revision != first, "an edited buffer is rescanned")
    testing.expect_value(t, file.indent.width, 4)
}

// The Undo and Redo menu rows grey out from these, so they have to answer for
// the focused buffer's own history as well as a cross-file edit set.
@(test)
test_can_undo_and_redo_follow_the_buffer :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    // No file open at all: both rows stay dead.
    ui.signal_set(&thor.active_file, -1)
    testing.expect(t, !thor_can_undo(thor), "nothing is open, so there is nothing to undo")
    testing.expect(t, !thor_can_redo(thor), "nothing is open, so there is nothing to redo")

    file := indent_test_file("alpha\n")
    defer indent_test_destroy(file)
    append(&thor.open_files, file)
    ui.signal_set(&thor.active_file, 0)

    // set_text clears the history, so an untouched buffer has nothing either.
    testing.expect(t, !thor_can_undo(thor), "an untouched buffer has no history")

    textedit.replace_ranges(&file.state, []textedit.Replace{{start = 0, end = 5, text = "beta"}})
    testing.expect(t, thor_can_undo(thor), "an edit is undoable")
    testing.expect(t, !thor_can_redo(thor), "nothing has been undone yet")

    textedit.undo(&file.state)
    testing.expect(t, thor_can_redo(thor), "an undone edit is redoable")
}

// A buffer still loading has nothing to read, so the scan must not run on it.
@(test)
test_status_indent_skips_an_unloaded_file :: proc(t: ^testing.T) {
    file := indent_test_file("")
    defer indent_test_destroy(file)
    file.loaded = false

    thor_refresh_indent(file)
    testing.expect(t, !file.indent_ready, "an unloaded buffer is not scanned")
}
