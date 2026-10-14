package editview

import "core:testing"

import "../textedit"
import ui "../vendor/loom/loom"

import "../font"
import "../snippet"
// The candidate strings are clones; editor_dismiss_completion is file-private to
// editor.odin, so a stack editor frees them here.
@(private = "file")
editor_test_free_completions :: proc(editor: ^Editor) {
    for row in editor.completion_rows {
        delete(row.text)
        delete(row.insert)
        delete(row.filter)
    }
    clear(&editor.completion_rows)
    delete(editor.completion_word)
    editor.completion_word = ""
}

@(private = "file")
editor_test_free_snippet :: proc(editor: ^Editor) {
    snippet.destroy(&editor.snippet_snip)
    delete(editor.snippet_stops)
}

// A stack editor with one caret at the end of `text`, laid out large enough for
// the completion popup to fit under the caret. The caller frees visual_rows.
@(private = "file")
editor_test_completion_setup :: proc(editor: ^Editor, state: ^textedit.State, text: string) {
    textedit.set_text(state, text)
    editor.state = state
    editor.font_size = 16
    editor.view = ui.Rect{0, 0, 600, 600}
    textedit.select_range(state, len(text) - 1, len(text) - 1)
    editor.rows_stale = true
    editor_ensure_visual_rows(editor)
}

// Typing one more character of the same word narrows the candidate list in place
// instead of rescanning the buffer, so the result must still be exactly the words
// that match, in first-occurrence order.
@(test)
test_completion_narrows_while_typing :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "alpha albatross alpine \n")
    for r in "alp" {
        editor_text(&editor, r, {})
    }

    testing.expect(t, editor.completion_active, "typing a word opens the popup")
    testing.expect(t, editor.completion_full, "a list under the cap holds every match")
    testing.expect_value(t, len(editor.completion_rows), 2)
    testing.expect_value(t, editor.completion_rows[0].text, "alpha")
    testing.expect_value(t, editor.completion_rows[1].text, "alpine")
    testing.expect_value(t, editor.completion_prefix, 3)
}

// Clicking a candidate accepts it. The click point comes from the shared rects,
// never from a fixed pixel: font.measure reports 0 with no font atlas, so the
// box collapses to its minimum width in a headless run.
@(test)
test_completion_click_accepts :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "al\n")
    editor_set_completions(&editor, []Completion_Item{{text = "alpha"}, {text = "alphabet"}})
    testing.expect_value(t, len(editor.completion_rows), 2)

    box, lh, top, ok := editor_completion_rects(&editor)
    testing.expect(t, ok, "an active popup has a box")
    testing.expect_value(t, top, 0)

    // Row 1 is "alphabet"; row 0 stays selected until the click moves it.
    point := ui.Vec2 {box.x + 4, box.y + 2 + lh * 1.5}
    testing.expect_value(t, editor_completion_row_at(&editor, point), 1)
    testing.expect_value(t, editor.completion_selected, 0)

    editor_press(&editor, point, .Left, {}, 1)

    testing.expect_value(t, textedit.text(&state), "alphabet\n")
    testing.expect(t, !editor.completion_active, "accepting closes the popup")
    testing.expect(t, editor.suppress_drag, "the accept must not smear into a selection")
}

// A point outside the rows is not a candidate, so the press falls through to the
// text underneath instead of accepting whatever was selected.
@(test)
test_completion_click_outside_rows :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "al\n")
    editor_set_completions(&editor, []Completion_Item{{text = "alpha"}, {text = "alphabet"}})

    box, lh, _, _ := editor_completion_rects(&editor)
    below := ui.Vec2 {box.x + 4, box.y + 2 + lh * cast(f32) len(editor.completion_rows) + 1}
    testing.expect_value(t, editor_completion_row_at(&editor, below), -1)

    left := ui.Vec2 {box.x - 4, box.y + 2}
    testing.expect_value(t, editor_completion_row_at(&editor, left), -1)
}

// The wheel over the popup walks the candidates and leaves the text where it is,
// or the popup drifts away from the caret it belongs to.
@(test)
test_completion_scroll_walks_candidates :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "al\n")
    editor_set_completions(&editor, []Completion_Item{{text = "alpha"}, {text = "alphabet"}})

    box, _, _, _ := editor_completion_rects(&editor)
    editor_wheel(&editor, {box.x + 4, box.y + 4}, -1, {}, 0)
    testing.expect_value(t, editor.completion_selected, 1)
    testing.expect_value(t, editor.scroll_y, 0)

    // Past the last candidate it wraps back to the first.
    editor_wheel(&editor, {box.x + 4, box.y + 4}, -1, {}, 0)
    testing.expect_value(t, editor.completion_selected, 0)
}

