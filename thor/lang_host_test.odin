package thor

import "core:os"
import "core:strings"
import "core:testing"

import "../lang"
import "../textedit"

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

// An LSP code action's edit names its file with the drive letter the server
// spelled it with (basedpyright, notably, lowercases it), which need not match
// the case the file was opened under. The origin buffer must still be
// recognized as itself — a case-only difference used to fall through to the
// "already saved" branch and refuse the edit on an unsaved buffer, exactly the
// state a quick fix is applied from.
@(test)
test_apply_edits_matches_origin_regardless_of_drive_letter_case :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    defer thor_clear_edit_undo(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)
    defer delete(thor.status_message)

    file := new(Open_File)
    file.path = "D:/w/pkg/a.odin"
    file.loaded = true
    textedit.init(&file.state)
    textedit.set_text(&file.state, "foo := bar\n")
    file.saved_revision = file.state.revision
    // An unsaved keystroke past what "foo" needs, so the buffer is dirty —
    // the state a quick fix is normally applied from.
    textedit.replace_ranges(&file.state, []textedit.Replace{{start = 11, end = 11, text = "x"}})
    defer {
        textedit.destroy(&file.state)
        free(file)
    }
    append(&thor.open_files, file)

    edits := []lang.Text_Edit {
        {path = "d:/w/pkg/a.odin", start = 0, end = 3, old_text = "foo", new_text = "baz"},
    }
    applied, files, ok, reason := thor_apply_edits(thor, edits, file.path, file.state.revision)
    testing.expectf(t, ok, "apply refused an edit against its own origin buffer: %s", reason)
    testing.expect_value(t, applied, 1)
    testing.expect_value(t, files, 1)
    testing.expect_value(t, textedit.text(&file.state), "baz := bar\nx")
}

// Resource_Op.Create writes an empty file when nothing is there yet.
@(test)
test_create_resource_writes_empty_file :: proc(t: ^testing.T) {
    PATH :: "thor_create_resource.tmp"
    defer os.remove(PATH)

    ok, reason := thor_create_resource(PATH, false, false)
    testing.expectf(t, ok, "create refused an empty target: %s", reason)
    data, err := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect(t, err == nil, "the file was never written")
    testing.expect_value(t, string(data), "")
}

// CreateFileOptions.ignoreIfExists: an existing target is left untouched, not
// truncated, and the op still reports success.
@(test)
test_create_resource_ignore_if_exists_leaves_content :: proc(t: ^testing.T) {
    PATH :: "thor_create_resource_ignore.tmp"
    testing.expect(t, os.write_entire_file(PATH, "kept") == nil, "could not create test file")
    defer os.remove(PATH)

    ok, _ := thor_create_resource(PATH, false, true)
    testing.expect(t, ok, "ignore_if_exists must not refuse an existing target")
    data, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, string(data), "kept")
}

// Neither overwrite nor ignoreIfExists set: an existing target refuses the op.
@(test)
test_create_resource_refuses_existing_target :: proc(t: ^testing.T) {
    PATH :: "thor_create_resource_refuse.tmp"
    testing.expect(t, os.write_entire_file(PATH, "kept") == nil, "could not create test file")
    defer os.remove(PATH)

    ok, _ := thor_create_resource(PATH, false, false)
    testing.expect(t, !ok, "create must refuse an existing target with no option set")
    data, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, string(data), "kept")
}

