package lang

import "core:testing"

@(test)
test_symbol_matches_empty_query_matches_everything :: proc(t: ^testing.T) {
    testing.expect(t, symbol_matches("", "anything"))
    testing.expect(t, symbol_matches("", ""))
}

@(test)
test_symbol_matches_subsequence :: proc(t: ^testing.T) {
    testing.expect(t, symbol_matches("tfw", "thor_format_write"))
    testing.expect(t, symbol_matches("format", "thor_format_write"))
    testing.expect(t, !symbol_matches("wft", "thor_format_write"), "order must be respected")
    testing.expect(t, !symbol_matches("zz", "thor_format_write"))
}

@(test)
test_symbol_matches_is_case_insensitive :: proc(t: ^testing.T) {
    testing.expect(t, symbol_matches("TFW", "thor_format_write"))
    testing.expect(t, symbol_matches("point", "Point"))
}

@(test)
test_symbol_matches_rejects_longer_query :: proc(t: ^testing.T) {
    testing.expect(t, !symbol_matches("abcdef", "abc"))
}
