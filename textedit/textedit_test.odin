package textedit

import "core:testing"
import "core:unicode/utf8"

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

// The line table must answer exactly what the scanning procs answer, at every
// offset, and must follow an edit and a set_text.
@(test)
test_line_table_matches_scan :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "l0\nl1\n\nl3\n")
    txt := text(&state)
    testing.expect_value(t, state_line_count(&state), line_count(txt))
    for pos in 0 ..= len(txt) {
        testing.expect_value(t, state_line_index(&state, pos), line_index(txt, pos))
    }
    for line in -1 ..= state_line_count(&state) + 1 {
        testing.expect_value(t, state_line_start(&state, line), line_start_of_index(txt, line))
    }

    // An edit moves every following line start, so the table must be rebuilt.
    set_single_cursor(&state, 0)
    insert_text(&state, "x\n")
    txt = text(&state)
    testing.expect_value(t, state_line_count(&state), line_count(txt))
    testing.expect_value(t, state_line_start(&state, 1), line_start_of_index(txt, 1))

    // set_text puts the revision back to 0, which the table cannot detect on its
    // own.
    set_text(&state, "a\nb")
    testing.expect_value(t, state_line_count(&state), 2)
    testing.expect_value(t, state_line_start(&state, 1), 2)
}

// Types `s` one character at a time, the way the editor feeds keystrokes in.
@(private = "file")
type_runes :: proc(state: ^State, s: string) {
    for r in s {
        buffer, width := utf8.encode_rune(r)
        insert_text(state, string(buffer[:width]))
    }
}

@(test)
test_typing_coalesces_into_one_entry :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    type_runes(&state, "hello")
    testing.expect_value(t, text(&state), "hello")
    testing.expect_value(t, state.undo_stack.count, 1)

    undo(&state)
    testing.expect_value(t, text(&state), "")

    redo(&state)
    testing.expect_value(t, text(&state), "hello")
    testing.expect_value(t, primary_cursor(&state).caret, 5)
}

// A run breaks where the character class changes, so a word, the space after
// it and a following word each undo separately.
@(test)
test_typing_run_breaks_on_class_change :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    type_runes(&state, "two words")
    testing.expect_value(t, state.undo_stack.count, 3)

    undo(&state)
    testing.expect_value(t, text(&state), "two ")
    undo(&state)
    testing.expect_value(t, text(&state), "two")
    undo(&state)
    testing.expect_value(t, text(&state), "")
}

// A paste is one keystroke's worth of nothing: it must not join a typing run,
// and typing after it must not fold into the paste.
@(test)
test_paste_is_its_own_entry :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    type_runes(&state, "ab")
    insert_text(&state, "cd")
    type_runes(&state, "ef")
    testing.expect_value(t, text(&state), "abcdef")
    testing.expect_value(t, state.undo_stack.count, 3)

    undo(&state)
    testing.expect_value(t, text(&state), "abcd")
    undo(&state)
    testing.expect_value(t, text(&state), "ab")
}

// Replacing a selection is a step of its own, and the typing after it starts a
// fresh run rather than extending the replacement.
@(test)
test_selection_replace_is_not_coalesced :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "keep drop")
    select_range(&state, 5, 9)
    type_runes(&state, "xy")

    testing.expect_value(t, text(&state), "keep xy")
    undo(&state)
    testing.expect_value(t, text(&state), "keep x")
    undo(&state)
    testing.expect_value(t, text(&state), "keep drop")
}

@(test)
test_backspace_run_coalesces :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "hello")
    for i := 0; i < 5; i += 1 {
        delete_backward(&state)
    }
    testing.expect_value(t, text(&state), "")

    undo(&state)
    testing.expect_value(t, text(&state), "hello")
    testing.expect_value(t, primary_cursor(&state).caret, 5)

    redo(&state)
    testing.expect_value(t, text(&state), "")
}

@(test)
test_delete_forward_run_coalesces :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "hello")
    set_single_cursor(&state, 0)
    for i := 0; i < 5; i += 1 {
        delete_forward(&state)
    }
    testing.expect_value(t, text(&state), "")

    undo(&state)
    testing.expect_value(t, text(&state), "hello")

    redo(&state)
    testing.expect_value(t, text(&state), "")
}

// Typing after an undo must start a new entry rather than being absorbed by the
// older one it happens to sit next to.
@(test)
test_typing_after_undo_starts_new_entry :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    type_runes(&state, "ab")
    insert_text(&state, "!") // breaks the run: punctuation
    undo(&state)
    testing.expect_value(t, text(&state), "ab")

    type_runes(&state, "c")
    testing.expect_value(t, text(&state), "abc")

    undo(&state)
    testing.expect_value(t, text(&state), "ab")
    undo(&state)
    testing.expect_value(t, text(&state), "")
}

@(test)
test_multi_cursor_typing_coalesces :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "aa\nbb\ncc")
    set_single_cursor(&state, 0)
    add_cursor_vertical(&state, 1)
    add_cursor_vertical(&state, 1)
    testing.expect_value(t, len(state.cursors), 3)

    type_runes(&state, "xy")
    testing.expect_value(t, text(&state), "xyaa\nxybb\nxycc")

    undo(&state)
    testing.expect_value(t, text(&state), "aa\nbb\ncc")

    redo(&state)
    testing.expect_value(t, text(&state), "xyaa\nxybb\nxycc")
}

