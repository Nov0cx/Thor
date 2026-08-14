package widgets

import "core:testing"

@(private = "file")
make_test_git_view :: proc() -> ^Git_View {
    view := git_view_create("test-git-view")
    // Geometry large enough that every region has room; no window is needed,
    // layout is pure math.
    git_view_layout(&view.widget, {0, 0, 1400, 900})
    return view
}

@(private = "file")
destroy_test_git_view :: proc(view: ^Git_View) {
    git_view_destroy(&view.widget)
}

// The combined Up/Down selection walks the unstaged list into the staged one,
// notifying the host on each move.
@(test)
test_git_view_selection_crosses_sections :: proc(t: ^testing.T) {
    view := make_test_git_view()
    defer destroy_test_git_view(view)
    git_view_add_file(view, "a.txt", "a.txt", .Modified, false)
    git_view_add_file(view, "b.txt", "b.txt", .Untracked, false)
    git_view_add_file(view, "c.txt", "c.txt", .Added, true)

    selected: [dynamic]string
    defer delete(selected)
    view.cbs.on_select_file = proc(data: rawptr, path: string, staged: bool) {
        append(cast(^[dynamic]string) data, path)
    }
    view.data = &selected

    git_view_move_file_selection(view, 1) // first move lands on the first row
    git_view_move_file_selection(view, 1)
    git_view_move_file_selection(view, 1) // crosses into the staged list
    git_view_move_file_selection(view, 1) // clamped at the end

    path, staged, ok := git_view_selected_file(view)
    testing.expect(t, ok, "no selection after moves")
    testing.expect_value(t, path, "c.txt")
    testing.expect_value(t, staged, true)
    testing.expect_value(t, len(selected), 3)
    testing.expect_value(t, selected[0], "a.txt")
    testing.expect_value(t, selected[2], "c.txt")
}

// A refresh (clear + re-add) keeps the selected path selected when it is still
// in the same list, so the diff pane does not blank on every stage.
@(test)
test_git_view_selection_survives_refresh :: proc(t: ^testing.T) {
    view := make_test_git_view()
    defer destroy_test_git_view(view)
    git_view_add_file(view, "a.txt", "a.txt", .Modified, false)
    git_view_add_file(view, "b.txt", "b.txt", .Modified, false)
    git_view_select_file(view, false, 1)

    git_view_clear_files(view)
    git_view_add_file(view, "b.txt", "b.txt", .Modified, false)
    git_view_add_file(view, "a.txt", "a.txt", .Modified, false)

    path, staged, ok := git_view_selected_file(view)
    testing.expect(t, ok, "selection lost across refresh")
    testing.expect_value(t, path, "b.txt")
    testing.expect_value(t, staged, false)

    // The file left the list entirely: nothing stays selected.
    git_view_clear_files(view)
    git_view_add_file(view, "other.txt", "other.txt", .Modified, false)
    _, _, gone := git_view_selected_file(view)
    testing.expect(t, !gone, "selection survived a vanished file")
}

// The commit button needs something to commit and a subject; amend commits
// with an empty index, busy blocks everything.
@(test)
test_git_view_can_commit :: proc(t: ^testing.T) {
    view := make_test_git_view()
    defer destroy_test_git_view(view)

    testing.expect(t, !git_view_can_commit(view), "empty view can commit")

    git_view_add_file(view, "a.txt", "a.txt", .Modified, true)
    testing.expect(t, !git_view_can_commit(view), "no subject but can commit")

    git_view_field_insert(&view.subject, "fix things", false)
    testing.expect(t, git_view_can_commit(view), "staged + subject refused")

    view.busy = true
    testing.expect(t, !git_view_can_commit(view), "busy but can commit")
    view.busy = false

    git_view_clear_files(view)
    testing.expect(t, !git_view_can_commit(view), "nothing staged but can commit")
    view.amend = true
    testing.expect(t, git_view_can_commit(view), "amend with empty index refused")
}

// Pasted text is filtered: \r never lands, and a single-line field stops at
// the first newline.
@(test)
test_git_view_field_insert_filters :: proc(t: ^testing.T) {
    view := make_test_git_view()
    defer destroy_test_git_view(view)

    git_view_field_insert(&view.subject, "one\r\ntwo", false)
    testing.expect_value(t, string(view.subject.buf[:]), "one")

    git_view_field_insert(&view.description, "one\r\ntwo", true)
    testing.expect_value(t, string(view.description.buf[:]), "one\ntwo")
    testing.expect_value(t, view.description.caret, len("one\ntwo"))
}

// Up/Down in the description keep the rune column, counted in runes so a
// multi-byte line does not land the caret mid-rune.
@(test)
test_git_view_caret_vertical_keeps_column :: proc(t: ^testing.T) {
    text := "äbc\nxy\nlong line"

    // From column 2 of the first line down to column 2 of the second.
    caret := len("äb") // after ä (2 bytes) + b
    caret = git_view_caret_vertical(text, caret, 1)
    testing.expect_value(t, text[:caret], "äbc\nxy")

    // Down again: column 2 of the third line.
    caret = git_view_caret_vertical(text, caret, 1)
    testing.expect_value(t, text[:caret], "äbc\nxy\nlo")

    // Up twice returns to the first line, same column.
    caret = git_view_caret_vertical(text, caret, -1)
    caret = git_view_caret_vertical(text, caret, -1)
    testing.expect_value(t, text[:caret], "äb")

    // The edges stay put.
    testing.expect_value(t, git_view_caret_vertical(text, 0, -1), 0)
    end := len(text)
    testing.expect_value(t, git_view_caret_vertical(text, end, 1), end)
}

// Line helpers work on byte offsets around embedded newlines.
@(test)
test_git_view_line_bounds :: proc(t: ^testing.T) {
    text := "ab\ncd"
    testing.expect_value(t, git_view_line_start(text, 4), 3)
    testing.expect_value(t, git_view_line_end(text, 0), 2)
    testing.expect_value(t, git_view_line_end(text, 4), 5)
    testing.expect_value(t, git_view_line_start(text, 1), 0)
}
