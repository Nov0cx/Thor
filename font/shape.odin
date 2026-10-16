package font

import "core:c"
import "core:math"
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

// Draw-time shaping buffer; main thread only, freed in shutdown.
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
@(private)
Placed_Glyph :: struct {
    rect:     rl.Rectangle,
    offset_x: i32,
    offset_y: i32,
    advance:  i32,
    cluster:  i32, // byte offset in the line of the text the glyph draws
    page:     i32, // 0 for the family atlas, else the 1-based fallback page
    tab:      bool, // no glyph: `advance` is the cell, the walker snaps to the next stop
    rtl:      bool, // the glyph belongs to a right-to-left run
}

// Placement scratch for a cache miss; cloned into shape_cache on success and
// cleared again before the next miss. Main thread only, freed in shutdown.
@(private = "file")
placed: [dynamic]Placed_Glyph

// Fills the family's probe glyph set once. The ids come out of shaping alone
// and never depend on the pixel size, so every size of a family bakes the same
// set. Not thread-safe: the bootstrap worker calls it before it spawns the
// per-size jobs, and the on-demand bake path is main-thread only.
shape_family_probe_ligatures :: proc(family: ^Font_Family) {
    if family.ligature_scan {
        return
    }
    family.ligature_scan = true
    if family.icon_font {
        return
    }
    family.ligature_gids = shape_collect_ligature_glyphs(family.file_data)
}

// Shapes the probes with a local HarfBuzz font; returns the distinct glyph ids
// they produce.
@(private)
shape_collect_ligature_glyphs :: proc(file_data: []u8) -> []u32 {
    extra := make([dynamic]u32)
    if len(file_data) == 0 {
        return extra[:]
    }
    seen := make(map[u32]bool, 0, context.temp_allocator)

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
    return extra[:]
}

// Shapes one run of a line. The whole line goes to HarfBuzz and the run selects
// part of it, so a run keeps its neighbours' context (Arabic joining needs it)
// and clusters stay byte offsets into the line. The language stays "en", which
// selects only locl variants, so a code editor draws the same text everywhere.
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
// borrows family.file_data (resident until shutdown).
shape_family_init :: proc(family: ^Font_Family) {
    if family.hb_font != nil || len(family.file_data) == 0 {
        return
    }
    family.hb_blob = hb.blob_create(raw_data(family.file_data), cast(c.uint) len(family.file_data), .MEMORY_MODE_READONLY, nil, nil)
    family.hb_face = hb.face_create(family.hb_blob, 0)
    family.hb_font = hb.font_create(family.hb_face)
    // hb_font_extents_t holds nine reserved fields the binding leaves out.
    extents: [12]hb.position_t
    if family.hb_font != nil && bool(hb.font_get_h_extents(family.hb_font, cast(^hb.font_extents_t) &extents)) {
        family.hb_em_height = f32(extents[0] - extents[1])
    }
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
    shape_cache_shutdown()
}

// Draws the font's ligatures, or the plain glyphs. Main thread only.
set_ligatures :: proc(enabled: bool) {
    ligatures_enabled = enabled
}

ligatures_enabled :: proc() -> bool {
    return ligatures_enabled
}

// Display cells per tab stop, pushed down from the tab_width setting. A cell is
// the font's space advance. Deliberately not part of the shape cache key: a tab
// is placed as a marker and resolved when the placement is walked, so a width
// change needs no shape_cache_clear. Main thread only.
@(private = "file")
tab_width_cells := 4

// Per-document tab widths are not honoured here — only the global setting is
// pushed down, so a document override would move the caret off the pixels.
set_tab_width :: proc(cells: int) {
    tab_width_cells = clamp(cells, 1, 16)
}

tab_width :: proc() -> int {
    return tab_width_cells
}

