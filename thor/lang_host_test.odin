package thor

import "core:os"
import "core:strings"
import "core:testing"

import "../lang"
import "../setting"
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
    // An undone set moves to the redo slot rather than being dropped, so that
    // side owns the record afterwards.
    defer thor_clear_edit_redo(thor)
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

// Undo hands the set to the redo slot, so ctrl+shift+z puts a whole rename back
// across the files it touched — including those that were never open.
@(test)
test_redo_edits_in_closed_files :: proc(t: ^testing.T) {
    PATH :: "thor_edit_redo.tmp"
    ORIGINAL :: "alpha :: 1\nbeta :: alpha\n"
    RENAMED :: "gamma :: 1\nbeta :: gamma\n"

    testing.expect(t, os.write_entire_file(PATH, ORIGINAL) == nil, "could not create test file")
    defer os.remove(PATH)

    thor := new(Thor)
    defer free(thor)
    defer thor_clear_edit_undo(thor)
    defer thor_clear_edit_redo(thor)
    defer delete(thor.status_message)

    edits := []lang.Text_Edit {
        {path = PATH, start = 0, end = 5, old_text = "alpha", new_text = "gamma"},
        {path = PATH, start = 19, end = 24, old_text = "alpha", new_text = "gamma"},
    }
    _, _, ok, reason := thor_apply_edits(thor, edits, "", 0)
    testing.expectf(t, ok, "apply refused the edits: %s", reason)

    testing.expect(t, thor_undo_last_edits(thor), "undo refused a file it had just written")
    undone, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, string(undone), ORIGINAL)

    testing.expect(t, thor_redo_last_edits(thor), "redo refused a file it had just restored")
    redone, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, string(redone), RENAMED)

    // Redo is spent, and the set is undoable again: the two sides hand the one
    // record back and forth.
    testing.expect(t, !thor_redo_last_edits(thor), "the edit set redid twice")
    testing.expect(t, thor_undo_last_edits(thor), "the set is undoable again after a redo")
    again, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, string(again), ORIGINAL)
}

// The settings own a backend's gate for every key they state, and state nothing
// for the rest — those fall back to the backend's own default. Without a client
// the fallback is fully on, which is what the in-client Odin engine always uses.
@(test)
test_backend_gate_resolves_stated_over_default :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.config.general.language_backends = make(map[string]setting.Backend_Setting)
    defer {
        for key in thor.config.general.language_backends {
            delete(key)
        }
        delete(thor.config.general.language_backends)
    }

    on, features := thor_backend_gate(thor, &thor.config, ODIN_BACKEND_ID)
    testing.expect(t, on, "a backend no layer names must default to on")
    testing.expect_value(t, features, lang.FEATURES_ALL)

    // A layer that names one feature and nothing else: only that key is owned.
    thor.config.general.language_backends[strings.clone(ODIN_BACKEND_ID)] = setting.Backend_Setting {
        enabled      = false,
        features     = lang.FEATURES_ALL - {.Format},
        features_set = {.Format},
    }
    on, features = thor_backend_gate(thor, &thor.config, ODIN_BACKEND_ID)
    testing.expect(t, on, "an unstated enabled key must not take this struct's own default")
    testing.expect_value(t, features, lang.FEATURES_ALL - {.Format})

    // The same entry, now stating the switch too.
    thor.config.general.language_backends[ODIN_BACKEND_ID] = setting.Backend_Setting {
        enabled      = false,
        enabled_set  = true,
        features     = lang.FEATURES_ALL,
        features_set = {},
    }
    on, features = thor_backend_gate(thor, &thor.config, ODIN_BACKEND_ID)
    testing.expect(t, !on)
    testing.expect_value(t, features, lang.FEATURES_ALL)
}

// A file that changed after the undo is left alone: what redo would write over
// is no longer what the undo put there.
@(test)
test_redo_edits_refuses_changed_file :: proc(t: ^testing.T) {
    PATH :: "thor_edit_redo_changed.tmp"
    ORIGINAL :: "alpha :: 1\n"
    TOUCHED :: "something else entirely\n"

    testing.expect(t, os.write_entire_file(PATH, ORIGINAL) == nil, "could not create test file")
    defer os.remove(PATH)

    thor := new(Thor)
    defer free(thor)
    defer thor_clear_edit_undo(thor)
    defer thor_clear_edit_redo(thor)
    defer delete(thor.status_message)

    edits := []lang.Text_Edit {
        {path = PATH, start = 0, end = 5, old_text = "alpha", new_text = "gamma"},
    }
    _, _, ok, _ := thor_apply_edits(thor, edits, "", 0)
    testing.expect(t, ok, "apply refused the edit")
    testing.expect(t, thor_undo_last_edits(thor), "undo refused the file")

    testing.expect(t, os.write_entire_file(PATH, TOUCHED) == nil, "could not touch the test file")
    testing.expect(t, !thor_redo_last_edits(thor), "redo clobbered a file that changed since")

    after, _ := os.read_entire_file(PATH, context.temp_allocator)
    testing.expect_value(t, string(after), TOUCHED)
}

