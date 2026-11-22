package vt

import "core:strings"
import "core:testing"

@(private = "file")
feed :: proc(t: ^Term, text: string) {
    term_feed(t, transmute([]u8)text)
}

@(private = "file")
row_text :: proc(t: ^Term, y: int) -> string {
    g := grid(t)
    return line_text(t, &g[y], context.temp_allocator)
}

// True when every double-width lead has its spacer and every spacer its lead.
@(private = "file")
wide_whole :: proc(line: ^Line) -> bool {
    cells := line.cells[:]
    for c, x in cells {
        if .Wide in c.flags && (x + 1 >= len(cells) || .Spacer not_in cells[x + 1].flags) {
            return false
        }
        if .Spacer in c.flags && (x == 0 || .Wide not_in cells[x - 1].flags) {
            return false
        }
    }
    return true
}

// A row that wrapped joins its continuation when the screen gets wider.
@(test)
test_reflow_joins_on_widen :: proc(h: ^testing.T) {
    t := term_make(5, 3)
    defer term_destroy(t)

    feed(t, "abcdefgh")
    testing.expect_value(h, row_text(t, 0), "abcde")
    term_resize(t, 10, 3)
    testing.expect_value(h, row_text(t, 0), "abcdefgh")
    testing.expect_value(h, row_text(t, 1), "")
    testing.expect_value(h, t.cur.x, 8)
    testing.expect_value(h, t.cur.y, 0)
}

// A long row splits when the screen gets narrower, and a cursor past the edge
// waits to wrap.
@(test)
test_reflow_splits_on_narrow :: proc(h: ^testing.T) {
    t := term_make(10, 3)
    defer term_destroy(t)

    feed(t, "abcdefgh")
    term_resize(t, 4, 3)
    testing.expect_value(h, row_text(t, 0), "abcd")
    testing.expect_value(h, row_text(t, 1), "efgh")
    testing.expect_value(h, t.cur.y, 1)
    testing.expect_value(h, t.cur.x, 3)
    testing.expect(h, t.cur.pending_wrap, "the cursor waits past the edge")
    feed(t, "X")
    testing.expect_value(h, row_text(t, 2), "X")
}

// The history is rewrapped too: a line split between it and the screen comes
// back whole.
@(test)
test_reflow_rewraps_the_scrollback :: proc(h: ^testing.T) {
    t := term_make(4, 2)
    defer term_destroy(t)

    feed(t, "abcdefgh\r\nxy")
    testing.expect_value(h, len(t.scrollback), 1)
    testing.expect_value(h, row_text(t, 0), "efgh")
    term_resize(t, 8, 2)
    testing.expect_value(h, len(t.scrollback), 0)
    testing.expect_value(h, row_text(t, 0), "abcdefgh")
    testing.expect_value(h, row_text(t, 1), "xy")
    testing.expect_value(h, t.cur.x, 2)
    testing.expect_value(h, t.cur.y, 1)

    // Narrow again: the rows above the cursor go back into the history.
    term_resize(t, 4, 2)
    testing.expect_value(h, row_text(t, 1), "xy")
    testing.expect_value(h, term_line_text(t, 0, context.temp_allocator), "abcd")
}

// Spaces at the end of a wrapped row survive the join.
@(test)
test_reflow_keeps_spaces_at_a_wrap :: proc(h: ^testing.T) {
    t := term_make(4, 2)
    defer term_destroy(t)

    feed(t, "ab  cd\r\n\r\n")
    term_resize(t, 8, 2)
    testing.expect_value(h, term_line_text(t, 0, context.temp_allocator), "ab  cd")
}

// A double-width rune is never split by the new width.
@(test)
test_reflow_keeps_wide_runes_whole :: proc(h: ^testing.T) {
    t := term_make(5, 3)
    defer term_destroy(t)

    feed(t, "ab中cd")
    term_resize(t, 4, 3)
    testing.expect_value(h, row_text(t, 0), "ab中")
    testing.expect_value(h, row_text(t, 1), "cd")
    term_resize(t, 3, 3)
    testing.expect_value(h, row_text(t, 0), "ab")
    testing.expect_value(h, row_text(t, 1), "中c")
    testing.expect_value(h, row_text(t, 2), "d")
    for y in 0 ..< 3 {
        testing.expect(h, wide_whole(&t.primary[y]), "a wide rune lost a half")
    }
}