// Next tab stop at or after `pen`, measured from the line origin. A pen already
// on a stop advances a whole span, so a tab is never zero-width.
@(private)
tab_stop :: proc(pen, cell: f32) -> f32 {
    span := cell * cast(f32) tab_width_cells
    if span <= 0 {
        return pen + cell
    }
    return (cast(f32) (cast(int) (pen / span)) + 1) * span
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

// Places one shaped line; false when the family has no shaping data. Cached by
// family, size, ligatures and text; an atlas rebake must call shape_cache_clear.
// The slice is cache-owned until its entry is evicted: do not change or free it.
@(private = "file")
shape_place_line :: proc(family: ^Font_Family, font: rl.Font, size: i32, line: string) -> ([]Placed_Glyph, bool) {
    if family == nil || family.hb_font == nil {
        return nil, false
    }
    shaped, has_size := family.shaped[size]
    if !has_size {
        return nil, false
    }
    if line == "" {
        return nil, true
    }

    key := Shape_Cache_Key{family = family, size = size, ligatures = ligatures_enabled, line = line}
    if glyphs, hit := shape_cache_get(&shape_cache, key); hit {
        return glyphs, true
    }

    // Pixels per font unit, as the atlas was baked: stb_truetype scales by the
    // pixel size over ascent minus descent.
    scale := family.hb_em_height > 0 ? f32(size) / family.hb_em_height : 0

    clear(&placed)
    // The runs come in visual order and a right-to-left run is already in visual
    // order inside itself, so appending them in order places the line correctly.
    for run in shape_itemize(line) {
        infos, glyph_count := shape_line_run(family, line, run)
        position_count: c.uint
        positions := cast([^]hb.glyph_position_t) hb.buffer_get_glyph_positions(shape_buffer, &position_count)
        for i in 0 ..< glyph_count {
            first := len(placed)
            place_glyph(family, size, shaped, font, line, infos[i])
            placed[first].rtl = run.level % 2 == 1
            if i < position_count && scale > 0 && !placed[first].tab {
                apply_position(&placed[first], family.hb_font, infos[i], positions[i], scale)
            }
        }
    }
    return shape_cache_put(&shape_cache, key, placed[:]), true
}

// Adds what the font's positioning tables move a glyph by: the kerning delta
// on the atlas advance, and the offset that puts a mark on its base.
@(private = "file")
apply_position :: proc(
    glyph: ^Placed_Glyph,
    hb_font: ^hb.font_t,
    info: hb.glyph_info_t,
    position: hb.glyph_position_t,
    scale: f32,
) {
    nominal := hb.font_get_glyph_h_advance(hb_font, info.codepoint)
    if delta := position.x_advance - nominal; delta != 0 {
        glyph.advance = max(glyph.advance + i32(math.round(f32(delta) * scale)), 0)
    }
    glyph.offset_x += i32(math.round(f32(position.x_offset) * scale))
    // HarfBuzz counts y up, the screen counts it down.
    glyph.offset_y -= i32(math.round(f32(position.y_offset) * scale))
}

@(private = "file")
place_glyph :: proc(
    family: ^Font_Family,
    size: i32,
    shaped: map[u32]Shaped_Glyph,
    font: rl.Font,
    line: string,
    info: hb.glyph_info_t,
) {
    cluster := cast(int) info.cluster
    // Before the glyph lookup: a font whose cmap maps U+0009 would otherwise
    // return a mapped glyph and never become a tab.
    if cluster >= 0 && cluster < len(line) && line[cluster] == '\t' {
        space := rl.GetGlyphIndex(font, ' ')
        append(&placed, Placed_Glyph {advance = font.glyphs[space].advanceX, cluster = i32(cluster), tab = true})
        return
    }

    gid := cast(u32) info.codepoint
    if glyph, mapped := shaped[gid]; mapped {
        append(
            &placed,
            Placed_Glyph {
                rect = glyph.rect,
                offset_x = glyph.offset_x,
                offset_y = glyph.offset_y,
                advance = glyph.advance,
                cluster = i32(cluster),
            },
        )
        return
    }

    // Glyph substituted outside the baked set (e.g. JetBrains Mono's
    // contextual backtick): use the source char's baked glyph instead.
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
                offset_x = baked.offsetX,
                offset_y = baked.offsetY,
                advance = baked.advanceX,
                cluster = i32(cluster),
            },
        )
        return
    }
    // A character the atlas lacks: from the family's own file or a system face.
    if r > 0 {
        if glyph, ok := fallback_glyph(family, size, r); ok {
            append(
                &placed,
                Placed_Glyph {
                    rect = glyph.rect,
                    offset_x = glyph.offset_x,
                    offset_y = glyph.offset_y,
                    advance = glyph.advance,
                    cluster = i32(cluster),
                    page = glyph.page,
                },
            )
            return
        }
    }
    space := rl.GetGlyphIndex(font, ' ')
    append(&placed, Placed_Glyph {advance = font.glyphs[space].advanceX, cluster = i32(cluster)})
}