// A plain dwell over a squiggle explains the diagnostic under it, and one over
// the gutter marker — which stands for a whole line — explains the worst on that
// line. Neither may answer where nothing is flagged.
@(test)
test_hover_diagnostic_lookup :: proc(t: ^testing.T) {
    // 0: package demo
    // 1: (blank)
    // 2: x := 1  -> bytes 15..16 warn, 20..21 error
    src := "package demo\n\nx := 1\n"
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_text(&state, src)

    editor: Editor
    editor.state = &state
    diags := []Diagnostic {
        {start = 14, end = 15, line = 2, severity = .Warning, message = "shadowed"},
        {start = 19, end = 20, line = 2, severity = .Error, message = "type mismatch"},
    }
    editor.diagnostics = diags

    d, ok := editor_hover_diagnostic(&editor, 14, whole_line = false)
    testing.expect(t, ok && d.message == "shadowed", "a dwell inside a range explains that range")

    d, ok = editor_hover_diagnostic(&editor, 19, whole_line = false)
    testing.expect(t, ok && d.message == "type mismatch", "the other range, not the first listed")

    // Ranges are half-open, so the byte just past one is not on it.
    _, ok = editor_hover_diagnostic(&editor, 15, whole_line = false)
    testing.expect(t, !ok, "the byte after a range is unflagged")

    // The gutter marker is drawn in the error color, so it must explain the error.
    d, ok = editor_hover_diagnostic(&editor, 14, whole_line = true)
    testing.expect(t, ok && d.message == "type mismatch", "the gutter takes the worst on the line")

    // Offset 0 is on line 0, which carries nothing.
    _, ok = editor_hover_diagnostic(&editor, 0, whole_line = true)
    testing.expect(t, !ok, "an unflagged line explains nothing")

    // A diagnostic the compiler gave no text has nothing to say.
    editor.diagnostics = []Diagnostic{{start = 14, end = 15, line = 2, severity = .Error}}
    _, ok = editor_hover_diagnostic(&editor, 14, whole_line = false)
    testing.expect(t, !ok, "an empty message is not a popup")
}

// A collapsed fold builds no row for the lines it hides, so a caret left on one
// has no row that contains it. Rebuilding the rows pulls the caret onto the
// fold's visible start line, and a lookup that still misses clamps into its row
// instead of slicing backwards.
@(test)
test_caret_inside_collapsed_fold :: proc(t: ^testing.T) {
    // Lines start at 0, 6, 11, 17, 23.
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_text(&state, "alpha\nbeta\ngamma\ndelta\nepsilon\n")

    editor: Editor
    editor.state = &state
    editor.font_size = 16
    editor.foldable = make(map[int]int)
    editor.folded = make(map[int]int)
    defer delete(editor.foldable)
    defer delete(editor.folded)
    defer delete(editor.visual_rows)

    // "beta" stays visible; "gamma" and "delta" hide under it.
    editor_set_folds(&editor, []Fold_Range{{start_line = 1, end_line = 3}})
    editor.folded[1] = 6
    editor.folds_revision = state.revision

    textedit.select_range(&state, 13, 13) // column 2 of the hidden "gamma"
    editor.rows_stale = true
    editor_ensure_visual_rows(&editor)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 6) // start of "beta"
    // alpha, beta, epsilon and the empty line after the trailing newline.
    testing.expect_value(t, len(editor.visual_rows), 4)

    // Rows already fresh: the caret goes back onto a hidden line with no rebuild
    // to catch it, which is what the clamp in the row lookup's callers is for.
    editor_rebuild_visual_rows(&editor)
    textedit.select_range(&state, 13, 13)
    editor_move_visual(&editor, -1, false)
    caret := textedit.primary_cursor(&state).caret
    testing.expect(t, caret >= 0 && caret <= len(textedit.text(&state)), "the caret stays in the buffer")
}

// A collapsed fold moves with its line: Enter above it pushes it down one line
// instead of opening it, and deleting its start line drops it.
@(test)
test_fold_follows_an_edit_above :: proc(t: ^testing.T) {
    // Lines start at 0, 3, 6, 9, 12, 15.
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_text(&state, "l0\nl1\nl2\nl3\nl4\nl5\n")

    editor: Editor
    editor.state = &state
    editor.font_size = 16
    defer delete(editor.foldable)
    defer delete(editor.folded)
    defer delete(editor.visual_rows)

    editor_set_folds(&editor, []Fold_Range{{start_line = 2, end_line = 4}})
    textedit.set_single_cursor(&state, 7)
    editor_toggle_fold(&editor)
    testing.expect(t, 2 in editor.folded)

    textedit.set_single_cursor(&state, 2)
    textedit.insert_newline(&state)
    editor_set_folds(&editor, []Fold_Range{{start_line = 3, end_line = 5}})
    testing.expect(t, 3 in editor.folded, "the fold moved down with its line")
    testing.expect(t, 2 not_in editor.folded)
    editor_ensure_visual_rows(&editor)
    // l0, the new line, l1, l2 and l5 with the empty last line; l3 and l4 hide.
    testing.expect_value(t, len(editor.visual_rows), 6)

    // Deleting the start line with the line above it drops the fold.
    textedit.select_range(&state, 6, 13)
    textedit.delete_backward(&state)
    editor_ensure_visual_rows(&editor)
    testing.expect_value(t, len(editor.folded), 0)
}

