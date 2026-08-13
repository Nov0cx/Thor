package input

import "core:strings"
import "core:testing"

// Run from the repository root: odin test input

@(test)
test_modifier_from_token_reads_every_spelling :: proc(t: ^testing.T) {
    expect_token :: proc(t: ^testing.T, token: string, want: Modifier) {
        mod, ok := modifier_from_token(token)
        testing.expectf(t, ok, "%q is not read as a modifier", token)
        testing.expectf(t, mod == want, "%q reads as %v, not %v", token, mod, want)
    }
    expect_token(t, "ctrl", .Ctrl)
    expect_token(t, "control", .Ctrl)
    expect_token(t, "shift", .Shift)
    expect_token(t, "alt", .Alt)
    expect_token(t, "option", .Alt)
    expect_token(t, "cmd", .Cmd)
    expect_token(t, "command", .Cmd)
    expect_token(t, "super", .Cmd)
    expect_token(t, "meta", .Cmd)
    expect_token(t, "win", .Cmd)
}

// A key name must not read as a modifier, or the chord would lose its key.
@(test)
test_modifier_from_token_refuses_a_key :: proc(t: ^testing.T) {
    for token in ([?]string {"k", "page_up", "", "ctrl+shift", "CTRL"}) {
        _, ok := modifier_from_token(token)
        testing.expectf(t, !ok, "%q reads as a modifier", token)
    }
}

@(test)
test_write_tokens_keeps_the_parse_order :: proc(t: ^testing.T) {
    b := strings.builder_make(context.temp_allocator)
    write_tokens(&b, {.Cmd, .Ctrl, .Shift, .Alt})
    testing.expect_value(t, strings.to_string(b), "ctrl+shift+alt+cmd+")
}

@(test)
test_write_names_is_the_display_form :: proc(t: ^testing.T) {
    b := strings.builder_make(context.temp_allocator)
    write_names(&b, {.Cmd, .Shift})
    testing.expect_value(t, strings.to_string(b), "Shift+Cmd+")

    empty := strings.builder_make(context.temp_allocator)
    write_names(&empty, {})
    testing.expect_value(t, strings.to_string(empty), "")
}
