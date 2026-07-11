package syntax

import "core:testing"

@(test)
test_highlight_odin :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    src := "package main\n\nfoo :: proc() {\n\ts := \"hi\" // note\n}\n"
    spans := highlight(&h, src, "odin", context.allocator)
    defer delete(spans)

    testing.expect(t, len(spans) > 0, "expected highlight spans")

    // Spans must be ascending and non-overlapping.
    kinds: bit_set[Token_Kind]
    prev := 0
    for s in spans {
        testing.expect(t, s.start >= prev, "spans overlap or are unsorted")
        testing.expect(t, s.end > s.start, "empty span")
        prev = s.end
        kinds += {s.kind}
    }

    testing.expect(t, .String in kinds, "expected a string span")
    testing.expect(t, .Comment in kinds, "expected a comment span")

    // Unknown language yields nothing.
    none := highlight(&h, src, "cobol", context.allocator)
    testing.expect(t, len(none) == 0, "unsupported language should have no spans")
}
