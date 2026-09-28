package thor

import "core:testing"

// The palette's fuzzy matcher, which both the command palette and quick open
// filter with and which the rows mark from. Run from the repository root:
// odin test thor

// Positions come back in ascending order, inside the text, and on the
// characters the score was built from.
@(test)
test_fuzzy_match_reports_positions :: proc(t: ^testing.T) {
    hits: [16]int
    score, count, ok := fuzzy_match("tfw", "thor_format_write", hits[:])
    testing.expect(t, ok, "a subsequence must match")
    testing.expect(t, score > 0, "a word-start match must score")
    testing.expect_value(t, count, 3)
    for i in 0 ..< count {
        testing.expect(t, hits[i] >= 0 && hits[i] < len("thor_format_write"), "position out of range")
        if i > 0 {
            testing.expect(t, hits[i] > hits[i - 1], "positions must ascend")
        }
    }
    testing.expect_value(t, hits[0], 0)  // t of thor
    testing.expect_value(t, hits[1], 5)  // f of format
    testing.expect_value(t, hits[2], 12) // w of write
}

// Case is ignored, and a query character that is missing fails the whole match
// with no positions reported.
@(test)
test_fuzzy_match_rejects_a_missing_character :: proc(t: ^testing.T) {
    hits: [8]int
    _, count, ok := fuzzy_match("TH", "thor.odin", hits[:])
    testing.expect(t, ok, "the match must ignore case")
    testing.expect_value(t, count, 2)

    _, missing, bad := fuzzy_match("zz", "thor.odin", hits[:])
    testing.expect(t, !bad, "a missing character must fail the match")
    testing.expect_value(t, missing, 0)
}

// An empty query matches everything and marks nothing, and fuzzy_score still
// answers exactly what fuzzy_match scores.
@(test)
test_fuzzy_score_matches_fuzzy_match :: proc(t: ^testing.T) {
    hits: [8]int
    score, count, ok := fuzzy_match("", "anything", hits[:])
    testing.expect(t, ok, "an empty query matches all")
    testing.expect_value(t, score, 0)
    testing.expect_value(t, count, 0)

    texts := []string{"thor/palette.odin", "build.odin", "README.md"}
    queries := []string{"", "od", "pal", "zzz"}
    for text in texts {
        for query in queries {
            want, want_ok := fuzzy_score(query, text)
            got, _, got_ok := fuzzy_match(query, text, hits[:])
            testing.expect_value(t, got_ok, want_ok)
            testing.expect_value(t, got, want)
        }
    }
}

// More matched characters than the mark buffer holds still score and still
// match; only the reported positions stop at the buffer.
@(test)
test_fuzzy_match_bounds_its_output :: proc(t: ^testing.T) {
    hits: [2]int
    score, count, ok := fuzzy_match("abcd", "abcd", hits[:])
    testing.expect(t, ok, "the match must survive a short buffer")
    testing.expect(t, score > 0, "the score must be unaffected")
    testing.expect_value(t, count, 2)
}

// A span never cuts a rune: the matcher works in bytes, so a run over non-ASCII
// text is snapped out to the rune boundaries around it.
@(test)
test_palette_match_spans_stay_on_runes :: proc(t: ^testing.T) {
    text := "ölçü.odin"
    spans := palette_match_spans("od", text, {})
    testing.expect(t, len(spans) > 0, "the query matches the extension")
    for s in spans {
        testing.expect(t, s.start >= 0 && s.end <= len(text), "span out of range")
        testing.expect(t, s.start < s.end, "an empty span must not be emitted")
        testing.expect(t, text[s.start] & 0xC0 != 0x80, "a span starts inside a rune")
        if s.end < len(text) {
            testing.expect(t, text[s.end] & 0xC0 != 0x80, "a span ends inside a rune")
        }
    }
    // Adjacent matched bytes coalesce into one run, apart ones do not.
    joined := palette_match_spans("din", "thor.odin", {})
    testing.expect_value(t, len(joined), 1)
    testing.expect_value(t, joined[0].start, 6)
    testing.expect_value(t, joined[0].end, 9)
    split := palette_match_spans("odin", "thor.odin", {})
    testing.expect_value(t, len(split), 2)
}
