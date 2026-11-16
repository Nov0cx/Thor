package font

import "../platform"

// One baked glyph of a Glyph_Set.
Glyph :: struct {
    value:    rune, // -1 for a ligature glyph, reached through shaping only
    rect:     platform.Rect,
    offset_x: i32,
    offset_y: i32,
    advance:  i32,
}

// A font baked at one size: the atlas texture and its glyphs.
Glyph_Set :: struct {
    texture: platform.Texture,
    size:    i32,
    glyphs:  []Glyph,      // font arena
    index:   map[rune]i32, // font arena
    builtin: bool,         // the backend's own font, never freed here
}

// The index of the glyph of `r`. Without one, the index of '?' or 0, and ok is
// false. An empty set answers 0 and false, so check len(set.glyphs) first.
glyph_index :: proc(set: Glyph_Set, r: rune) -> (index: i32, ok: bool) {
    if i, found := set.index[r]; found {
        return i, true
    }
    if i, found := set.index['?']; found {
        return i, false
    }
    return 0, false
}

// The advance of a space, 0 when the set has none.
space_advance :: proc(set: Glyph_Set) -> i32 {
    if i, ok := glyph_index(set, ' '); ok {
        return set.glyphs[i].advance
    }
    return 0
}

// Fills `set.index` from its glyphs. A ligature glyph has no codepoint and stays out.
@(private)
glyph_set_index :: proc(set: ^Glyph_Set) {
    set.index = make(map[rune]i32, len(set.glyphs))
    for g, i in set.glyphs {
        if g.value >= 0 {
            if _, taken := set.index[g.value]; !taken {
                set.index[g.value] = i32(i)
            }
        }
    }
}

@(private = "file")
builtin_cache: Glyph_Set

@(private = "file")
builtin_loaded: bool

// The backend's built-in font as a Glyph_Set. Empty until the window opens.
builtin_set :: proc() -> Glyph_Set {
    if builtin_loaded {
        return builtin_cache
    }
    if font_allocator.procedure == nil {
        return {builtin = true}
    }
    tex, size, raw, ok := platform.builtin_font(context.temp_allocator)
    if !ok {
        return {builtin = true}
    }
    set := Glyph_Set{texture = tex, size = size, builtin = true}
    set.glyphs = make([]Glyph, len(raw), font_allocator)
    for g, i in raw {
        set.glyphs[i] = {value = g.value, rect = g.rect, offset_x = g.offset_x, offset_y = g.offset_y, advance = g.advance}
    }
    context.allocator = font_allocator
    glyph_set_index(&set)
    builtin_cache = set
    builtin_loaded = true
    return set
}

// Forgets the built-in set, whose memory goes with the font arena.
@(private)
builtin_reset :: proc() {
    builtin_cache = {}
    builtin_loaded = false
}

// Frees the texture of `set`; its glyphs go with the font arena.
@(private)
glyph_set_destroy :: proc(set: Glyph_Set) {
    if !set.builtin {
        platform.texture_free(set.texture)
    }
}
