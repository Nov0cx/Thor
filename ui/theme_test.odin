package ui

import "core:testing"
import rl "vendor:raylib"

@(test)
test_theme_load :: proc(t: ^testing.T) {
    theme, ok := theme_load("assets/themes/material-deep-ocean.json")
    defer delete(theme.name)
    testing.expect(t, ok, "theme should load")
    testing.expect(t, theme.name == "Material Theme Deep Ocean", "name from file")

    // 6-digit color.
    testing.expect(t, theme.background == rl.Color{0x0F, 0x11, 0x1A, 0xFF}, "background")
    // 8-digit color keeps its alpha.
    testing.expect(t, theme.selection_background == rl.Color{0x71, 0x7C, 0xB4, 0x80}, "selection alpha")
    // Syntax key routed through theme_assign_color.
    testing.expect(t, theme.keywords_color == rl.Color{0xC7, 0x92, 0xEA, 0xFF}, "keywords")
}

@(test)
test_theme_load_missing_falls_back :: proc(t: ^testing.T) {
    theme, ok := theme_load("assets/themes/does-not-exist.json")
    testing.expect(t, !ok, "missing file reports failure")
    testing.expect(t, theme.background == rl.Color{0x0F, 0x11, 0x1A, 0xFF}, "falls back to default")
}
