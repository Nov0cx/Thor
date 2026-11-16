package font

import "../platform"

// A synthetic face variant. The families ship one Regular file, so bold is the
// glyph drawn again beside itself and italic is the glyph sheared.
Style_Flag :: enum u8 {
    Bold,
    Italic,
}

Style :: bit_set[Style_Flag; u8]

// The slant of synthetic italic: the top edge moves right by this much per
// pixel of glyph height.
ITALIC_SLANT :: f32(0.21)

// Where the baseline sits down the em, the convention render draws by.
@(private)
STYLE_ASCENT :: f32(0.8)

// The extra pixels a bold run takes past its regular width.
bold_extra :: proc(size: i32) -> i32 {
    return max(1, size / 14)
}

// The width `measure` adds for `style` at `size`.
style_extra :: proc(style: Style, size: i32) -> i32 {
    return .Bold in style ? bold_extra(size) : 0
}

// Draws one glyph cell of `texture` at `pos` in `style`. `baseline` is the y
// an italic glyph leans around.
@(private)
draw_glyph_styled :: proc(texture: platform.Texture, src: platform.Rect, pos: [2]f32, color: platform.Color, style: Style, size: i32, baseline: f32) {
    passes := .Bold in style ? bold_extra(size) : 0
    for pass in 0 ..= passes {
        at := [2]f32{pos.x + f32(pass), pos.y}
        if .Italic in style {
            draw_sheared(texture, src, at, color, baseline)
        } else {
            platform.draw_texture_at(texture, src, at, color)
        }
    }
}

// Draws `src` as a quad that leans right above `baseline` and left below it.
@(private = "file")
draw_sheared :: proc(texture: platform.Texture, src: platform.Rect, pos: [2]f32, color: platform.Color, baseline: f32) {
    if texture.id == 0 || texture.width <= 0 || texture.height <= 0 {
        return
    }
    tw, th := f32(texture.width), f32(texture.height)
    u0, v0 := src.x / tw, src.y / th
    u1, v1 := (src.x + abs(src.w)) / tw, (src.y + abs(src.h)) / th
    w, h := abs(src.w), abs(src.h)
    x, y := pos.x, pos.y
    top    := (baseline - y) * ITALIC_SLANT
    bottom := (baseline - y - h) * ITALIC_SLANT

    platform.draw_textured_quad(
        texture,
        {{{x + top, y}, {u0, v0}}, {{x + bottom, y + h}, {u0, v1}}, {{x + w + bottom, y + h}, {u1, v1}}, {{x + w + top, y}, {u1, v0}}},
        color,
    )
}
