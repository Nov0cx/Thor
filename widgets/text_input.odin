package widgets

import "core:unicode/utf8"

import "../ui"

// Caret helpers for the single-line inputs (command palette, find/replace).
// Carets are byte offsets into the field's text and always sit on a rune
// boundary.

// Byte offset one rune before `pos`, clamped to the text.
input_prev_rune :: proc(text: string, pos: int) -> int {
    i := clamp(pos, 0, len(text)) - 1
    for i > 0 && (text[i] & 0xC0) == 0x80 {
        i -= 1
    }
    return max(i, 0)
}

// Byte offset one rune after `pos`, clamped to the text.
input_next_rune :: proc(text: string, pos: int) -> int {
    i := clamp(pos, 0, len(text))
    if i >= len(text) {
        return len(text)
    }
    _, w := utf8.decode_rune_in_string(text[i:])
    return min(i + w, len(text))
}

// Rune boundary nearest to `x` for text drawn from `origin` at `font_size`.
input_caret_at_x :: proc(text: string, origin, x: f32, font_size: i32) -> int {
    best := 0
    best_distance := abs(x - origin)
    i := 0
    for i < len(text) {
        _, w := utf8.decode_rune_in_string(text[i:])
        i += w
        distance := abs(x - (origin + cast(f32) ui.measure_text(text[:i], font_size)))
        if distance < best_distance {
            best_distance = distance
            best = i
        }
    }
    return best
}
