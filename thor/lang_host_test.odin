package thor

import "core:os"
import "core:testing"

import "../lang"

// A rename touching a file that is not open is written straight to disk, so the
// buffer undo stack knows nothing about it. Ctrl+Z has to take those files back
// too, or a workspace rename is only half undoable.
@(test)
test_undo_edits_in_closed_files :: proc(t: ^testing.T) {
    PATH :: "thor_edit_undo.tmp"
    ORIGINAL :: "alpha :: 1\nbeta :: alpha\n"

    testing.expect(t, os.write_entire_file(PATH, ORIGINAL) == nil, "could not create test file")
    defer os.remove(PATH)

    thor := new(Thor)
    defer free(thor)
    defer thor_clear_edit_undo(thor)
    defer delete(thor.status_message)

    edits := []lang.Text_Edit {
        {path = PATH, start = 0, end = 5, old_text = "alpha", new_text = "gamma"},
        {path = PATH, start = 19, end = 24, old_text = "alpha", new_text = "gamma"},
    }
    applied, files, ok, reason := thor_apply_edits(thor, edits, "", 0)
    testing.expectf(t, ok, "apply refused the edits: %s", reason)
    testing.expect_value(t, applied, 2)
    testing.expect_value(t, files, 1)

    renamed, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, string(renamed), "gamma :: 1\nbeta :: gamma\n")

    testing.expect(t, thor_undo_last_edits(thor), "undo refused a file it had just written")
    restored, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, string(restored), ORIGINAL)

    // The set is undoable once; a second ctrl+z belongs to the focused buffer.
    testing.expect(t, !thor_undo_last_edits(thor), "the edit set undid twice")
}

// A file that changed after the edits landed is left alone: the content that
// would be written back is no longer what the edits were computed against.
@(test)
test_undo_edits_refuses_changed_file :: proc(t: ^testing.T) {
    PATH :: "thor_edit_undo_changed.tmp"
    ORIGINAL :: "alpha :: 1\n"
    EDITED :: "gamma :: 1\nextra :: 2\n"

    testing.expect(t, os.write_entire_file(PATH, ORIGINAL) == nil, "could not create test file")
    defer os.remove(PATH)

    thor := new(Thor)
    defer free(thor)
    defer thor_clear_edit_undo(thor)
    defer delete(thor.status_message)

    edits := []lang.Text_Edit {
        {path = PATH, start = 0, end = 5, old_text = "alpha", new_text = "gamma"},
    }
    _, _, ok, _ := thor_apply_edits(thor, edits, "", 0)
    testing.expect(t, ok, "apply refused the edit")

    testing.expect(t, os.write_entire_file(PATH, EDITED) == nil, "could not touch the test file")
    testing.expect(t, !thor_undo_last_edits(thor), "undo clobbered a file that changed since")

    after, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, string(after), EDITED)
}