// Vertical movement finds the caret's row by binary search over the row extents,
// and the rows it searches are rebuilt on demand — an edit between two moves must
// be visible to the second one.
@(test)
test_visual_row_movement :: proc(t: ^testing.T) {
    // "alpha\nbeta\ngamma\ndelta\n": lines start at 0, 6, 11, 17, 23.
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_text(&state, "alpha\nbeta\ngamma\ndelta\n")

    editor: Editor
    editor.state = &state
    editor.font_size = 16
    defer delete(editor.visual_rows)

    textedit.select_range(&state, 13, 13) // column 2 of "gamma"
    editor_move_visual(&editor, -1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 8)

    editor_move_visual(&editor, 2, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 19)

    // Two lines pushed in at the top move every row extent; a move that still
    // walked the rows built above would read the caret onto the wrong line.
    textedit.select_range(&state, 0, 0)
    textedit.insert_text(&state, "one\ntwo\n")
    textedit.select_range(&state, 21, 21) // column 2 of "gamma", now at 19
    editor_move_visual(&editor, -1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 16)
}

// Down through a short line comes back to the column it started at. A
// horizontal move in between starts a new run from the caret's column.
@(test)
test_visual_move_keeps_its_column :: proc(t: ^testing.T) {
    // Lines start at 0, 11 and 15.
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_text(&state, "abcdefghij\nabc\nabcdefghij\n")

    editor: Editor
    editor.state = &state
    editor.font_size = 16
    defer delete(editor.visual_rows)

    textedit.set_single_cursor(&state, 8)
    editor_move_visual(&editor, 1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 14)
    editor_move_visual(&editor, 1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 23)
    editor_move_visual(&editor, -1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 14)

    textedit.move_horizontal(&state, -1, false)
    editor_move_visual(&editor, 1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 17)
}

// Builds wrapped rows of `cols` cells by hand and stamps them fresh: with no
// font atlas the editor cannot measure a column, so it would not wrap itself.
@(private = "file")
editor_test_wrap_rows :: proc(editor: ^Editor, state: ^textedit.State, cols: int) {
    text := textedit.text(state)
    editor.wrap = true
    clear(&editor.visual_rows)
    start, line := 0, 0
    for {
        end := textedit.line_end(text, start)
        editor_wrap_line(editor, text, start, end, cols, line, 4)
        if end >= len(text) {
            break
        }
        start, line = end + 1, line + 1
    }
    editor.rows_revision = state.revision
    editor.rows_wrap = true
    editor.rows_font_size = editor.font_size
    editor.rows_width = editor.view.w - editor.gutter_width - TEXT_PAD_LEFT - 10
    editor.rows_tab_width = textedit.tab_width(state)
    editor.rows_stale = false
}

// A wrap point belongs to the row it starts: Down from column 0 of a wrapped
// line walks its rows, and a move never lands on the end of a row that wraps.
@(test)
test_wrapped_rows_own_their_wrap_point :: proc(t: ^testing.T) {
    // Line 0 wraps into [0, 5), [5, 10), [10, 14); line 1 is [15, 20).
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_text(&state, "aaaa bbbb cccc\nxyzuv")

    editor: Editor
    editor.state = &state
    editor.font_size = 16
    defer delete(editor.visual_rows)
    editor_test_wrap_rows(&editor, &state, 5)
    testing.expect_value(t, len(editor.visual_rows), 4)

    textedit.set_single_cursor(&state, 0)
    editor_move_visual(&editor, 1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 5)
    editor_move_visual(&editor, 1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 10)
    editor_move_visual(&editor, 1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 15)

    // Column 5 is the end of a full row: the end of the line's last row, but one
    // cluster back on a row that wraps.
    textedit.set_single_cursor(&state, 20)
    editor_move_visual(&editor, -1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 14)
    editor_move_visual(&editor, -1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 9)
    editor_move_visual(&editor, -1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 4)
}

// Twenty lines of three characters, so line i starts at byte 4 * i, with the
// caret on line 0.
@(private = "file")
editor_test_jump_setup :: proc(editor: ^Editor, state: ^textedit.State) {
    textedit.set_text(
        state,
        "l00\nl01\nl02\nl03\nl04\nl05\nl06\nl07\nl08\nl09\n" +
        "l10\nl11\nl12\nl13\nl14\nl15\nl16\nl17\nl18\nl19",
    )
    editor.state = state
    editor.font_size = 16
    editor.view = ui.Rect{0, 0, 600, 600}
    textedit.select_range(state, 0, 0)
}

@(private = "file")
editor_test_key :: proc(editor: ^Editor, key: ui.Key, mods: ui.Mod_Set, repeat := false) {
    editor_key(editor, {key = key, mods = mods, action = repeat ? .Repeat : .Press})
}

