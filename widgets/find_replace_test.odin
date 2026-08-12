package widgets

import "core:testing"
import rl "vendor:raylib"

import "../textedit"
import "../ui"

// A Find_Replace over a fixed buffer, wired to a bare editor. The editor is a
// stack value rather than editor_create's heap widget, so its row cache is freed
// here rather than by editor_destroy.
@(private = "file")
fixture :: proc(state: ^textedit.State, editor: ^Editor, src: string) -> ^Find_Replace {
    textedit.init(state)
    textedit.set_text(state, src)
    editor.state = state
    editor.font_size = 16
    return find_replace_create("find")
}

@(private = "file")
fixture_destroy :: proc(state: ^textedit.State, editor: ^Editor, fr: ^Find_Replace) {
    delete(editor.visual_rows)
    textedit.destroy(state)
    find_replace_destroy(&fr.widget)
}

// Types a query into the find field one rune at a time.
@(private = "file")
fr_test_type :: proc(fr: ^Find_Replace, ctx: ^ui.Context, text: string) {
    for r in text {
        event := ui.Event {kind = .Text_Input, codepoint = r}
        find_replace_handle_event(&fr.widget, ctx, &event)
    }
}

@(private = "file")
fr_test_chord :: proc(fr: ^Find_Replace, ctx: ^ui.Context, key: rl.KeyboardKey) {
    event := ui.Event {kind = .Key_Press, key = key, alt = true}
    find_replace_handle_event(&fr.widget, ctx, &event)
}

// Opening find on a selected word starts on that occurrence. Anchoring on the
// caret instead skipped to the next one, because a selection leaves the caret
// at its end.
@(test)
test_find_opens_on_the_selection :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "alpha beta alpha gamma alpha\n")
    defer fixture_destroy(&state, &editor, fr)

    textedit.select_range(&state, 11, 16) // the second "alpha", as a double-click leaves it
    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, false)

    testing.expectf(t, len(fr.matches) == 3, "expected 3 matches, got %d", len(fr.matches))
    testing.expectf(t, fr.current == 1, "expected the selected occurrence to stay current, got %d", fr.current)
    lo, hi := textedit.selection_range(textedit.primary_cursor(&state))
    testing.expectf(t, lo == 11 && hi == 16, "expected the selection to stay put, got %d..%d", lo, hi)
}

// Text goes in at the field's caret, and the arrows and Home/End move it.
@(test)
test_find_field_caret :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "abc\n")
    defer fixture_destroy(&state, &editor, fr)

    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, false)

    type_rune :: proc(fr: ^Find_Replace, ctx: ^ui.Context, r: rune) {
        event := ui.Event {kind = .Text_Input, codepoint = r}
        find_replace_handle_event(&fr.widget, ctx, &event)
    }
    press :: proc(fr: ^Find_Replace, ctx: ^ui.Context, key: rl.KeyboardKey) {
        event := ui.Event {kind = .Key_Press, key = key}
        find_replace_handle_event(&fr.widget, ctx, &event)
    }

    type_rune(fr, &ctx, 'a')
    type_rune(fr, &ctx, 'c')
    press(fr, &ctx, .LEFT)
    type_rune(fr, &ctx, 'b')
    testing.expectf(t, string(fr.find[:]) == "abc", "expected \"abc\", got %q", string(fr.find[:]))
    testing.expectf(t, fr.find_caret == 2, "expected the caret after the insert, got %d", fr.find_caret)

    // Home, then Delete takes the first rune; End, then Backspace the last.
    press(fr, &ctx, .HOME)
    press(fr, &ctx, .DELETE)
    press(fr, &ctx, .END)
    press(fr, &ctx, .BACKSPACE)
    testing.expectf(t, string(fr.find[:]) == "b", "expected \"b\", got %q", string(fr.find[:]))
    testing.expectf(t, fr.find_caret == 1, "expected the caret at the end, got %d", fr.find_caret)
}

