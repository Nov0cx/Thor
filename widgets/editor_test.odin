package widgets

import "core:testing"

import "../textedit"

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