// The alt release, which is what ends a jump: by then the polled modifiers no
// longer hold Alt.
@(private = "file")
editor_test_release_alt :: proc(editor: ^Editor) {
    editor_key(editor, {key = .Left_Alt, action = .Release})
}

@(private = "file")
editor_test_caret_line :: proc(editor: ^Editor) -> int {
    return textedit.state_line_index(editor.state, textedit.primary_cursor(editor.state).caret)
}

// The digits typed while alt is held make one count, so a gutter distance of ten
// or more is reachable. Nothing moves until alt is released.
@(test)
test_relative_jump_multi_digit :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    editor_test_jump_setup(&editor, &state)

    editor_test_key(&editor, .Num_1, {.Alt})
    editor_test_key(&editor, .Num_2, {.Alt})
    testing.expect_value(t, editor_test_caret_line(&editor), 0)
    count, up, active := editor_pending_jump(&editor)
    testing.expect_value(t, count, 12)
    testing.expect(t, active && !up, "a count is pending, downward")

    editor_test_release_alt(&editor)
    testing.expect_value(t, editor_test_caret_line(&editor), 12)
    _, _, active = editor_pending_jump(&editor)
    testing.expect(t, !active, "the release consumes the count")

    // Shift on the last digit turns the same count around.
    editor_test_key(&editor, .Num_1, {.Alt})
    editor_test_key(&editor, .Num_0, {.Alt, .Shift})
    editor_test_release_alt(&editor)
    testing.expect_value(t, editor_test_caret_line(&editor), 2)
}

// One digit still jumps that far, and a held digit must not repeat itself into
// the count.
@(test)
test_relative_jump_single_digit_and_repeat :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    editor_test_jump_setup(&editor, &state)

    editor_test_key(&editor, .Num_3, {.Alt})
    editor_test_key(&editor, .Num_3, {.Alt}, true)
    editor_test_key(&editor, .Num_3, {.Alt}, true)
    editor_test_release_alt(&editor)
    testing.expect_value(t, editor_test_caret_line(&editor), 3)
}

// Another key abandons the count; a modifier does not, since shift is taken
// part-way through one.
@(test)
test_relative_jump_cancelled :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    editor_test_jump_setup(&editor, &state)

    editor_test_key(&editor, .Num_4, {.Alt})
    editor_test_key(&editor, .Left_Shift, {.Alt})
    _, _, active := editor_pending_jump(&editor)
    testing.expect(t, active, "a modifier press keeps the count")

    editor_test_key(&editor, .Right, {.Alt})
    _, _, active = editor_pending_jump(&editor)
    testing.expect(t, !active, "another key drops the count")

    editor_test_release_alt(&editor)
    testing.expect_value(t, editor_test_caret_line(&editor), 0)
}

// Up/Down goes through editor_move_visual, not textedit.move_vertical, so the
// display columns have to reach here too or tab-indented lines drift.
@(test)
test_visual_row_movement_with_tabs :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    // "\tab" spans columns 0..6; line 2 starts at byte 4.
    textedit.set_text(&state, "\tab\n12345678")

    editor: Editor
    editor.state = &state
    editor.font_size = 16
    defer delete(editor.visual_rows)

    textedit.select_range(&state, 12, 12) // column 8 on line 2
    editor_move_visual(&editor, -1, false)
    // Column 8 is past the end of "\tab" (column 6), so it clamps to the end.
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 3)

    textedit.select_range(&state, 1, 1) // just past the tab: column 4
    editor_move_visual(&editor, 1, false)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 8)
}

// Accepting a snippet candidate expands it, selects the first placeholder, and
// Tab walks to the next one and then out.
@(test)
test_snippet_session_walks_tabstops :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "fn\n")
    editor_set_completions(
        &editor,
        []Completion_Item{{text = "fn", owner_id = 1, insert = "fn(${1:a}, ${2:b})$0", snippet = true, start = -1, end = -1}},
    )
    testing.expect_value(t, len(editor.completion_rows), 1)

    editor_key(&editor, {key = .Tab})

    testing.expect_value(t, textedit.text(&state), "fn(a, b)\n")
    testing.expect(t, editor.snippet_active, "a template opens a session")
    testing.expect_value(t, textedit.primary_cursor(&state).anchor, 3)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 4)

    editor_key(&editor, {key = .Tab})
    testing.expect_value(t, textedit.primary_cursor(&state).anchor, 6)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 7)

    // The exit stop places the caret and closes the session.
    editor_key(&editor, {key = .Tab})
    testing.expect(t, !editor.snippet_active, "$0 is where the session ends")
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 8)
}

// Typing over a placeholder moves the stops after it by what the edit changed,
// so the next Tab still lands on the right bytes.
@(test)
test_snippet_session_follows_typing :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "fn\n")
    editor_set_completions(
        &editor,
        []Completion_Item{{text = "fn", owner_id = 1, insert = "fn(${1:a}, ${2:b})$0", snippet = true, start = -1, end = -1}},
    )
    editor_key(&editor, {key = .Tab})

    editor_text(&editor, 'z', {})
    testing.expect_value(t, textedit.text(&state), "fn(z, b)\n")

    editor_key(&editor, {key = .Tab})
    testing.expect(t, editor.snippet_active, "one edit inside the active stop keeps the session")
    testing.expect_value(t, textedit.primary_cursor(&state).anchor, 6)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 7)
}

