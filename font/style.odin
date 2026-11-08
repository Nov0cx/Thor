package font

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// A synthetic face variant. The families ship one Regular file, so bold is the
// glyph drawn again beside itself and italic is the glyph sheared.
Style_Flag :: enum u8 {
    Bold,
    Italic,
}

Style :: bit_set[Style_Flag;u8]

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
draw_glyph_styled :: proc(
    texture: rl.Texture2D,
    src: rl.Rectangle,
    pos: rl.Vector2,
    color: rl.Color,
    style: Style,
    size: i32,
    baseline: f32,
) {
    passes := .Bold in style ? bold_extra(size) : 0
    for pass in 0 ..= passes {
        at := rl.Vector2{pos.x + f32(pass), pos.y}
        if .Italic in style {
            draw_sheared(texture, src, at, color, baseline)
        } else {
            rl.DrawTextureRec(texture, src, at, color)
        }
    }
}

// Draws `src` as a quad that leans right above `baseline` and left below it.
@(private = "file")
draw_sheared :: proc(texture: rl.Texture2D, src: rl.Rectangle, pos: rl.Vector2, color: rl.Color, baseline: f32) {
    if texture.id == 0 || texture.width <= 0 || texture.height <= 0 {
        return
    }
    tw, th := f32(texture.width), f32(texture.height)
    u0, v0 := src.x / tw, src.y / th
    u1, v1 := (src.x + abs(src.width)) / tw, (src.y + abs(src.height)) / th
    w, h := abs(src.width), abs(src.height)
    x, y := pos.x, pos.y
    top := (baseline - y) * ITALIC_SLANT
    bottom := (baseline - y - h) * ITALIC_SLANT

    rlgl.SetTexture(texture.id)
    rlgl.Begin(rlgl.QUADS)
    rlgl.Color4ub(color.r, color.g, color.b, color.a)
    rlgl.Normal3f(0, 0, 1)
    rlgl.TexCoord2f(u0, v0)
    rlgl.Vertex2f(x + top, y)
    rlgl.TexCoord2f(u0, v1)
    rlgl.Vertex2f(x + bottom, y + h)
    rlgl.TexCoord2f(u1, v1)
    rlgl.Vertex2f(x + w + bottom, y + h)
    rlgl.TexCoord2f(u1, v0)
    rlgl.Vertex2f(x + w + top, y)
    rlgl.End()
    rlgl.SetTexture(0)
}
