package thor

import "core:strings"
import "core:testing"

@(test)
test_encoding_is_read_off_the_bytes :: proc(t: ^testing.T) {
    encoding, bom := thor_detect_encoding({0xEF, 0xBB, 0xBF, 'a'})
    testing.expect_value(t, encoding, Encoding.UTF8)
    testing.expect_value(t, bom, 3)

    encoding, bom = thor_detect_encoding({0xFF, 0xFE, 'a', 0})
    testing.expect_value(t, encoding, Encoding.UTF16_LE)
    testing.expect_value(t, bom, 2)

    encoding, bom = thor_detect_encoding({0xFE, 0xFF, 0, 'a'})
    testing.expect_value(t, encoding, Encoding.UTF16_BE)
    testing.expect_value(t, bom, 2)

    // No mark: the NUL high bytes of ASCII text name the byte order.
    encoding, bom = thor_detect_encoding({'a', 0, 'b', 0, 'c', 0})
    testing.expect_value(t, encoding, Encoding.UTF16_LE)
    testing.expect_value(t, bom, 0)

    encoding, bom = thor_detect_encoding({'p', 'l', 'a', 'i', 'n', '\n'})
    testing.expect_value(t, encoding, Encoding.UTF8)
    testing.expect_value(t, bom, 0)
}

@(test)
test_utf16_round_trip :: proc(t: ^testing.T) {
    source := "héllo 😀\n"
    for encoding in ([2]Encoding{.UTF16_LE, .UTF16_BE}) {
        disk := thor_encode_text(strings.clone(source), encoding, true, context.allocator)
        defer delete(disk)

        found, bom := thor_detect_encoding(transmute([]u8) disk)
        testing.expect_value(t, found, encoding)
        testing.expect_value(t, bom, 2)

        text, ok := thor_decode_utf16(transmute([]u8) disk[bom:], encoding == .UTF16_BE, context.allocator)
        defer delete(text)
        testing.expect(t, ok, "the text decodes")
        testing.expect_value(t, text, source)
    }

    marked := thor_encode_text(strings.clone("a"), .UTF8, true, context.allocator)
    defer delete(marked)
    testing.expect_value(t, marked, "\xEF\xBB\xBFa")
}

@(test)
test_mixed_line_endings_are_kept :: proc(t: ^testing.T) {
    testing.expect_value(t, thor_detect_line_ending("a\nb\n"), Line_Ending.LF)
    testing.expect_value(t, thor_detect_line_ending("a\r\nb\r\n"), Line_Ending.CRLF)
    testing.expect_value(t, thor_detect_line_ending("a\r\nb\n"), Line_Ending.Mixed)

    // A Mixed buffer holds its CRs, so the bytes go back as they came.
    disk := thor_to_disk_text("a\r\nb\n", .Mixed)
    defer delete(disk)
    testing.expect_value(t, disk, "a\r\nb\n")
}