// A caret that leaves the snippet ends the session: the offsets can no longer be
// followed, and guessing at them would splice text at the wrong place.
@(test)
test_snippet_session_ends_when_the_caret_leaves :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "fn\n")
    editor_set_completions(
        &editor,
        []Completion_Item{{text = "fn", owner_id = 1, insert = "fn(${1:a}, ${2:b})$0", snippet = true, start = -1, end = -1}},
    )
    editor_key(&editor, {key = .Tab})
    testing.expect(t, editor.snippet_active)

    // "fn(a, b)\n": the snippet spans [0, 8), so the byte past the newline is out.
    textedit.set_single_cursor(&state, 9)
    editor_key(&editor, {key = .End})
    testing.expect(t, !editor.snippet_active, "the caret left the snippet's span")
}

// A candidate that names the range it replaces replaces exactly that, rather
// than appending whatever follows the typed prefix.
@(test)
test_completion_replaces_its_own_range :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "al\n")
    editor_set_completions(
        &editor,
        []Completion_Item{{text = "alpha", owner_id = 1, insert = "ALPHA", start = 0, end = 2}},
    )
    editor_key(&editor, {key = .Tab})

    testing.expect_value(t, textedit.text(&state), "ALPHA\n")
}

// A candidate already spelled out in full survives the filter when its owner
// backs it: what it is there for may be the import it carries, not its letters.
@(test)
test_completion_keeps_a_fully_typed_owner_row :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "al\n")
    editor_set_completions(
        &editor,
        []Completion_Item{{text = "al", owner_id = 1, start = -1, end = -1}, {text = "al"}},
    )
    testing.expect_value(t, len(editor.completion_rows), 1)
    if len(editor.completion_rows) == 1 {
        testing.expect_value(t, editor.completion_rows[0].owner_id, 1)
    }
}

// A complete list narrows in place as the word grows, and a candidate that named
// the range it replaces has that range moved by the characters just typed.
@(test)
test_completion_narrows_a_complete_owner_list :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "al\n")
    editor_set_completions(
        &editor,
        []Completion_Item {
            {text = "alpha", owner_id = 1, insert = "ALPHA", start = 0, end = 2},
            {text = "beta", owner_id = 2, start = -1, end = -1},
        },
        complete = true,
    )
    testing.expect_value(t, len(editor.completion_rows), 1)
    testing.expect(t, editor.completion_full, "a complete list may be narrowed here")

    editor_text(&editor, 'p', {})

    testing.expect_value(t, len(editor.completion_rows), 1)
    if len(editor.completion_rows) != 1 {
        return
    }
    // "al" became "alp": the replaced range grew with it.
    testing.expect_value(t, editor.completion_rows[0].end, 3)

    editor_key(&editor, {key = .Tab})
    testing.expect_value(t, textedit.text(&state), "ALPHA\n")
}

// Diagnostics and diff lines are borrowed from the open file, whose owner frees
// them the moment its tab closes. Binding another buffer must drop both, or the
// same frame's draw reads freed memory.
@(test)
test_set_state_drops_borrowed_spans :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_text(&state, "alpha\nbeta\n")

    editor: Editor
    defer delete(editor.visual_rows)
    editor.font_size = 16
    editor.view = ui.Rect{0, 0, 600, 600}
    editor_set_state(&editor, &state)

    diagnostics := []Diagnostic {{start = 0, end = 5, line = 0, severity = .Error, message = "bad"}}
    diffs := []Diff_Line_Kind {.Added, .Modified}
    editor_set_diagnostics(&editor, diagnostics)
    editor_set_diff_lines(&editor, diffs)
    testing.expect(t, len(editor.diagnostics) == 1, "the setter pushes the borrowed diagnostics")
    testing.expect(t, len(editor.diff_lines) == 2, "the setter pushes the borrowed diff lines")

    editor_set_state(&editor, nil)
    testing.expect(t, editor.diagnostics == nil, "closing the buffer drops the borrowed diagnostics")
    testing.expect(t, editor.diff_lines == nil, "closing the buffer drops the borrowed diff lines")
}

// A stack editor over `text`, laid out large enough for a card to fit, with the
// rows built. The caller frees visual_rows.
@(private = "file")
editor_test_overlay_setup :: proc(editor: ^Editor, state: ^textedit.State, text: string) {
    textedit.init(state)
    textedit.set_text(state, text)
    editor.font_size = 16
    editor.view = ui.Rect{0, 0, 600, 600}
    editor_set_state(editor, state)
    editor_ensure_visual_rows(editor)
}

