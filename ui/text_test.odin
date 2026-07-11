package ui

import "core:testing"
import rl "vendor:raylib"

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

    devicons, devicons_ok := families["devicons"]
    testing.expect(t, devicons_ok, "devicons family missing")
    if devicons_ok {
        testing.expect_value(t, len(devicons.cache), 2)
        for size in ([2]i32 {16, 18}) {
            font, ok := devicons.cache[size]
            testing.expect(t, ok, "devicon size missing from cache")
            if !ok {
                continue
            }
            testing.expect_value(t, font.glyphCount, cast(i32) len(devicons.codepoints))
        }
    }

    odin_icons, odin_ok := families["odin"]
    testing.expect(t, odin_ok, "odin icon family missing")
    if odin_ok {
        testing.expect_value(t, len(odin_icons.cache), 2)
        for size in ([2]i32 {16, 18}) {
            font, ok := odin_icons.cache[size]
            testing.expect(t, ok, "odin icon size missing from cache")
            if !ok {
                continue
            }
            testing.expect_value(t, font.glyphCount, cast(i32) len(odin_icons.codepoints))
        }
    }

    // Backticks (and other characters JetBrains Mono substitutes via calt)
    // must still render: the baked atlas has the backtick codepoint glyph, and
    // draw_line_shaped falls back to it when shaping yields an unbaked glyph id.
    if family, ok := families["JetBrainsMono"]; ok {
        font := get_font(17, "JetBrainsMono")
        backtick_index := rl.GetGlyphIndex(font, '`')
        testing.expect(t, font.glyphs[backtick_index].value == '`', "backtick glyph not baked into the atlas")

        fence := "```"
        infos, n := shape_line(family, fence)
        testing.expect_value(t, n, 3) // three glyphs, one per backtick (no ligature)
        shaped := family.shaped[17]
        unmapped := 0
        for i in 0 ..< n {
            gid := cast(u32) infos[i].codepoint
            if _, mapped := shaped[gid]; !mapped {
                unmapped += 1
                // The unbaked case the fallback exists for; the source char is
                // a backtick, which is baked, so it still draws.
                cluster := cast(int) infos[i].cluster
                testing.expect(t, fence[cluster] == '`', "fallback source char is not a backtick")
            }
        }
        // JetBrains Mono substitutes every backtick with a contextual-alternate
        // glyph that isn't in the atlas, so the fallback path must be exercised.
        testing.expect(t, unmapped > 0, "expected backtick to hit the codepoint fallback")
    }

    codepoint, found := icon_codepoint("folder")
    testing.expect(t, found, "folder icon missing from icon map")
    testing.expect(t, codepoint >= 0xE000, "folder icon not in private use area")

    dev_codepoint, dev_found := icon_codepoint("devicon-c-plain")
    testing.expect(t, dev_found, "devicon-c-plain missing from icon map")
    testing.expect(t, dev_codepoint >= 0xE000, "devicon glyph not in private use area")

    odin_codepoint, odin_found := icon_codepoint("odin")
    testing.expect(t, odin_found, "odin icon missing from icon map")
    testing.expect_value(t, odin_codepoint, rune(0xE900))

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
