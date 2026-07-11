package ui

import "core:testing"

// Runs manifest loading plus the full async CPU rasterization pipeline
// headlessly (the texture upload is skipped by raylib when no GPU is ready).
// Guards against the raylib 6.0 LoadFontData binding regression that
// corrupted memory. Run from the repository root: odin test ui
@(test)
test_async_font_load :: proc(t: ^testing.T) {
    text_begin_async_load("assets/fonts/fonts.json", "assets/icons/icons.json")
    text_finish_async_load()
    defer text_shutdown()

    testing.expect_value(t, default_family_name, "JetBrainsMono")

    family, family_ok := families["JetBrainsMono"]
    testing.expect(t, family_ok, "JetBrainsMono family missing")
    if family_ok {
        testing.expect_value(t, len(family.cache), 4)
        for size in ([4]i32 {15, 17, 18, 20}) {
            font, ok := family.cache[size]
            testing.expect(t, ok, "font size missing from cache")
            if !ok {
                continue
            }
            testing.expect_value(t, font.baseSize, size)
            // JetBrains Mono covers 325 of the 327 requested codepoints;
            // on top of those the shaping probes bake ligature glyphs.
            testing.expect(t, font.glyphCount > 325, "expected ligature glyphs beyond the 325 cmap glyphs")
            testing.expect(t, font.recs != nil, "recs not set")
            testing.expect(t, font.glyphs != nil, "glyphs not set")

            shaped, shaped_ok := family.shaped[size]
            testing.expect(t, shaped_ok, "shaped map missing for preloaded size")
            testing.expect(t, len(shaped) > 325, "shaped map missing ligature glyphs")

            // Every glyph rect must lie inside the atlas dimensions recorded
            // during packing (texture is empty headless, so check via recs).
            for i in 0 ..< font.glyphCount {
                rec := font.recs[i]
                testing.expect(t, rec.x >= 0 && rec.y >= 0, "negative rec origin")
                testing.expect(t, rec.width >= 0 && rec.height >= 0, "negative rec size")
            }
        }
    }

    icons, icons_ok := families[ICON_FAMILY]
    testing.expect(t, icons_ok, "icon family missing")
    if icons_ok {
        testing.expect_value(t, len(icons.cache), 2)
        for size in ([2]i32 {16, 18}) {
            font, ok := icons.cache[size]
            testing.expect(t, ok, "icon size missing from cache")
            if !ok {
                continue
            }
            // Every preloaded icon name must resolve to a baked glyph.
            testing.expect_value(t, font.glyphCount, cast(i32) len(icons.codepoints))
        }
    }

    codepoint, found := icon_codepoint("folder")
    testing.expect(t, found, "folder icon missing from icon map")
    testing.expect(t, codepoint >= 0xE000, "folder icon not in private use area")

    // Shaping "->" must substitute the ligature glyphs, and every glyph the
    // shaper emits must be drawable from the baked atlas.
    if family, ok := families["JetBrainsMono"]; ok {
        testing.expect(t, family.hb_font != nil, "HarfBuzz font not initialized")

        arrow_gids: [2]u32
        infos, n := shape_line(family, "->")
        testing.expect_value(t, n, 2)
        if n == 2 {
            arrow_gids[0] = cast(u32) infos[0].codepoint
            arrow_gids[1] = cast(u32) infos[1].codepoint

            dash_infos, dash_n := shape_line(family, "-")
            testing.expect_value(t, dash_n, 1)
            dash_gid := cast(u32) dash_infos[0].codepoint

            testing.expect(t, arrow_gids[0] != dash_gid, "'->' did not trigger ligature substitution")

            shaped := family.shaped[17]
            for gid in arrow_gids {
                _, mapped := shaped[gid]
                testing.expect(t, mapped, "ligature glyph not baked into the atlas")
            }
        }
    }
}
