package ui

import "core:c"
import "core:unicode/utf8"
import rl "vendor:raylib"

import hb "../vendor/odin-harfbuzz/harfbuzz"

// One glyph in a baked atlas, addressed by glyph index instead of codepoint.
// This is what makes ligatures drawable: ligature glyphs have no codepoint
// and are only reachable through HarfBuzz shaping.
Shaped_Glyph :: struct {
    rect:     rl.Rectangle,
    offset_x: i32,
    offset_y: i32,
    advance:  i32,
}

// Sequences shaped at atlas-bake time to discover which ligature glyphs the
// font actually produces; whatever new glyph ids come back get rasterized
// into the same atlas. Unknown sequences simply add nothing. Covers the
// JetBrains Mono / Fira Code style programming ligature sets.
@(private = "file")
LIGATURE_PROBES := [?]string {
    "--", "---", "->", "->>", "-<", "-<<", "-~", "-|",
    "=>", "==", "===", "=>>", "=<<", "=/=", "=!=", "=:=",
    "!=", "!==", "!!", "!!.",
    ">=", ">>", ">>>", ">->", ">>-", ">>=", ">-", ">:",
    "<=", "<<", "<<<", "<-", "<--", "<->", "<=>", "<==", "<<=", "<=<",
    "<-<", "<<-", "<~", "<~>", "<~~", "<|", "<||", "<|||", "<|>", "<:", "<>",
    "<*", "<*>", "<+", "<+>", "<$", "<$>", "</", "</>", "<!--",
    "::", ":::", ":=", ":-", ":+", ":>",
    "..", "...", "..<", ".=", ".-", ".?",
    "??", "???", "?.", "?:", "?=",
    "||", "|||", "|>", "||>", "|||>", "|=", "||=", "|-", "|]", "|}",
    "&&", "&&&", "&=", "&&=",
    "++", "+++", "+>",
    "**", "***", "*>", "*/",
    "//", "///", "/*", "/>", "/=", "/==",
    "~~", "~~>", "~>", "~=", "~@", "~-",
    "^=", "^^",
    "%%",
    "##", "###", "####", "#(", "#{", "#[", "#!", "#?", "#:", "#=", "#_", "#_(",
    "@_",
    "_|_", "|-|",
    ";;",
    "$>",
    "www", "0x", "9x9", "===>", "==>", "-->",
}

// Reused across draw calls; main thread only. Created on first use,
// destroyed in text_shutdown.
@(private = "file")
shape_buffer: ^hb.buffer_t

// Shapes probe sequences with a worker-local HarfBuzz font and returns the
// glyph ids not already covered by the codepoint atlas. Runs on the atlas
// rasterizer threads; every HarfBuzz object is created and destroyed here,
// and the returned array uses context.allocator (the font arena).
shape_collect_ligature_glyphs :: proc(file_data: []u8, seen: ^map[u32]bool) -> [dynamic]u32 {
    extra := make([dynamic]u32)
    if len(file_data) == 0 {
        return extra
    }

    blob := hb.blob_create(raw_data(file_data), cast(c.uint) len(file_data), .MEMORY_MODE_READONLY, nil, nil)
    face := hb.face_create(blob, 0)
    font := hb.font_create(face)
    buffer := hb.buffer_create()
    defer {
        hb.buffer_destroy(buffer)
        hb.font_destroy(font)
        hb.face_destroy(face)
        hb.blob_destroy(blob)
    }

    for probe in LIGATURE_PROBES {
        infos, glyph_count := shape_into(buffer, font, probe)
        for i in 0 ..< glyph_count {
            gid := cast(u32) infos[i].codepoint
            if gid != 0 && !seen[gid] {
                seen[gid] = true
                append(&extra, gid)
            }
        }
    }
    return extra
}

@(private = "file")
shape_into :: proc(buffer: ^hb.buffer_t, font: ^hb.font_t, text: string) -> ([^]hb.glyph_info_t, c.uint) {
    hb.buffer_reset(buffer)
    hb.buffer_add_utf8(buffer, raw_data(text), cast(c.int) len(text), 0, cast(c.int) len(text))
    hb.buffer_set_direction(buffer, .DIRECTION_LTR)
    hb.buffer_set_script(buffer, .SCRIPT_LATIN)
    hb.buffer_set_language(buffer, hb.language_from_string("en", -1))
    hb.shape(font, buffer, nil, 0)

    glyph_count: c.uint
    infos := cast([^]hb.glyph_info_t) hb.buffer_get_glyph_infos(buffer, &glyph_count)
    return infos, glyph_count
}

