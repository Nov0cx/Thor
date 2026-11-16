package theme

import "core:math"

import ui "../vendor/loom/loom"

// The extremes a contrast lift ends at.
WHITE :: ui.Color{255, 255, 255, 255}
BLACK :: ui.Color{0, 0, 0, 255}

// `color` as hue (0 to 360), saturation and value (0 to 1). Alpha is ignored. A
// grey color has hue 0.
color_to_hsv :: proc(color: ui.Color) -> [3]f32 {
    r, g, b := f32(color.r) / 255, f32(color.g) / 255, f32(color.b) / 255
    hi    := max(r, g, b)
    delta := hi - min(r, g, b)
    if delta < 0.00001 || hi <= 0 {
        return {0, 0, hi}
    }
    hue: f32
    switch {
    case r >= hi:
        hue = (g - b) / delta
    case g >= hi:
        hue = 2 + (b - r) / delta
    case:
        hue = 4 + (r - g) / delta
    }
    hue *= 60
    if hue < 0 {
        hue += 360
    }
    return {hue, delta / hi, hi}
}

// The opaque color of hue (degrees), saturation and value (0 to 1).
color_from_hsv :: proc(hue, saturation, value: f32) -> ui.Color {
    channel :: proc(n, hue, saturation, value: f32) -> u8 {
        k := math.mod(n + hue / 60, 6)
        k = clamp(min(4 - k, k), 0, 1)
        return u8((value - value * saturation * k) * 255)
    }
    return {channel(5, hue, saturation, value), channel(3, hue, saturation, value), channel(1, hue, saturation, value), 255}
}

// `color` lightened (factor > 0) or darkened (factor < 0) by `factor` (-1 to 1).
// Alpha stays.
@(private)
color_brightness :: proc(color: ui.Color, factor: f32) -> ui.Color {
    f   := clamp(factor, -1, 1)
    out := color
    for i in 0 ..< 3 {
        c := f32(color[i])
        if f < 0 {
            c *= 1 + f
        } else {
            c += (255 - c) * f
        }
        out[i] = u8(c)
    }
    return out
}

// Text drawn on a light background.
COLOR_ON_DARK :: ui.Color{16, 18, 22, 255}

// Text drawn on a dark background.
COLOR_ON_LIGHT :: ui.Color{255, 255, 255, 255}

// One sRGB channel as a linear value, for the luminance sum.
@(private = "file")
channel_linear :: proc(value: u8) -> f32 {
    c := cast(f32)value / 255
    if c <= 0.03928 {
        return c / 12.92
    }
    return math.pow((c + 0.055) / 1.055, 2.4)
}

// Relative luminance (WCAG) of `color`: 0 for black, 1 for white. Alpha is ignored.
color_luminance :: proc(color: ui.Color) -> f32 {
    return 0.2126 * channel_linear(color.r) + 0.7152 * channel_linear(color.g) + 0.0722 * channel_linear(color.b)
}

// Contrast ratio (WCAG) between two colors, 1 to 21. Alpha is ignored.
color_contrast_ratio :: proc(a, b: ui.Color) -> f32 {
    high, low := color_luminance(a), color_luminance(b)
    if high < low {
        high, low = low, high
    }
    return (high + 0.05) / (low + 0.05)
}

// The label color that reads best on `background`. Every shipped theme has a
// light accent, so a fixed light label is unreadable on almost all of them.
color_on :: proc(background: ui.Color) -> ui.Color {
    if color_contrast_ratio(background, COLOR_ON_DARK) >= color_contrast_ratio(background, COLOR_ON_LIGHT) {
        return COLOR_ON_DARK
    }
    return COLOR_ON_LIGHT
}

// `color` moved away from its color_on label by `amount` (0 to 1): a light color
// gets lighter, a dark one darker. The hue stays, and the label contrast only grows.
color_shade :: proc(color: ui.Color, amount: f32) -> ui.Color {
    factor := color_on(color) == COLOR_ON_DARK ? amount : -amount
    shaded := color_brightness(color, factor)
    shaded.a = color.a
    return shaded
}

// `color` with the HSV components given, keeping its alpha.
color_with_hsv :: proc(color: ui.Color, hue, saturation, value: f32) -> ui.Color {
    out := color_from_hsv(hue, saturation, value)
    out.a = color.a
    return out
}

// `color` turned `degrees` around the hue wheel, keeping saturation, value and
// alpha. A grey color has no hue to turn and comes back unchanged.
color_rotate_hue :: proc(color: ui.Color, degrees: f32) -> ui.Color {
    hsv := color_to_hsv(color)
    return color_with_hsv(color, math.mod(hsv[0] + degrees + 360, 360), hsv[1], hsv[2])
}

// `a` blended `t` of the way to `b` (0 to 1), keeping a's alpha.
color_mix :: proc(a, b: ui.Color, t: f32) -> ui.Color {
    f     := clamp(t, 0, 1)
    mixed := a
    for i in 0 ..< 3 {
        mixed[i] = u8((1 - f) * f32(a[i]) + f * f32(b[i]))
    }
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
color_ensure_contrast :: proc(foreground, background: ui.Color, ratio: f32) -> ui.Color {
    if color_contrast_ratio(foreground, background) >= ratio {
        return foreground
    }

    // Away from the background is toward white on a dark one, toward black on a
    // light one.
    toward_light := color_on(background) == COLOR_ON_LIGHT
    hsv          := color_to_hsv(foreground)
    lifted       := color_with_hsv(foreground, hsv[0], hsv[1], toward_light ? 1 : 0)
    if color_contrast_ratio(lifted, background) >= ratio {
        return color_bisect(foreground, lifted, background, ratio)
    }
    return color_bisect(lifted, toward_light ? WHITE : BLACK, background, ratio)
}

// The point along `near` to `far` closest to `near` that still reads at `ratio`.
// Both ends differ in luminance alone, so the ratio is monotone along the blend.
@(private = "file")
color_bisect :: proc(near, far, background: ui.Color, ratio: f32) -> ui.Color {
    best := far
    low, high := f32(0), f32(1)
    for _ in 0 ..< CONTRAST_STEPS {
        mid       := (low + high) / 2
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
