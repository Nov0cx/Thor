package ui

import "core:c"
import "core:unicode/utf8"
import rl "vendor:raylib"

import hb "../vendor/odin-harfbuzz/harfbuzz"

// Atlas glyph keyed by glyph index, so ligature glyphs (which have no
// codepoint) are drawable.
Shaped_Glyph :: struct {
    rect:     rl.Rectangle,
    offset_x: i32,
    offset_y: i32,
    advance:  i32,
}

// Sequences shaped at bake time to discover ligature glyph ids to rasterize.
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

// Draw-time shaping buffer; main thread only, freed in text_shutdown.
@(private = "file")
shape_buffer: ^hb.buffer_t

// Draw-time ligatures, off via the ligatures setting. Bake-time probing ignores
// this, so the ligature glyphs stay in the atlas and the setting takes effect
// without a rebake.
@(private = "file")
ligatures_enabled := true

// OpenType feature tags as four-byte identifiers. Spelled out because hb.TAG
// needs a context, which the global scope has none of.
@(private = "file")
TAG_LIGA: hb.tag_t : ('l' << 24) | ('i' << 16) | ('g' << 8) | 'a'
@(private = "file")
TAG_CLIG: hb.tag_t : ('c' << 24) | ('l' << 16) | ('i' << 8) | 'g'
@(private = "file")
TAG_DLIG: hb.tag_t : ('d' << 24) | ('l' << 16) | ('i' << 8) | 'g'
@(private = "file")
TAG_CALT: hb.tag_t : ('c' << 24) | ('a' << 16) | ('l' << 8) | 't'

// The features that make a ligature, all forced off over the whole buffer.
// HarfBuzz applies liga and calt by default, so only an explicit 0 stops them.
@(private = "file")
LIGATURES_OFF := [?]hb.feature_t {
    {tag = TAG_LIGA, value = 0, start = 0, end = max(c.uint)},
    {tag = TAG_CLIG, value = 0, start = 0, end = max(c.uint)},
    {tag = TAG_DLIG, value = 0, start = 0, end = max(c.uint)},
    {tag = TAG_CALT, value = 0, start = 0, end = max(c.uint)},
}

// One positioned glyph of a shaped line. Measuring and drawing walk the same
// placement, so a measured width is the width that gets drawn.
@(private = "file")
Placed_Glyph :: struct {
    rect:     rl.Rectangle,
    offset_x: i32,
    offset_y: i32,
    advance:  i32,
}

// Placement scratch, reused per call; main thread only, freed in text_shutdown.
@(private = "file")
placed: [dynamic]Placed_Glyph

// Shapes the probes with a worker-local HarfBuzz font; returns glyph ids not
// already covered by the codepoint atlas. Runs on the rasterizer threads.
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
        infos, glyph_count := shape_into(buffer, font, probe, whole_run(probe))
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

// Shapes one run of a line. The whole line goes to HarfBuzz and the run selects
// a part of it, so a run keeps the context of its neighbours (Arabic joining
// forms need it) and the clusters stay byte offsets into the line.
// The language stays "en": it selects only locl variants, and a code editor must
// draw the same text on every machine.
@(private = "file")
shape_into :: proc(
    buffer: ^hb.buffer_t,
    font: ^hb.font_t,
    text: string,
    run: Shape_Run,
    features: []hb.feature_t = nil,
) -> ([^]hb.glyph_info_t, c.uint) {
    flags: c.uint = cast(c.uint) hb.buffer_flags_t.BUFFER_FLAG_DEFAULT
    if run.start == 0 {
        flags |= cast(c.uint) hb.buffer_flags_t.BUFFER_FLAG_BOT
    }
    if run.end == len(text) {
        flags |= cast(c.uint) hb.buffer_flags_t.BUFFER_FLAG_EOT
    }

    hb.buffer_reset(buffer)
    hb.buffer_add_utf8(
        buffer,
        raw_data(text),
        cast(c.int) len(text),
        cast(c.uint) run.start,
        cast(c.int) (run.end - run.start),
    )
    hb.buffer_set_direction(buffer, run.level % 2 == 1 ? .DIRECTION_RTL : .DIRECTION_LTR)
    hb.buffer_set_script(buffer, run.script)
    hb.buffer_set_language(buffer, hb.language_from_string("en", -1))
    hb.buffer_set_flags(buffer, cast(hb.buffer_flags_t) flags)
    hb.shape(font, buffer, raw_data(features), cast(c.uint) len(features))

    glyph_count: c.uint
    infos := cast([^]hb.glyph_info_t) hb.buffer_get_glyph_infos(buffer, &glyph_count)
    return infos, glyph_count
}