@(test)
test_multi_cursor_backspace_coalesces :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "xyaa\nxybb")
    set_single_cursor(&state, 2)
    add_cursor_vertical(&state, 1)
    testing.expect_value(t, len(state.cursors), 2)

    delete_backward(&state)
    delete_backward(&state)
    testing.expect_value(t, text(&state), "aa\nbb")

    undo(&state)
    testing.expect_value(t, text(&state), "xyaa\nxybb")

    redo(&state)
    testing.expect_value(t, text(&state), "aa\nbb")
}

// The history is capped, so the oldest entries fall off instead of the stack
// growing for the whole session.
@(test)
test_undo_history_is_capped :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    // Two runes per insert, so none of these coalesce.
    for i := 0; i < MAX_UNDO_ENTRIES + 50; i += 1 {
        insert_text(&state, "ab")
    }
    testing.expect_value(t, state.undo_stack.count, MAX_UNDO_ENTRIES)

    for i := 0; i < MAX_UNDO_ENTRIES + 50; i += 1 {
        undo(&state)
    }
    testing.expect_value(t, state.undo_stack.count, 0)
    testing.expect_value(t, state.undo_bytes, 0)
    // The 50 dropped entries can no longer be undone.
    testing.expect_value(t, length(&state), 100)
}

// text() is a borrow of the piece table's snapshot: every edit path must be
// visible through it, and a multi-cursor edit must still read the pre-edit text
// it takes its undo ops from.
@(test)
test_text_view_follows_edits :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    set_text(&state, "one\ntwo\nthree")
    testing.expect_value(t, text(&state), "one\ntwo\nthree")

    set_single_cursor(&state, 3)
    add_cursor_vertical(&state, 1)
    insert_text(&state, "!")
    testing.expect_value(t, text(&state), "one!\ntwo!\nthree")

    delete_backward(&state)
    testing.expect_value(t, text(&state), "one\ntwo\nthree")

    undo(&state)
    testing.expect_value(t, text(&state), "one!\ntwo!\nthree")
}

// Every multi-cursor edit walks the cursors low to high with one running
// offset, so overlapping ranges must be gone before the edit starts.
@(test)
test_overlapping_selections_merge :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    set_text(&state, "abcdefghij")
    set_cursors(&state, []Cursor{{anchor = 0, caret = 6}, {anchor = 4, caret = 10}})

    testing.expect_value(t, len(state.cursors), 1)
    testing.expect_value(t, state.cursors[0].anchor, 0)
    testing.expect_value(t, state.cursors[0].caret, 10)

    insert_text(&state, "X")
    testing.expect_value(t, text(&state), "X")
}

// The merged cursor faces the way the second one faced.
@(test)
test_overlapping_selections_keep_direction :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    set_text(&state, "abcdefghij")
    set_cursors(&state, []Cursor{{anchor = 6, caret = 0}, {anchor = 10, caret = 4}})

    testing.expect_value(t, len(state.cursors), 1)
    testing.expect_value(t, state.cursors[0].anchor, 10)
    testing.expect_value(t, state.cursors[0].caret, 0)
}

// A bare caret on the edge of a selection is one position, so it merges; two
// selections that only meet there are separate matches and stay apart.
@(test)
test_caret_merges_but_adjacent_selections_do_not :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    set_text(&state, "abcd")
    set_cursors(&state, []Cursor{{anchor = 0, caret = 2}, {anchor = 2, caret = 2}})
    testing.expect_value(t, len(state.cursors), 1)
    testing.expect_value(t, state.cursors[0].anchor, 0)
    testing.expect_value(t, state.cursors[0].caret, 2)

    set_text(&state, "abab")
    set_cursors(&state, []Cursor{{anchor = 0, caret = 2}, {anchor = 2, caret = 4}})
    testing.expect_value(t, len(state.cursors), 2)

    insert_text(&state, "X")
    testing.expect_value(t, text(&state), "XX")
}

// Selections that grow into each other (Shift+Down on stacked cursors) merge
// instead of double-applying the offset math.
@(test)
test_extending_selections_merge :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    set_text(&state, "aa\nbb\ncc\ndd")
    set_single_cursor(&state, 0)
    add_cursor_vertical(&state, 1)
    testing.expect_value(t, len(state.cursors), 2)

    move_vertical(&state, 1, true)
    move_vertical(&state, 1, true)
    testing.expect_value(t, len(state.cursors), 1)
    testing.expect_value(t, state.cursors[0].anchor, 0)
    testing.expect_value(t, state.cursors[0].caret, 9)

    insert_text(&state, "X")
    testing.expect_value(t, text(&state), "Xdd")
}

// A clone outlives the buffer it came from; the borrow does not.
@(test)
test_text_clone_survives_set_text :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    set_text(&state, "before")
    before := text_clone(&state, context.temp_allocator)
    set_text(&state, "after")

    testing.expect_value(t, before, "before")
    testing.expect_value(t, text(&state), "after")
}
