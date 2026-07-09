package textedit

import "core:testing"

@(test)
test_insert_and_undo_redo :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "hello")
    insert_text(&state, " world")
    testing.expect_value(t, text(&state), "hello world")

    undo(&state)
    testing.expect_value(t, text(&state), "hello")
    testing.expect_value(t, primary_cursor(&state).caret, 5)

    undo(&state)
    testing.expect_value(t, text(&state), "")

    redo(&state)
    redo(&state)
    testing.expect_value(t, text(&state), "hello world")
    testing.expect_value(t, primary_cursor(&state).caret, 11)
}

@(test)
test_selection_replace :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "foo bar baz")
    set_single_cursor(&state, 4)
    move_word(&state, 1, true) // select "bar"
    testing.expect_value(t, primary_cursor(&state).caret, 7)

    insert_text(&state, "qux")
    testing.expect_value(t, text(&state), "foo qux baz")

    undo(&state)
    testing.expect_value(t, text(&state), "foo bar baz")
}

@(test)
test_word_jump :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "one two_three  four")
    set_single_cursor(&state, 0)

    move_word(&state, 1, false)
    testing.expect_value(t, primary_cursor(&state).caret, 3) // after "one"
    move_word(&state, 1, false)
    testing.expect_value(t, primary_cursor(&state).caret, 13) // after "two_three"
    move_word(&state, 1, false)
    testing.expect_value(t, primary_cursor(&state).caret, 19) // after "four"

    move_word(&state, -1, false)
    testing.expect_value(t, primary_cursor(&state).caret, 15) // start of "four"
}

@(test)
test_bracket_match :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "call(a, (b), c)")
    set_single_cursor(&state, 4) // in front of '('

    move_to_matching_bracket(&state, false)
    testing.expect_value(t, primary_cursor(&state).caret, 14) // the outer ')'

    move_to_matching_bracket(&state, false)
    testing.expect_value(t, primary_cursor(&state).caret, 4) // back to '('

    move_to_matching_bracket(&state, true)
    cursor := primary_cursor(&state)
    lo, hi := selection_range(cursor)
    testing.expect_value(t, lo, 4)
    testing.expect_value(t, hi, 15) // both brackets included
}

@(test)
test_multi_cursor_insert :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "aa\nbb\ncc")
    set_single_cursor(&state, 0)
    add_cursor_vertical(&state, 1)
    add_cursor_vertical(&state, 1)
    testing.expect_value(t, len(state.cursors), 3)

    insert_text(&state, "> ")
    testing.expect_value(t, text(&state), "> aa\n> bb\n> cc")

    undo(&state)
    testing.expect_value(t, text(&state), "aa\nbb\ncc")
    testing.expect_value(t, len(state.cursors), 3)

    redo(&state)
    testing.expect_value(t, text(&state), "> aa\n> bb\n> cc")
}

@(test)
test_multi_cursor_backspace :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "xaa\nxbb")
    set_single_cursor(&state, 1)
    add_cursor_vertical(&state, 1)
    testing.expect_value(t, len(state.cursors), 2)

    delete_backward(&state)
    testing.expect_value(t, text(&state), "aa\nbb")

    undo(&state)
    testing.expect_value(t, text(&state), "xaa\nxbb")
}

@(test)
test_utf8_columns :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "äöü\nabc")
    set_single_cursor(&state, 6) // after "äöü" (3 two-byte runes)
    testing.expect_value(t, primary_cursor(&state).preferred_column, 3)

    move_vertical(&state, 1, false)
    testing.expect_value(t, primary_cursor(&state).caret, 10) // after "abc"

    move_vertical(&state, -1, false)
    testing.expect_value(t, primary_cursor(&state).caret, 6)

    delete_backward(&state) // removes the two-byte 'ü'
    testing.expect_value(t, text(&state), "äö\nabc")
}

@(test)
test_document_moves_and_select_all :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "one\ntwo\nthree")
    move_document_start(&state, false)
    testing.expect_value(t, primary_cursor(&state).caret, 0)
    move_document_end(&state, false)
    testing.expect_value(t, primary_cursor(&state).caret, 13)

    select_all(&state)
    cursor := primary_cursor(&state)
    lo, hi := selection_range(cursor)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 13)

    insert_text(&state, "replaced")
    testing.expect_value(t, text(&state), "replaced")
    undo(&state)
    testing.expect_value(t, text(&state), "one\ntwo\nthree")
}

@(test)
test_relative_line_jump :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "l0\nl1\nl2\nl3\nl4")
    set_single_cursor(&state, 0)

    move_vertical(&state, 3, false) // alt+3
    testing.expect_value(t, line_index(text(&state), primary_cursor(&state).caret), 3)

    move_vertical(&state, -2, false) // alt+shift+2
    testing.expect_value(t, line_index(text(&state), primary_cursor(&state).caret), 1)
}
