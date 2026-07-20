package thor

import "core:testing"

// Parsing of console error output into clickable source locations, headlessly.
// Run from the repository root: odin test thor

@(test)
test_console_location_odin :: proc(t: ^testing.T) {
    line := `D:\thor\thor\thor.odin(42:9) Error: 'foo' undeclared`
    loc, ok := parse_console_location(line)
    testing.expect(t, ok, "should parse an odin error line")
    testing.expect_value(t, loc.path, `D:\thor\thor\thor.odin`)
    testing.expect_value(t, loc.line, 42)
    testing.expect_value(t, loc.col, 9)
    // Span covers the "path(line:col)" run.
    testing.expect_value(t, loc.span_start, 0)
    testing.expect_value(t, loc.span_end, len(`D:\thor\thor\thor.odin(42:9)`))
}

@(test)
test_console_location_leading_indent :: proc(t: ^testing.T) {
    line := "    pkg/file.odin(3:1) Warning: unused import"
    loc, ok := parse_console_location(line)
    testing.expect(t, ok, "should parse an indented line")
    testing.expect_value(t, loc.path, "pkg/file.odin")
    // The clickable span skips the leading indentation.
    testing.expect_value(t, loc.span_start, 4)
}

@(test)
test_console_location_msvc_comma_and_no_col :: proc(t: ^testing.T) {
    c, cok := parse_console_location("src\\main.cpp(12,5): error C2065")
    testing.expect(t, cok, "should parse a comma separator")
    testing.expect_value(t, c.line, 12)
    testing.expect_value(t, c.col, 5)

    n, nok := parse_console_location("build.log(7): note")
    testing.expect(t, nok, "should parse a line number without a column")
    testing.expect_value(t, n.line, 7)
    testing.expect_value(t, n.col, 0)
}

@(test)
test_console_location_rejects_non_locations :: proc(t: ^testing.T) {
    // A source-snippet line: a "(i:j)" shape but no path with an extension.
    _, ok1 := parse_console_location("\t\tx := arr(1:2)")
    testing.expect(t, !ok1, "snippet line must not parse")

    // A bare identifier before the parens has no extension.
    _, ok2 := parse_console_location("main(1:1) hello")
    testing.expect(t, !ok2, "extensionless path must not parse")

    _, ok3 := parse_console_location("no location here")
    testing.expect(t, !ok3, "plain text must not parse")

    _, ok4 := parse_console_location("")
    testing.expect(t, !ok4, "blank line must not parse")
}

@(test)
test_console_location_trims_carriage_return :: proc(t: ^testing.T) {
    loc, ok := parse_console_location("a.odin(1:1) Error: bad\r")
    testing.expect(t, ok, "should parse despite trailing CR")
    testing.expect_value(t, loc.span_end, len("a.odin(1:1)"))
}
