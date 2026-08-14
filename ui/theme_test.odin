package ui

import "core:testing"
import rl "vendor:raylib"

@(test)
test_theme_load :: proc(t: ^testing.T) {
    theme, ok := theme_load("assets/themes/material-deep-ocean.json")
    defer theme_destroy(&theme)
    testing.expect(t, ok, "theme should load")
    testing.expect(t, theme.name == "Material Deep Ocean", "name from file")

    // 6-digit color.
    testing.expect(t, theme.background == rl.Color{0x0F, 0x11, 0x1A, 0xFF}, "background")
    // 8-digit color keeps its alpha.
    testing.expect(t, theme.selection_background == rl.Color{0x71, 0x7C, 0xB4, 0x80}, "selection alpha")
    // Syntax key routed through theme_assign_color.
    testing.expect(t, theme.keywords_color == rl.Color{0xC7, 0x92, 0xEA, 0xFF}, "keywords")
}

// Only `#` plus 6 or 8 hex digits parses; the loader warns about the rest.
@(test)
test_parse_hex_color :: proc(t: ^testing.T) {
    color, ok := parse_hex_color("#7f80FF")
    testing.expect(t, ok, "6 digits parse")
    testing.expect(t, color == rl.Color{0x7F, 0x80, 0xFF, 0xFF}, "6-digit value")

    color, ok = parse_hex_color("#7f80FF40")
    testing.expect(t, ok, "8 digits parse")
    testing.expect(t, color == rl.Color{0x7F, 0x80, 0xFF, 0x40}, "8-digit value")

    for value in ([]string {"7f80ff", "#7f80f", "#7f80fg", "#ff_f00", "#+f0f0f"}) {
        _, bad_ok := parse_hex_color(value)
        testing.expectf(t, !bad_ok, "%q must not parse", value)
    }
}

@(test)
test_theme_load_missing_falls_back :: proc(t: ^testing.T) {
    theme, ok := theme_load("assets/themes/does-not-exist.json")
    defer theme_destroy(&theme)
    testing.expect(t, !ok, "missing file reports failure")
    // Compared against the built-in itself, so renaming or recoloring the
    // fallback theme cannot break this test.
    fallback := theme_mjolnir()
    testing.expect(t, theme.name == fallback.name, "falls back to the built-in name")
    testing.expect(t, theme.background == fallback.background, "falls back to the built-in colors")
}
