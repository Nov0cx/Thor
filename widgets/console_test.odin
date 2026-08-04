package widgets

import "core:testing"

import rl "vendor:raylib"

import "../ui"

// Run from the repository root: odin test widgets

// Output from a real shell arrives with CRLF; the console keeps one newline per
// line so the scrollback splits where the shell meant it to.
@(test)
test_console_append_crlf :: proc(t: ^testing.T) {
    console := console_create("test")
    defer console_destroy(&console.widget)
    console_clear(console)

    console_append(console, "one\r\ntwo\r\n")
    testing.expect_value(t, console_text(console), "one\ntwo\n")
}

// A CRLF split across two reads must still be one newline, not a rewind of the
// line before it.
@(test)
test_console_append_split_crlf :: proc(t: ^testing.T) {
    console := console_create("test")
    defer console_destroy(&console.widget)
    console_clear(console)

    console_append(console, "one\r")
    console_append(console, "\ntwo")
    testing.expect_value(t, console_text(console), "one\ntwo")
}

// A bare carriage return rewrites the line, the way a progress bar expects.
@(test)
test_console_append_bare_cr_rewinds :: proc(t: ^testing.T) {
    console := console_create("test")
    defer console_destroy(&console.widget)
    console_clear(console)

    console_append(console, "kept\n50%\r100%\n")
    testing.expect_value(t, console_text(console), "kept\n100%\n")
}

// The console draws plain text, so a color sequence must leave nothing behind.
@(test)
test_console_append_strips_escapes :: proc(t: ^testing.T) {
    console := console_create("test")
    defer console_destroy(&console.widget)
    console_clear(console)

    console_append(console, "\x1b[31mred\x1b[0m\n\x1b]0;title\x07plain\n")
    testing.expect_value(t, console_text(console), "red\nplain\n")
}

// Tabs survive, since tool output aligns with them.
@(test)
test_console_append_keeps_tabs :: proc(t: ^testing.T) {
    console := console_create("test")
    defer console_destroy(&console.widget)
    console_clear(console)

    console_append(console, "a\tb\n")
    testing.expect_value(t, console_text(console), "a\tb\n")
}

// The wheel stops at both ends of the scrollback, so the view never leaves the
// output behind; reaching the last line makes it follow new output again.
@(test)
test_console_scroll_stops_at_the_ends :: proc(t: ^testing.T) {
    console := console_create("test")
    defer console_destroy(&console.widget)
    console_clear(console)
    console.bounds = rl.Rectangle {0, 0, 400, 200}

    for _ in 0 ..< 100 {
        console_append(console, "line\n")
    }

    line_height := cast(f32) ui.text_line_height(console.font_size)
    // 100 newlines end 101 lines, the last of them empty.
    end := 101 * line_height - (console.bounds.height - (line_height + 14))

    event := ui.Event {kind = .Scroll, wheel_delta = -1000}
    console_handle_event(&console.widget, nil, &event)
    testing.expect_value(t, console.scroll_y, end)
    testing.expect(t, console.autoscroll, "the view follows again at the last line")

    event.wheel_delta = 1000
    console_handle_event(&console.widget, nil, &event)
    testing.expect_value(t, console.scroll_y, 0)
    testing.expect(t, !console.autoscroll, "the view stays put above the last line")
}

// The arrow keys walk the submitted commands, and the line below the newest one
// is empty so the user can type a fresh command.
@(test)
test_console_history_walks :: proc(t: ^testing.T) {
    console := console_create("test")
    defer console_destroy(&console.widget)

    console_history_add(console, "first")
    console_history_add(console, "second")
    // A repeat of the newest entry is not recorded twice.
    console_history_add(console, "second")
    testing.expect_value(t, len(console.history), 2)

    console_history_show(console, console.history_index - 1)
    testing.expect_value(t, string(console.input[:]), "second")
    console_history_show(console, console.history_index - 1)
    testing.expect_value(t, string(console.input[:]), "first")
    // The oldest entry is the end of the walk.
    console_history_show(console, console.history_index - 1)
    testing.expect_value(t, string(console.input[:]), "first")

    console_history_show(console, len(console.history))
    testing.expect_value(t, string(console.input[:]), "")
}
