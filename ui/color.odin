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

// `color` with the HSV components given, keeping its alpha. rl.ColorFromHSV
// always returns an opaque color.
color_with_hsv :: proc(color: rl.Color, hue, saturation, value: f32) -> rl.Color {
    out := rl.ColorFromHSV(hue, saturation, value)
    out.a = color.a
    return out
}

// `color` turned `degrees` around the hue wheel, keeping saturation, value and
// alpha. A grey color has no hue to turn and comes back unchanged.
color_rotate_hue :: proc(color: rl.Color, degrees: f32) -> rl.Color {
    hsv := rl.ColorToHSV(color)
    return color_with_hsv(color, math.mod(hsv.x + degrees + 360, 360), hsv.y, hsv.z)
}

// `a` blended `t` of the way to `b` (0 to 1), keeping a's alpha.
color_mix :: proc(a, b: rl.Color, t: f32) -> rl.Color {
    mixed := rl.ColorLerp(a, b, clamp(t, 0, 1))
    mixed.a = a.a
    return mixed
}

// Iterations of the bisect in color_ensure_contrast. Fixed, so a ratio no color
// can reach terminates instead of looping.
@(private = "file")
CONTRAST_STEPS :: 12

// `foreground` moved away from `background` until it reads at `ratio` (WCAG), or
// as far as white or black goes. The HSV value moves first, so a palette keeps its
// hue where it can; a saturated hue is short of the floor even at its brightest
// (pure blue reads 2.4 on black), so the rest of the way is a blend toward white
// or black, which desaturates it. Returns the extreme when even that misses.
color_ensure_contrast :: proc(foreground, background: rl.Color, ratio: f32) -> rl.Color {
    if color_contrast_ratio(foreground, background) >= ratio {
        return foreground
    }

    // Away from the background is toward white on a dark one, toward black on a
    // light one.
    toward_light := color_on(background) == COLOR_ON_LIGHT
    hsv := rl.ColorToHSV(foreground)
    lifted := color_with_hsv(foreground, hsv.x, hsv.y, toward_light ? 1 : 0)
    if color_contrast_ratio(lifted, background) >= ratio {
        return color_bisect(foreground, lifted, background, ratio)
    }
    return color_bisect(lifted, toward_light ? rl.WHITE : rl.BLACK, background, ratio)
}

// The point along `near` to `far` closest to `near` that still reads at `ratio`.
// Both ends differ in luminance alone, so the ratio is monotone along the blend.
@(private = "file")
color_bisect :: proc(near, far, background: rl.Color, ratio: f32) -> rl.Color {
    best := far
    low, high := f32(0), f32(1)
    for _ in 0 ..< CONTRAST_STEPS {
        mid := (low + high) / 2
        candidate := color_mix(near, far, mid)
        if color_contrast_ratio(candidate, background) >= ratio {
            best = candidate
            high = mid
        } else {
            low = mid
        }
    }
    return best
}
