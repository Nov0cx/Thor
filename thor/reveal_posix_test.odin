#+build !windows
package thor

import "core:strings"
import "core:testing"

// The command that shows a file in the OS file manager. Only the string is under
// test -- a real reveal needs a session bus and a desktop. Run from the
// repository root: odin test thor

@(test)
test_reveal_file_uri_encodes_unsafe_bytes :: proc(t: ^testing.T) {
    uri := reveal_file_uri("/tmp/a b/c'd;e")
    testing.expect_value(t, uri, "file:///tmp/a%20b/c%27d%3Be")
}

@(test)
test_reveal_file_uri_keeps_the_unreserved_set :: proc(t: ^testing.T) {
    uri := reveal_file_uri("/home/u/a-b_c.d~e/F9")
    testing.expect_value(t, uri, "file:///home/u/a-b_c.d~e/F9")
}

@(test)
test_reveal_command_selects_the_file :: proc(t: ^testing.T) {
    command := reveal_command("/tmp/notes/a b.odin", "/tmp/notes")
    testing.expect(t, strings.contains(command, "ShowItems"), "an absolute path asks the file manager to select it")
    testing.expect(t, strings.contains(command, "file:///tmp/notes/a%20b.odin"), "the URI is percent-encoded")
    testing.expect(t, strings.contains(command, "xdg-open"), "the folder open stays as the fallback")
}

// The path reaches both a shell line and a GVariant literal, so a quote in it
// must never arrive unencoded.
@(test)
test_reveal_command_holds_no_path_quote :: proc(t: ^testing.T) {
    command := reveal_command("/tmp/it's; rm -rf ~/a", "/tmp")
    testing.expect(t, !strings.contains(command, "it's"), "the quote is encoded")
    testing.expect(t, !strings.contains(command, "rm -rf"), "no command breaks out of the line")
}

@(test)
test_reveal_command_falls_back_for_a_relative_path :: proc(t: ^testing.T) {
    command := reveal_command("notes/a.odin", "notes")
    testing.expect(t, !strings.contains(command, "gdbus"), "a relative path cannot become a file URI")
    testing.expect(t, strings.has_prefix(command, "xdg-open "), "it opens the folder alone")
}
