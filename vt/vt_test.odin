package vt

import "core:strings"
import "core:testing"

@(private = "file")
feed :: proc(t: ^Term, text: string) {
    term_feed(t, transmute([]u8) text)
}

@(private = "file")
row_text :: proc(t: ^Term, y: int) -> string {
    g := grid(t)
    return line_text(t, &g[y], context.temp_allocator)
}

@(test)
test_print_and_wrap :: proc(h: ^testing.T) {
    t := term_make(5, 3)
    defer term_destroy(t)

    feed(t, "abcdefg")
    testing.expect_value(h, row_text(t, 0), "abcde")
    testing.expect_value(h, row_text(t, 1), "fg")
    testing.expect_value(h, t.cur.y, 1)
    testing.expect_value(h, t.cur.x, 2)
    // The row that ran over says so, which is what joins the two on a copy.
    testing.expect(h, t.primary[0].wrapped)
}

@(test)
test_wrap_is_deferred :: proc(h: ^testing.T) {
    t := term_make(3, 2)
    defer term_destroy(t)

    // Filling the last column must not move to the next row on its own.
    feed(t, "abc")
    testing.expect_value(h, t.cur.y, 0)
    testing.expect(h, t.cur.pending_wrap)
    feed(t, "\r\n")
    testing.expect_value(h, t.cur.y, 1)
    testing.expect_value(h, row_text(t, 0), "abc")
}

@(test)
test_autowrap_off_overwrites_last_column :: proc(h: ^testing.T) {
    t := term_make(4, 2)
    defer term_destroy(t)

    feed(t, "\x1b[?7l")
    feed(t, "abcdef")
    testing.expect_value(h, row_text(t, 0), "abcf")
    testing.expect_value(h, row_text(t, 1), "")
}

@(test)
test_carriage_return_and_line_feed :: proc(h: ^testing.T) {
    t := term_make(8, 3)
    defer term_destroy(t)

    feed(t, "one\r\ntwo")
    testing.expect_value(h, row_text(t, 0), "one")
    testing.expect_value(h, row_text(t, 1), "two")

    // A bare carriage return rewrites the line, the way a progress bar does.
    feed(t, "\rTWO")
    testing.expect_value(h, row_text(t, 1), "TWO")
}

@(test)
test_scroll_into_history :: proc(h: ^testing.T) {
    t := term_make(4, 2)
    defer term_destroy(t)

    feed(t, "a\r\nb\r\nc\r\nd")
    testing.expect_value(h, len(t.scrollback), 2)
    testing.expect_value(h, term_total_lines(t), 4)
    testing.expect_value(h, term_line_text(t, 0, context.temp_allocator), "a")
    testing.expect_value(h, term_line_text(t, 3, context.temp_allocator), "d")
}

@(test)
test_scrollback_limit :: proc(h: ^testing.T) {
    t := term_make(4, 2, scrollback = 2)
    defer term_destroy(t)

    for line in ([?]string{"a", "b", "c", "d", "e"}) {
        feed(t, line)
        feed(t, "\r\n")
    }
    testing.expect_value(h, len(t.scrollback), 2)
    testing.expect_value(h, term_line_text(t, 0, context.temp_allocator), "c")
}

@(test)
test_scroll_region :: proc(h: ^testing.T) {
    t := term_make(4, 4)
    defer term_destroy(t)

    feed(t, "1\r\n2\r\n3\r\n4")
    // Rows two and three scroll on their own; the first and last stay put.
    feed(t, "\x1b[2;3r")
    feed(t, "\x1b[3;1H") // the region's last row
    feed(t, "\n")
    testing.expect_value(h, row_text(t, 0), "1")
    testing.expect_value(h, row_text(t, 1), "3")
    testing.expect_value(h, row_text(t, 2), "")
    testing.expect_value(h, row_text(t, 3), "4")
    // A region that does not reach the top keeps its rows out of the history.
    testing.expect_value(h, len(t.scrollback), 0)
}

@(test)
test_erase_display_and_line :: proc(h: ^testing.T) {
    t := term_make(6, 3)
    defer term_destroy(t)

    feed(t, "abcdef\r\nghijkl\r\nmnopqr")
    feed(t, "\x1b[2;3H\x1b[K") // erase to the end of row two
    testing.expect_value(h, row_text(t, 1), "gh")

    feed(t, "\x1b[1;1H\x1b[J") // erase from the top down
    testing.expect_value(h, row_text(t, 0), "")
    testing.expect_value(h, row_text(t, 2), "")
}

@(test)
test_insert_and_delete :: proc(h: ^testing.T) {
    t := term_make(6, 2)
    defer term_destroy(t)

    feed(t, "abcdef")
    feed(t, "\x1b[1;3H\x1b[2@") // two blanks at column three
    testing.expect_value(h, row_text(t, 0), "ab  cd")
    feed(t, "\x1b[1;3H\x1b[2P") // and take them back out
    testing.expect_value(h, row_text(t, 0), "abcd")
}

