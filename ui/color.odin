package ui

import "core:math"
import rl "vendor:raylib"

// Text drawn on a light background.
COLOR_ON_DARK :: rl.Color {16, 18, 22, 255}

// Text drawn on a dark background.
COLOR_ON_LIGHT :: rl.Color {255, 255, 255, 255}

// One sRGB channel as a linear value, for the luminance sum.
@(private = "file")
channel_linear :: proc(value: u8) -> f32 {
    c := cast(f32) value / 255
    if c <= 0.03928 {
        return c / 12.92
    }
    return math.pow((c + 0.055) / 1.055, 2.4)
}

// Relative luminance (WCAG) of `color`: 0 for black, 1 for white. Alpha is ignored.
color_luminance :: proc(color: rl.Color) -> f32 {
    return 0.2126 * channel_linear(color.r) +
        0.7152 * channel_linear(color.g) +
        0.0722 * channel_linear(color.b)
}

// Contrast ratio (WCAG) between two colors, 1 to 21. Alpha is ignored.
color_contrast_ratio :: proc(a, b: rl.Color) -> f32 {
    high, low := color_luminance(a), color_luminance(b)
    if high < low {
        high, low = low, high
    }
    return (high + 0.05) / (low + 0.05)
}

// The label color that reads best on `background`. Every shipped theme has a
// light accent, so a fixed light label is unreadable on almost all of them.
color_on :: proc(background: rl.Color) -> rl.Color {
    if color_contrast_ratio(background, COLOR_ON_DARK) >= color_contrast_ratio(background, COLOR_ON_LIGHT) {
        return COLOR_ON_DARK
    }
    return COLOR_ON_LIGHT
}

// `color` moved away from the label `color_on` picks for it: a light color gets
// lighter, a dark one darker, by `amount` (0 to 1). The hue stays, so a hover or
// pressed state keeps the accent's own color instead of jumping to another role,
// and contrast against that label only improves. Some accents are marginal at
// rest (solarized-dark reads 4.62 either way), so a state that moved toward the
// label would drop below AA.
color_shade :: proc(color: rl.Color, amount: f32) -> rl.Color {
    factor := color_on(color) == COLOR_ON_DARK ? amount : -amount
    shaded := rl.ColorBrightness(color, factor)
    shaded.a = color.a
    return shaded
}
