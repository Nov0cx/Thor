// LSP (line, character) <-> byte offset, converted at the backend's own edge. A
// server counts characters in UTF-16 units unless `initialize` negotiates
// otherwise; every offset that leaves this package is a byte offset over
// LF-collapsed source, so nothing outside lang/lsp learns that a server exists.
package lsp

import "base:runtime"
import "core:unicode/utf8"

// What `initialize` negotiated. Utf16 is the protocol default when the server
// names no encoding.
Encoding :: enum {
    Utf16,
    Utf8,
}

// Byte offsets of each line start, over one particular byte view of a file: the
// LF-collapsed text of an open document, or the raw CRLF bytes of a file the
// server read from disk. Lines split on '\n' only — a lone '\r' survives
// `lang.source_read`, so counting it as a break makes the two views disagree.
Line_Index :: struct {
    starts:    []int,             // owned
    crlf:      []int,             // owned; "\r\n" pairs before each line start (all zero for LF text)
    text:      string,            // borrowed for the index's lifetime
    encoding:  Encoding,
    allocator: runtime.Allocator, // what built `starts` and `crlf`
}

// Indexes the line starts of `text`, which must stay alive and unchanged for the
// life of the index. A UTF-8 BOM is counted like any other bytes, never
// stripped: Thor sends the buffer verbatim, so the server indexes the same
// leading bytes, and a strip on one side only skews every position of line 0 by
// three bytes.
line_index_build :: proc(text: string, encoding: Encoding, allocator := context.allocator) -> Line_Index {
    count := 1
    for index in 0 ..< len(text) {
        if text[index] == '\n' {
            count += 1
        }
    }

    starts := make([]int, count, allocator)
    crlf := make([]int, count, allocator)
    line := 1
    pairs := 0
    for index in 0 ..< len(text) {
        if text[index] != '\n' {
            continue
        }
        if index > 0 && text[index - 1] == '\r' {
            pairs += 1
        }
        starts[line] = index + 1
        crlf[line] = pairs
        line += 1
    }
    return Line_Index{starts = starts, crlf = crlf, text = text, encoding = encoding, allocator = allocator}
}

line_index_destroy :: proc(idx: ^Line_Index) {
    delete(idx.starts, idx.allocator)
    delete(idx.crlf, idx.allocator)
    idx.starts = nil
    idx.crlf = nil
}

// LSP (line, character) -> byte offset in `idx.text`. Clamps: a character past
// the line end lands on the line end, a line past EOF lands on len(text).
offset_from_position :: proc(idx: ^Line_Index, line, character: int) -> int {
    if line < 0 {
        return 0
    }
    if line >= len(idx.starts) {
        return len(idx.text)
    }

    start := idx.starts[line]
    end := line_end(idx, line)
    if character <= 0 {
        return start
    }

    if idx.encoding == .Utf8 {
        // `character` is a byte count within the line.
        at := start + character
        if at >= end {
            return end
        }
        return rune_floor(idx.text, start, at)
    }

    at := start
    units := 0
    for units < character && at < end {
        r, size := utf8.decode_rune_in_string(idx.text[at:end])
        if size == 0 {
            break
        }
        cost := 1
        if r >= 0x10000 {
            cost = 2
        }
        // A character inside a surrogate pair — some servers name the midpoint of
        // an astral rune — snaps back to the rune start. An offset that splits a
        // UTF-8 sequence is never returned: everything downstream needs valid UTF-8.
        if units + cost > character {
            break
        }
        units += cost
        at += size
    }
    return at
}

// The inverse, for the params we send.
position_from_offset :: proc(idx: ^Line_Index, offset: int) -> (line, character: int) {
    at := clamp(offset, 0, len(idx.text))
    line = line_of(idx, at)
    start := idx.starts[line]
    // An offset on the terminator reads as the end of the line's content, so the
    // pair converts back to the same spot.
    at = min(at, line_end(idx, line))
    at = rune_floor(idx.text, start, at)

    if idx.encoding == .Utf8 {
        return line, at - start
    }

    for off := start; off < at; {
        r, size := utf8.decode_rune_in_string(idx.text[off:at])
        if size == 0 {
            break
        }
        character += 1
        if r >= 0x10000 {
            character += 1
        }
        off += size
    }
    return line, character
}

// Raw-space byte offset -> LF-space byte offset, for a file the server read from
// disk with its CRLF intact. Exact because `lang.source_read` collapses only the
// two-byte "\r\n": a lone '\r' survives it and is not counted here either.
lf_offset :: proc(idx: ^Line_Index, raw_offset: int) -> int {
    at := clamp(raw_offset, 0, len(idx.text))
    // Both bytes of a "\r\n" collapse into the one '\n', so an offset on the '\n'
    // names the same spot as one on the '\r'.
    if at > 0 && at < len(idx.text) && idx.text[at] == '\n' && idx.text[at - 1] == '\r' {
        at -= 1
    }
    return at - idx.crlf[line_of(idx, at)]
}

// End of a line's content. In raw CRLF bytes the '\r' belongs to the terminator,
// so it is not part of the line a server counts characters over. A '\r' with no
// '\n' after it is content, not a terminator.
@(private = "file")
line_end :: proc(idx: ^Line_Index, line: int) -> int {
    if line + 1 >= len(idx.starts) {
        return len(idx.text)
    }
    end := idx.starts[line + 1] - 1
    if end > idx.starts[line] && idx.text[end - 1] == '\r' {
        end -= 1
    }
    return end
}

// The line `offset` sits on: the last line start at or before it.
@(private = "file")
line_of :: proc(idx: ^Line_Index, offset: int) -> int {
    low, high := 0, len(idx.starts) - 1
    for low < high {
        mid := (low + high + 1) / 2
        if idx.starts[mid] <= offset {
            low = mid
        } else {
            high = mid - 1
        }
    }
    return low
}

// Pulls `off` back to the start of the rune it is inside, never past `low`.
@(private = "file")
rune_floor :: proc(text: string, low, off: int) -> int {
    at := min(off, len(text))
    for at > low && at < len(text) && text[at] & 0xC0 == 0x80 {
        at -= 1
    }
    return at
}
