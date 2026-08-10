package lsp

import "core:strings"
import "core:testing"

// Run from the repository root: odin test lang/lsp

// Both directions of one position, since a conversion that is wrong the same way
// twice still round-trips.
@(private = "file")
expect_at :: proc(t: ^testing.T, idx: ^Line_Index, line, character, offset: int, loc := #caller_location) {
    testing.expect_value(t, offset_from_position(idx, line, character), offset, loc = loc)
    got_line, got_character := position_from_offset(idx, offset)
    testing.expect_value(t, got_line, line, loc = loc)
    testing.expect_value(t, got_character, character, loc = loc)
}

// The ASCII baseline: one line start per '\n', and the end of a line is the
// newline that ends it.
@(test)
test_position_ascii_lines :: proc(t: ^testing.T) {
    idx := line_index_build("one\ntwo\nthree", .Utf16)
    defer line_index_destroy(&idx)

    testing.expect_value(t, len(idx.starts), 3)
    expect_at(t, &idx, 0, 0, 0)
    expect_at(t, &idx, 0, 3, 3)
    expect_at(t, &idx, 1, 0, 4)
    expect_at(t, &idx, 1, 3, 7)
    expect_at(t, &idx, 2, 0, 8)
    expect_at(t, &idx, 2, 5, 13)
}

// An empty file still has line 0, or every position on it reads as past EOF.
@(test)
test_position_empty_file :: proc(t: ^testing.T) {
    idx := line_index_build("", .Utf16)
    defer line_index_destroy(&idx)

    testing.expect_value(t, len(idx.starts), 1)
    expect_at(t, &idx, 0, 0, 0)
    testing.expect_value(t, offset_from_position(&idx, 0, 5), 0)
    testing.expect_value(t, offset_from_position(&idx, 3, 0), 0)
}

// A trailing newline opens an empty last line; without it the last line is the
// text itself. Getting this wrong is one line of drift over a whole file.
@(test)
test_position_trailing_newline :: proc(t: ^testing.T) {
    with_newline := line_index_build("a\n", .Utf16)
    defer line_index_destroy(&with_newline)
    testing.expect_value(t, len(with_newline.starts), 2)
    expect_at(t, &with_newline, 0, 1, 1)
    expect_at(t, &with_newline, 1, 0, 2)

    without := line_index_build("a", .Utf16)
    defer line_index_destroy(&without)
    testing.expect_value(t, len(without.starts), 1)
    expect_at(t, &without, 0, 1, 1)
}

// Two- and three-byte characters cost one UTF-16 unit each, so a character index
// is not a byte index anywhere after the first one.
@(test)
test_position_multibyte :: proc(t: ^testing.T) {
    // 'é' is two bytes.
    two := line_index_build("aébc\nx", .Utf16)
    defer line_index_destroy(&two)
    expect_at(t, &two, 0, 0, 0)
    expect_at(t, &two, 0, 1, 1)
    expect_at(t, &two, 0, 2, 3)
    expect_at(t, &two, 0, 3, 4)
    expect_at(t, &two, 0, 4, 5)
    expect_at(t, &two, 1, 0, 6)
    expect_at(t, &two, 1, 1, 7)

    // '€' and '漢' are three bytes.
    three := line_index_build("€漢!", .Utf16)
    defer line_index_destroy(&three)
    expect_at(t, &three, 0, 1, 3)
    expect_at(t, &three, 0, 2, 6)
    expect_at(t, &three, 0, 3, 7)
}

// An astral character is four bytes and *two* UTF-16 units. The ASCII after it is
// the case that catches a +1 where +2 belongs.
@(test)
test_position_astral :: proc(t: ^testing.T) {
    after := line_index_build("😀A", .Utf16)
    defer line_index_destroy(&after)
    expect_at(t, &after, 0, 0, 0)
    expect_at(t, &after, 0, 2, 4)
    expect_at(t, &after, 0, 3, 5)

    alone := line_index_build("𝄞", .Utf16)
    defer line_index_destroy(&alone)
    expect_at(t, &alone, 0, 0, 0)
    expect_at(t, &alone, 0, 2, 4)

    pair := line_index_build("😀𝄞", .Utf16)
    defer line_index_destroy(&pair)
    expect_at(t, &pair, 0, 2, 4)
    expect_at(t, &pair, 0, 4, 8)
}

