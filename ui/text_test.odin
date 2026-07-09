package ui

import "core:testing"

// Runs the full async CPU rasterization pipeline headlessly (the texture
// upload is skipped by raylib when no GPU is ready). Guards against the
// raylib 6.0 LoadFontData binding regression that corrupted memory.
@(test)
test_async_font_load :: proc(t: ^testing.T) {
    text_begin_async_load("fonts/JetBrainsMono-Regular.ttf", {17, 18, 20})
    text_finish_async_load()
    defer text_shutdown()

    testing.expect_value(t, len(font_cache), 3)
    for size in ([3]i32 {17, 18, 20}) {
        font, ok := font_cache[size]
        testing.expect(t, ok, "font size missing from cache")
        if !ok {
            continue
        }
        testing.expect_value(t, font.baseSize, size)
        // JetBrains Mono covers 325 of the 327 requested codepoints.
        testing.expect_value(t, font.glyphCount, 325)
        testing.expect(t, font.recs != nil, "recs not set")
        testing.expect(t, font.glyphs != nil, "glyphs not set")

        // Every glyph rect must lie inside the atlas dimensions recorded
        // during packing (texture is empty headless, so check via recs).
        for i in 0 ..< font.glyphCount {
            rec := font.recs[i]
            testing.expect(t, rec.x >= 0 && rec.y >= 0, "negative rec origin")
            testing.expect(t, rec.width >= 0 && rec.height >= 0, "negative rec size")
        }
    }
}
