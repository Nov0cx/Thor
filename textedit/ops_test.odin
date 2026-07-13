package textedit

import "core:testing"

@(private = "file")
ops_state :: proc(content: string, caret: int) -> State {
    state: State
    init(&state)
    set_text(&state, content)
    set_single_cursor(&state, caret)
    return state
}

@(test)
test_copy_payload :: proc(t: ^testing.T) {
    state := ops_state("one\ntwo\nthree", 5) // caret inside "two"
    defer destroy(&state)

    payload, had_selection := copy_payload(&state)
    testing.expect(t, !had_selection, "no selection expected")
    testing.expect_value(t, payload, "two\n")

    state.cursors[0].anchor = 4
    state.cursors[0].caret = 7
    payload, had_selection = copy_payload(&state)
    testing.expect(t, had_selection, "selection expected")
    testing.expect_value(t, payload, "two")
}

@(test)
test_select_word_and_next :: proc(t: ^testing.T) {
    state := ops_state("foo bar foo baz foo", 9) // inside first... second "foo"? caret 9 = inside "foo" at 8
    defer destroy(&state)

    select_word_or_next(&state)
    lo, hi := selection_range(primary_cursor(&state))
    testing.expect_value(t, text(&state)[lo:hi], "foo")

    select_word_or_next(&state)
    testing.expect_value(t, len(state.cursors), 2)
    select_word_or_next(&state) // wraps to the first occurrence
    testing.expect_value(t, len(state.cursors), 3)
    select_word_or_next(&state) // everything selected already: no growth
    testing.expect_value(t, len(state.cursors), 3)
}

@(test)
test_move_and_duplicate_lines :: proc(t: ^testing.T) {
    state := ops_state("aaa\nbbb\nccc", 4) // caret on "bbb"
    defer destroy(&state)

    move_lines(&state, -1)
    testing.expect_value(t, text(&state), "bbb\naaa\nccc")
    testing.expect_value(t, primary_cursor(&state).caret, 0)

    move_lines(&state, 1)
    testing.expect_value(t, text(&state), "aaa\nbbb\nccc")

    undo(&state)
    undo(&state)
    testing.expect_value(t, text(&state), "aaa\nbbb\nccc")

    set_single_cursor(&state, 4)
    duplicate_lines(&state, 1)
    testing.expect_value(t, text(&state), "aaa\nbbb\nbbb\nccc")
    testing.expect_value(t, primary_cursor(&state).caret, 8)
}

@(test)
test_trim_trailing_whitespace :: proc(t: ^testing.T) {
    state := ops_state("aaa  \nbbb\t\n\tccc \n", 0)
    defer destroy(&state)

    trim_trailing_whitespace(&state)
    testing.expect_value(t, text(&state), "aaa\nbbb\n\tccc\n")

    // Leading indentation is preserved; a clean buffer is left unchanged.
    undo(&state)
    testing.expect_value(t, text(&state), "aaa  \nbbb\t\n\tccc \n")
}

@(test)
test_brace_block :: proc(t: ^testing.T) {
    // At the end of a line, `{` opens a three-line block with the caret parked
    // on the indented middle line.
    state := ops_state("foo", 3)
    defer destroy(&state)
    testing.expect(t, brace_block_applies(&state), "should apply at line end")
    insert_brace_block(&state)
    testing.expect_value(t, text(&state), "foo{\n    \n}")
    testing.expect_value(t, primary_cursor(&state).caret, 9)
    undo(&state)
    testing.expect_value(t, text(&state), "foo")

    // The opening line's indentation is carried onto the closing brace.
    state2 := ops_state("\tbar", 4)
    defer destroy(&state2)
    insert_brace_block(&state2)
    testing.expect_value(t, text(&state2), "\tbar{\n\t    \n\t}")

    // Mid-line, with a selection, or multi-cursor: the block form does not apply.
    state3 := ops_state("foobar", 3)
    defer destroy(&state3)
    testing.expect(t, !brace_block_applies(&state3), "should not apply mid-line")

    state4 := ops_state("foo", 3)
    defer destroy(&state4)
    state4.cursors[0].anchor = 0 // selection covering "foo"
    testing.expect(t, !brace_block_applies(&state4), "should not apply with a selection")
}

@(test)
test_indent_outdent :: proc(t: ^testing.T) {
    state := ops_state("aaa\nbbb\nccc", 0)
    defer destroy(&state)
    state.cursors[0].anchor = 0
    state.cursors[0].caret = 5 // covers lines 1 and 2

    indent_lines(&state)
    testing.expect_value(t, text(&state), "    aaa\n    bbb\nccc")

    outdent_lines(&state)
    testing.expect_value(t, text(&state), "aaa\nbbb\nccc")

    outdent_lines(&state) // nothing left to remove: no-op
    testing.expect_value(t, text(&state), "aaa\nbbb\nccc")
}

@(test)
test_insert_soft_tab :: proc(t: ^testing.T) {
    state := ops_state("ab", 0)
    defer destroy(&state)

    // From column 0, a soft tab fills a whole TAB_WIDTH stop.
    set_single_cursor(&state, 0)
    insert_soft_tab(&state)
    testing.expect_value(t, text(&state), "    ab")
    testing.expect_value(t, primary_cursor(&state).caret, 4)

    // From column 6, it only pads to the next stop (column 8): 2 spaces.
    set_single_cursor(&state, 6)
    insert_soft_tab(&state)
    testing.expect_value(t, text(&state), "    ab  ")
    testing.expect_value(t, primary_cursor(&state).caret, 8)
}

@(test)
test_toggle_comment :: proc(t: ^testing.T) {
    state := ops_state("aaa\n\n\tbbb", 0)
    defer destroy(&state)
    select_all(&state)

    toggle_comment(&state, "//")
    testing.expect_value(t, text(&state), "// aaa\n\n\t// bbb")

    toggle_comment(&state, "//")
    testing.expect_value(t, text(&state), "aaa\n\n\tbbb")
}

@(test)
test_delete_word_and_lines :: proc(t: ^testing.T) {
    state := ops_state("hello world", 11)
    defer destroy(&state)

    delete_word_backward(&state)
    testing.expect_value(t, text(&state), "hello ")

    set_text(&state, "aaa\nbbb\nccc")
    set_single_cursor(&state, 5)
    delete_lines(&state)
    testing.expect_value(t, text(&state), "aaa\nccc")
    testing.expect_value(t, primary_cursor(&state).caret, 4)
}
