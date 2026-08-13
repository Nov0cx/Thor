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
test_copy_payload_multi_caret :: proc(t: ^testing.T) {
    state := ops_state("one\ntwo\nthree", 0)
    defer destroy(&state)
    set_cursors(&state, {Cursor{caret = 1, anchor = 1}, Cursor{caret = 9, anchor = 9}})

    payload, had_selection := copy_payload(&state)
    testing.expect(t, !had_selection, "no selection expected")
    testing.expect_value(t, payload, "one\nthree")

    // Two carets on one line yield it once.
    set_cursors(&state, {Cursor{caret = 4, anchor = 4}, Cursor{caret = 6, anchor = 6}})
    payload, _ = copy_payload(&state)
    testing.expect_value(t, payload, "two\n")
}

@(test)
test_select_word_and_next :: proc(t: ^testing.T) {
    state := ops_state("foo bar foo baz foo", 9) // inside first... second "foo"? caret 9 = inside "foo" at 8
    defer destroy(&state)

    select_word_or_next(&state, true)
    lo, hi := selection_range(primary_cursor(&state))
    testing.expect_value(t, text(&state)[lo:hi], "foo")

    select_word_or_next(&state, true)
    testing.expect_value(t, len(state.cursors), 2)
    select_word_or_next(&state, true) // wraps to the first occurrence
    testing.expect_value(t, len(state.cursors), 3)
    select_word_or_next(&state, true) // everything selected already: no growth
    testing.expect_value(t, len(state.cursors), 3)
}

@(test)
test_select_next_skips_substring :: proc(t: ^testing.T) {
    state := ops_state("foo food foo", 1)
    defer destroy(&state)

    select_word_or_next(&state, true)
    select_word_or_next(&state, true) // "food" is not a whole-word hit
    testing.expect_value(t, len(state.cursors), 2)
    lo, hi := selection_range(state.cursors[1])
    testing.expect_value(t, lo, 9)
    testing.expect_value(t, hi, 12)

    // Substring mode reaches the "foo" inside "food".
    sub := ops_state("foo food foo", 1)
    defer destroy(&sub)
    select_word_or_next(&sub, false)
    select_word_or_next(&sub, false)
    slo, shi := selection_range(sub.cursors[1])
    testing.expect_value(t, slo, 4)
    testing.expect_value(t, shi, 7)
}

@(test)
test_select_next_reaches_occurrence_before_primary :: proc(t: ^testing.T) {
    // Starting on the last "foo", the wrap must reach the middle one, not stop
    // at the document-first occurrence because it is already selected.
    state := ops_state("foo bar foo baz foo", 17)
    defer destroy(&state)

    select_word_or_next(&state, true) // selects the third "foo" at 16
    select_word_or_next(&state, true) // wraps to the first at 0
    testing.expect_value(t, len(state.cursors), 2)
    select_word_or_next(&state, true) // must find the middle one at 8
    testing.expect_value(t, len(state.cursors), 3)

    found := false
    for cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if lo == 8 && hi == 11 {
            found = true
        }
    }
    testing.expect(t, found, "the occurrence between the first and the primary is reachable")
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
test_align_at_char :: proc(t: ^testing.T) {
    // Select the whole block and align the `=` into one column. Whitespace
    // before the target is normalized, so both under- and over-spaced lines snap.
    content := "a = 1\nbb = 2\nccc     = 3"
    state := ops_state(content, 0)
    defer destroy(&state)
    state.cursors[0].anchor = 0
    state.cursors[0].caret = len(content)

    align_at_char(&state, '=')
    testing.expect_value(t, text(&state), "a   = 1\nbb  = 2\nccc = 3")

    // One undo entry restores the original block.
    undo(&state)
    testing.expect_value(t, text(&state), content)

    // A line whose target is its first non-blank character keeps its indentation,
    // and lines without the target are left alone.
    state2 := ops_state("x = 1\n= 2\nnope", 0)
    defer destroy(&state2)
    state2.cursors[0].anchor = 0
    state2.cursors[0].caret = len(text(&state2))
    align_at_char(&state2, '=')
    testing.expect_value(t, text(&state2), "x = 1\n= 2\nnope")

    // A tab-indented line contributes its display width, so the space padding
    // lands the target on the same column the tab-indented one reaches.
    tabbed_src := "\tb = 2\nlonger = 3"
    tabbed := ops_state(tabbed_src, 0)
    defer destroy(&tabbed)
    tabbed.cursors[0].anchor = 0
    tabbed.cursors[0].caret = len(tabbed_src)
    align_at_char(&tabbed, '=')
    // "\tb" ends at column 5 and "longer" at 6, so both '=' land on column 7.
    // Counting the tab as one column would pad "\tb" out to column 10.
    testing.expect_value(t, text(&tabbed), "\tb  = 2\nlonger = 3")
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

    // A literal tab counts as a whole stop, so the caret after "\tab" is at
    // column 6 and pads 2 to reach column 8 — counting the tab as one column
    // would pad 1.
    tabbed := ops_state("\tab", 3)
    defer destroy(&tabbed)
    insert_soft_tab(&tabbed)
    testing.expect_value(t, text(&tabbed), "\tab  ")
}