@(test)
test_insert_mode :: proc(h: ^testing.T) {
    t := term_make(6, 2)
    defer term_destroy(t)

    feed(t, "abcd")
    feed(t, "\x1b[1;2H\x1b[4hXY")
    testing.expect_value(h, row_text(t, 0), "aXYbcd")
}

@(test)
test_sgr_colors :: proc(h: ^testing.T) {
    t := term_make(8, 2)
    defer term_destroy(t)

    feed(t, "\x1b[1;31mA")
    feed(t, "\x1b[38;2;10;20;30mB")
    feed(t, "\x1b[38:5:200mC")
    feed(t, "\x1b[0mD")

    cells := t.primary[0].cells
    testing.expect(h, .Bold in cells[0].attrs)
    testing.expect_value(h, cells[0].fg, color_indexed(1))
    testing.expect_value(h, cells[1].fg, color_rgb(10, 20, 30))
    testing.expect_value(h, cells[2].fg, color_indexed(200))
    testing.expect_value(h, cells[3].fg, Color{})
    testing.expect(h, .Bold not_in cells[3].attrs)
}

@(test)
test_sgr_underline_styles :: proc(h: ^testing.T) {
    t := term_make(4, 2)
    defer term_destroy(t)

    feed(t, "\x1b[4:3mA\x1b[4mB\x1b[24mC")
    cells := t.primary[0].cells
    testing.expect_value(h, cells[0].underline, Underline.Curly)
    testing.expect_value(h, cells[1].underline, Underline.Single)
    testing.expect_value(h, cells[2].underline, Underline.None)
}

@(test)
test_utf8_and_wide :: proc(h: ^testing.T) {
    t := term_make(8, 2)
    defer term_destroy(t)

    feed(t, "aä漢b")
    testing.expect_value(h, row_text(t, 0), "aä漢b")
    // The wide character owns two columns, so the one behind it is a spacer.
    testing.expect(h, .Wide in t.primary[0].cells[2].flags)
    testing.expect(h, .Spacer in t.primary[0].cells[3].flags)
    testing.expect_value(h, t.cur.x, 5)
}

@(test)
test_utf8_split_across_feeds :: proc(h: ^testing.T) {
    t := term_make(4, 2)
    defer term_destroy(t)

    bytes := transmute([]u8) string("ä")
    term_feed(t, bytes[:1])
    term_feed(t, bytes[1:])
    testing.expect_value(h, row_text(t, 0), "ä")
}

@(test)
test_combining_mark :: proc(h: ^testing.T) {
    t := term_make(4, 2)
    defer term_destroy(t)

    feed(t, "é")
    testing.expect_value(h, row_text(t, 0), "é")
    testing.expect_value(h, t.cur.x, 1)
}

@(test)
test_escape_split_across_feeds :: proc(h: ^testing.T) {
    t := term_make(8, 2)
    defer term_destroy(t)

    feed(t, "\x1b[1")
    feed(t, ";31mX")
    testing.expect_value(h, t.primary[0].cells[0].fg, color_indexed(1))
}

@(test)
test_alt_screen :: proc(h: ^testing.T) {
    t := term_make(6, 2)
    defer term_destroy(t)

    feed(t, "main")
    feed(t, "\x1b[?1049h")
    testing.expect(h, t.alt_active)
    testing.expect_value(h, row_text(t, 0), "")
    feed(t, "alt")
    feed(t, "\x1b[?1049l")
    testing.expect(h, !t.alt_active)
    testing.expect_value(h, row_text(t, 0), "main")
    // The alternate screen is never history.
    testing.expect_value(h, len(t.scrollback), 0)
}

@(test)
test_tabs :: proc(h: ^testing.T) {
    t := term_make(20, 2)
    defer term_destroy(t)

    feed(t, "a\tb")
    testing.expect_value(h, t.cur.x, 9)
    feed(t, "\x1b[3g") // every stop gone
    feed(t, "\r\t")
    testing.expect_value(h, t.cur.x, 19)
}

@(test)
test_device_reports :: proc(h: ^testing.T) {
    t := term_make(10, 4)
    defer term_destroy(t)

    feed(t, "\x1b[2;5H\x1b[6n")
    testing.expect_value(h, string(term_take_reply(t)), "\x1b[2;5R")
    term_clear_reply(t)

    feed(t, "\x1b[18t")
    testing.expect_value(h, string(term_take_reply(t)), "\x1b[8;4;10t")
    term_clear_reply(t)

    feed(t, "\x1b[?25l\x1b[?25$p")
    testing.expect_value(h, string(term_take_reply(t)), "\x1b[?25;2$y")
}

@(test)
test_osc_title_and_command_end :: proc(h: ^testing.T) {
    t := term_make(8, 2)
    defer term_destroy(t)

    feed(t, "\x1b]0;a title\x07")
    testing.expect_value(h, t.title, "a title")

    feed(t, "\x1b]133;D;3\x1b\\")
    end, ok := term_take_command_end(t)
    testing.expect(h, ok)
    testing.expect_value(h, end.code, 3)
    _, again := term_take_command_end(t)
    testing.expect(h, !again)
}

