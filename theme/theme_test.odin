package theme

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "../luaconf"
import ui "../vendor/loom/loom"

@(test)
test_theme_load :: proc(t: ^testing.T) {
    theme, ok := load("assets/themes/material-deep-ocean.lua")
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

    for value in ([]string{"7f80ff", "#7f80f", "#7f80fg", "#ff_f00", "#+f0f0f"}) {
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
        color_at(&theme, i)^ = ui.Color{u8(i), u8(i), u8(i), u8(i)}
    }
    for entry, i in COLORS {
        got := color_at(&theme, i)^
        testing.expectf(t, got == ui.Color{u8(i), u8(i), u8(i), u8(i)}, "%q aliases another field", entry.key)
    }
    testing.expect(t, theme.name == "Mjolnir", "no entry lands on the name")
}

@(test)
test_theme_assign_and_read_roundtrip :: proc(t: ^testing.T) {
    theme := mjolnir()
    for entry, i in COLORS {
        want := ui.Color{u8(i + 1), 0x20, 0x30, 0x40}
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
    opaque := to_hex(ui.Color{0x7F, 0x80, 0xFF, 0xFF})
    testing.expect(t, opaque == "#7F80FF", "an opaque color drops its alpha")

    translucent := to_hex(ui.Color{0x7F, 0x80, 0xFF, 0x40})
    testing.expect(t, translucent == "#7F80FF40", "a translucent color keeps its alpha")

    for value in ([]string{opaque, translucent}) {
        _, ok := parse_hex(value)
        testing.expectf(t, ok, "%q parses back", value)
    }
}

@(test)
test_theme_save_roundtrip :: proc(t: ^testing.T) {
    path := "bin/test/theme-roundtrip.lua"
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
    theme, ok := load("assets/themes/does-not-exist.lua")
    defer destroy(&theme)
    testing.expect(t, !ok, "missing file reports failure")
    // Compared against the built-in itself, so renaming or recoloring the
    // fallback theme cannot break this test.
    fallback := mjolnir()
    testing.expect(t, theme.name == fallback.name, "falls back to the built-in name")
    testing.expect(t, theme.background == fallback.background, "falls back to the built-in colors")
}

// Every color has a role id, no id names two colors, and each id resolves to
// its own field.
@(test)
test_role_color_covers_every_color :: proc(t: ^testing.T) {
    th   := mjolnir()
    seen := make(map[string]bool, context.temp_allocator)
    for entry, i in COLORS {
        testing.expectf(t, entry.role != "", "%q has no role", entry.key)
        testing.expectf(t, !(entry.role in seen), "role %q names two colors", entry.role)
        seen[entry.role] = true

        want := ui.Color{u8(i), 0x11, 0x22, 0x33}
        color_at(&th, i)^ = want
        testing.expect_value(t, role_color(th, entry.role), want)
    }
    testing.expect_value(t, len(seen), 37)
    testing.expect_value(t, role_color(th, "no such role"), th.foreground)
}

// Every shipped theme evaluates and names every role by its role id.
@(test)
test_shipped_themes_load :: proc(t: ^testing.T) {
    matches, err := filepath.glob("assets/themes/*.lua", context.temp_allocator)
    testing.expect(t, err == nil && len(matches) > 0, "assets/themes ships themes")
    for path in matches {
        root, status, message := luaconf.eval_file(path, context.temp_allocator)
        testing.expectf(t, status == .Ok, "%s: %s", path, message)
        colors, _ := root.(json.Object)["colors"].(json.Object)
        testing.expectf(t, len(colors) == len(COLORS), "%s names every role", path)
        for key in colors {
            i := color_index(key)
            testing.expectf(t, i >= 0 && COLORS[i].role == key, "%s: %q is not a role id", path, key)
        }
    }
}

// A theme file may still name a role by its old display label.
@(test)
test_theme_accepts_display_keys :: proc(t: ^testing.T) {
    path := "bin/test/theme-labels.lua"
    defer os.remove(path)
    text := "return { name = 'Old \"keys\"', colors = { [\"Keywords Color\"] = \"#112233\", strings = \"#445566\" } }"
    testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil)

    loaded, ok := load(path)
    defer destroy(&loaded)
    testing.expect(t, ok, "the theme loads")
    testing.expect_value(t, loaded.name, "Old \"keys\"")
    testing.expect_value(t, loaded.keywords_color, ui.Color{0x11, 0x22, 0x33, 0xFF})
    testing.expect_value(t, loaded.strings_color, ui.Color{0x44, 0x55, 0x66, 0xFF})

    // The quote in the name survives a save.
    testing.expect(t, save(loaded, path))
    again, again_ok := load(path)
    defer destroy(&again)
    testing.expect(t, again_ok && again.name == loaded.name, "the name round-trips")
}
