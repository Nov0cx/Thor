// Content-Length framing, the base protocol under LSP's JSON-RPC. Pure: it knows
// nothing of JSON, of a transport or of a server. An explicit byte length is what
// separates this from the terminal's end-marker scan — no heuristic decides where
// a message ends, so no tail is ever held back.
package lsp

import "core:strconv"
import "core:strings"

// The largest body a frame may declare. A server that names more is broken or
// hostile, and the number is rejected before anything is allocated on it.
MAX_FRAME :: 64 * 1024 * 1024

// The largest header block a frame may carry before its "\r\n\r\n". Without the
// bound a server that never terminates its headers grows the read buffer forever.
MAX_HEADER :: 8 * 1024

Frame_Error :: enum {
    None,
    Bad_Header,
    Missing_Length,
    Length_Too_Large,
}

// Appends "Content-Length: N\r\n\r\n" + body to `out`. N is the byte length, so a
// body with a multi-byte character frames by its bytes and not by its runes.
frame_write :: proc(out: ^[dynamic]u8, body: []u8) {
    digits: [32]u8
    append(out, "Content-Length: ")
    append(out, strconv.write_int(digits[:], i64(len(body)), 10))
    append(out, "\r\n\r\n")
    append(out, ..body)
}

// Takes the first complete frame off the head of `buf`, copying its body into
// `allocator` and removing the whole frame. ok=false with err=.None means the
// frame has not arrived whole yet and `buf` is untouched, so the caller reads
// more. Any other err leaves `buf` untouched too, but the stream cannot
// resynchronise from it: the caller kills the server.
frame_take :: proc(buf: ^[dynamic]u8, allocator := context.allocator) -> (body: []u8, err: Frame_Error, ok: bool) {
    text := string(buf[:])
    end := strings.index(text, "\r\n\r\n")
    if end < 0 {
        // Only "\r\n" ends a header line. A bare "\n\n" is not a terminator, and
        // guessing that it is one is what desynchronises a parser for good.
        if len(text) > MAX_HEADER {
            return nil, .Bad_Header, false
        }
        return nil, .None, false
    }
    if end > MAX_HEADER {
        return nil, .Bad_Header, false
    }

    length, header_err := content_length(text[:end])
    if header_err != .None {
        return nil, header_err, false
    }

    start := end + 4
    if len(text) - start < length {
        return nil, .None, false
    }
    // A zero-length body is consumed like any other, so the stream stays in step;
    // the JSON layer above is what rejects it.
    body = make([]u8, length, allocator)
    copy(body, buf[start:start + length])
    remove_range(buf, 0, start + length)
    return body, .None, true
}

// The Content-Length of a header block. The name is compared without case, every
// other header is ignored, and a line with no ':' is a broken frame rather than
// an unknown header. A second Content-Length is refused: which one to believe is
// not a guess worth making.
@(private = "file")
content_length :: proc(header: string) -> (int, Frame_Error) {
    rest := header
    length := -1
    for line in strings.split_iterator(&rest, "\r\n") {
        if line == "" {
            continue
        }
        at := strings.index_byte(line, ':')
        if at < 0 {
            return 0, .Bad_Header
        }
        if !strings.equal_fold(strings.trim_space(line[:at]), "content-length") {
            continue
        }
        if length >= 0 {
            return 0, .Bad_Header
        }
        value, value_err := decimal(strings.trim_space(line[at + 1:]))
        if value_err != .None {
            return 0, value_err
        }
        length = value
    }
    if length < 0 {
        return 0, .Missing_Length
    }
    return length, .None
}

// A run of decimal digits and nothing else. strconv.parse_int is not used here:
// it stops at the first non-digit and reports the prefix it read, so "12abc"
// would frame as 12 and a sign or an underscore would pass. A length that is not
// exactly a number must fail, or the stream silently desynchronises.
@(private = "file")
decimal :: proc(text: string) -> (int, Frame_Error) {
    if text == "" {
        return 0, .Missing_Length
    }
    value := 0
    for index in 0 ..< len(text) {
        digit := text[index]
        if digit < '0' || digit > '9' {
            return 0, .Missing_Length
        }
        value = value * 10 + int(digit - '0')
        // Bounded as it is read, so no digit string can overflow on the way to
        // the comparison, and nothing is allocated on a hostile number.
        if value > MAX_FRAME {
            return 0, .Length_Too_Large
        }
    }
    return value, .None
}