@(test)
test_osc_hyperlink :: proc(h: ^testing.T) {
    t := term_make(8, 2)
    defer term_destroy(t)

    feed(t, "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\x")
    cells := t.primary[0].cells
    testing.expect_value(h, term_link(t, cells[0].link), "https://example.com")
    testing.expect_value(h, cells[4].link, u32(0))
}

@(test)
test_dec_graphics_charset :: proc(h: ^testing.T) {
    t := term_make(4, 2)
    defer term_destroy(t)

    feed(t, "\x1b(0q\x1b(Bq")
    testing.expect_value(h, row_text(t, 0), "─q")
}

@(test)
test_resize_keeps_content :: proc(h: ^testing.T) {
    t := term_make(6, 3)
    defer term_destroy(t)

    feed(t, "abc\r\ndef")
    term_resize(t, 10, 4)
    testing.expect_value(h, t.cols, 10)
    testing.expect_value(h, row_text(t, 0), "abc")
    testing.expect_value(h, row_text(t, 1), "def")

    // Shrinking past the cursor moves the rows above it into the history.
    term_resize(t, 10, 1)
    testing.expect_value(h, row_text(t, 0), "def")
    testing.expect_value(h, term_line_text(t, 0, context.temp_allocator), "abc")
}

@(test)
test_key_encoding :: proc(h: ^testing.T) {
    t := term_make(8, 2)
    defer term_destroy(t)

    text, ok := encode_key(t, .Up)
    testing.expect(h, ok)
    testing.expect_value(h, text, "\x1b[A")

    feed(t, "\x1b[?1h") // application cursor keys
    text, _ = encode_key(t, .Up)
    testing.expect_value(h, text, "\x1bOA")

    text, _ = encode_key(t, .Up, {.Ctrl})
    testing.expect_value(h, text, "\x1b[1;5A")

    text, _ = encode_key(t, .F5, {.Shift})
    testing.expect_value(h, text, "\x1b[15;2~")

    text, _ = encode_rune(t, 'c', {.Ctrl})
    testing.expect_value(h, text, "\x03")

    text, _ = encode_rune(t, 'b', {.Alt})
    testing.expect_value(h, text, "\x1bb")

    text, _ = encode_key(t, .Backspace)
    testing.expect_value(h, text, "\x7f")
}

@(test)
test_bracketed_paste :: proc(h: ^testing.T) {
    t := term_make(8, 2)
    defer term_destroy(t)

    testing.expect_value(h, encode_paste(t, "a\nb"), "a\rb")
    feed(t, "\x1b[?2004h")
    testing.expect_value(h, encode_paste(t, "a\nb"), "\x1b[200~a\rb\x1b[201~")
    // An escape inside a paste would end the fence early, so it never goes.
    testing.expect_value(h, encode_paste(t, "a\x1bb"), "\x1b[200~ab\x1b[201~")
}

@(test)
test_mouse_encoding :: proc(h: ^testing.T) {
    t := term_make(8, 4)
    defer term_destroy(t)

    _, ok := encode_mouse(t, .Left, .Press, 3, 2)
    testing.expect(h, !ok)

    feed(t, "\x1b[?1000h\x1b[?1006h")
    report, sent := encode_mouse(t, .Left, .Press, 3, 2)
    testing.expect(h, sent)
    testing.expect_value(h, report, "\x1b[<0;4;3M")

    report, _ = encode_mouse(t, .Left, .Release, 3, 2)
    testing.expect_value(h, report, "\x1b[<0;4;3m")

    _, moved := encode_mouse(t, .Left, .Move, 3, 2)
    testing.expect(h, !moved)
}

@(test)
test_selection_text_joins_wrapped_rows :: proc(h: ^testing.T) {
    t := term_make(4, 3)
    defer term_destroy(t)

    feed(t, "abcdef\r\nxy")
    text := term_text_range(t, {line = 0, col = 0}, {line = 2, col = 2})
    testing.expect_value(h, text, "abcdef\nxy")
}

@(test)
test_reset :: proc(h: ^testing.T) {
    t := term_make(6, 2)
    defer term_destroy(t)

    feed(t, "\x1b[31mabc\r\ndef\r\nghi")
    feed(t, "\x1bc")
    testing.expect_value(h, row_text(t, 0), "")
    testing.expect_value(h, len(t.scrollback), 0)
    testing.expect_value(h, t.cur.pen.fg, Color{})
}

@(test)
test_reply_survives_split_osc :: proc(h: ^testing.T) {
    t := term_make(6, 2)
    defer term_destroy(t)

    feed(t, "\x1b]0;half")
    feed(t, " a title\x07")
    testing.expect_value(h, t.title, "half a title")
}

@(test)
test_text_all :: proc(h: ^testing.T) {
    t := term_make(6, 2)
    defer term_destroy(t)

    feed(t, "one\r\ntwo\r\nthree")
    testing.expect(h, strings.contains(term_text_all(t), "one"))
    testing.expect(h, strings.contains(term_text_all(t), "three"))
}