// Screen point on visual row `row`, just inside the text column. font.measure
// reports 0 with no font atlas, so every cluster is zero wide and any x past the
// column's left edge resolves to the row's last byte — the row is what the point
// picks, which is all these tests need.
@(private = "file")
editor_test_row_point :: proc(editor: ^Editor, row: int) -> ui.Vec2 {
    lh := cast(f32) font.line_height(editor.font_size)
    return {
        editor.view.x + editor.gutter_width + TEXT_PAD_LEFT + 1,
        editor.view.y + cast(f32) row * lh + lh * 0.5,
    }
}

// The underline is the ctrl gesture, not the hover: without the modifier there is
// no link, and a point over whitespace names no word.
@(test)
test_link_range_wants_ctrl_and_a_word :: proc(t: ^testing.T) {
    state: textedit.State
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    editor_test_overlay_setup(&editor, &state, "alpha\nbeta  \n")

    point := editor_test_row_point(&editor, 0)

    _, _, ok := editor_link_range(&editor, point, {})
    testing.expect(t, !ok, "no modifier is no link")

    _, _, ok = editor_link_range(&editor, point, {.Shift})
    testing.expect(t, !ok, "another modifier is no link either")

    lo, hi, found := editor_link_range(&editor, point, {.Ctrl})
    testing.expect(t, found, "ctrl over a word is a link")
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 5)

    // Row 1 ends in spaces, and whitespace is no word.
    _, _, ok = editor_link_range(&editor, editor_test_row_point(&editor, 1), {.Ctrl})
    testing.expect(t, !ok, "whitespace names no word")
}

// An edit moves the bytes a card was anchored to, so the tick drops it. A hover
// carries a diagnostic message the compiler measured against the old text, which
// is the other half of the same reason.
@(test)
test_overlay_tick_drops_a_stale_card :: proc(t: ^testing.T) {
    state: textedit.State
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer editor_clear_hover(&editor)
    defer editor_clear_signature(&editor)
    editor_test_overlay_setup(&editor, &state, "alpha\n")
    editor.focused = true

    // editor_show_hover refuses without a pending dwell.
    editor.hover_probe_offset = 0
    editor_show_hover(&editor, "a thing", 0, 5)
    editor_show_signature(&editor, "proc(a: int)", 0)
    testing.expect(t, editor.hover_active, "the hover card is up")
    testing.expect(t, editor.signature_active, "the signature card is up")

    editor_overlay_tick(&editor)
    testing.expect(t, editor.hover_active, "an untouched buffer keeps the hover card")
    testing.expect(t, editor.signature_active, "an untouched buffer keeps the signature card")

    textedit.insert_text(&state, "x")
    editor_overlay_tick(&editor)
    testing.expect(t, !editor.hover_active, "an edit drops the hover card")
    testing.expect(t, !editor.signature_active, "an edit drops the signature card")
}

// The candidate list and the signature belong to the pane that holds the
// keyboard. A dwell peeks without focusing, so the hover card is not theirs to
// drop — editor_leave owns that one.
@(test)
test_overlay_tick_drops_an_unfocused_card :: proc(t: ^testing.T) {
    state: textedit.State
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_completions(&editor)
    defer editor_clear_hover(&editor)
    editor_test_overlay_setup(&editor, &state, "al\n")
    textedit.select_range(&state, 2, 2)

    editor_set_completions(&editor, []Completion_Item{{text = "alpha"}})
    editor_show_signature(&editor, "proc(a: int)", 0)
    editor.hover_probe_offset = 0
    editor_show_hover(&editor, "a thing", 0, 2)
    testing.expect(t, editor.completion_active, "the list is up")

    editor.focused = false
    editor_overlay_tick(&editor)
    testing.expect(t, !editor.completion_active, "losing the keyboard drops the list")
    testing.expect(t, !editor.signature_active, "losing the keyboard drops the signature card")
    testing.expect(t, editor.hover_active, "the hover card does not need the keyboard")
}

// An indented line draws one guide per whole tab stop inside its own indent, so
// a body at one level reads back to the line that opened it.
@(test)
test_indent_stops_count_the_levels :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_tab_width(&state, 4)
    textedit.set_text(&state, "a\n    b\n        c\n\td\n")

    editor: Editor
    editor.state = &state
    text := textedit.text(&state)

    testing.expect_value(t, editor_indent_stops(&editor, text, 0), 0)
    testing.expect_value(t, editor_indent_stops(&editor, text, 1), 1)
    testing.expect_value(t, editor_indent_stops(&editor, text, 2), 2)
    // A tab is one stop wide, so it counts as one level.
    testing.expect_value(t, editor_indent_stops(&editor, text, 3), 1)
}