// Resource_Op.Delete removes the file; a target that no longer exists refuses
// rather than silently succeeding.
@(test)
test_delete_resource :: proc(t: ^testing.T) {
    PATH :: "thor_delete_resource.tmp"
    testing.expect(t, os.write_entire_file(PATH, "x") == nil, "could not create test file")

    thor := new(Thor)
    defer free(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    ok, reason := thor_delete_resource(thor, PATH)
    testing.expectf(t, ok, "delete refused an existing file: %s", reason)
    testing.expect(t, !os.exists(PATH), "the file was not removed")

    ok2, _ := thor_delete_resource(thor, PATH)
    testing.expect(t, !ok2, "delete must refuse a target that no longer exists")
}

// Resource_Op.Rename moves the file on disk and retargets any open tab that
// pointed at the old path, the same way thor_prompt_rename does.
@(test)
test_rename_resource_moves_file_and_retargets_tab :: proc(t: ^testing.T) {
    OLD :: "thor_rename_resource_old.tmp"
    NEW :: "thor_rename_resource_new.tmp"
    testing.expect(t, os.write_entire_file(OLD, "x") == nil, "could not create test file")
    defer os.remove(OLD)
    defer os.remove(NEW)

    thor := new(Thor)
    defer free(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    file := new(Open_File)
    file.path = strings.clone(OLD) // owned, matching a real Open_File's contract
    file.name = OLD
    file.loaded = true
    defer {
        delete(file.path)
        delete(file.tab_label)
        free(file)
    }
    append(&thor.open_files, file)

    ok, reason := thor_rename_resource(thor, OLD, NEW, false)
    testing.expectf(t, ok, "rename refused: %s", reason)
    testing.expect(t, !os.exists(OLD), "the old path still exists")
    testing.expect(t, os.exists(NEW), "the new path was never written")
    testing.expect(t, thor_same_path(file.path, NEW), "the open tab was not retargeted")
}

// A rename target that already exists refuses the op unless the server asked
// to overwrite it.
@(test)
test_rename_resource_refuses_existing_target :: proc(t: ^testing.T) {
    OLD :: "thor_rename_resource_refuse_old.tmp"
    NEW :: "thor_rename_resource_refuse_new.tmp"
    testing.expect(t, os.write_entire_file(OLD, "x") == nil, "could not create test file")
    testing.expect(t, os.write_entire_file(NEW, "y") == nil, "could not create test file")
    defer os.remove(OLD)
    defer os.remove(NEW)

    thor := new(Thor)
    defer free(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    ok, _ := thor_rename_resource(thor, OLD, NEW, false)
    testing.expect(t, !ok, "rename must refuse an existing target with no overwrite")
    testing.expect(t, os.exists(OLD), "the old file must be left alone on refusal")
}

// The indicator waits out LANG_BUSY_DELAY_SECS of unbroken work: a request
// answered in a few frames must never flash it, and a break resets the wait.
@(test)
test_lang_busy_needs_a_sustained_stretch :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)

    thor_lang_busy_update(thor, {.Completion}, 1.0)
    testing.expect(t, !thor.lang_busy_shown, "the indicator should not show the instant work starts")

    thor_lang_busy_update(thor, {.Completion}, 1.0 + LANG_BUSY_DELAY_SECS)
    testing.expect(t, thor.lang_busy_shown, "the indicator should show once the delay elapses")

    // Idle clears it, and the next stretch is timed from its own start.
    thor_lang_busy_update(thor, {}, 2.0)
    testing.expect(t, !thor.lang_busy_shown, "an idle manager should clear the indicator")

    thor_lang_busy_update(thor, {.Semantic_Tokens}, 3.0)
    testing.expect(t, !thor.lang_busy_shown, "a fresh stretch should restart the delay")
}

// The label names the most user-visible kind in flight, not whatever the
// passes that run while typing happen to be doing alongside it.
@(test)
test_lang_busy_label_prefers_the_visible_kind :: proc(t: ^testing.T) {
    testing.expect_value(t, thor_lang_busy_label({.Semantic_Tokens}), "Analyzing...")
    testing.expect_value(t, thor_lang_busy_label({.Semantic_Tokens, .Diagnostics}), "Checking...")
    testing.expect_value(t, thor_lang_busy_label({.Semantic_Tokens, .References}), "Finding references...")
    testing.expect_value(t, thor_lang_busy_label({.Completion, .Hover}), "Resolving...")
}
