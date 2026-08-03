package shell

import "core:strings"
import "core:testing"

// Run from the repository root: odin test shell

// The plain case: a command's output, then the marker line the terminal added
// behind it.
@(test)
test_scan_end_marker_splits :: proc(t: ^testing.T) {
    before, code, rest, found := scan_end_marker("hello\nTOKEN0\nnoise", "TOKEN")
    testing.expect(t, found)
    testing.expect_value(t, before, "hello\n")
    testing.expect_value(t, code, 0)
    testing.expect_value(t, rest, "noise")
}

// The exit status the marker carries is what the terminal reports, so a failed
// build is not read as a clean one.
@(test)
test_scan_end_marker_exit_code :: proc(t: ^testing.T) {
    _, code, _, found := scan_end_marker("TOKEN3\n", "TOKEN")
    testing.expect(t, found)
    testing.expect_value(t, code, 3)
}

// Output that ends mid-line keeps the marker on the same line, so the text
// ahead of it is still the command's.
@(test)
test_scan_end_marker_inline :: proc(t: ^testing.T) {
    before, code, rest, found := scan_end_marker("no newline hereTOKEN1\n", "TOKEN")
    testing.expect(t, found)
    testing.expect_value(t, before, "no newline here")
    testing.expect_value(t, code, 1)
    testing.expect_value(t, rest, "")
}

// A marker whose line has not arrived whole is not a marker yet: the whole text
// comes back for the next chunk to complete.
@(test)
test_scan_end_marker_incomplete :: proc(t: ^testing.T) {
    _, _, rest, found := scan_end_marker("out\nTOKEN0", "TOKEN")
    testing.expect(t, !found)
    testing.expect_value(t, rest, "out\nTOKEN0")

    _, _, rest2, found2 := scan_end_marker("out\n", "TOKEN")
    testing.expect(t, !found2)
    testing.expect_value(t, rest2, "out\n")
}

// cmd.exe writes its prompt just before it reads the marker command; that
// fragment sits after the last newline and is not output.
@(test)
test_trim_prompt_tail :: proc(t: ^testing.T) {
    testing.expect_value(t, trim_prompt_tail("done\n   "), "done\n")
    testing.expect_value(t, trim_prompt_tail("done\n"), "done\n")
    testing.expect_value(t, trim_prompt_tail(""), "")
    // A last line with real text keeps its trailing spaces: they are output.
    testing.expect_value(t, trim_prompt_tail("value:  "), "value:  ")
}

// A chunk that ends inside the marker must hold back exactly the part that
// could still grow into it, and nothing more.
@(test)
test_partial_marker_len :: proc(t: ^testing.T) {
    testing.expect_value(t, partial_marker_len("out\nTOK", "TOKEN"), 3)
    testing.expect_value(t, partial_marker_len("out\n", "TOKEN"), 0)
    testing.expect_value(t, partial_marker_len("Password: ", "TOKEN"), 0)
    // The full token is not a partial one; the caller waits for its newline.
    testing.expect_value(t, partial_marker_len("TOKEN", "TOKEN"), 0)
}

// Every shell must be able to report where a command ended, and the marker it
// prints must be the token the terminal scans for.
@(test)
test_end_command_names_token :: proc(t: ^testing.T) {
    for kind in Profile_Kind {
        command := end_command(kind, "TOKEN")
        defer delete(command)
        testing.expectf(t, strings.contains(command, "TOKEN"), "%v drops the token: %q", kind, command)
    }
}

// Two terminals must never scan for the same token, or one would read the
// other's marker out of a file it printed.
@(test)
test_end_token_is_unique :: proc(t: ^testing.T) {
    first := end_token(0)
    defer delete(first)
    second := end_token(1)
    defer delete(second)
    testing.expect(t, first != second)
}