// Creates the persistent HarfBuzz font used for shaping at draw time.
// Main thread only; the blob borrows family.file_data, which stays resident
// in the font arena until text_shutdown.
shape_family_init :: proc(family: ^Font_Family) {
    if family.hb_font != nil || len(family.file_data) == 0 {
        return
    }
    family.hb_blob = hb.blob_create(raw_data(family.file_data), cast(c.uint) len(family.file_data), .MEMORY_MODE_READONLY, nil, nil)
    family.hb_face = hb.face_create(family.hb_blob, 0)
    family.hb_font = hb.font_create(family.hb_face)
}

shape_family_destroy :: proc(family: ^Font_Family) {
    if family.hb_font == nil {
        return
    }
    hb.font_destroy(family.hb_font)
    hb.face_destroy(family.hb_face)
    hb.blob_destroy(family.hb_blob)
    family.hb_font = nil
    family.hb_face = nil
    family.hb_blob = nil
}

shape_shutdown :: proc() {
    if shape_buffer != nil {
        hb.buffer_destroy(shape_buffer)
        shape_buffer = nil
    }
}

// Shapes one line with the family's persistent font. The returned slice
// lives inside shape_buffer and is valid until the next shape_line call.
shape_line :: proc(family: ^Font_Family, line: string) -> ([^]hb.glyph_info_t, int) {
    if shape_buffer == nil {
        shape_buffer = hb.buffer_create()
    }
    infos, glyph_count := shape_into(shape_buffer, family.hb_font, line)
    return infos, cast(int) glyph_count
}

// Draws one line through the shaping pipeline. Returns false when this
// family/size has no shaping data (lazily loaded size, raylib fallback
// font), in which case the caller draws through the codepoint path.
//
// HarfBuzz positions are deliberately not used: advances come from the
// Shaped_Glyph entries, which were computed with the exact same
// stb_truetype scaling and truncation as the codepoint atlas, so shaped
// text stays pixel-aligned with measure_text (monospace fonts have no
// kerning offsets to lose).
draw_line_shaped :: proc(family: ^Font_Family, font: rl.Font, size: i32, line: string, x, y: i32, color: rl.Color) -> bool {
    if family == nil || family.hb_font == nil {
        return false
    }
    shaped, has_size := family.shaped[size]
    if !has_size {
        return false
    }
    if line == "" {
        return true
    }

    infos, glyph_count := shape_line(family, line)

    pen := cast(f32) x
    for i in 0 ..< glyph_count {
        gid := cast(u32) infos[i].codepoint
        glyph, mapped := shaped[gid]
        if !mapped {
            // Shaping substituted a glyph outside the baked set (e.g. JetBrains
            // Mono's contextual backtick/quote alternates). Fall back to the
            // source character's own baked glyph so it still renders; genuine
            // blanks (tabs, control chars) advance one empty cell.
            cluster := cast(int) infos[i].cluster
            r: rune = 0
            if cluster >= 0 && cluster < len(line) {
                r, _ = utf8.decode_rune_in_string(line[cluster:])
            }
            index := rl.GetGlyphIndex(font, r)
            if r >= 32 && font.glyphs[index].value == r {
                rec := font.recs[index]
                info := font.glyphs[index]
                if rec.width > 0 {
                    rl.DrawTextureRec(
                        font.texture,
                        rec,
                        rl.Vector2 {pen + cast(f32) info.offsetX, cast(f32) y + cast(f32) info.offsetY},
                        color,
                    )
                }
                pen += cast(f32) info.advanceX
            } else {
                space := rl.GetGlyphIndex(font, ' ')
                pen += cast(f32) font.glyphs[space].advanceX
            }
            continue
        }

        if glyph.rect.width > 0 {
            rl.DrawTextureRec(
                font.texture,
                glyph.rect,
                rl.Vector2 {pen + cast(f32) glyph.offset_x, cast(f32) y + cast(f32) glyph.offset_y},
                color,
            )
        }
        pen += cast(f32) glyph.advance
    }
    return true
}
