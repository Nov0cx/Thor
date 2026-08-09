package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

// Run from the repository root: odin test lang/lsp

// A frame written and taken back is the body it started as, and the buffer is
// empty after it.
@(test)
test_frame_round_trip :: proc(t: ^testing.T) {
    buf := make([dynamic]u8)
    defer delete(buf)
    frame_write(&buf, transmute([]u8) string(`{"id":1}`))

    body, err, ok := frame_take(&buf)
    defer delete(body)
    testing.expect_value(t, err, Frame_Error.None)
    testing.expect(t, ok)
    testing.expect_value(t, string(body), `{"id":1}`)
    testing.expect_value(t, len(buf), 0)
}

// One read is not one message. A frame arriving one byte at a time must be taken
// exactly once, and at the byte that completes it.
@(test)
test_frame_take_one_byte_at_a_time :: proc(t: ^testing.T) {
    whole := make([dynamic]u8)
    defer delete(whole)
    frame_write(&whole, transmute([]u8) string("hello"))

    buf := make([dynamic]u8)
    defer delete(buf)
    taken := 0
    for index in 0 ..< len(whole) {
        append(&buf, whole[index])
        body, err, ok := frame_take(&buf)
        testing.expect_value(t, err, Frame_Error.None)
        if !ok {
            continue
        }
        taken += 1
        testing.expect_value(t, string(body), "hello")
        // Only the last byte can complete it.
        testing.expect_value(t, index, len(whole) - 1)
        delete(body)
    }
    testing.expect_value(t, taken, 1)
}

// A message is not one read either: three frames can arrive in one chunk, and
// each must come off in order.
@(test)
test_frame_take_three_in_one_chunk :: proc(t: ^testing.T) {
    buf := make([dynamic]u8)
    defer delete(buf)
    for text in ([]string{"one", "two", "three"}) {
        frame_write(&buf, transmute([]u8) text)
    }

    for want in ([]string{"one", "two", "three"}) {
        body, err, ok := frame_take(&buf)
        defer delete(body)
        testing.expect_value(t, err, Frame_Error.None)
        testing.expectf(t, ok, "%q did not come off", want)
        testing.expect_value(t, string(body), want)
    }
    testing.expect_value(t, len(buf), 0)
}

// The length is what ends the body, so a body may hold the header terminator and
// the header's own name. The parser must never rescan it.
@(test)
test_frame_take_body_holds_a_header :: proc(t: ^testing.T) {
    payload := "a\r\n\r\nContent-Length: 9\r\n\r\nb"
    buf := make([dynamic]u8)
    defer delete(buf)
    frame_write(&buf, transmute([]u8) payload)

    body, err, ok := frame_take(&buf)
    defer delete(body)
    testing.expect_value(t, err, Frame_Error.None)
    testing.expect(t, ok)
    testing.expect_value(t, string(body), payload)
    testing.expect_value(t, len(buf), 0)
}

// The header name is compared without case and every other header is ignored,
// since a server may send Content-Type and anything else it likes.
@(test)
test_frame_take_ignores_other_headers :: proc(t: ^testing.T) {
    buf := make([dynamic]u8)
    defer delete(buf)
    append(&buf, "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n")
    append(&buf, "content-length: 2\r\n")
    append(&buf, "X-Thor: ignored\r\n\r\n")
    append(&buf, "hi")

    body, err, ok := frame_take(&buf)
    defer delete(body)
    testing.expect_value(t, err, Frame_Error.None)
    testing.expect(t, ok)
    testing.expect_value(t, string(body), "hi")
}

// A zero-length body is consumed like any other, so the stream stays in step and
// the frame after it still arrives.
@(test)
test_frame_take_empty_body :: proc(t: ^testing.T) {
    buf := make([dynamic]u8)
    defer delete(buf)
    append(&buf, "Content-Length: 0\r\n\r\n")
    frame_write(&buf, transmute([]u8) string("next"))

    body, err, ok := frame_take(&buf)
    defer delete(body)
    testing.expect_value(t, err, Frame_Error.None)
    testing.expect(t, ok)
    testing.expect_value(t, len(body), 0)

    second, second_err, second_ok := frame_take(&buf)
    defer delete(second)
    testing.expect_value(t, second_err, Frame_Error.None)
    testing.expect(t, second_ok)
    testing.expect_value(t, string(second), "next")
}

// A frame whose body has not arrived whole is not a frame yet, and the buffer is
// left as it was for the next read to complete.
@(test)
test_frame_take_waits_for_the_body :: proc(t: ^testing.T) {
    buf := make([dynamic]u8)
    defer delete(buf)
    append(&buf, "Content-Length: 5\r\n\r\nab")

    body, err, ok := frame_take(&buf)
    testing.expect_value(t, err, Frame_Error.None)
    testing.expect(t, !ok)
    testing.expect_value(t, len(body), 0)
    testing.expect_value(t, len(buf), 23)
}

