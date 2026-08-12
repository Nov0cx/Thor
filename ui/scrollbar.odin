package ui

import rl "vendor:raylib"

// Geometry of a vertical scrollbar. Every widget that scrolls draws its own bar
// -- widths, insets, rounding and colors differ -- but the track and thumb math
// is the same everywhere, so it lives here once.

// Look of a scrollbar. `inset` is the gap between the bar and the right edge of
// the area it sits in.
Scrollbar_Style :: struct {
    width:     f32,
    min_thumb: f32,
    inset:     f32,
}

// Track and thumb of a vertical scrollbar over `area`, whose height is the
// visible height. `content` is the full content height and `scroll` the current
// offset, both in pixels; a row-based list passes rows * row_height. `ok` is
// false when the content fits and no bar is shown.
//
// Call it from both the draw and the hit test, so the two cannot drift.
scrollbar_rects :: proc(
    area: rl.Rectangle,
    content, scroll: f32,
    style: Scrollbar_Style,
) -> (track, thumb: rl.Rectangle, ok: bool) {
    if area.height <= 0 || content <= area.height {
        return
    }

    track = rl.Rectangle {
        area.x + area.width - style.width - style.inset,
        area.y,
        style.width,
        area.height,
    }
    thumb_height := min(max(area.height * area.height / content, style.min_thumb), area.height)
    max_scroll := content - area.height
    t := max_scroll > 0 ? clamp(scroll / max_scroll, 0, 1) : 0
    thumb = rl.Rectangle {track.x, track.y + (track.height - thumb_height) * t, style.width, thumb_height}
    return track, thumb, true
}

// The strip a press has to land in to take hold of the thumb. A bar a few pixels
// wide is hard to hit, so the grab strip is wider and grows to the left.
scrollbar_grab_rect :: proc(track: rl.Rectangle, grab_width: f32) -> rl.Rectangle {
    return rl.Rectangle {track.x + track.width - grab_width, track.y, grab_width, track.height}
}

// Scroll offset that puts the thumb top `grab` pixels above `mouse_y`, so the
// thumb keeps its grip on the cursor instead of jumping.
scrollbar_scroll_at :: proc(track, thumb: rl.Rectangle, mouse_y, grab, max_scroll: f32) -> f32 {
    span := track.height - thumb.height
    if span <= 0 {
        return 0
    }
    return clamp((mouse_y - grab - track.y) / span, 0, 1) * max_scroll
}
