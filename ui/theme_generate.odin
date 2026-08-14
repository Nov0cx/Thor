package ui

import "core:math"
import "core:strings"
import rl "vendor:raylib"

// Value a dark background is clamped at or below, and a light one at or above. A
// mid-grey seed would give an editor no room to shade its surfaces, so the mode
// says which end the palette is built from.
@(private = "file")
DARK_BACKGROUND_VALUE :: f32(0.22)
@(private = "file")
LIGHT_BACKGROUND_VALUE :: f32(0.92)

// Contrast floor (WCAG AA) every text and syntax role is lifted to.
@(private = "file")
TEXT_FLOOR :: f32(4.5)

// Builds a whole palette from two seeds. `background` sets every surface, `accent`
// the interactive and syntax colors, and `dark` says which way the surfaces step
// and which end the text comes from. Every text and syntax role is pushed to a
// contrast floor against the background, so a bad seed pair still reads. `name` is
// cloned, as theme_load's is, so theme_destroy pairs.
theme_generate :: proc(name: string, background, accent: rl.Color, dark: bool) -> Theme {
    bg := theme_clamp_background(background, dark)
    up := dark ? rl.WHITE : rl.BLACK
    down := dark ? rl.BLACK : rl.WHITE

    theme: Theme
    theme.name = strings.clone(name)

    theme.background = bg
    theme.second_background = color_mix(bg, up, 0.04)
    theme.buttons = color_mix(bg, up, 0.07)
    theme.active = color_mix(bg, up, 0.11)
    theme.highlight = color_mix(bg, up, 0.15)
    theme.border = color_mix(bg, up, 0.20)
    theme.contrast = color_mix(bg, down, 0.35)
    theme.notifications = theme.contrast

    theme.accent_color = color_ensure_contrast(accent, bg, 3.0)
    theme.accent_secondary_color = color_ensure_contrast(color_rotate_hue(theme.accent_color, 30), bg, 3.0)
    theme.links_color = color_ensure_contrast(color_rotate_hue(theme.accent_color, -20), bg, TEXT_FLOOR)

    theme.tree = theme_alpha(theme.accent_color, 0x40)
    theme.selection_background = theme_alpha(theme.accent_color, 0x60)
    theme.selection_foreground = color_on(color_mix(bg, theme.accent_color, 0.4))

    primary := color_ensure_contrast(color_mix(color_on(bg), bg, 0.06), bg, 12)
    theme.primary_text_color = primary
    theme.text = primary
    theme.variables_color = primary
    theme.foreground = color_ensure_contrast(color_mix(primary, bg, 0.25), bg, 7)
    theme.muted_color = color_ensure_contrast(color_mix(primary, bg, 0.55), bg, TEXT_FLOOR)
    theme.comments_color = theme.muted_color
    theme.disabled = color_ensure_contrast(color_mix(primary, bg, 0.70), bg, 2.5)
    // Deliberately dim: an excluded file has to read as out of the way.
    theme.excluded_files_color = color_ensure_contrast(color_mix(primary, bg, 0.80), bg, 1.8)

    theme.success_color = theme_status(theme.accent_color, bg, 140)
    theme.warning_color = theme_status(theme.accent_color, bg, 42)
    theme.info_color = theme_status(theme.accent_color, bg, 210)
    theme.danger_color = theme_status(theme.accent_color, bg, 355)
    theme.error_color = theme.danger_color
    theme.conflict_color = theme_status(theme.accent_color, bg, 20)
    theme.submodule_color = theme_status(theme.accent_color, bg, 280)

    theme.functions_color = theme_syntax(theme.accent_color, bg, 0)
    theme.operators_color = theme_syntax(theme.accent_color, bg, 30)
    theme.attributes_color = theme_syntax(theme.accent_color, bg, 60)
    theme.strings_color = theme_syntax(theme.accent_color, bg, 100)
    theme.keywords_color = theme_syntax(theme.accent_color, bg, 150)
    theme.tags_color = theme_syntax(theme.accent_color, bg, 180)
    theme.numbers_color = theme_syntax(theme.accent_color, bg, 200)
    theme.parameters_color = theme_syntax(theme.accent_color, bg, 230)

    return theme
}

// The seed background pulled into the band its mode needs, keeping hue and
// saturation. color_on then answers for it on its own.
@(private = "file")
theme_clamp_background :: proc(background: rl.Color, dark: bool) -> rl.Color {
    hsv := rl.ColorToHSV(background)
    value := dark ? min(hsv.z, DARK_BACKGROUND_VALUE) : max(hsv.z, LIGHT_BACKGROUND_VALUE)
    out := color_with_hsv(background, hsv.x, hsv.y, value)
    out.a = 0xFF
    return out
}

@(private = "file")
theme_alpha :: proc(color: rl.Color, alpha: u8) -> rl.Color {
    out := color
    out.a = alpha
    return out
}

// A status color: a fixed hue, but the accent's saturation and value, so the
// palette stays one family.
@(private = "file")
theme_status :: proc(accent, background: rl.Color, hue: f32) -> rl.Color {
    hsv := rl.ColorToHSV(accent)
    return color_ensure_contrast(color_with_hsv(accent, hue, max(hsv.y, 0.55), hsv.z), background, TEXT_FLOOR)
}

// A syntax color: the accent turned `degrees` around the wheel. The rotations skip
// the accent's own neighbourhood, so the roles stay apart.
@(private = "file")
theme_syntax :: proc(accent, background: rl.Color, degrees: f32) -> rl.Color {
    hsv := rl.ColorToHSV(accent)
    rotated := color_with_hsv(accent, math.mod(hsv.x + degrees + 360, 360), max(hsv.y, 0.50), hsv.z)
    return color_ensure_contrast(rotated, background, TEXT_FLOOR)
}
