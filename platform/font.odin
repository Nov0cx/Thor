package platform

import rl "vendor:raylib"

// One glyph of the backend's built-in font.
Builtin_Glyph :: struct {
    value:    rune,
    rect:     Rect,
    offset_x: i32,
    offset_y: i32,
    advance:  i32,
}

// The backend's built-in bitmap font: its atlas, the size it was drawn at and
// its glyphs, cloned with `allocator`. ok is false before the window opens,
// since the font is made with the GL context.
builtin_font :: proc(allocator := context.allocator) -> (tex: Texture, size: i32, glyphs: []Builtin_Glyph, ok: bool) {
    font := rl.GetFontDefault()
    if font.texture.id == 0 || font.glyphs == nil || font.glyphCount <= 0 {
        return
    }
    glyphs = make([]Builtin_Glyph, font.glyphCount, allocator)
    for i in 0 ..< int(font.glyphCount) {
        g := font.glyphs[i]
        r := font.recs[i]
        glyphs[i] = {value = g.value, rect = {r.x, r.y, r.width, r.height}, offset_x = g.offsetX, offset_y = g.offsetY, advance = g.advanceX}
    }
    return from_rl_texture(font.texture), font.baseSize, glyphs, true
}
