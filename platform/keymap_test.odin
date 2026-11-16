package platform

import "core:testing"

import rl "vendor:raylib"

import ui "../vendor/loom/loom"

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

@(test)
test_numpad_keys_are_not_remapped :: proc(t: ^testing.T) {
    testing.expect(t, !layout_remaps(.KP_1))
    testing.expect(t, !layout_remaps(.KP_DIVIDE))
    testing.expect(t, !layout_remaps(.KP_ENTER))
    testing.expect(t, !layout_remaps(.F1))
    testing.expect(t, layout_remaps(.Y))
    testing.expect(t, layout_remaps(.ONE))
    testing.expect(t, layout_remaps(.SEMICOLON))
}

@(test)
test_every_mapped_key_is_distinct :: proc(t: ^testing.T) {
    // Two raylib keys may share one Loom key on purpose, but a raylib key must
    // never appear twice, or its release fires against a stale mapping.
    for a, i in KEYS {
        for b, j in KEYS {
            if i >= j {
                continue
            }
            testing.expect(t, a.rk != b.rk, "a raylib key is listed once")
        }
    }
}

@(test)
test_the_key_table_maps_both_ways :: proc(t: ^testing.T) {
    testing.expect_value(t, ui_key(.F5), ui.Key.F5)
    testing.expect_value(t, ui_key(.SEMICOLON), ui.Key.Semicolon)
    testing.expect_value(t, ui_key(.KP_ENTER), ui.Key.Enter)
    testing.expect_value(t, ui_key(.KP_5), ui.Key.Pad_5)
    // A key raylib knows and Loom does not is dropped, never mapped to a wrong
    // one, so a binding cannot fire by accident.
    testing.expect_value(t, ui_key(.KEY_NULL), ui.Key.None)

    testing.expect(t, is_modifier_key(.LEFT_CONTROL), "ctrl is a modifier")
    testing.expect(t, is_modifier_key(.RIGHT_ALT), "altgr is a modifier")
    testing.expect(t, !is_modifier_key(.A), "a letter is not")
}
