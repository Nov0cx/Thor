package theme

import "core:testing"


import ui "../vendor/loom/loom"

// The accent of every theme in assets/themes, the input color_on has to answer for.
@(private = "file")
SHIPPED_ACCENTS :: [?]ui.Color{
    {0xE5, 0xA6, 0x73, 255}, // ember-night
    {0xf9, 0x82, 0x6c, 255}, // github-dark
    {0xFF, 0xDD, 0x33, 255}, // gruber-darker
    {0xFF, 0x6B, 0x2C, 255}, // jogo
    {0xFF, 0x98, 0x00, 255}, // material-darker
    {0x84, 0xFF, 0xFF, 255}, // material-deep-ocean
    {0xFF, 0x79, 0xC5, 255}, // material-dracula
    {0xFF, 0xCC, 0x80, 255}, // material-forest
    {0x00, 0xBC, 0xD4, 255}, // material-lighter
    {0xad, 0x9b, 0xf6, 255}, // material-space
    {0x3A, 0x72, 0x69, 255}, // meadow-dew
    {0x4F, 0xC3, 0xF7, 255}, // mjolnir
    {0xd3, 0x36, 0x82, 255}, // solarized-dark
    {0x72, 0xD8, 0x9A, 255}, // verdant-shade
}

@(test)
test_color_luminance_orders_black_to_white :: proc(t: ^testing.T) {
    black := color_luminance(ui.Color{0, 0, 0, 255})
    mid   := color_luminance(ui.Color{128, 128, 128, 255})
    white := color_luminance(ui.Color{255, 255, 255, 255})

    testing.expectf(t, black < 0.001, "black is 0, got %v", black)
    testing.expectf(t, white > 0.999, "white is 1, got %v", white)
    testing.expectf(t, black < mid && mid < white, "grey sits between, got %v", mid)

    // Green weighs most in the sum, blue least, so equal channel values do not
    // give equal luminance.
    green := color_luminance(ui.Color{0, 255, 0, 255})
    blue  := color_luminance(ui.Color{0, 0, 255, 255})
    testing.expect(t, green > blue, "green outweighs blue")
}

@(test)
test_color_contrast_ratio_is_symmetric_and_bounded :: proc(t: ^testing.T) {
    black := ui.Color{0, 0, 0, 255}
    white := ui.Color{255, 255, 255, 255}

    extreme := color_contrast_ratio(black, white)
    testing.expectf(t, extreme > 20.9 && extreme < 21.1, "black on white is 21, got %v", extreme)
    testing.expectf(t, color_contrast_ratio(white, black) == extreme, "the ratio does not depend on the order")

    same := color_contrast_ratio(white, white)
    testing.expectf(t, same > 0.99 && same < 1.01, "a color against itself is 1, got %v", same)
}

// The reported bug: near-white text on a light accent. Every shipped accent has
// to answer with the label that actually reads on it.
@(test)
test_color_on_beats_a_fixed_light_label :: proc(t: ^testing.T) {
    accents := SHIPPED_ACCENTS
    for accent in accents {
        picked         := color_on(accent)
        against_light  := color_contrast_ratio(accent, COLOR_ON_LIGHT)
        against_picked := color_contrast_ratio(accent, picked)

        testing.expectf(t, against_picked >= against_light, "%v: the pick (%v) reads no worse than a fixed light label", accent, picked)
        testing.expectf(t, against_picked >= 4.5, "%v: the pick clears AA, got %v", accent, against_picked)
    }
}

// Every shipped accent has to carry a readable label at rest. This is the floor
// the state shades then move away from, so it is the worst case of the three.
@(test)
test_shipped_accents_clear_aa_at_rest :: proc(t: ^testing.T) {
    accents := SHIPPED_ACCENTS
    for accent in accents {
        ratio := color_contrast_ratio(accent, color_on(accent))
        testing.expectf(t, ratio >= 4.5, "%v: rest state reads %v", accent, ratio)
    }
}

@(test)
test_color_on_answers_both_extremes :: proc(t: ^testing.T) {
    testing.expect(t, color_on(ui.Color{255, 255, 255, 255}) == COLOR_ON_DARK, "white takes a dark label")
    testing.expect(t, color_on(ui.Color{0, 0, 0, 255}) == COLOR_ON_LIGHT, "black takes a light label")
}

// A state shade has to move away from the label color_on picked, or the two
// converge and the text stops reading at exactly the moment it is pointed at.
@(test)
test_color_shade_moves_away_from_the_label :: proc(t: ^testing.T) {
    light := ui.Color{0x4F, 0xC3, 0xF7, 255} // mjolnir accent, takes a dark label
    dark  := ui.Color{0x3A, 0x72, 0x69, 255} // meadow-dew accent, takes a light label

    testing.expect(t, color_luminance(color_shade(light, 0.2)) > color_luminance(light), "a color with a dark label gets lighter")
    testing.expect(t, color_luminance(color_shade(dark, 0.2)) < color_luminance(dark), "a color with a light label gets darker")

    accents := SHIPPED_ACCENTS
    for accent in accents {
        label   := color_on(accent)
        rest    := color_contrast_ratio(accent, label)
        hover   := color_contrast_ratio(color_shade(accent, 0.10), label)
        pressed := color_contrast_ratio(color_shade(accent, 0.20), label)

        testing.expectf(t, hover >= rest, "%v: hover reads at least as well as rest (%v vs %v)", accent, hover, rest)
        testing.expectf(t, pressed >= hover, "%v: pressed keeps moving the same way (%v vs %v)", accent, pressed, hover)
        // The label is picked once from the rest color, so it has to stay legible
        // on the states too.
        testing.expectf(t, pressed >= 4.5, "%v: pressed still clears AA, got %v", accent, pressed)
    }
}