// Draws one line via shaping; false when the family/size has no shaping data,
// so the caller falls back to the codepoint path. `origin` is the distance from
// the line origin to the start of `line`, so a caller drawing one line in pieces
// keeps the tab stops on one grid.
draw_line_shaped :: proc(
    family: ^Font_Family,
    font: rl.Font,
    size: i32,
    line: string,
    x, y: i32,
    color: rl.Color,
    origin: f32 = 0,
) -> bool {
    glyphs, ok := shape_place_line(family, font, size, line)
    if !ok {
        return false
    }

    base := cast(f32) x - origin // virtual x of column 0
    pen := cast(f32) x
    for glyph in glyphs {
        if glyph.tab {
            pen = base + tab_stop(pen - base, cast(f32) glyph.advance)
            continue
        }
        if glyph.rect.width > 0 {
            texture := glyph.page > 0 ? fallback_page(family, size, glyph.page) : font.texture
            rl.DrawTextureRec(
                texture,
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
measure_line_shaped :: proc(
    family: ^Font_Family,
    font: rl.Font,
    size: i32,
    line: string,
    origin: f32 = 0,
) -> (f32, bool) {
    glyphs, ok := shape_place_line(family, font, size, line)
    if !ok {
        return 0, false
    }

    pen := origin
    for glyph in glyphs {
        if glyph.tab {
            pen = tab_stop(pen, cast(f32) glyph.advance)
            continue
        }
        pen += cast(f32) glyph.advance
    }
    return pen - origin, true
}

// One cluster of a shaped left-to-right line: the bytes it draws, where it
// starts and how far it advances.
@(private = "file")
Placed_Cluster :: struct {
    start, end: int,
    x, advance: f32,
}

// Walks the clusters of a shaped line in order. False when the line has no
// shaping data or a right-to-left run, whose clusters do not ascend.
@(private = "file")
shape_clusters :: proc(
    family: ^Font_Family,
    font: rl.Font,
    size: i32,
    line: string,
    origin: f32,
    allocator := context.temp_allocator,
) -> ([]Placed_Cluster, bool) {
    glyphs, ok := shape_place_line(family, font, size, line)
    if !ok {
        return nil, false
    }
    clusters := make([dynamic]Placed_Cluster, 0, len(glyphs), allocator)
    pen := origin
    for glyph in glyphs {
        if glyph.rtl {
            return nil, false
        }
        start := pen
        if glyph.tab {
            pen = tab_stop(pen, cast(f32) glyph.advance)
        } else {
            pen += cast(f32) glyph.advance
        }
        at := int(glyph.cluster)
        if n := len(clusters); n > 0 && clusters[n - 1].start == at {
            clusters[n - 1].advance = pen - clusters[n - 1].x
            continue
        }
        if n := len(clusters); n > 0 {
            clusters[n - 1].end = at
        }
        append(&clusters, Placed_Cluster {start = at, end = len(line), x = start - origin, advance = pen - start})
    }
    return clusters[:], true
}

// The x of byte offset `at` in a shaped line. Inside a ligature the offset is
// placed in proportion to the runes before it.
offset_x_shaped :: proc(
    family: ^Font_Family,
    font: rl.Font,
    size: i32,
    line: string,
    at: int,
    origin: f32 = 0,
) -> (x: f32, ok: bool) {
    clusters := shape_clusters(family, font, size, line, origin) or_return
    for cl in clusters {
        if at <= cl.start {
            return cl.x, true
        }
        if at < cl.end {
            part := f32(utf8.rune_count_in_string(line[cl.start:at]))
            whole := f32(max(utf8.rune_count_in_string(line[cl.start:cl.end]), 1))
            return cl.x + cl.advance * part / whole, true
        }
    }
    if len(clusters) == 0 {
        return 0, true
    }
    last := clusters[len(clusters) - 1]
    return last.x + last.advance, true
}

// The rune boundary of a shaped line nearest `x`.
index_at_shaped :: proc(
    family: ^Font_Family,
    font: rl.Font,
    size: i32,
    line: string,
    x: f32,
    origin: f32 = 0,
) -> (index: int, ok: bool) {
    clusters := shape_clusters(family, font, size, line, origin) or_return
    prev, prev_x := 0, f32(0)
    for cl in clusters {
        whole := max(utf8.rune_count_in_string(line[cl.start:cl.end]), 1)
        at := cl.start
        for k in 1 ..= whole {
            if at < cl.end {
                _, n := utf8.decode_rune_in_string(line[at:])
                at += max(n, 1)
            }
            bx := cl.x + cl.advance * f32(k) / f32(whole)
            if bx >= x {
                return x - prev_x > bx - x ? min(at, len(line)) : prev, true
            }
            prev, prev_x = min(at, len(line)), bx
        }
    }
    return len(line), true
}

