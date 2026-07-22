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
test_bracket_match_enclosing :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "call(a, b, c)")
    set_single_cursor(&state, 8) // inside the parens, between "b," and " c"

    // Not adjacent to a bracket: jumps out to the enclosing '('.
    move_to_matching_bracket(&state, false)
    testing.expect_value(t, primary_cursor(&state).caret, 4)

    set_single_cursor(&state, 8)
    move_to_matching_bracket(&state, true)
    cursor := primary_cursor(&state)
    lo, hi := selection_range(cursor)
    testing.expect_value(t, lo, 4)
    testing.expect_value(t, hi, 13) // whole "(a, b, c)" pair
}

@(test)
test_insert_newline_auto_indent :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    // Caret at end of an indented line: the new line keeps the indent.
    insert_text(&state, "    foo")
    insert_newline(&state)
    testing.expect_value(t, text(&state), "    foo\n    ")

    // After an opening brace, add one more level (4 spaces).
    brace: State
    init(&brace)
    defer destroy(&brace)
    insert_text(&brace, "if x {")
    insert_newline(&brace)
    testing.expect_value(t, text(&brace), "if x {\n    ")
}

@(test)
test_auto_pairing :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    // Typing an opener inserts the pair with the caret between.
    insert_pair(&state, '(', ')')
    testing.expect_value(t, text(&state), "()")
    testing.expect_value(t, primary_cursor(&state).caret, 1)

    // Typing the closer over the auto-inserted one just steps past it.
    insert_or_step(&state, ')')
    testing.expect_value(t, text(&state), "()")
    testing.expect_value(t, primary_cursor(&state).caret, 2)

    // Backspace between an empty pair deletes both sides.
    set_single_cursor(&state, 1)
    delete_backward(&state)
    testing.expect_value(t, text(&state), "")

    // Quote wraps a selection.
    insert_text(&state, "abc")
    select_range(&state, 0, 3)
    insert_quote(&state, '"')
    testing.expect_value(t, text(&state), "\"abc\"")

    // Apostrophe after a word char inserts a single quote, not a pair.
    set_single_cursor(&state, 0)
    insert_text(&state, "don")
    insert_quote(&state, '\'')
    testing.expect_value(t, text(&state), "don'\"abc\"")
}

@(test)
test_block_comment_pairing :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    // Typing `*` right after a `/` closes the block comment: `/*|*/`.
    insert_text(&state, "/")
    testing.expect(t, block_comment_applies(&state), "should apply after a slash")
    insert_block_comment(&state)
    testing.expect_value(t, text(&state), "/**/")
    testing.expect_value(t, primary_cursor(&state).caret, 2)

    // Undo removes the whole inserted `**/` in one step.
    undo(&state)
    testing.expect_value(t, text(&state), "/")

    // Not right after a slash: no auto-close.
    set_single_cursor(&state, 0)
    insert_text(&state, "x")
    testing.expect(t, !block_comment_applies(&state), "should not apply after a non-slash")

    // A selection suppresses it too.
    select_range(&state, 0, 1)
    testing.expect(t, !block_comment_applies(&state), "should not apply with a selection")
}

@(test)
test_replace_all :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "foo bar Foo baz foo")

    // Case-insensitive: replaces foo, Foo, foo.
    count := replace_all(&state, "foo", "X", false)
    testing.expect_value(t, count, 3)
    testing.expect_value(t, text(&state), "X bar X baz X")

    // Undo restores the original in one step.
    undo(&state)
    testing.expect_value(t, text(&state), "foo bar Foo baz foo")

    // Case-sensitive: only the two lowercase.
    count = replace_all(&state, "foo", "X", true)
    testing.expect_value(t, count, 2)
    testing.expect_value(t, text(&state), "X bar Foo baz X")
}

@(test)
test_select_between_brackets :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "call(a, b, c)")

    // From inside the parens: selects "a, b, c" (brackets excluded).
    set_single_cursor(&state, 8)
    select_between_brackets(&state)
    cursor := primary_cursor(&state)
    lo, hi := selection_range(cursor)
    testing.expect_value(t, lo, 5)  // just after '('
    testing.expect_value(t, hi, 12) // just before ')'

    // From directly next to the opening bracket: same span.
    set_single_cursor(&state, 4)
    select_between_brackets(&state)
    cursor = primary_cursor(&state)
    lo, hi = selection_range(cursor)
    testing.expect_value(t, lo, 5)
    testing.expect_value(t, hi, 12)
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
test_transform_case :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    // No selection: acts on the word under the caret.
    insert_text(&state, "foo bar baz")
    set_single_cursor(&state, 5) // inside "bar"
    transform_case(&state, .Upper)
    testing.expect_value(t, text(&state), "foo BAR baz")

    undo(&state)
    testing.expect_value(t, text(&state), "foo bar baz")

    // Selection: title-cases every word in the range, keeps the selection.
    select_range(&state, 0, 11)
    transform_case(&state, .Title)
    testing.expect_value(t, text(&state), "Foo Bar Baz")
    cursor := primary_cursor(&state)
    lo, hi := selection_range(cursor)
    testing.expect_value(t, lo, 0)
    testing.expect_value(t, hi, 11)

    transform_case(&state, .Lower)
    testing.expect_value(t, text(&state), "foo bar baz")
}

@(test)
test_join_lines :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    // No selection: joins the current line with the one below, dropping the
    // next line's indentation down to a single space.
    insert_text(&state, "foo\n    bar\nbaz")
    set_single_cursor(&state, 1) // on the first line
    join_lines(&state)
    testing.expect_value(t, text(&state), "foo bar\nbaz")
    testing.expect_value(t, primary_cursor(&state).caret, 3) // at the join

    undo(&state)
    testing.expect_value(t, text(&state), "foo\n    bar\nbaz")

    // Selection spanning all three lines joins them into one.
    select_range(&state, 0, 13)
    join_lines(&state)
    testing.expect_value(t, text(&state), "foo bar baz")
}

@(test)
test_quote_delimiters :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    // "select between" works inside a quoted string, excluding the quotes.
    insert_text(&state, "x = \"hello\" + y")
    set_single_cursor(&state, 7) // inside "hello"
    select_between_brackets(&state)
    cursor := primary_cursor(&state)
    lo, hi := selection_range(cursor)
    testing.expect_value(t, lo, 5)  // just after the opening quote
    testing.expect_value(t, hi, 10) // just before the closing quote

    // Jumping from just after the opening quote lands on the closing quote.
    set_single_cursor(&state, 5)
    move_to_matching_bracket(&state, false)
    testing.expect_value(t, primary_cursor(&state).caret, 10)
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