// A shade must stay visibly different from the color it came from, or hover
// reads as no feedback at all.
@(test)
test_color_shade_is_visible :: proc(t: ^testing.T) {
    accents := SHIPPED_ACCENTS
    for accent in accents {
        hover   := color_shade(accent, 0.10)
        changed := hover.r != accent.r || hover.g != accent.g || hover.b != accent.b
        testing.expectf(t, changed, "%v: hover differs from the rest state", accent)
    }
}

@(test)
test_color_shade_keeps_alpha :: proc(t: ^testing.T) {
    translucent := ui.Color{0x4F, 0xC3, 0xF7, 128}
    testing.expect(t, color_shade(translucent, 0.2).a == 128, "shading is opaque to alpha")
}

@(test)
test_color_rotate_hue_wraps :: proc(t: ^testing.T) {
    // 350 degrees plus 30 is 20, not 380.
    red := color_from_hsv(350, 0.8, 0.9)
    red.a = 128
    turned := color_rotate_hue(red, 30)
    hsv    := color_to_hsv(turned)

    testing.expectf(t, hsv[0] > 19 && hsv[0] < 21, "the hue wraps past 360, got %v", hsv[0])
    testing.expectf(t, hsv[1] > 0.79 && hsv[1] < 0.81, "saturation stays, got %v", hsv[1])
    testing.expectf(t, hsv[2] > 0.89 && hsv[2] < 0.91, "value stays, got %v", hsv[2])
    testing.expect(t, turned.a == 128, "alpha stays")
}

@(test)
test_color_ensure_contrast :: proc(t: ^testing.T) {
    dark  := ui.Color{0x11, 0x13, 0x1A, 255}
    light := ui.Color{0xF5, 0xF5, 0xF2, 255}

    for background in ([]ui.Color{dark, light}) {
        // A mid grey reads at about 4 either way, so both directions have work to do.
        fixed := color_ensure_contrast(ui.Color{0x70, 0x70, 0x70, 255}, background, 4.5)
        ratio := color_contrast_ratio(fixed, background)
        testing.expectf(t, ratio >= 4.5, "%v: lifted to AA, got %v", background, ratio)
    }

    // Already readable: returned untouched, not re-derived.
    white := ui.Color{255, 255, 255, 255}
    testing.expect(t, color_ensure_contrast(white, dark, 4.5) == white, "a passing color is left alone")

    // 21 against a mid grey is impossible; the extreme comes back rather than a loop.
    grey    := ui.Color{128, 128, 128, 255}
    extreme := color_ensure_contrast(ui.Color{0x40, 0x80, 0xC0, 255}, grey, 21)
    testing.expect(t, color_luminance(extreme) < 0.01, "an impossible ratio settles on the far end")
}

// The HSV conversions agree with the values raylib's ColorToHSV and ColorFromHSV give.
@(test)
test_color_hsv :: proc(t: ^testing.T) {
    testing.expect_value(t, color_from_hsv(0, 1, 1), ui.Color{255, 0, 0, 255})
    testing.expect_value(t, color_from_hsv(120, 1, 1), ui.Color{0, 255, 0, 255})
    testing.expect_value(t, color_from_hsv(240, 1, 1), ui.Color{0, 0, 255, 255})
    testing.expect_value(t, color_from_hsv(60, 0.5, 0.5), ui.Color{127, 127, 63, 255})
    testing.expect_value(t, color_from_hsv(200, 0, 1), ui.Color{255, 255, 255, 255})

    testing.expect_value(t, color_to_hsv({255, 0, 0, 255}), [3]f32{0, 1, 1})
    testing.expect_value(t, color_to_hsv({0, 0, 255, 9}), [3]f32{240, 1, 1})
    testing.expect_value(t, color_to_hsv({255, 0, 255, 255}), [3]f32{300, 1, 1})
    testing.expect_value(t, color_to_hsv({0, 0, 0, 255}), [3]f32{0, 0, 0})
    grey := color_to_hsv({128, 128, 128, 255})
    testing.expect(t, grey[0] == 0 && grey[1] == 0, "a grey color has no hue or saturation")

    for c in ([?]ui.Color{{18, 52, 86, 255}, {250, 128, 114, 255}, {1, 200, 3, 255}}) {
        hsv  := color_to_hsv(c)
        back := color_from_hsv(hsv[0], hsv[1], hsv[2])
        for i in 0 ..< 3 {
            testing.expectf(t, abs(int(back[i]) - int(c[i])) <= 1, "%v round trips to %v", c, back)
        }
    }
}

@(test)
test_color_brightness_and_mix :: proc(t: ^testing.T) {
    testing.expect_value(t, color_brightness({100, 50, 200, 7}, 0.5), ui.Color{177, 152, 227, 7})
    testing.expect_value(t, color_brightness({100, 50, 200, 7}, -0.5), ui.Color{50, 25, 100, 7})
    testing.expect_value(t, color_mix({0, 0, 0, 10}, {255, 255, 255, 255}, 0.5), ui.Color{127, 127, 127, 10})
    testing.expect_value(t, color_mix({10, 20, 30, 255}, {0, 0, 0, 0}, 2), ui.Color{0, 0, 0, 255})
}
