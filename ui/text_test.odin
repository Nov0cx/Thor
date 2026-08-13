package ui

import "core:testing"
import rl "vendor:raylib"

// A glyph wider than any atlas this input packs into must not be packed:
// doing so would overrun into the next row or past the buffer entirely.
// Not reachable with a shipped font manifest (every family preloads dozens
// of glyphs, so the sqrt-derived atlas dwarfs any single glyph), but the
// packer must not corrupt memory if that ever stopped being true.
@(test)
test_pack_glyph_atlas_rejects_oversized_glyph :: proc(t: ^testing.T) {
    glyphs := make([]rl.GlyphInfo, 3, context.temp_allocator)
    glyphs[0].image = {width = 10, height = 10}
    glyphs[1].image = {width = 100_000, height = 10} // wider than any atlas this produces
    glyphs[2].image = {width = 10, height = 10}

    atlas_data, atlas_w, atlas_h, recs := pack_glyph_atlas(raw_data(glyphs), len(glyphs), 16, "test")
    defer rl.MemFree(atlas_data)
    defer rl.MemFree(recs)

    testing.expect_value(t, recs[1], rl.Rectangle{})
    for i in ([2]int {0, 2}) {
        rec := recs[i]
        testing.expect(t, rec.x >= 0 && rec.y >= 0, "negative rec origin")
        testing.expect(t, rec.x + rec.width <= cast(f32) atlas_w, "rec overruns atlas width")
        testing.expect(t, rec.y + rec.height <= cast(f32) atlas_h, "rec overruns atlas height")
    }
}