// The whole text as one left-to-right Latin run.
@(private = "file")
whole_run :: proc(text: string) -> Shape_Run {
    return Shape_Run {start = 0, end = len(text), script = .SCRIPT_LATIN}
}

// Creates the persistent draw-time HarfBuzz font. Main thread only; the blob
// borrows family.file_data (resident until text_shutdown).
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
    delete(placed)
    placed = nil
}

// Draws the font's ligatures, or the plain glyphs. Main thread only.
shape_set_ligatures :: proc(enabled: bool) {
    ligatures_enabled = enabled
}

shape_ligatures_enabled :: proc() -> bool {
    return ligatures_enabled
}

// Shapes one line as a single left-to-right Latin run; the returned slice is
// valid until the next shape_line call. The draw path uses shape_place_line,
// which itemizes the line by script and direction first.
shape_line :: proc(family: ^Font_Family, line: string) -> ([^]hb.glyph_info_t, int) {
    infos, glyph_count := shape_line_run(family, line, whole_run(line))
    return infos, cast(int) glyph_count
}

@(private = "file")
shape_line_run :: proc(family: ^Font_Family, line: string, run: Shape_Run) -> ([^]hb.glyph_info_t, c.uint) {
    if shape_buffer == nil {
        shape_buffer = hb.buffer_create()
    }
    features := ligatures_enabled ? nil : LIGATURES_OFF[:]
    return shape_into(shape_buffer, family.hb_font, line, run, features)
}

// Places one shaped line; false when the family/size has no shaping data, so
// the caller falls back to the codepoint path. Advances come from
// Shaped_Glyph, not HarfBuzz, to stay aligned with the atlas.
// The result is valid until the next call.
@(private = "file")
shape_place_line :: proc(family: ^Font_Family, font: rl.Font, size: i32, line: string) -> ([]Placed_Glyph, bool) {
    if family == nil || family.hb_font == nil {
        return nil, false
    }
    shaped, has_size := family.shaped[size]
    if !has_size {
        return nil, false
    }
    clear(&placed)
    if line == "" {
        return placed[:], true
    }

    // The runs come in visual order and a right-to-left run is already in visual
    // order inside itself, so appending them in order places the line correctly.
    for run in shape_itemize(line) {
        infos, glyph_count := shape_line_run(family, line, run)
        for i in 0 ..< glyph_count {
            place_glyph(shaped, font, line, infos[i])
        }
    }
    return placed[:], true
}

@(private = "file")
place_glyph :: proc(shaped: map[u32]Shaped_Glyph, font: rl.Font, line: string, info: hb.glyph_info_t) {
    gid := cast(u32) info.codepoint
    if glyph, mapped := shaped[gid]; mapped {
        append(
            &placed,
            Placed_Glyph {
                rect = glyph.rect,
                offset_x = glyph.offset_x,
                offset_y = glyph.offset_y,
                advance = glyph.advance,
            },
        )
        return
    }

    // Glyph substituted outside the baked set (e.g. JetBrains Mono's
    // contextual backtick): use the source char's baked glyph instead.
    cluster := cast(int) info.cluster
    r: rune = 0
    if cluster >= 0 && cluster < len(line) {
        r, _ = utf8.decode_rune_in_string(line[cluster:])
    }
    index := rl.GetGlyphIndex(font, r)
    if r >= 32 && font.glyphs[index].value == r {
        baked := font.glyphs[index]
        append(
            &placed,
            Placed_Glyph {
                rect = font.recs[index],
                offset_x = cast(i32) baked.offsetX,
                offset_y = cast(i32) baked.offsetY,
                advance = cast(i32) baked.advanceX,
            },
        )
        return
    }
    space := rl.GetGlyphIndex(font, ' ')
    append(&placed, Placed_Glyph {advance = cast(i32) font.glyphs[space].advanceX})
}

// Draws one line via shaping; false when the family/size has no shaping data,
// so the caller falls back to the codepoint path.
draw_line_shaped :: proc(family: ^Font_Family, font: rl.Font, size: i32, line: string, x, y: i32, color: rl.Color) -> bool {
    glyphs, ok := shape_place_line(family, font, size, line)
    if !ok {
        return false
    }

    pen := cast(f32) x
    for glyph in glyphs {
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

// Width of one line via shaping; false when the family/size has no shaping
// data. A ligature has its own advance, so the shaped sum is the only width
// that agrees with draw_line_shaped.
measure_line_shaped :: proc(family: ^Font_Family, font: rl.Font, size: i32, line: string) -> (f32, bool) {
    glyphs, ok := shape_place_line(family, font, size, line)
    if !ok {
        return 0, false
    }

    width: f32 = 0
    for glyph in glyphs {
        width += cast(f32) glyph.advance
    }
    return width, true
}