// A character that names the second half of a surrogate pair snaps back to the
// rune start. Any other answer hands a UTF-8 sequence split down the middle to
// everything downstream.
@(test)
test_position_surrogate_midpoint :: proc(t: ^testing.T) {
    idx := line_index_build("😀𝄞", .Utf16)
    defer line_index_destroy(&idx)

    testing.expect_value(t, offset_from_position(&idx, 0, 1), 0)
    testing.expect_value(t, offset_from_position(&idx, 0, 3), 4)
}

// A character past the line end lands on the line end, never on the next line;
// a line past EOF lands on len(text).
@(test)
test_position_clamps :: proc(t: ^testing.T) {
    idx := line_index_build("ab\ncd", .Utf16)
    defer line_index_destroy(&idx)

    testing.expect_value(t, offset_from_position(&idx, 0, 99), 2)
    testing.expect_value(t, offset_from_position(&idx, 99, 0), 5)
    testing.expect_value(t, offset_from_position(&idx, -1, 4), 0)
    testing.expect_value(t, offset_from_position(&idx, 0, -3), 0)

    line, character := position_from_offset(&idx, -5)
    testing.expect_value(t, line, 0)
    testing.expect_value(t, character, 0)

    line, character = position_from_offset(&idx, 99)
    testing.expect_value(t, line, 1)
    testing.expect_value(t, character, 2)
}

// With utf-8 negotiated a character is a byte count within the line, but a byte
// inside a rune is still pulled back to the rune start.
@(test)
test_position_utf8_encoding :: proc(t: ^testing.T) {
    idx := line_index_build("aébc", .Utf8)
    defer line_index_destroy(&idx)

    expect_at(t, &idx, 0, 0, 0)
    expect_at(t, &idx, 0, 1, 1)
    expect_at(t, &idx, 0, 3, 3)
    expect_at(t, &idx, 0, 5, 5)
    testing.expect_value(t, offset_from_position(&idx, 0, 2), 1)
    testing.expect_value(t, offset_from_position(&idx, 0, 99), 5)
}

// A file the server read from disk keeps its CRLF, so a raw offset is one byte
// per line ahead of the LF-collapsed offset the seam counts in. The expected
// value is computed by collapsing the text here, so the test cannot inherit the
// implementation's own idea of the answer.
@(test)
test_lf_offset_crlf :: proc(t: ^testing.T) {
    raw := "let a = 1\r\nlet b = 2\r\nlet c = 3"
    collapsed, allocated := strings.replace_all(raw, "\r\n", "\n")
    defer if allocated {
        delete(collapsed)
    }

    idx := line_index_build(raw, .Utf16)
    defer line_index_destroy(&idx)

    at := offset_from_position(&idx, 2, 4)
    testing.expect_value(t, raw[at], u8('c'))
    testing.expect_value(t, lf_offset(&idx, at), strings.index(collapsed, "let c") + 4)
    testing.expect_value(t, collapsed[lf_offset(&idx, at)], u8('c'))

    // The '\r' is the terminator, not content, so the line end stops before it.
    end := offset_from_position(&idx, 0, 9)
    testing.expect_value(t, end, 9)
    testing.expect_value(t, offset_from_position(&idx, 0, 99), 9)
    testing.expect_value(t, collapsed[lf_offset(&idx, end)], u8('\n'))
    // Both bytes of the pair name the one '\n' they collapse into.
    testing.expect_value(t, lf_offset(&idx, 10), lf_offset(&idx, 9))
}