// A blank line takes the smaller indent of its nearest non-blank neighbours, so
// no guide outlives the block it belongs to, and none stands in empty space at
// the end of the file.
@(test)
test_indent_stops_of_a_blank_line :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_tab_width(&state, 4)
    textedit.set_text(&state, "        a\n\n        b\n\nc\n\n")

    editor: Editor
    editor.state = &state
    text := textedit.text(&state)

    // Inside the block: both neighbours are two levels deep.
    testing.expect_value(t, editor_indent_stops(&editor, text, 1), 2)
    // After it: the line below is at the margin, so the block's guides stop here.
    testing.expect_value(t, editor_indent_stops(&editor, text, 3), 0)
    // Past the last line with text there is no block left to belong to.
    testing.expect_value(t, editor_indent_stops(&editor, text, 5), 0)
}

@(test)
test_wrap_counts_wide_runes_as_two_cells :: proc(t: ^testing.T) {
    editor: Editor
    defer delete(editor.visual_rows)

    // Four wide runes at three bytes each, in a row of five cells.
    text := "日本語字"
    editor_wrap_line(&editor, text, 0, len(text), 5, 0, 4)
    testing.expect_value(t, len(editor.visual_rows), 2)
    testing.expect_value(t, editor.visual_rows[0].end, 6)
    testing.expect_value(t, editor.visual_rows[1].start, 6)

    // A break never lands inside a cluster: e + combining acute is one cell.
    clear(&editor.visual_rows)
    marks := "aéb"
    editor_wrap_line(&editor, marks, 0, len(marks), 2, 0, 4)
    testing.expect_value(t, len(editor.visual_rows), 2)
    testing.expect_value(t, editor.visual_rows[0].end, 4)
}

@(test)
test_page_keys_move_by_the_view :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    editor: Editor
    defer delete(editor.visual_rows)
    editor_test_jump_setup(&editor, &state)

    // 20 lines; a 110 px view at 22 px a line shows 5 rows, so a page is 4.
    editor.view = ui.Rect{0, 0, 600, 110}
    editor_test_key(&editor, .Page_Down, {})
    testing.expect_value(t, editor_test_caret_line(&editor), 4)
    editor_test_key(&editor, .Page_Down, {})
    testing.expect_value(t, editor_test_caret_line(&editor), 8)
    editor_test_key(&editor, .Page_Up, {})
    testing.expect_value(t, editor_test_caret_line(&editor), 4)
}

@(test)
test_editing_keys_follow_the_keymap :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    editor: Editor
    defer delete(editor.visual_rows)
    editor_test_jump_setup(&editor, &state)
    defer keymap_reset()

    // The built-in chord, and shift on a movement chord extends the selection.
    editor_test_key(&editor, .End, {.Ctrl})
    testing.expect_value(t, editor_test_caret_line(&editor), 19)
    editor_test_key(&editor, .Home, {.Ctrl, .Shift})
    testing.expect(t, textedit.has_any_selection(&state), "shift extends")

    // A moved chord works, and the old one stops.
    keymap_bind(.File_End, {.G, {.Alt}})
    textedit.select_range(&state, 0, 0)
    editor_test_key(&editor, .End, {.Ctrl})
    testing.expect_value(t, editor_test_caret_line(&editor), 0)
    editor_test_key(&editor, .G, {.Alt})
    testing.expect_value(t, editor_test_caret_line(&editor), 19)

    // An action with no chord answers to no key.
    keymap_bind(.Delete_Line, {})
    before := textedit.length(&state)
    editor_test_key(&editor, .K, {.Ctrl, .Shift})
    testing.expect_value(t, textedit.length(&state), before)
}

// Accepts the one candidate `template` makes over the word "fn" at the end of `text`.
@(private = "file")
editor_test_accept_snippet :: proc(editor: ^Editor, state: ^textedit.State, text, template: string) {
    editor_test_completion_setup(editor, state, text)
    editor_set_completions(
        editor,
        []Completion_Item{{text = "fn", owner_id = 1, insert = template, snippet = true, start = -1, end = -1}},
    )
    editor_key(editor, {key = .Tab})
}

// A tabstop used twice is one text: what is typed in the first lands in the
// second, and one undo takes both back.
@(test)
test_snippet_mirror_follows_typing :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_accept_snippet(&editor, &state, "fn\n", "${1:a} = $1; ${2:b}$0")
    testing.expect_value(t, textedit.text(&state), "a = a; b\n")

    editor_text(&editor, 'z', {})
    testing.expect_value(t, textedit.text(&state), "z = z; b\n")
    editor_text(&editor, 'y', {})
    testing.expect_value(t, textedit.text(&state), "zy = zy; b\n")
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 2)

    editor_key(&editor, {key = .Backspace})
    testing.expect_value(t, textedit.text(&state), "z = z; b\n")
    testing.expect(t, editor.snippet_active, "the session follows its mirrors")

    // The next stop is where the mirror edits left it.
    editor_dismiss_completion(&editor)
    editor_key(&editor, {key = .Tab})
    testing.expect_value(t, textedit.primary_cursor(&state).anchor, 7)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 8)

    textedit.undo(&state)
    testing.expect_value(t, textedit.text(&state), "zy = zy; b\n")
}