// Alt+C narrows the search to the query's own casing.
@(test)
test_find_case_sensitive_toggle :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "Alpha alpha\n")
    defer fixture_destroy(&state, &editor, fr)

    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, false)
    fr_test_type(fr, &ctx, "alpha")
    testing.expect_value(t, len(fr.matches), 2)

    fr_test_chord(fr, &ctx, .C)
    testing.expect(t, fr.case_sensitive, "alt + c turns matching case-sensitive")
    testing.expect_value(t, len(fr.matches), 1)
    testing.expect_value(t, fr.matches[0].start, 6)
    testing.expect_value(t, fr.matches[0].end, 11)

    // And back: the toggle is not one-way.
    fr_test_chord(fr, &ctx, .C)
    testing.expect_value(t, len(fr.matches), 2)
}

// Alt+W drops the occurrences glued to a longer identifier.
@(test)
test_find_whole_word_toggle :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "alpha alphabet _alpha\n")
    defer fixture_destroy(&state, &editor, fr)

    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, false)
    fr_test_type(fr, &ctx, "alpha")
    testing.expect_value(t, len(fr.matches), 3)

    fr_test_chord(fr, &ctx, .W)
    testing.expect(t, fr.whole_word, "alt + w turns on whole-word matching")
    testing.expect_value(t, len(fr.matches), 1)
    testing.expect_value(t, fr.matches[0].start, 0)
}

// A match that whole-word rejects must not hide the one right after it: the
// skip table advances from the window, so a rejected match still has to step on.
@(test)
test_find_whole_word_keeps_scanning :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "alphabet alpha\n")
    defer fixture_destroy(&state, &editor, fr)

    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, false)
    fr_test_type(fr, &ctx, "alpha")
    fr_test_chord(fr, &ctx, .W)

    testing.expect_value(t, len(fr.matches), 1)
    testing.expect_value(t, fr.matches[0].start, 9)
}

// A regex match spans what the pattern matched, which is the length the old
// start-offsets-only model could not carry.
@(test)
test_find_regex_matches_carry_their_length :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "a1 b22 c333\n")
    defer fixture_destroy(&state, &editor, fr)

    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, false)
    fr_test_type(fr, &ctx, "[0-9]+")
    // Until regex is on, the pattern is a literal and matches nothing.
    testing.expect_value(t, len(fr.matches), 0)

    fr_test_chord(fr, &ctx, .R)
    testing.expect(t, fr.use_regex, "alt + r turns on regular expressions")
    testing.expect_value(t, len(fr.matches), 3)
    testing.expect_value(t, fr.matches[0].end - fr.matches[0].start, 1)
    testing.expect_value(t, fr.matches[1].end - fr.matches[1].start, 2)
    testing.expect_value(t, fr.matches[2].end - fr.matches[2].start, 3)

    // The selection covers the whole match, not len(query) bytes of it.
    lo, hi := textedit.selection_range(textedit.primary_cursor(&state))
    testing.expect_value(t, lo, fr.matches[fr.current].start)
    testing.expect_value(t, hi, fr.matches[fr.current].end)
}

// The case toggle drives the regex flags too, so "match case" means one thing.
@(test)
test_find_regex_honors_case_and_word :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "Alpha alpha alphabet\n")
    defer fixture_destroy(&state, &editor, fr)

    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, false)
    fr_test_type(fr, &ctx, "alpha")
    fr_test_chord(fr, &ctx, .R)
    testing.expect_value(t, len(fr.matches), 3)

    fr_test_chord(fr, &ctx, .C)
    testing.expect_value(t, len(fr.matches), 2)

    fr_test_chord(fr, &ctx, .W)
    testing.expect_value(t, len(fr.matches), 1)
    testing.expect_value(t, fr.matches[0].start, 6)
}