// lang.source_read collapses "\r\n" only, so a lone '\r' is neither a line break
// nor a byte that disappears.
@(test)
test_lf_offset_lone_cr :: proc(t: ^testing.T) {
    raw := "a\rb\r\nc"
    collapsed, allocated := strings.replace_all(raw, "\r\n", "\n")
    defer if allocated {
        delete(collapsed)
    }

    idx := line_index_build(raw, .Utf16)
    defer line_index_destroy(&idx)

    testing.expect_value(t, len(idx.starts), 2)
    testing.expect_value(t, offset_from_position(&idx, 0, 3), 3)
    testing.expect_value(t, offset_from_position(&idx, 0, 99), 3)
    testing.expect_value(t, collapsed[lf_offset(&idx, 1)], u8('\r'))
    testing.expect_value(t, collapsed[lf_offset(&idx, 2)], u8('b'))
    testing.expect_value(t, collapsed[lf_offset(&idx, 5)], u8('c'))
}

// A file with both terminators shifts by the pairs before the line, not by the
// lines before it.
@(test)
test_lf_offset_mixed_terminators :: proc(t: ^testing.T) {
    raw := "a\r\nb\nc\r\nd"
    collapsed, allocated := strings.replace_all(raw, "\r\n", "\n")
    defer if allocated {
        delete(collapsed)
    }

    idx := line_index_build(raw, .Utf16)
    defer line_index_destroy(&idx)

    testing.expect_value(t, len(idx.starts), 4)
    testing.expect_value(t, collapsed[lf_offset(&idx, 0)], u8('a'))
    testing.expect_value(t, collapsed[lf_offset(&idx, 3)], u8('b'))
    testing.expect_value(t, collapsed[lf_offset(&idx, 5)], u8('c'))
    testing.expect_value(t, collapsed[lf_offset(&idx, 8)], u8('d'))
}

// A UTF-8 BOM is counted, never stripped: Thor sends the buffer verbatim, so the
// server indexes the same three leading bytes and they cost one unit like any
// other character.
@(test)
test_position_bom :: proc(t: ^testing.T) {
    idx := line_index_build("\xef\xbb\xbflet x", .Utf16)
    defer line_index_destroy(&idx)

    expect_at(t, &idx, 0, 0, 0)
    expect_at(t, &idx, 0, 1, 3)
    expect_at(t, &idx, 0, 2, 4)
    expect_at(t, &idx, 0, 6, 8)
}

// SignatureHelp gives a parameter as a [start, end) pair of character offsets into
// the label, so the label is converted with the same index a file is.
@(test)
test_position_signature_label_span :: proc(t: ^testing.T) {
    label := "f(a: 😀) -> int"
    idx := line_index_build(label, .Utf16)
    defer line_index_destroy(&idx)

    start := offset_from_position(&idx, 0, 5)
    end := offset_from_position(&idx, 0, 7)
    testing.expect_value(t, start, 5)
    testing.expect_value(t, end, 9)
    testing.expect_value(t, label[start:end], "😀")
    testing.expect_value(t, offset_from_position(&idx, 0, 15), len(label))
}

// The decoder converts a parameter label with no index at all, since the count
// runs over the label rather than over a file. It must agree with the index, and
// clamp the same way at both ends.
@(test)
test_position_utf16_offset :: proc(t: ^testing.T) {
    label := "f(a: 😀) -> int"
    idx := line_index_build(label, .Utf16)
    defer line_index_destroy(&idx)

    for units in 0 ..= 16 {
        testing.expectf(
            t,
            utf16_offset(label, units) == offset_from_position(&idx, 0, units),
            "%d units gave %d, the index gave %d",
            units,
            utf16_offset(label, units),
            offset_from_position(&idx, 0, units),
        )
    }
    testing.expect_value(t, utf16_offset(label, -1), 0)
    // A count inside the surrogate pair snaps back to the rune start.
    testing.expect_value(t, utf16_offset(label, 6), 5)
}