@(test)
test_tab_width_is_per_state :: proc(t: ^testing.T) {
    wide := ops_state("aaa", 0)
    defer destroy(&wide)
    narrow := ops_state("aaa", 0)
    defer destroy(&narrow)

    set_tab_width(&wide, 8)
    testing.expect_value(t, tab_width(&wide), 8)
    testing.expect_value(t, tab_width(&narrow), default_tab_width())

    indent_lines(&wide)
    indent_lines(&narrow)
    testing.expect_value(t, text(&wide), "        aaa")
    testing.expect_value(t, text(&narrow), "    aaa")

    // Back to 0: the state follows the default again.
    set_tab_width(&wide, 0)
    testing.expect_value(t, tab_width(&wide), default_tab_width())
}

@(test)
test_detect_indent :: proc(t: ^testing.T) {
    spaces := ops_state("a\n  b\n    c\n\n  d", 0)
    defer destroy(&spaces)
    info := detect_indent(&spaces)
    testing.expect_value(t, info.style, Indent_Style.Spaces)
    testing.expect_value(t, info.width, 2)
    testing.expect_value(t, info.space_lines, 3)
    testing.expect_value(t, info.tab_lines, 0)

    tabs := ops_state("a\n\tb\n\t\tc\n    d", 0)
    defer destroy(&tabs)
    info = detect_indent(&tabs)
    testing.expect_value(t, info.style, Indent_Style.Tabs)
    testing.expect_value(t, info.width, 0)
    testing.expect_value(t, info.tab_lines, 2)
    testing.expect_value(t, info.space_lines, 1)

    flat := ops_state("a\nb\n", 0)
    defer destroy(&flat)
    info = detect_indent(&flat)
    testing.expect_value(t, info.style, Indent_Style.Unknown)
    testing.expect_value(t, info.width, 0)
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

// Two carets in one word grow onto the same boundary. Before they were merged,
// the second range started behind the first delete and the running offset made a
// negative edit position: wrong bytes removed, a corrupt undo entry, then a panic.
@(test)
test_delete_word_merges_carets_in_one_word :: proc(t: ^testing.T) {
    state := ops_state("hello world", 3)
    defer destroy(&state)

    set_cursors(&state, []Cursor {{caret = 3, anchor = 3}, {caret = 5, anchor = 5}})
    testing.expect_value(t, len(state.cursors), 2)

    delete_word_backward(&state)
    testing.expect_value(t, text(&state), " world")
    testing.expect_value(t, len(state.cursors), 1)
    testing.expect_value(t, primary_cursor(&state).caret, 0)

    undo(&state)
    testing.expect_value(t, text(&state), "hello world")

    set_cursors(&state, []Cursor {{caret = 6, anchor = 6}, {caret = 8, anchor = 8}})
    delete_word_forward(&state)
    testing.expect_value(t, text(&state), "hello ")
    testing.expect_value(t, len(state.cursors), 1)
}

@(test)
test_replace_ranges :: proc(t: ^testing.T) {
    // A rename's occurrences: three spans of "foo" replaced in one undo entry,
    // handed in unsorted so the ordering is the operation's job, not the caller's.
    state := ops_state("foo bar foo baz foo", 4)
    defer destroy(&state)

    n := replace_ranges(&state, []Replace {
        {start = 16, end = 19, text = "quux"},
        {start = 0, end = 3, text = "quux"},
        {start = 8, end = 11, text = "quux"},
    })
    testing.expect_value(t, n, 3)
    testing.expect_value(t, text(&state), "quux bar quux baz quux")
    // The caret sat after the first replacement, so it shifts by that one edit.
    testing.expect_value(t, primary_cursor(&state).caret, 5)

    // One undo entry for the whole set.
    undo(&state)
    testing.expect_value(t, text(&state), "foo bar foo baz foo")

    // Overlapping and out-of-bounds ranges are skipped rather than corrupting.
    set_text(&state, "abcdef")
    set_single_cursor(&state, 0)
    m := replace_ranges(&state, []Replace {
        {start = 0, end = 3, text = "X"},
        {start = 2, end = 4, text = "Y"},
        {start = 5, end = 99, text = "Z"},
    })
    testing.expect_value(t, m, 1)
    testing.expect_value(t, text(&state), "Xdef")
}

@(test)
test_insert_at_and_delete_range :: proc(t: ^testing.T) {
    state := ops_state("hello world", 0)
    defer destroy(&state)

    testing.expect_value(t, insert_at(&state, 5, ","), Error.None)
    testing.expect_value(t, text(&state), "hello, world")

    testing.expect_value(t, delete_range(&state, 0, 7), Error.None)
    testing.expect_value(t, text(&state), "world")

    testing.expect_value(t, replace_range(&state, 0, 5, "earth"), Error.None)
    testing.expect_value(t, text(&state), "earth")

    // Each landed as its own undo entry.
    undo(&state)
    testing.expect_value(t, text(&state), "world")
    undo(&state)
    testing.expect_value(t, text(&state), "hello, world")
    undo(&state)
    testing.expect_value(t, text(&state), "hello world")
}

// An offset outside the buffer is refused, not clamped, and changes neither the
// text nor the undo history.
@(test)
test_checked_edits_reject_out_of_range :: proc(t: ^testing.T) {
    state := ops_state("abc", 0)
    defer destroy(&state)
    revision := state.revision

    testing.expect_value(t, insert_at(&state, 4, "x"), Error.Out_Of_Range)
    testing.expect_value(t, insert_at(&state, -1, "x"), Error.Out_Of_Range)
    testing.expect_value(t, delete_range(&state, 2, 5), Error.Out_Of_Range)
    testing.expect_value(t, delete_range(&state, 0, -1), Error.Out_Of_Range)
    testing.expect_value(t, replace_range(&state, 3, 1, "x"), Error.Out_Of_Range)
    testing.expect_value(t, text(&state), "abc")
    testing.expect_value(t, state.revision, revision)
    testing.expect_value(t, state.undo_stack.count, 0)

    testing.expect(t, valid_offset(&state, 3), "the end is a valid insert offset")
    testing.expect(t, !valid_offset(&state, 4), "past the end is not")
    testing.expect(t, valid_range(&state, 3, 0), "an empty range at the end is valid")
    testing.expect(t, !valid_range(&state, 3, 1), "a byte past the end is not")
}

// The cursors move with the edit, like every other one-undo-entry operation.
@(test)
test_insert_at_remaps_cursors :: proc(t: ^testing.T) {
    state := ops_state("abcdef", 4)
    defer destroy(&state)

    testing.expect_value(t, insert_at(&state, 1, "XY"), Error.None)
    testing.expect_value(t, text(&state), "aXYbcdef")
    testing.expect_value(t, primary_cursor(&state).caret, 6)

    testing.expect_value(t, delete_range(&state, 0, 3), Error.None)
    testing.expect_value(t, text(&state), "bcdef")
    testing.expect_value(t, primary_cursor(&state).caret, 3)
}
