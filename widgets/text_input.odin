package widgets

import "../textedit"
import "../ui"

// Caret helpers for the single-line inputs (command palette, find/replace).
// Carets are byte offsets into the field's text and always sit on a grapheme
// cluster boundary.

// Byte offset one grapheme cluster before `pos`, clamped to the text.
input_prev_rune :: proc(text: string, pos: int) -> int {
    return textedit.grapheme_prev(text, clamp(pos, 0, len(text)))
}

// Byte offset one grapheme cluster after `pos`, clamped to the text.
input_next_rune :: proc(text: string, pos: int) -> int {
    i := clamp(pos, 0, len(text))
    if i >= len(text) {
        return len(text)
    }
    return min(textedit.grapheme_next(text, i), len(text))
}

// Cluster boundary nearest to `x` for text drawn from `origin` at `font_size`.
input_caret_at_x :: proc(text: string, origin, x: f32, font_size: i32) -> int {
    best := 0
    best_distance := abs(x - origin)
    i := 0
    for i < len(text) {
        i = textedit.grapheme_next(text, i)
        distance := abs(x - (origin + cast(f32) ui.measure_text(text[:i], font_size)))
        if distance < best_distance {
            best_distance = distance
            best = i
        }
    }
    return best
}
