package widgets

import "core:testing"

import rl "vendor:raylib"

import "../textedit"

import "../ui"

// The candidate strings are clones; editor_dismiss_completion is file-private to
// editor.odin, so a stack editor frees them here.
@(private = "file")
editor_test_free_completions :: proc(editor: ^Editor) {
    for item in editor.completion_items {
        delete(item)
    }
    clear(&editor.completion_items)
}

// A stack editor with one caret at the end of `text`, laid out large enough for
// the completion popup to fit under the caret. The caller frees visual_rows.
@(private = "file")
editor_test_completion_setup :: proc(editor: ^Editor, state: ^textedit.State, text: string) {
    textedit.set_text(state, text)
    editor.state = state
    editor.font_size = 16
    editor.bounds = rl.Rectangle {0, 0, 600, 600}
    textedit.select_range(state, len(text) - 1, len(text) - 1)
    editor.rows_stale = true
    editor_ensure_visual_rows(editor)
}

// Clicking a candidate accepts it. The click point comes from the shared rects,
// never from a fixed pixel: ui.measure_text reports 0 with no font atlas, so the
// box collapses to its minimum width in a headless run.
@(test)
test_completion_click_accepts :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)

    editor: Editor
    defer delete(editor.visual_rows)
    defer delete(editor.completion_items)
    defer delete(editor.completion_colors)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "al\n")
    editor_set_completions(&editor, []Completion_Item{{text = "alpha"}, {text = "alphabet"}})
    testing.expect_value(t, len(editor.completion_items), 2)

    box, lh, top, ok := editor_completion_rects(&editor)
    testing.expect(t, ok, "an active popup has a box")
    testing.expect_value(t, top, 0)

    // Row 1 is "alphabet"; row 0 stays selected until the click moves it.
    point := rl.Vector2 {box.x + 4, box.y + 2 + lh * 1.5}
    testing.expect_value(t, editor_completion_row_at(&editor, point), 1)
    testing.expect_value(t, editor.completion_selected, 0)

    down := ui.Event {kind = .Mouse_Down, mouse_button = .LEFT, mouse_position = point}
    editor_handle_event(&editor.widget, nil, &down)

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
    defer delete(editor.completion_items)
    defer delete(editor.completion_colors)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "al\n")
    editor_set_completions(&editor, []Completion_Item{{text = "alpha"}, {text = "alphabet"}})

    box, lh, _, _ := editor_completion_rects(&editor)
    below := rl.Vector2 {box.x + 4, box.y + 2 + lh * cast(f32) len(editor.completion_items) + 1}
    testing.expect_value(t, editor_completion_row_at(&editor, below), -1)

    left := rl.Vector2 {box.x - 4, box.y + 2}
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
    defer delete(editor.completion_items)
    defer delete(editor.completion_colors)
    defer editor_test_free_completions(&editor)

    editor_test_completion_setup(&editor, &state, "al\n")
    editor_set_completions(&editor, []Completion_Item{{text = "alpha"}, {text = "alphabet"}})

    box, _, _, _ := editor_completion_rects(&editor)
    scroll := ui.Event {
        kind = .Scroll,
        mouse_position = rl.Vector2 {box.x + 4, box.y + 4},
        wheel_delta = -1,
    }
    editor_handle_event(&editor.widget, nil, &scroll)
    testing.expect_value(t, editor.completion_selected, 1)
    testing.expect_value(t, editor.scroll_y, 0)

    // Past the last candidate it wraps back to the first.
    editor_handle_event(&editor.widget, nil, &scroll)
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
    editor.folded = make(map[int]bool)
    defer delete(editor.foldable)
    defer delete(editor.folded)
    defer delete(editor.visual_rows)

    // "beta" stays visible; "gamma" and "delta" hide under it.
    editor_set_folds(&editor, []Fold_Range{{start_line = 1, end_line = 3}})
    editor.folded[1] = true

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