// A glyph taller than the nominal font size must grow the atlas to fit its
// own bitmap, not just the usual size-based row height.
@(test)
test_pack_glyph_atlas_grows_for_tall_glyph :: proc(t: ^testing.T) {
    glyphs := make([]rl.GlyphInfo, 2, context.temp_allocator)
    glyphs[0].image = {width = 10, height = 10}
    glyphs[1].image = {width = 10, height = 500} // far taller than the requested size

    atlas_data, _, atlas_h, recs := pack_glyph_atlas(raw_data(glyphs), len(glyphs), 16, "test")
    defer rl.MemFree(atlas_data)
    defer rl.MemFree(recs)

    rec := recs[1]
    testing.expect(t, rec.y + rec.height <= cast(f32) atlas_h, "tall glyph overruns atlas height")
}

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
        testing.expect_value(t, len(family.cache), 6)
        for size in ([6]i32 {14, 15, 16, 17, 18, 20}) {
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

    // Iosevka ships subset to the ranges build_codepoint_list asks for, so it
    // must cover every one of them and still carry its calt ligatures.
    iosevka, iosevka_ok := families["Iosevka"]
    testing.expect(t, iosevka_ok, "Iosevka family missing")
    if iosevka_ok {
        testing.expect_value(t, len(iosevka.cache), 4)
        for size in ([4]i32 {15, 17, 18, 20}) {
            font, ok := iosevka.cache[size]
            testing.expect(t, ok, "Iosevka size missing from cache")
            if !ok {
                continue
            }
            testing.expect(t, font.glyphCount >= cast(i32) len(iosevka.codepoints), "Iosevka is missing requested codepoints")
        }
        // shape_line hands back the shared buffer, so keep the glyph id before
        // shaping again.
        arrow, arrow_n := shape_line(iosevka, "->")
        testing.expect_value(t, arrow_n, 2)
        if arrow_n == 2 {
            arrow_gid := arrow[0].codepoint
            dash, dash_n := shape_line(iosevka, "-")
            testing.expect_value(t, dash_n, 1)
            if dash_n == 1 {
                testing.expect(t, arrow_gid != dash[0].codepoint, "'->' did not trigger ligature substitution")
            }
        }
    }

    icons, icons_ok := families[ICON_FAMILY]
    testing.expect(t, icons_ok, "icon family missing")
    if icons_ok {
        testing.expect_value(t, len(icons.cache), 3)
        for size in ([3]i32 {14, 16, 18}) {
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
        testing.expect_value(t, len(devicons.cache), 3)
        for size in ([3]i32 {14, 16, 18}) {
            font, ok := devicons.cache[size]
            testing.expect(t, ok, "devicon size missing from cache")
            if !ok {
                continue
            }
            testing.expect_value(t, font.glyphCount, cast(i32) len(devicons.codepoints))
        }
    }

    mdi, mdi_ok := families["mdi"]
    testing.expect(t, mdi_ok, "mdi icon family missing")
    if mdi_ok {
        testing.expect_value(t, mdi.pack_group, "files")
        testing.expect_value(t, len(mdi.cache), 3)
        for size in ([3]i32 {14, 16, 18}) {
            font, ok := mdi.cache[size]
            testing.expect(t, ok, "mdi icon size missing from cache")
            if !ok {
                continue
            }
            // MDI lives in Plane 15, so this also covers astral codepoints
            // surviving the manifest's surrogate pairs into the atlas.
            testing.expect_value(t, font.glyphCount, cast(i32) len(mdi.codepoints))
        }
    }

    odin_icons, odin_ok := families["odin"]
    testing.expect(t, odin_ok, "odin icon family missing")
    if odin_ok {
        testing.expect_value(t, len(odin_icons.cache), 3)
        for size in ([3]i32 {14, 16, 18}) {
            font, ok := odin_icons.cache[size]
            testing.expect(t, ok, "odin icon size missing from cache")
            if !ok {
                continue
            }
            testing.expect_value(t, font.glyphCount, cast(i32) len(odin_icons.codepoints))
        }
    }

    material, material_ok := families["material"]
    testing.expect(t, material_ok, "material icon family missing")
    if material_ok {
        testing.expect_value(t, material.pack_group, "primary")
        testing.expect_value(t, len(material.cache), 3)
        for size in ([3]i32 {14, 16, 18}) {
            font, ok := material.cache[size]
            testing.expect(t, ok, "material icon size missing from cache")
            if !ok {
                continue
            }
            testing.expect_value(t, font.glyphCount, cast(i32) len(material.codepoints))
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

    // A size the manifest never named must bake the same way a preloaded one
    // does: without a shaped map, shape_place_line drops the line to the
    // codepoint fallback and the size silently loses ligatures and bidi.
    if family, ok := families["JetBrainsMono"]; ok {
        LAZY_SIZE :: 23

        _, preloaded := family.shaped[LAZY_SIZE]
        testing.expect(t, !preloaded, "test size is preloaded, so it proves nothing")

        font := get_font(LAZY_SIZE, "JetBrainsMono")
        testing.expect_value(t, font.baseSize, i32(LAZY_SIZE))

        shaped, shaped_ok := family.shaped[LAZY_SIZE]
        testing.expect(t, shaped_ok, "lazily baked size has no shaped map")
        testing.expect(t, len(shaped) > 325, "lazily baked size is missing its ligature glyphs")
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

    // Both "icons" (tabler) and "material" claim pack_group "primary", so
    // exactly one must win as the default and be switchable at runtime.
    labels, names := icon_pack_choices("primary")
    testing.expect_value(t, len(names), 2)
    testing.expect_value(t, len(labels), 2)

    testing.expect(t, icon_set_active_pack("primary", "icons"), "tabler pack should be selectable")
    tabler_folder, tabler_found := icon_codepoint("folder")
    testing.expect(t, tabler_found, "folder missing while tabler pack active")
    testing.expect_value(t, icon_active_pack("primary"), "icons")

    testing.expect(t, icon_set_active_pack("primary", "material"), "material pack should be selectable")
    material_folder, material_found := icon_codepoint("folder")
    testing.expect(t, material_found, "folder missing while material pack active")
    testing.expect_value(t, icon_active_pack("primary"), "material")
    testing.expect(t, tabler_folder != material_folder, "expected different glyphs per pack")

    testing.expect(t, !icon_set_active_pack("primary", "devicons"), "devicons is not a primary-group pack")
    testing.expect(t, !icon_set_active_pack("primary", "no-such-pack"), "unknown pack should fail")

    // The "files" group backs the tree's filetype- names the same way.
    file_labels, file_names := icon_pack_choices("files")
    testing.expect_value(t, len(file_names), 2)
    testing.expect_value(t, len(file_labels), 2)

    testing.expect(t, icon_set_active_pack("files", "devicons"), "devicon file pack should be selectable")
    devicon_rust, devicon_rust_found := icon_codepoint("filetype-rust")
    testing.expect(t, devicon_rust_found, "filetype-rust missing while devicon pack active")
    testing.expect_value(t, icon_active_pack("files"), "devicons")

    testing.expect(t, icon_set_active_pack("files", "mdi"), "mdi file pack should be selectable")
    mdi_rust, mdi_rust_found := icon_codepoint("filetype-rust")
    testing.expect(t, mdi_rust_found, "filetype-rust missing while mdi pack active")
    testing.expect_value(t, icon_active_pack("files"), "mdi")
    testing.expect(t, devicon_rust != mdi_rust, "expected different glyphs per file pack")
    testing.expect(t, mdi_rust > 0xFFFF, "mdi glyph should decode from a surrogate pair")

    // Switching the file pack must not disturb the primary pack's names.
    testing.expect_value(t, icon_active_pack("primary"), "material")

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

    // measure_text must walk the same shaped placement draw_text draws, or a
    // ligature (one glyph with its own advance) measures as the sum of the two
    // codepoints it replaced. Both text families are monospace, so every line
    // stays a whole number of cells wide, ligature or not. The samples are
    // ASCII, so len() is the cell count.
    for name in ([2]string {"JetBrainsMono", "Iosevka"}) {
        cell := measure_text("0", 17, name)
        testing.expect(t, cell > 0, "monospace cell width not measured")
        // "```" is the unbaked-glyph fallback, which must advance one cell too.
        for line in ([?]string {"->", "=>", "!=", "::", "...", "```", "a -> b", "<==>", "|||>"}) {
            testing.expect_value(t, measure_text(line, 17, name), cell * cast(i32) len(line))
        }
        // Multiple lines measure as the widest line.
        testing.expect_value(t, measure_text("ab\nabcd\na", 17, name), cell * 4)

        // A tab advances to the next stop, not by one space. A tab already on a
        // stop advances a whole span, so it is never zero-width.
        testing.expect_value(t, measure_text("\t", 17, name), cell * 4)
        testing.expect_value(t, measure_text("a\t", 17, name), cell * 4)
        testing.expect_value(t, measure_text("abc\t", 17, name), cell * 4)
        testing.expect_value(t, measure_text("abcd\t", 17, name), cell * 8)
        testing.expect_value(t, measure_text("\tab", 17, name), cell * 6)

        // tab_origin moves the grid: the same tab measured as if it started two
        // cells into the line reaches the same stop, so it is two cells wide.
        testing.expect_value(t, measure_text("\t", 17, name, cell * 2), cell * 2)
        // Measuring a line in pieces totals the same as measuring it whole.
        piece := measure_text("ab", 17, name)
        testing.expect_value(t, piece + measure_text("\tc", 17, name, piece), measure_text("ab\tc", 17, name))
    }

    // The tab width reaches shaping without a cache clear: a tab is placed as a
    // marker and resolved when the placement is walked, so the cached line stays
    // valid. Restored to the default for any later test.
    {
        cell := measure_text("0", 17, "JetBrainsMono")
        before := shape_cache_len(&shape_cache)
        testing.expect_value(t, measure_text("\ta", 17, "JetBrainsMono"), cell * 5)
        shape_set_tab_width(8)
        testing.expect_value(t, shape_tab_width(), 8)
        testing.expect_value(t, measure_text("\ta", 17, "JetBrainsMono"), cell * 9)
        // The line was shaped once; the width change added no cache entry.
        testing.expect_value(t, shape_cache_len(&shape_cache), before + 1)
        shape_set_tab_width(4)
        testing.expect_value(t, measure_text("\ta", 17, "JetBrainsMono"), cell * 5)
    }

    // The ligatures setting reaches shaping: with it off, "->" shapes to the
    // plain glyphs the codepoints carry. Left back on for any later test.
    // This also doubles as the shape cache's key regression test: a cache
    // that forgot the ligatures flag in its key would return the pre-toggle
    // glyphs and fail the width assertion below.
    if family, ok := families["JetBrainsMono"]; ok {
        dash_infos, dash_n := shape_line(family, "-")
        testing.expect_value(t, dash_n, 1)
        dash_gid := cast(u32) dash_infos[0].codepoint

        shape_set_ligatures(false)
        testing.expect(t, !shape_ligatures_enabled(), "ligature toggle not recorded")
        plain, plain_n := shape_line(family, "->")
        testing.expect_value(t, plain_n, 2)
        if plain_n == 2 {
            testing.expect_value(t, cast(u32) plain[0].codepoint, dash_gid)
        }
        // A monospace family measures the same either way.
        cell := measure_text("0", 17, "JetBrainsMono")
        testing.expect_value(t, measure_text("->", 17, "JetBrainsMono"), cell * 2)

        shape_set_ligatures(true)
        back, back_n := shape_line(family, "->")
        testing.expect_value(t, back_n, 2)
        if back_n == 2 {
            testing.expect(t, cast(u32) back[0].codepoint != dash_gid, "ligature not restored")
        }
    }

    // A line measured twice must agree whether the second call hits the
    // cache or not, and the cache's resident count must grow only on a true
    // miss (new content), not on a repeat of content already shaped.
    defer shape_cache_clear(&shape_cache)
    line := "if x == 1 { return true }"
    w1 := measure_text(line, 17, "JetBrainsMono")
    w2 := measure_text(line, 17, "JetBrainsMono")
    testing.expect_value(t, w1, w2)

    before := shape_cache_len(&shape_cache)
    _ = measure_text("first unique line", 17, "JetBrainsMono")
    after_first := shape_cache_len(&shape_cache)
    testing.expect_value(t, after_first, before + 1)
    _ = measure_text("first unique line", 17, "JetBrainsMono")
    testing.expect_value(t, shape_cache_len(&shape_cache), after_first)
    _ = measure_text("second unique line", 17, "JetBrainsMono")
    testing.expect_value(t, shape_cache_len(&shape_cache), after_first + 1)
}
