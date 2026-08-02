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
