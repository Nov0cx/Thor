package thor

import "core:testing"

import "../widgets"

// Parsing of `odin check` output lines into diagnostics, headlessly. Run from
// the repository root: odin test thor

@(test)
test_parse_error_line :: proc(t: ^testing.T) {
    // A Windows absolute path (note the drive-letter colon, which the parser must
    // not mistake for the line:col colon).
    line := `D:\thor\thor\thor.odin(42:9) Error: 'foo' undeclared`
    p, ok := parse_diagnostic_line(line)
    testing.expect(t, ok, "should parse an error line")
    testing.expect_value(t, p.path, `D:\thor\thor\thor.odin`)
    testing.expect_value(t, p.line, 42)
    testing.expect_value(t, p.col, 9)
    testing.expect(t, p.severity == widgets.Diagnostic_Severity.Error, "severity should be error")
    testing.expect_value(t, p.message, "'foo' undeclared")
}

@(test)
test_parse_warning_and_syntax :: proc(t: ^testing.T) {
    w, wok := parse_diagnostic_line(`pkg/file.odin(3:1) Warning: unused import`)
    testing.expect(t, wok, "should parse a warning line")
    testing.expect(t, w.severity == widgets.Diagnostic_Severity.Warning, "severity should be warning")

    s, sok := parse_diagnostic_line(`pkg/file.odin(10:20) Syntax Error: expected ';'`)
    testing.expect(t, sok, "should parse a syntax error line")
    testing.expect(t, s.severity == widgets.Diagnostic_Severity.Error, "syntax error maps to error")
    testing.expect_value(t, s.message, "expected ';'")
}

@(test)
test_parse_rejects_non_diagnostics :: proc(t: ^testing.T) {
    // A source-snippet line the compiler prints under a diagnostic: has a "(i:j)"
    // shape but no .odin path prefix and no level word.
    _, ok1 := parse_diagnostic_line("\t\tx := arr(1:2)")
    testing.expect(t, !ok1, "snippet line must not parse")

    // A path without .odin suffix is rejected outright.
    _, ok2 := parse_diagnostic_line("notes.txt(1:1) Error: nope")
    testing.expect(t, !ok2, "non-.odin path must not parse")

    // Blank and summary lines.
    _, ok3 := parse_diagnostic_line("")
    testing.expect(t, !ok3, "blank line must not parse")
}

@(test)
test_parse_trims_carriage_return :: proc(t: ^testing.T) {
    p, ok := parse_diagnostic_line("a.odin(1:1) Error: bad\r")
    testing.expect(t, ok, "should parse despite trailing CR")
    testing.expect_value(t, p.message, "bad")
}

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