// DECSED and DECSEL keep the cells DECSCA protected; ED and EL take them.
@(test)
test_selective_erase_keeps_protected :: proc(h: ^testing.T) {
    t := term_make(10, 2)
    defer term_destroy(t)

    feed(t, "ab\x1b[1\"qCD\x1b[0\"qef")
    feed(t, "\x1b[?2K")
    testing.expect_value(h, row_text(t, 0), "  CD")
    feed(t, "\x1b[2K")
    testing.expect_value(h, row_text(t, 0), "")

    feed(t, "\x1b[H\x1b[1\"qP\x1b[0\"q\r\nQ\x1b[?2J")
    testing.expect_value(h, row_text(t, 0), "P")
    testing.expect_value(h, row_text(t, 1), "")
}

// Each edit that cuts a double-width rune blanks the half it left.
@(test)
test_edits_repair_wide_halves :: proc(h: ^testing.T) {
    Case :: struct {
        seq:  string,
        want: string,
    }
    cases := []Case{
        {"\x1b[3G\x1b[@", "a   b"}, // ICH on the spacer
        {"\x1b[3G\x1b[P", "a b"}, // DCH on the spacer
        {"\x1b[2G\x1b[P", "a b"}, // DCH on the lead
        {"\x1b[3G\x1b[X", "a  b"}, // ECH on the spacer
        {"\x1b[2G\x1b[X", "a  b"}, // ECH on the lead
        {"\x1b[3G\x1b[K", "a"}, // EL 0 from the spacer
        {"\x1b[2G\x1b[1K", "   b"}, // EL 1 to the lead
    }
    for c in cases {
        t := term_make(6, 1)
        feed(t, "a中b")
        feed(t, c.seq)
        testing.expectf(h, row_text(t, 0) == c.want, "%q: got %q, want %q", c.seq, row_text(t, 0), c.want)
        testing.expectf(h, wide_whole(&t.primary[0]), "%q left half a wide rune", c.seq)
        term_destroy(t)
    }

    // The alternate screen is cut, not reflowed; a lead cut from its spacer goes.
    t := term_make(6, 1)
    defer term_destroy(t)
    feed(t, "\x1b[?1049habcd中")
    term_resize(t, 5, 1)
    testing.expect(h, wide_whole(&t.alt[0]), "the column cut left half a wide rune")
}

// Over-long UTF-8 is a replacement character, and a C1 control written as UTF-8
// is dropped instead of joining the cell before it.
@(test)
test_utf8_overlong_and_c1 :: proc(h: ^testing.T) {
    t := term_make(10, 1)
    defer term_destroy(t)

    feed(t, "a\xe0\x80\xafb\xf0\x80\x80\xafc")
    testing.expect_value(h, row_text(t, 0), "a�b�c")

    feed(t, "\r\x1b[2Kx\xe0\x80\x80y\xc2\x9bz")
    testing.expect_value(h, row_text(t, 0), "x�yz")
    testing.expect_value(h, t.primary[0].cells[0].grapheme, u32(0))
}

// An OSC with no terminator swallows what follows, C0 controls included, until
// a BEL ends it; then printing carries on.
@(test)
test_unterminated_osc :: proc(h: ^testing.T) {
    t := term_make(10, 2)
    defer term_destroy(t)

    feed(t, "\x1b]0;abc")
    feed(t, "hi\r\nthere")
    testing.expect_value(h, row_text(t, 0), "")
    testing.expect_value(h, t.cur.x, 0)
    testing.expect_value(h, t.cur.y, 0)
    feed(t, "\x07ok")
    testing.expect_value(h, t.title, "abchithere")
    testing.expect_value(h, row_text(t, 0), "ok")
}

// An OSC past MAX_OSC is cut at the cap and the parser comes back to text.
@(test)
test_huge_osc_is_capped :: proc(h: ^testing.T) {
    t := term_make(10, 1)
    defer term_destroy(t)

    body := strings.repeat("a", 2 << 20)
    defer delete(body)
    feed(t, strings.concatenate({"\x1b]0;", body, "\x07z"}, context.temp_allocator))
    testing.expect_value(h, len(t.title), MAX_OSC - 2)
    testing.expect_value(h, row_text(t, 0), "z")
}

// A sixel DCS payload is read and dropped: no reply, no change to the grid.
@(test)
test_sixel_payload_is_dropped :: proc(h: ^testing.T) {
    t := term_make(10, 1)
    defer term_destroy(t)

    feed(t, "\x1bPq#0;2;0;0;0#0~~@@vv-\n~~\x1b\\A")
    testing.expect_value(h, row_text(t, 0), "A")
    testing.expect_value(h, len(term_take_reply(t)), 0)
}
