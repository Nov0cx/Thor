package thor

import "core:testing"

@(test)
test_clipboard_history_order :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    defer thor_clipboard_history_destroy(thor)

    thor_clipboard_note(thor, "a")
    thor_clipboard_note(thor, "b")
    thor_clipboard_note(thor, "   ")
    thor_clipboard_note(thor, "a")
    testing.expect_value(t, len(thor.clipboard_history), 2)
    testing.expect_value(t, thor.clipboard_history[0], "a")
    testing.expect_value(t, thor.clipboard_history[1], "b")
}

@(test)
test_clipboard_label :: proc(t: ^testing.T) {
    testing.expect_value(t, thor_clipboard_label("one"), "one")
    testing.expect_value(t, thor_clipboard_label("\n  foo :: 1\nbar\n"), "foo :: 1  (+2 lines)")
    testing.expect_value(t, thor_clipboard_label("a\nb"), "a  (+1 line)")
}

@(test)
test_clipboard_history_cap :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    defer thor_clipboard_history_destroy(thor)

    texts: [CLIPBOARD_HISTORY_MAX + 3]string
    for &text, i in texts {
        text = fmt_entry(i)
        thor_clipboard_note(thor, text)
    }
    testing.expect_value(t, len(thor.clipboard_history), CLIPBOARD_HISTORY_MAX)
    testing.expect_value(t, thor.clipboard_history[0], texts[len(texts) - 1])
}

@(private = "file")
fmt_entry :: proc(i: int) -> string {
    buf := make([]u8, 3, context.temp_allocator)
    buf[0] = 'e'
    buf[1] = u8('a' + i / 26)
    buf[2] = u8('a' + i % 26)
    return string(buf)
}
