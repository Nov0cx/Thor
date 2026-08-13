package ui

import "core:testing"

import rl "vendor:raylib"

@(test)
test_layout_name_maps_letters_and_digits :: proc(t: ^testing.T) {
    // QWERTZ prints z on the key raylib calls Y.
    testing.expect_value(t, key_from_layout_name("z", .Y), rl.KeyboardKey.Z)
    testing.expect_value(t, key_from_layout_name("y", .Z), rl.KeyboardKey.Y)
    testing.expect_value(t, key_from_layout_name("a", .Q), rl.KeyboardKey.A)
    testing.expect_value(t, key_from_layout_name("Q", .A), rl.KeyboardKey.Q)
    testing.expect_value(t, key_from_layout_name("1", .ONE), rl.KeyboardKey.ONE)
    testing.expect_value(t, key_from_layout_name("0", .ZERO), rl.KeyboardKey.ZERO)
}

@(test)
test_layout_name_maps_punctuation :: proc(t: ^testing.T) {
    testing.expect_value(t, key_from_layout_name(";", .A), rl.KeyboardKey.SEMICOLON)
    testing.expect_value(t, key_from_layout_name("-", .A), rl.KeyboardKey.MINUS)
    testing.expect_value(t, key_from_layout_name("[", .A), rl.KeyboardKey.LEFT_BRACKET)
    testing.expect_value(t, key_from_layout_name("`", .A), rl.KeyboardKey.GRAVE)
}

@(test)
test_layout_name_falls_back_when_it_names_no_key :: proc(t: ^testing.T) {
    // A German layout prints ü where raylib has [, and raylib has no key for it.
    testing.expect_value(t, key_from_layout_name("ü", .LEFT_BRACKET), rl.KeyboardKey.LEFT_BRACKET)
    testing.expect_value(t, key_from_layout_name("", .F1), rl.KeyboardKey.F1)
    testing.expect_value(t, key_from_layout_name("abc", .F1), rl.KeyboardKey.F1)
    testing.expect_value(t, key_from_layout_name(" ", .SPACE), rl.KeyboardKey.SPACE)
}
