package thor

import "core:strings"
import "core:testing"

import "../textedit"

@(private = "file")
undo_test_file :: proc(thor: ^Thor) -> ^Open_File {
    thor.open_files = make([dynamic]^Open_File)
    file := new(Open_File)
    file.path = strings.clone("w/a.txt")
    file.loaded = true
    textedit.init(&file.state)
    append(&thor.open_files, file)
    signal_set(&thor.active_file, 0)
    return file
}

@(private = "file")
undo_test_free :: proc(thor: ^Thor, file: ^Open_File) {
    thor_undo_history_destroy(thor)
    textedit.destroy(&file.state)
    delete(file.path)
    free(file)
    delete(thor.open_files)
    delete(thor.status_message)
    free(thor)
}

@(test)
test_undo_history_preview_and_restore :: proc(t: ^testing.T) {
    thor := new(Thor)
    file := undo_test_file(thor)
    defer undo_test_free(thor, file)

    textedit.insert_text(&file.state, "aa")
    textedit.insert_text(&file.state, "bb")
    textedit.undo(&file.state)
    textedit.insert_text(&file.state, "cc")

    thor_cmd_undo_history(thor)
    v := &thor.undo_view
    testing.expect(t, thor.undo_open)
    // cc, bb, aa, root.
    testing.expect_value(t, len(v.rows), 4)
    testing.expect_value(t, v.selected, 0)
    testing.expect_value(t, v.branches, 2)

    // A move previews the state; Escape goes back.
    undo_view_select(thor, file, 1)
    testing.expect_value(t, textedit.text(&file.state), "aabb")
    undo_view_select(thor, file, 3)
    testing.expect_value(t, textedit.text(&file.state), "")
    thor_undo_history_close(thor, false)
    testing.expect(t, !thor.undo_open)
    testing.expect_value(t, textedit.text(&file.state), "aacc")

    // Enter keeps the state.
    thor_cmd_undo_history(thor)
    undo_view_select(thor, file, 1)
    thor_undo_history_close(thor, true)
    testing.expect_value(t, textedit.text(&file.state), "aabb")

    // An edit made under the modal is never undone by the close.
    thor_cmd_undo_history(thor)
    undo_view_select(thor, file, 2)
    textedit.insert_text(&file.state, "zz")
    thor_undo_history_close(thor, false)
    testing.expect_value(t, textedit.text(&file.state), "aazz")
}

@(test)
test_undo_history_joins_typing_runs :: proc(t: ^testing.T) {
    thor := new(Thor)
    file := undo_test_file(thor)
    defer undo_test_free(thor, file)

    for s in ([]string{"a", " ", "b"}) {
        textedit.insert_text(&file.state, s)
    }
    thor_cmd_undo_history(thor)
    v := &thor.undo_view
    // The three keystroke steps, then the root.
    testing.expect_value(t, len(v.rows), 2)
    testing.expect_value(t, v.rows[0].count, 3)
    testing.expect_value(t, undo_row_label(&file.state, v.rows[0]), "Typed \"a b\"")
    label, hunks, _ := undo_row_change(&file.state, v.rows[0])
    testing.expect_value(t, label, "Typed \"a b\"")
    testing.expect_value(t, len(hunks), 1)
    testing.expect_value(t, hunks[0], textedit.Node_Hunk{pos = 0, inserted = 3})

    // Left steps inside the run; the row stays selected.
    undo_view_step(thor, file, -1)
    testing.expect_value(t, textedit.text(&file.state), "a ")
    testing.expect_value(t, v.selected, 0)
    label, _, _ = undo_row_change(&file.state, v.rows[0])
    testing.expect(t, strings.has_prefix(label, "Step 2 of 3"))
    undo_view_step(thor, file, 1)
    testing.expect_value(t, textedit.text(&file.state), "a b")

    // The start state is never inside a run.
    thor_undo_history_close(thor, true)
    textedit.undo(&file.state)
    thor_cmd_undo_history(thor)
    testing.expect_value(t, len(v.rows), 3)
    thor_undo_history_close(thor, true)
}

@(test)
test_undo_history_labels_and_diff :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_text(&state, "one\ntwo\nthree\n")

    root := textedit.history_node(&state, textedit.history_root(&state))
    testing.expect(t, root == nil)

    textedit.select_range(&state, 4, 7)
    textedit.insert_text(&state, "2")
    node := textedit.history_node(&state, textedit.history_current(&state))
    testing.expect_value(t, undo_step_label(node), "Replaced \"two\" → \"2\"")
    testing.expect_value(t, node.line, 1)

    rows := undo_diff_rows(&state, textedit.node_hunks(node, context.temp_allocator))
    found_removed, found_added := false, false
    for row in rows {
        if row.kind == .Removed && row.text == "two" && row.line == 2 {
            found_removed = true
        }
        if row.kind == .Added && row.text == "2" && row.line == 2 {
            found_added = true
        }
    }
    testing.expect(t, found_removed)
    testing.expect(t, found_added)

    // A whole line deleted shows only that line.
    textedit.select_range(&state, 0, 4)
    textedit.delete_backward(&state)
    node = textedit.history_node(&state, textedit.history_current(&state))
    testing.expect_value(t, undo_step_label(node), "Deleted 1 line")
    rows = undo_diff_rows(&state, textedit.node_hunks(node, context.temp_allocator))
    removed := 0
    for row in rows {
        if row.kind == .Removed {
            removed += 1
            testing.expect_value(t, row.text, "one")
        }
        testing.expect(t, row.kind != .Added)
    }
    testing.expect_value(t, removed, 1)

    root = textedit.history_node(&state, textedit.history_root(&state))
    testing.expect_value(t, undo_step_label(root), "Opened file")
}
