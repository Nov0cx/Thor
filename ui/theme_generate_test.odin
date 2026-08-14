package ui

import "core:testing"
import rl "vendor:raylib"

// Seed pairs the generator has to answer for, hostile ones included: an accent
// that cannot be seen on its own background, and a mid-grey with no direction of
// its own.
@(private = "file")
SEED_PAIRS :: [?][2]rl.Color {
    {{0x1A, 0x1C, 0x23, 255}, {0x4F, 0xC3, 0xF7, 255}}, // an ordinary dark pair
    {{0xF5, 0xF5, 0xF2, 255}, {0x00, 0xBC, 0xD4, 255}}, // an ordinary light pair
    {{0x00, 0x00, 0x00, 255}, {0x01, 0x01, 0x02, 255}}, // near-black on black
    {{0xFF, 0xFF, 0xFF, 255}, {0xFE, 0xFE, 0xFE, 255}}, // near-white on white
    {{0x80, 0x80, 0x80, 255}, {0x80, 0x80, 0x80, 255}}, // no direction at all
    {{0x24, 0x10, 0x30, 255}, {0xFF, 0x00, 0x00, 255}}, // a fully saturated accent
}

@(test)
test_theme_generate_contrast_floor :: proc(t: ^testing.T) {
    pairs := SEED_PAIRS
    for pair in pairs {
        for dark in ([]bool {true, false}) {
            theme := theme_generate("Generated", pair[0], pair[1], dark)
            defer theme_destroy(&theme)

            for entry, i in THEME_COLORS {
                if entry.group != .Text && entry.group != .Status && entry.group != .Syntax {
                    continue
                }
                // Two roles are meant to be dim; they carry their own floors.
                if entry.key == "Disabled" || entry.key == "Excluded Files Color" {
                    continue
                }
                // Drawn on the selection, not on the background.
                if entry.key == "Selection Foreground" {
                    continue
                }
                ratio := color_contrast_ratio(theme_color_at(&theme, i)^, theme.background)
                testing.expectf(
                    t, ratio >= 4.4, "%v dark=%v: %q reads %v against the background", pair, dark, entry.key, ratio,
                )
            }

            accent := color_contrast_ratio(theme.accent_color, theme.background)
            testing.expectf(t, accent >= 2.9, "%v dark=%v: the accent reads %v", pair, dark, accent)
        }
    }
}

@(test)
test_theme_generate_syntax_roles_are_distinct :: proc(t: ^testing.T) {
    theme := theme_generate("Generated", rl.Color {0x1A, 0x1C, 0x23, 255}, rl.Color {0x4F, 0xC3, 0xF7, 255}, true)
    defer theme_destroy(&theme)

    syntax := [?]rl.Color {
        theme.functions_color, theme.operators_color, theme.attributes_color, theme.strings_color,
        theme.keywords_color, theme.tags_color, theme.numbers_color, theme.parameters_color,
    }
    for a, i in syntax {
        for b, j in syntax {
            if i < j {
                testing.expectf(t, a != b, "syntax roles %v and %v are the same color %v", i, j, a)
            }
        }
    }
}

@(test)
test_theme_generate_dark_and_light :: proc(t: ^testing.T) {
    seed := rl.Color {0x80, 0x80, 0x80, 255}
    accent := rl.Color {0x4F, 0xC3, 0xF7, 255}

    night := theme_generate("Night", seed, accent, true)
    defer theme_destroy(&night)
    testing.expectf(
        t, color_luminance(night.background) < 0.15, "dark clamps a grey seed, got %v",
        color_luminance(night.background),
    )
    testing.expect(t, color_on(night.background) == COLOR_ON_LIGHT, "dark takes a light label")

    day := theme_generate("Day", seed, accent, false)
    defer theme_destroy(&day)
    testing.expectf(
        t, color_luminance(day.background) > 0.7, "light clamps a grey seed, got %v",
        color_luminance(day.background),
    )
    testing.expect(t, color_on(day.background) == COLOR_ON_DARK, "light takes a dark label")
}

// The generated name is owned, as theme_load's is, so the same destroy pairs with
// both. Under the tracking allocator a leak or a bad free is reported at exit.
@(test)
test_theme_generate_owns_its_name :: proc(t: ^testing.T) {
    theme := theme_generate("Owned", rl.Color {0x1A, 0x1C, 0x23, 255}, rl.Color {0x4F, 0xC3, 0xF7, 255}, true)
    testing.expect(t, theme.name == "Owned", "the name is kept")
    theme_destroy(&theme)
    testing.expect(t, theme.name == "", "destroy clears the name")
}
