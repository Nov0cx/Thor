// The byte encoding of a file on disk. The buffer always holds UTF-8: a file is
// decoded on load and encoded again on save, with its byte order mark kept.
package thor

import "core:mem"
import "core:unicode/utf16"

Encoding :: enum u8 {
    UTF8,
    UTF16_LE,
    UTF16_BE,
}

// Status bar label for an encoding.
thor_encoding_label :: proc(encoding: Encoding, bom: bool) -> string {
    switch encoding {
    case .UTF8:
        return bom ? "UTF-8 BOM" : "UTF-8"
    case .UTF16_LE:
        return "UTF-16 LE"
    case .UTF16_BE:
        return "UTF-16 BE"
    }
    return "UTF-8"
}

// What `bytes` is encoded as, and the length of the byte order mark it opens
// with. UTF-16 with no mark is taken from where the NUL bytes of its ASCII
// text are: the high byte of each unit.
thor_detect_encoding :: proc(bytes: []u8) -> (encoding: Encoding, bom: int) {
    switch {
    case len(bytes) >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF:
        return .UTF8, 3
    case len(bytes) >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE:
        return .UTF16_LE, 2
    case len(bytes) >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF:
        return .UTF16_BE, 2
    }

    probe := min(len(bytes), BINARY_PROBE_BYTES) &~ 1
    if probe < 4 {
        return .UTF8, 0
    }
    even, odd := 0, 0
    for i := 0; i < probe; i += 2 {
        even += int(bytes[i] == 0)
        odd += int(bytes[i + 1] == 0)
    }
    units := probe / 2
    switch {
    case odd * 10 >= units * 6 && even * 10 <= units:
        return .UTF16_LE, 0
    case even * 10 >= units * 6 && odd * 10 <= units:
        return .UTF16_BE, 0
    }
    return .UTF8, 0
}

// UTF-16 bytes as UTF-8. An odd last byte is dropped. The result is owned by
// `allocator`; false when the memory is not there.
thor_decode_utf16 :: proc(bytes: []u8, big_endian: bool, allocator: mem.Allocator) -> (text: string, ok: bool) {
    count := len(bytes) / 2
    if count == 0 {
        return "", true
    }
    units, units_err := make([]u16, count, allocator)
    if units_err != nil {
        return "", false
    }
    defer delete(units, allocator)
    for i in 0 ..< count {
        lo, hi := u16(bytes[i * 2]), u16(bytes[i * 2 + 1])
        units[i] = big_endian ? lo << 8 | hi : hi << 8 | lo
    }

    // One unit is at most three bytes of UTF-8; a surrogate pair is four.
    out, out_err := make([]u8, count * 3, allocator)
    if out_err != nil {
        return "", false
    }
    n := utf16.decode_to_utf8(out, units)
    return string(out[:n]), true
}

// Buffer text as the bytes of `encoding`, with the byte order mark when `bom`
// is set. Takes `text`, which `allocator` owns: UTF-8 with no mark gives it
// back, any other encoding frees it. The result is owned by `allocator`.
thor_encode_text :: proc(text: string, encoding: Encoding, bom: bool, allocator: mem.Allocator) -> string {
    if encoding == .UTF8 {
        if !bom {
            return text
        }
        out := make([]u8, len(text) + 3, allocator)
        out[0], out[1], out[2] = 0xEF, 0xBB, 0xBF
        copy(out[3:], text)
        delete(text, allocator)
        return string(out)
    }

    // A UTF-8 byte never makes more than one unit.
    units := make([]u16, len(text), allocator)
    defer delete(units, allocator)
    count := utf16.encode_string(units, text)
    lead := bom ? 2 : 0
    out := make([]u8, count * 2 + lead, allocator)
    big := encoding == .UTF16_BE
    if bom {
        out[0], out[1] = big ? 0xFE : 0xFF, big ? 0xFF : 0xFE
    }
    for unit, i in units[:count] {
        lo, hi := u8(unit), u8(unit >> 8)
        out[lead + i * 2] = big ? hi : lo
        out[lead + i * 2 + 1] = big ? lo : hi
    }
    delete(text, allocator)
    return string(out)
}

// Counts the two kinds of line end, for the line-ending label of a file.
thor_count_line_endings :: proc(content: string) -> (lf, crlf: int) {
    for i in 0 ..< len(content) {
        if content[i] != '\n' {
            continue
        }
        if i > 0 && content[i - 1] == '\r' {
            crlf += 1
        } else {
            lf += 1
        }
    }
    return
}