// A fresh edit set makes the redo chain moot, the way a buffer edit clears its
// own redo stack.
@(test)
test_new_edit_set_clears_redo :: proc(t: ^testing.T) {
    PATH :: "thor_edit_redo_cleared.tmp"
    ORIGINAL :: "alpha :: 1\n"

    testing.expect(t, os.write_entire_file(PATH, ORIGINAL) == nil, "could not create test file")
    defer os.remove(PATH)

    thor := new(Thor)
    defer free(thor)
    defer thor_clear_edit_undo(thor)
    defer thor_clear_edit_redo(thor)
    defer delete(thor.status_message)

    first := []lang.Text_Edit {
        {path = PATH, start = 0, end = 5, old_text = "alpha", new_text = "gamma"},
    }
    _, _, ok, _ := thor_apply_edits(thor, first, "", 0)
    testing.expect(t, ok, "apply refused the first edit")
    testing.expect(t, thor_undo_last_edits(thor), "undo refused the file")
    testing.expect_value(t, len(thor.edit_redo), 1)

    second := []lang.Text_Edit {
        {path = PATH, start = 0, end = 5, old_text = "alpha", new_text = "delta"},
    }
    _, _, second_ok, _ := thor_apply_edits(thor, second, "", 0)
    testing.expect(t, second_ok, "apply refused the second edit")
    testing.expect_value(t, len(thor.edit_redo), 0)
    testing.expect(t, !thor_redo_last_edits(thor), "a new edit set left a stale redo behind")
}

// An open buffer rides its own undo entry in both directions, and the recorded
// revision has to follow each move or the next one refuses the set.
@(test)
test_redo_edits_in_an_open_buffer :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    defer thor_clear_edit_undo(thor)
    defer thor_clear_edit_redo(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)
    defer delete(thor.status_message)

    file := new(Open_File)
    file.path = "D:/w/pkg/a.odin"
    file.loaded = true
    textedit.init(&file.state)
    textedit.set_text(&file.state, "alpha :: 1\n")
    file.saved_revision = file.state.revision
    defer {
        textedit.destroy(&file.state)
        free(file)
    }
    append(&thor.open_files, file)

    edits := []lang.Text_Edit {
        {path = "D:/w/pkg/a.odin", start = 0, end = 5, old_text = "alpha", new_text = "gamma"},
    }
    _, _, ok, reason := thor_apply_edits(thor, edits, "", 0)
    testing.expectf(t, ok, "apply refused the edits: %s", reason)
    testing.expect_value(t, textedit.text(&file.state), "gamma :: 1\n")

    testing.expect(t, thor_undo_last_edits(thor), "undo refused the buffer")
    testing.expect_value(t, textedit.text(&file.state), "alpha :: 1\n")
    testing.expect_value(t, thor.edit_redo[0].revision, file.state.revision)

    testing.expect(t, thor_redo_last_edits(thor), "redo refused the buffer")
    testing.expect_value(t, textedit.text(&file.state), "gamma :: 1\n")
    testing.expect_value(t, thor.edit_undo[0].revision, file.state.revision)

    // A keystroke of its own moves the buffer past the recorded entry, so the
    // set no longer applies and ctrl+z belongs to the buffer alone.
    textedit.replace_ranges(&file.state, []textedit.Replace{{start = 10, end = 10, text = "x"}})
    testing.expect(t, !thor_undo_last_edits(thor), "the set undid over a buffer that moved on")
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
    defer thor_clear_edit_redo(thor)
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

// An LSP code action's edit names its file the way the server spells it, which
// need not match the spelling it was opened under. The origin buffer must still
// be recognized as itself — a spelling-only difference used to fall through to
// the "already saved" branch and refuse the edit on an unsaved buffer, exactly
// the state a quick fix is applied from.
@(test)
test_apply_edits_matches_origin_regardless_of_path_spelling :: proc(t: ^testing.T) {
    OPEN_PATH :: "w/pkg/a.odin"
    EDIT_PATH :: "w/./pkg/a.odin"

    thor := new(Thor)
    defer free(thor)
    defer thor_clear_edit_undo(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)
    defer delete(thor.status_message)

    file := new(Open_File)
    file.path = OPEN_PATH
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
        {path = EDIT_PATH, start = 0, end = 3, old_text = "foo", new_text = "baz"},
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
// pointed at the old path, the same way thor_confirm_rename does.
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
