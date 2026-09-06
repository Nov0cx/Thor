package search

import "core:testing"

@(test)
test_literal_finds_every_occurrence :: proc(t: ^testing.T) {
    out := make([dynamic]Match, context.temp_allocator)
    testing.expect(t, scan("abcabc", "bc", {}, &out))
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0].start, 1)
    testing.expect_value(t, out[1].start, 4)
}

@(test)
test_case_sensitive_skips_the_other_case :: proc(t: ^testing.T) {
    out := make([dynamic]Match, context.temp_allocator)
    testing.expect(t, scan("Abc abc", "abc", {case_sensitive = true}, &out))
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0].start, 4)
}

@(test)
test_whole_word_rejects_a_glued_match :: proc(t: ^testing.T) {
    out := make([dynamic]Match, context.temp_allocator)
    testing.expect(t, scan("cat category", "cat", {whole_word = true}, &out))
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0].start, 0)
}

// A folded non-ASCII query cannot be measured as len(query) bytes.
@(test)
test_folded_match_keeps_its_own_width :: proc(t: ^testing.T) {
    out := make([dynamic]Match, context.temp_allocator)
    testing.expect(t, scan("straße", "STRASSE", {}, &out))
    testing.expect_value(t, len(out), 0)

    clear(&out)
    testing.expect(t, scan("STRAẞE", "straße", {}, &out))
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0].end - out[0].start, len("STRAẞE"))
}

@(test)
test_regex_matches_spans_of_its_own_size :: proc(t: ^testing.T) {
    out := make([dynamic]Match, context.temp_allocator)
    testing.expect(t, scan("a1 bb22", "[0-9]+", {use_regex = true}, &out))
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0].end - out[0].start, 1)
    testing.expect_value(t, out[1].end - out[1].start, 2)
}

@(test)
test_bad_pattern_reports_instead_of_matching :: proc(t: ^testing.T) {
    out := make([dynamic]Match, context.temp_allocator)
    testing.expect(t, !scan("abc", "(", {use_regex = true}, &out))
    testing.expect_value(t, len(out), 0)
}

@(test)
test_empty_query_matches_nothing :: proc(t: ^testing.T) {
    out := make([dynamic]Match, context.temp_allocator)
    testing.expect(t, scan("abc", "", {}, &out))
    testing.expect_value(t, len(out), 0)
}
