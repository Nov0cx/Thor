package syntax

import "core:strings"
import "core:testing"

// Kind of the span covering the first occurrence of `needle` in source.
@(private = "file")
kind_at :: proc(spans: []Span, source, needle: string) -> (Token_Kind, bool) {
    at := strings.index(source, needle)
    if at < 0 {
        return .Default, false
    }
    for s in spans {
        if s.start <= at && at < s.end {
            return s.kind, true
        }
    }
    return .Default, false
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
    expect_kind :: proc(t: ^testing.T, spans: []Span, src, needle: string, want: Token_Kind) {
        got, ok := kind_at(spans, src, needle)
        testing.expectf(t, ok && got == want, "%q: got %v (found=%v), want %v", needle, got, ok, want)
    }
    expect_kind(t, spans, src, "demo", .Namespace)   // package name
    expect_kind(t, spans, src, "Point", .Type)       // struct declaration
    expect_kind(t, spans, src, "main", .Function)    // proc
    expect_kind(t, spans, src, "int", .Type)         // builtin type via #any-of?
    expect_kind(t, spans, src, "\"hi\"", .String)
    expect_kind(t, spans, src, "// note", .Comment)

    // A named parameter in a `#type proc(...)` keeps its parameter kind rather
    // than being recolored as a type.
    expect_kind(t, spans, src, "data", .Parameter)

    // Unknown language yields nothing.
    none := highlight(&h, src, "cobol", context.allocator)
    testing.expect(t, len(none) == 0, "unsupported language should have no spans")
}