// Every length that is not exactly a number of bytes must fail. A prefix that
// parses is the dangerous case: it would frame the wrong count and desynchronise
// the stream for good.
@(test)
test_frame_take_bad_lengths :: proc(t: ^testing.T) {
    Case :: struct {
        value: string,
        want:  Frame_Error,
    }
    cases := []Case {
        {"-1", .Missing_Length},
        {"+4", .Missing_Length},
        {"12abc", .Missing_Length},
        {"1_2", .Missing_Length},
        {"0x10", .Missing_Length},
        {"", .Missing_Length},
        {"   ", .Missing_Length},
        {"999999999999", .Length_Too_Large},
        {"67108865", .Length_Too_Large}, // MAX_FRAME + 1
    }
    for entry in cases {
        buf := make([dynamic]u8)
        defer delete(buf)
        append(&buf, fmt.tprintf("Content-Length: %s\r\n\r\nbody", entry.value))

        body, err, ok := frame_take(&buf)
        testing.expectf(t, !ok, "%q framed", entry.value)
        testing.expectf(t, err == entry.want, "%q gave %v, wanted %v", entry.value, err, entry.want)
        testing.expect_value(t, len(body), 0)
    }
}

// A frame with no length at all, and a header line that is not a header. Both
// leave a stream that cannot resynchronise, so the caller kills the server.
@(test)
test_frame_take_broken_headers :: proc(t: ^testing.T) {
    missing := make([dynamic]u8)
    defer delete(missing)
    append(&missing, "Content-Type: text\r\n\r\nbody")
    _, missing_err, missing_ok := frame_take(&missing)
    testing.expect(t, !missing_ok)
    testing.expect_value(t, missing_err, Frame_Error.Missing_Length)

    no_colon := make([dynamic]u8)
    defer delete(no_colon)
    append(&no_colon, "Content-Length: 4\r\ngarbage\r\n\r\nbody")
    _, colon_err, colon_ok := frame_take(&no_colon)
    testing.expect(t, !colon_ok)
    testing.expect_value(t, colon_err, Frame_Error.Bad_Header)

    // Which of two lengths to believe is not a guess worth making.
    twice := make([dynamic]u8)
    defer delete(twice)
    append(&twice, "Content-Length: 4\r\nContent-Length: 9\r\n\r\nbody")
    _, twice_err, twice_ok := frame_take(&twice)
    testing.expect(t, !twice_ok)
    testing.expect_value(t, twice_err, Frame_Error.Bad_Header)
}

// Only "\r\n\r\n" ends the headers. A bare "\n\n" is not a terminator, so the
// frame is still incomplete and the header bound is what eventually stops it.
@(test)
test_frame_take_needs_crlf :: proc(t: ^testing.T) {
    buf := make([dynamic]u8)
    defer delete(buf)
    append(&buf, "Content-Length: 4\n\nbody")

    _, err, ok := frame_take(&buf)
    testing.expect(t, !ok)
    testing.expect_value(t, err, Frame_Error.None)
}

// A server that never terminates its headers must not grow the read buffer
// forever; past the bound it is a broken frame.
@(test)
test_frame_take_header_bound :: proc(t: ^testing.T) {
    buf := make([dynamic]u8)
    defer delete(buf)
    append(&buf, "Content-Length: 4\r\n")
    for _ in 0 ..< MAX_HEADER {
        append(&buf, 'x')
    }

    _, err, ok := frame_take(&buf)
    testing.expect(t, !ok)
    testing.expect_value(t, err, Frame_Error.Bad_Header)
}

// The length is a byte count, not a rune count: a body of multi-byte characters
// frames by its bytes or every frame after it is misread.
@(test)
test_frame_write_counts_bytes :: proc(t: ^testing.T) {
    payload := "é€😀"
    buf := make([dynamic]u8)
    defer delete(buf)
    frame_write(&buf, transmute([]u8) payload)

    testing.expect(t, strings.contains(string(buf[:]), "Content-Length: 9\r\n\r\n"))
    body, err, ok := frame_take(&buf)
    defer delete(body)
    testing.expect_value(t, err, Frame_Error.None)
    testing.expect(t, ok)
    testing.expect_value(t, string(body), payload)
}

// The escaping the whole JSON layer above rests on. Buffer text reaches a server
// through json.marshal, so a control character, a Latin-1 range byte, a
// replacement character and an astral character must all come back unchanged.
@(test)
test_json_round_trip_escapes :: proc(t: ^testing.T) {
    Payload :: struct {
        text: string,
    }
    // Built rather than written, so no control character sits raw in the source.
    controls := [?]u8{'b', 'e', 'l', 'l', 0x07, ' ', 'u', 'n', 'i', 't', 0x1f, ' ', 'e', 'n', 'd'}
    cases := []string {
        "plain",
        "tab\there",
        "line\nbreak\r\n",
        "quote\" and \\ backslash",
        string(controls[:]),
        "¡¢£ ÿ",
        "�",
        "😀𝄞",
        "mixed é\t😀 end",
    }
    for text in cases {
        encoded, marshal_err := json.marshal(Payload{text = text}, {}, context.temp_allocator)
        testing.expectf(t, marshal_err == nil, "%q did not marshal: %v", text, marshal_err)
        if marshal_err != nil {
            continue
        }

        value, parse_err := json.parse(encoded, .JSON, true, context.temp_allocator)
        testing.expectf(t, parse_err == nil, "%q did not parse back: %v", text, parse_err)
        if parse_err != nil {
            continue
        }
        object, is_object := value.(json.Object)
        testing.expectf(t, is_object, "%q parsed to %T", text, value)
        if !is_object {
            continue
        }
        back, is_string := object["text"].(json.String)
        testing.expectf(t, is_string, "%q lost its string", text)
        testing.expectf(t, string(back) == text, "%q came back as %q", text, string(back))
    }
}
