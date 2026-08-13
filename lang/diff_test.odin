package lang

import "core:testing"

// Applies spans (already ascending, non-overlapping per diff_spans'
// contract) to `old` and checks the result equals `new` — the property
// thor_apply_edits relies on when it turns these into textedit.Replace
// ranges.
@(private)
diff_apply_spans :: proc(old: string, spans: []Diff_Span) -> string {
    out: [dynamic]u8
    pos := 0
    for s in spans {
        for i := pos; i < s.start; i += 1 {
            append(&out, old[i])
        }
        for i := 0; i < len(s.text); i += 1 {
            append(&out, s.text[i])
        }
        pos = s.end
    }
    for i := pos; i < len(old); i += 1 {
        append(&out, old[i])
    }
    return string(out[:])
}

@(private)
diff_assert_reassembles :: proc(t: ^testing.T, old, new: string) {
    spans := diff_spans(old, new)
    for i := 1; i < len(spans); i += 1 {
        testing.expect(t, spans[i - 1].end <= spans[i].start, "spans must be ascending and non-overlapping")
    }
    got := diff_apply_spans(old, spans)
    testing.expect_value(t, got, new)
}

@(test)
test_diff_identical :: proc(t: ^testing.T) {
    spans := diff_spans("same\ntext\n", "same\ntext\n")
    testing.expect(t, spans == nil)
}

@(test)
test_diff_single_line_change_is_minimal :: proc(t: ^testing.T) {
    old := "a\nb\nc\nd\ne\n"
    new := "a\nb\nX\nd\ne\n"
    spans := diff_spans(old, new)
    testing.expect_value(t, len(spans), 1)
    testing.expect_value(t, spans[0].text, "X\n")
    diff_assert_reassembles(t, old, new)
}

@(test)
test_diff_reassembles_multi_hunk :: proc(t: ^testing.T) {
    old := "1\n2\n3\n4\n5\n6\n7\n8\n"
    new := "1\n22\n3\n4\n55\n6\n7\n888\n"
    diff_assert_reassembles(t, old, new)
}

@(test)
test_diff_pure_insertion :: proc(t: ^testing.T) {
    old := "a\nb\n"
    new := "a\nNEW\nb\n"
    diff_assert_reassembles(t, old, new)
}

@(test)
test_diff_pure_deletion :: proc(t: ^testing.T) {
    old := "a\nDROP\nb\n"
    new := "a\nb\n"
    diff_assert_reassembles(t, old, new)
}

@(test)
test_diff_whole_file_rewrite :: proc(t: ^testing.T) {
    old := "completely\ndifferent\n"
    new := "totally\nnew\ncontent\n"
    diff_assert_reassembles(t, old, new)
}

// A line owns its terminator, so a source that gains or loses its final newline
// differs in its last line rather than in a zero-width phantom one.
@(test)
test_diff_adds_trailing_newline :: proc(t: ^testing.T) {
    diff_assert_reassembles(t, "a", "a\n")
    diff_assert_reassembles(t, "x\ny", "x\ny\n")
}

@(test)
test_diff_removes_trailing_newline :: proc(t: ^testing.T) {
    diff_assert_reassembles(t, "a\n", "a")
    diff_assert_reassembles(t, "x\ny\n", "x\ny")
}

// Lines appended to a source whose last line has no newline: the new text must
// keep the separator instead of gluing onto that line.
@(test)
test_diff_appends_to_unterminated_last_line :: proc(t: ^testing.T) {
    diff_assert_reassembles(t, "a", "a\nb\n")
    diff_assert_reassembles(t, "a", "a\nb")
}

// An insertion at the tail of the trimmed middle anchors on the first surviving
// suffix line, not on end-of-source.
@(test)
test_diff_insertion_before_trimmed_suffix :: proc(t: ^testing.T) {
    old := "p\nq\nr\n"
    new := "P\nq\nZ\nr\n"
    diff_assert_reassembles(t, old, new)
}

@(test)
test_diff_empty_source :: proc(t: ^testing.T) {
    diff_assert_reassembles(t, "", "x\n")
    diff_assert_reassembles(t, "x\n", "")
    diff_assert_reassembles(t, "", "x")
}
