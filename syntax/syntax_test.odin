package syntax

import "core:strings"
import "core:testing"

// Leading component of the capture covering the first occurrence of `needle`.
@(private = "file")
head_at :: proc(spans: []Span, source, needle: string) -> (string, bool) {
    at := strings.index(source, needle)
    if at < 0 {
        return "", false
    }
    for s in spans {
        if s.start <= at && at < s.end {
            return capture_head(s.capture), true
        }
    }
    return "", false
}

@(test)
test_highlight_odin :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    src := `package demo

Point :: struct { x: int }

Click_Proc :: #type proc(data: rawptr, widget: int)

main :: proc() {
	p: Point
	s := "hi" // note
}
`
    spans := highlight(&h, src, "odin", context.allocator)
    defer delete(spans)
    testing.expect(t, len(spans) > 0, "expected highlight spans")

    // Spans must be ascending and non-overlapping.
    prev := 0
    for s in spans {
        testing.expect(t, s.start >= prev, "spans overlap or are unsorted")
        testing.expect(t, s.end > s.start, "empty span")
        prev = s.end
    }

    // Precedence: specific captures override the broad (identifier) @variable.
    expect :: proc(t: ^testing.T, spans: []Span, src, needle, want: string) {
        got, ok := head_at(spans, src, needle)
        testing.expectf(t, ok && got == want, "%q: got %q (found=%v), want %q", needle, got, ok, want)
    }
    expect(t, spans, src, "Point", "type")     // struct declaration
    expect(t, spans, src, "main", "function")  // proc
    expect(t, spans, src, "int", "type")       // builtin type via #any-of?
    expect(t, spans, src, "\"hi\"", "string")
    expect(t, spans, src, "// note", "comment")
    // A named parameter in a `#type proc(...)` stays a parameter, not a type.
    expect(t, spans, src, "data", "parameter")

    // Unknown language yields nothing.
    none := highlight(&h, src, "cobol", context.allocator)
    testing.expect(t, len(none) == 0, "unsupported language should have no spans")
}
