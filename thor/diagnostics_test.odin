package thor

import "core:testing"

// The editor's half of the diagnostics path: mapping a compiler position onto a
// span of the live buffer. The `odin check` run and its output parsing live
// behind the language seam (see lang/odin/check_test.odin). Run from the
// repository root: odin test thor

@(test)
test_token_end_covers_identifier :: proc(t: ^testing.T) {
    text := "foo := bar\n"
    // Start on the 'b' of "bar": extends across the whole identifier.
    testing.expect_value(t, diagnostic_token_end(text, 7), 10)
    // Start on a non-identifier (the ':'): a short bounded span, at least one byte.
    end := diagnostic_token_end(text, 4)
    testing.expect(t, end > 4, "non-identifier still underlines something")
    testing.expect(t, end <= 10, "underline stops at the newline")
}
