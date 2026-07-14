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

@(private = "file")
expect_head :: proc(t: ^testing.T, spans: []Span, src, needle, want: string) {
    got, ok := head_at(spans, src, needle)
    testing.expectf(t, ok && got == want, "%q: got %q (found=%v), want %q", needle, got, ok, want)
}

// Each newly added grammar must build its highlights query (the combined
// javascript/typescript queries especially) and tag a few obvious tokens.
@(test)
test_highlight_c_family :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    c := "int main(void) {\n\treturn 0; // done\n}\n"
    cs := highlight(&h, c, "c", context.temp_allocator)
    testing.expect(t, len(cs) > 0, "expected c spans")
    expect_head(t, cs, c, "// done", "comment")

    cpp := "#include <vector>\nnamespace app { int x = 1; }\n"
    cps := highlight(&h, cpp, "cpp", context.temp_allocator)
    testing.expect(t, len(cps) > 0, "expected cpp spans")

    go := "package main\nfunc main() {\n\ts := \"hi\" // note\n}\n"
    gos := highlight(&h, go, "go", context.temp_allocator)
    testing.expect(t, len(gos) > 0, "expected go spans")
    expect_head(t, gos, go, "\"hi\"", "string")
    expect_head(t, gos, go, "// note", "comment")

    jai := "main :: () {\n\ts := \"hi\"; // note\n}\n"
    jas := highlight(&h, jai, "jai", context.temp_allocator)
    testing.expect(t, len(jas) > 0, "expected jai spans")
}

@(test)
test_highlight_js_ts :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    js := "const x = 1 // note\nfunction f(a) { return \"hi\" }\n"
    jss := highlight(&h, js, "javascript", context.temp_allocator)
    testing.expect(t, len(jss) > 0, "expected javascript spans")
    expect_head(t, jss, js, "// note", "comment")
    expect_head(t, jss, js, "\"hi\"", "string")

    ts := "const n: number = 1\ntype Id = string // alias\n"
    tss := highlight(&h, ts, "typescript", context.temp_allocator)
    testing.expect(t, len(tss) > 0, "expected typescript spans")
    expect_head(t, tss, ts, "// alias", "comment") // from the javascript base
    expect_head(t, tss, ts, "number", "type")      // from the typescript layer

    tsx := "const el = <div className=\"a\">{x}</div>\n"
    tsxs := highlight(&h, tsx, "tsx", context.temp_allocator)
    testing.expect(t, len(tsxs) > 0, "expected tsx spans")
}