@(private = "file")
editor_test_expect_selection :: proc(t: ^testing.T, state: ^textedit.State, lo, hi: int, loc := #caller_location) {
    got_lo, got_hi := textedit.selection_range(textedit.primary_cursor(state))
    testing.expect_value(t, got_lo, lo, loc = loc)
    testing.expect_value(t, got_hi, hi, loc = loc)
}

// Typing in a nested placeholder grows the placeholder around it too.
@(test)
test_snippet_nested_stop_grows_its_parent :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_accept_snippet(&editor, &state, "fn\n", "f(${1:a, ${2:b}})$0")
    testing.expect_value(t, textedit.text(&state), "f(a, b)\n")
    editor_test_expect_selection(t, &state, 2, 6)

    editor_key(&editor, {key = .Tab})
    editor_test_expect_selection(t, &state, 5, 6)
    editor_text(&editor, 'x', {})
    editor_text(&editor, 'y', {})
    testing.expect_value(t, textedit.text(&state), "f(a, xy)\n")

    editor_dismiss_completion(&editor)
    editor_key(&editor, {key = .Tab, mods = {.Shift}})
    testing.expect(t, editor.snippet_active)
    editor_test_expect_selection(t, &state, 2, 7)
}

// An edit between two stops moves the stops after it and leaves the active
// one its own size.
@(test)
test_snippet_edit_outside_the_active_stop :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_accept_snippet(&editor, &state, "fn\n", "${1:a} + ${2:b} + ${3:c}$0")
    testing.expect_value(t, textedit.text(&state), "a + b + c\n")
    editor_key(&editor, {key = .Tab})
    editor_test_expect_selection(t, &state, 4, 5)

    // Typed after "a", before the active stop.
    textedit.set_single_cursor(&state, 1)
    editor_text(&editor, 'q', {})
    testing.expect_value(t, textedit.text(&state), "aq + b + c\n")
    testing.expect(t, editor.snippet_active, "the caret is still inside the snippet")

    editor_dismiss_completion(&editor)
    editor_key(&editor, {key = .Tab})
    editor_test_expect_selection(t, &state, 9, 10)
    editor_key(&editor, {key = .Tab, mods = {.Shift}})
    editor_test_expect_selection(t, &state, 5, 6)
    // An edit at the end of a stop that is not active does not grow it.
    editor_key(&editor, {key = .Tab, mods = {.Shift}})
    editor_test_expect_selection(t, &state, 0, 1)
}

@(test)
test_snippet_mirror_runs_its_transform :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_accept_snippet(&editor, &state, "fn\n", "${1:name} ${1/(.*)/${1:/upcase}/}$0")
    testing.expect_value(t, textedit.text(&state), "name NAME\n")

    editor_text(&editor, 'x', {})
    editor_text(&editor, 'y', {})
    testing.expect_value(t, textedit.text(&state), "xy XY\n")
}

// An undo cannot be followed by a length delta, so it ends the session.
@(test)
test_snippet_undo_ends_the_session :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_accept_snippet(&editor, &state, "fn\n", "${1:a} = $1;$0")
    editor_text(&editor, 'z', {})
    testing.expect_value(t, textedit.text(&state), "z = z;\n")

    editor_run_action(&editor, .Undo, false)
    testing.expect_value(t, textedit.text(&state), "a = a;\n")
    testing.expect(t, !editor.snippet_active)
}

// A choice stop lists its alternatives; the accepted one goes over the stop and
// the session carries on.
@(test)
test_snippet_choice_opens_a_list :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_accept_snippet(&editor, &state, "fn\n", "${1|one,three|}! ${2:b}$0")
    testing.expect_value(t, textedit.text(&state), "one! b\n")
    testing.expect(t, editor.completion_active && editor.completion_choice, "the alternatives are listed")
    testing.expect_value(t, len(editor.completion_rows), 2)

    editor_key(&editor, {key = .Down})
    editor_key(&editor, {key = .Tab})
    testing.expect_value(t, textedit.text(&state), "three! b\n")
    testing.expect(t, !editor.completion_active)
    testing.expect(t, editor.snippet_active, "a choice does not end the session")
    testing.expect_value(t, textedit.primary_cursor(&state).anchor, 0)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 5)

    editor_key(&editor, {key = .Tab})
    testing.expect_value(t, textedit.primary_cursor(&state).anchor, 7)
    testing.expect_value(t, textedit.primary_cursor(&state).caret, 8)
}

// A multi-line template takes the indent of the line it lands on, and its own
// tabs become one indent level each.
@(test)
test_snippet_takes_the_line_indent :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.set_indent_style(&state, .Spaces)
    textedit.set_tab_width(&state, 4)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_rows)
    defer editor_test_free_snippet(&editor)
    defer editor_test_free_completions(&editor)

    editor_test_accept_snippet(&editor, &state, "  fn\n", "if {\n\t$0\n}")
    testing.expect_value(t, textedit.text(&state), "  if {\n      \n  }\n")
    testing.expect_value(t, textedit.primary_cursor(&state).caret, len("  if {\n      "))
}