// A pattern that does not compile says so and finds nothing, rather than
// throwing away the keystroke that will finish it.
@(test)
test_find_regex_invalid_pattern :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "alpha\n")
    defer fixture_destroy(&state, &editor, fr)

    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, false)
    fr_test_chord(fr, &ctx, .R)
    fr_test_type(fr, &ctx, "a(")

    testing.expect(t, fr.regex_bad, "an unclosed group does not compile")
    testing.expect_value(t, len(fr.matches), 0)

    // Stepping over no matches must not fault.
    enter := ui.Event {kind = .Key_Press, key = .ENTER}
    find_replace_handle_event(&fr.widget, &ctx, &enter)

    // Finishing the group makes it valid again.
    fr_test_type(fr, &ctx, "l)")
    testing.expect_value(t, string(fr.find[:]), "a(l)")
    testing.expect(t, !fr.regex_bad, "a complete pattern compiles")
    testing.expect_value(t, len(fr.matches), 1)
    testing.expect_value(t, fr.matches[0].end - fr.matches[0].start, 2)
}

// A zero-width pattern is dropped: it selects nothing, and replacing over one
// would splice forever.
@(test)
test_find_regex_skips_zero_width :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "aaa\n")
    defer fixture_destroy(&state, &editor, fr)

    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, false)
    fr_test_chord(fr, &ctx, .R)
    fr_test_type(fr, &ctx, "b*")

    testing.expect(t, !fr.regex_bad, "the pattern is valid")
    testing.expect_value(t, len(fr.matches), 0)
}

// Replace All over a regex rewrites spans of different lengths in one sweep.
@(test)
test_find_regex_replace_all :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "a1 b22 c333\n")
    defer fixture_destroy(&state, &editor, fr)

    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, true)
    fr_test_chord(fr, &ctx, .R)
    fr_test_type(fr, &ctx, "[0-9]+")

    tab := ui.Event {kind = .Key_Press, key = .TAB}
    find_replace_handle_event(&fr.widget, &ctx, &tab)
    fr_test_type(fr, &ctx, "#")

    find_replace_layout(&fr.widget, rl.Rectangle {0, 0, 1200, 800})
    click := ui.Event {
        kind = .Mouse_Down,
        mouse_button = .LEFT,
        mouse_position = rl.Vector2 {
            fr.btn_all.x + fr.btn_all.width * 0.5,
            fr.btn_all.y + fr.btn_all.height * 0.5,
        },
    }
    find_replace_handle_event(&fr.widget, &ctx, &click)
    testing.expect_value(t, textedit.text(&state), "a# b# c#\n")

    textedit.undo(&state)
    testing.expect_value(t, textedit.text(&state), "a1 b22 c333\n")
}

// Replace All goes through replace_ranges, so the whole sweep is one undo entry.
@(test)
test_find_replace_all_is_one_undo :: proc(t: ^testing.T) {
    state: textedit.State
    editor: Editor
    fr := fixture(&state, &editor, "alpha beta alpha\n")
    defer fixture_destroy(&state, &editor, fr)

    ctx: ui.Context
    find_replace_open(fr, &ctx, &editor, true)
    fr_test_type(fr, &ctx, "alpha")

    tab := ui.Event {kind = .Key_Press, key = .TAB}
    find_replace_handle_event(&fr.widget, &ctx, &tab)
    fr_test_type(fr, &ctx, "x")

    // Through the button, so the layout rect is exercised with it.
    find_replace_layout(&fr.widget, rl.Rectangle {0, 0, 1200, 800})
    click := ui.Event {
        kind = .Mouse_Down,
        mouse_button = .LEFT,
        mouse_position = rl.Vector2 {
            fr.btn_all.x + fr.btn_all.width * 0.5,
            fr.btn_all.y + fr.btn_all.height * 0.5,
        },
    }
    find_replace_handle_event(&fr.widget, &ctx, &click)
    testing.expect_value(t, textedit.text(&state), "x beta x\n")

    textedit.undo(&state)
    testing.expect_value(t, textedit.text(&state), "alpha beta alpha\n")
}
