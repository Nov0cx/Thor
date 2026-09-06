package theme

import "core:os"
import "core:testing"
import rl "vendor:raylib"

import ui "../vendor/loom/loom"

@(test)
test_theme_load :: proc(t: ^testing.T) {
    theme, ok := load("assets/themes/material-deep-ocean.json")
    defer destroy(&theme)
    testing.expect(t, ok, "theme should load")
    testing.expect(t, theme.name == "Material Deep Ocean", "name from file")

    // 6-digit color.
    testing.expect(t, theme.background == ui.Color{0x0F, 0x11, 0x1A, 0xFF}, "background")
    // 8-digit color keeps its alpha.
    testing.expect(t, theme.selection_background == ui.Color{0x71, 0x7C, 0xB4, 0x80}, "selection alpha")
    // Syntax key routed through assign_color.
    testing.expect(t, theme.keywords_color == ui.Color{0xC7, 0x92, 0xEA, 0xFF}, "keywords")
}

// Only `#` plus 6 or 8 hex digits parses; the loader warns about the rest.
@(test)
test_parse_hex_color :: proc(t: ^testing.T) {
    color, ok := parse_hex("#7f80FF")
    testing.expect(t, ok, "6 digits parse")
    testing.expect(t, color == ui.Color{0x7F, 0x80, 0xFF, 0xFF}, "6-digit value")

    color, ok = parse_hex("#7f80FF40")
    testing.expect(t, ok, "8 digits parse")
    testing.expect(t, color == ui.Color{0x7F, 0x80, 0xFF, 0x40}, "8-digit value")

    for value in ([]string {"7f80ff", "#7f80f", "#7f80fg", "#ff_f00", "#+f0f0f"}) {
        _, bad_ok := parse_hex(value)
        testing.expectf(t, !bad_ok, "%q must not parse", value)
    }
}

// Each entry must name its own field: a wrong offset would alias another color, or
// land on `name` and corrupt the string. Distinct values in, distinct values out.
@(test)
test_theme_color_table_covers_every_field :: proc(t: ^testing.T) {
    theme := mjolnir()
    testing.expect(t, len(COLORS) == 37, "every color role is in the table")

    for _, i in COLORS {
        color_at(&theme, i)^ = ui.Color {u8(i), u8(i), u8(i), u8(i)}
    }
    for entry, i in COLORS {
        got := color_at(&theme, i)^
        testing.expectf(t, got == ui.Color {u8(i), u8(i), u8(i), u8(i)}, "%q aliases another field", entry.key)
    }
    testing.expect(t, theme.name == "Mjolnir", "no entry lands on the name")
}

@(test)
test_theme_assign_and_read_roundtrip :: proc(t: ^testing.T) {
    theme := mjolnir()
    for entry, i in COLORS {
        want := ui.Color {u8(i + 1), 0x20, 0x30, 0x40}
        testing.expectf(t, assign_color(&theme, entry.key, want), "%q assigns", entry.key)
        got, ok := color(&theme, entry.key)
        testing.expectf(t, ok && got == want, "%q reads back", entry.key)
    }

    testing.expect(t, !assign_color(&theme, "Nope", WHITE), "unknown key is refused")
    _, ok := color(&theme, "Nope")
    testing.expect(t, !ok, "unknown key has no color")
}

@(test)
test_color_to_hex :: proc(t: ^testing.T) {
    opaque := to_hex(ui.Color {0x7F, 0x80, 0xFF, 0xFF})
    testing.expect(t, opaque == "#7F80FF", "an opaque color drops its alpha")

    translucent := to_hex(ui.Color {0x7F, 0x80, 0xFF, 0x40})
    testing.expect(t, translucent == "#7F80FF40", "a translucent color keeps its alpha")

    for value in ([]string {opaque, translucent}) {
        _, ok := parse_hex(value)
        testing.expectf(t, ok, "%q parses back", value)
    }
}

@(test)
test_theme_save_roundtrip :: proc(t: ^testing.T) {
    path := "bin/test/theme-roundtrip.json"
    defer os.remove(path)

    saved := mjolnir()
    testing.expect(t, save(saved, path), "theme writes")

    loaded, ok := load(path)
    defer destroy(&loaded)
    testing.expect(t, ok, "the written theme loads")
    testing.expect(t, loaded.name == saved.name, "the name survives")
    for entry, i in COLORS {
        testing.expectf(t, color_at(&loaded, i)^ == color_at(&saved, i)^, "%q survives", entry.key)
    }
}

@(test)
test_theme_load_missing_falls_back :: proc(t: ^testing.T) {
    theme, ok := load("assets/themes/does-not-exist.json")
    defer destroy(&theme)
    testing.expect(t, !ok, "missing file reports failure")
    // Compared against the built-in itself, so renaming or recoloring the
    // fallback theme cannot break this test.
    fallback := mjolnir()
    testing.expect(t, theme.name == fallback.name, "falls back to the built-in name")
    testing.expect(t, theme.background == fallback.background, "falls back to the built-in colors")
}
