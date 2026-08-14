package ui

import "core:c"
import "core:log"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:thread"
import rl "vendor:raylib"
import stbtt "vendor:stb/truetype"

// Fonts are rasterized per size: drawing a bitmap atlas at any size other
// than the one it was baked for gets scaled and turns blurry.

// Rasterizing a glyph atlas is pure CPU work (stb_truetype), done on worker
// threads; only the texture upload needs GL, on the main thread.
@(private = "file")
Font_Load_Job :: struct {
    family:      ^Font_Family,
    size:        i32,
    glyphs:      [^]rl.GlyphInfo,
    recs:        [^]rl.Rectangle,
    glyph_count: i32,
    atlas:       rl.Image,
    shaped:      map[u32]Shaped_Glyph,
    ok:          bool,
    worker:      ^thread.Thread,
}

// One glyph scheduled for rasterization: cmap glyphs carry their codepoint;
// ligature glyphs found by shaping carry -1, reachable only via the shaped map.
@(private = "file")
Bake_Entry :: struct {
    value: rune,
    gid:   u32,
}

@(private = "file")
async_jobs: [dynamic]^Font_Load_Job

// Row-packs `count` rasterized glyphs into a freshly allocated grayscale
// atlas (raylib packMethod 0), sized from their total area and grown taller
// on a row wrap that runs out of room. A glyph taller than the nominal row
// height grows the atlas further still; one wider than the atlas itself is
// skipped with a zero rect rather than packed, which would overrun into the
// next row or past the buffer entirely. Caller frees atlas_data and recs
// with rl.MemFree.
@(private)
pack_glyph_atlas :: proc(glyphs: [^]rl.GlyphInfo, count: int, size: i32, family_name: string) -> (atlas_data: [^]u8, atlas_w, atlas_h: c.int, recs: [^]rl.Rectangle) {
    PADDING :: 4

    total_width: c.int = 0
    for k in 0 ..< count {
        total_width += glyphs[k].image.width + 2 * PADDING
    }
    padded_font_size := size + 2 * PADDING
    total_area := cast(f32) total_width * cast(f32) padded_font_size * 1.2
    image_min_size := math.sqrt(total_area)
    image_size := cast(c.int) math.pow(2, math.ceil(math.ln(image_min_size) / math.ln(cast(f32) 2)))

    atlas_w = image_size
    atlas_h = image_size
    if total_area < cast(f32) ((image_size * image_size) / 2) {
        atlas_h = image_size / 2
    }

    // Zeroed: the padding between packed glyphs stays fully transparent.
    atlas_data = cast([^]u8) rl.MemAlloc(cast(c.uint) (atlas_w * atlas_h))
    mem.zero(atlas_data, cast(int) (atlas_w * atlas_h))
    recs = cast([^]rl.Rectangle) rl.MemAlloc(cast(c.uint) (count * size_of(rl.Rectangle)))

    offset_x: c.int = PADDING
    offset_y: c.int = PADDING
    for k in 0 ..< count {
        glyph := glyphs[k]
        gw, gh := glyph.image.width, glyph.image.height

        // Wider than a whole row: no wrap ever fits it, and packing it anyway
        // would overrun into the next row or past the buffer. Leaves a zero
        // rect, so this glyph draws nothing instead of corrupting the atlas.
        if gw + 2 * PADDING > atlas_w {
            log.warnf("font %s: glyph %d is %dpx wide, wider than the %dpx atlas; skipped", family_name, glyph.value, gw, atlas_w)
            recs[k] = rl.Rectangle{}
            continue
        }

        if offset_x >= atlas_w - gw - 2 * PADDING {
            offset_x = PADDING
            offset_y += size + 2 * PADDING
        }

        // Grow past whichever is taller: the nominal row height or this
        // glyph's own bitmap (an accent or icon glyph can exceed size).
        // Loops since one doubling may still be short for a very tall glyph;
        // checked every row, not only a wrap, so a tall first glyph is covered.
        for offset_y + max(size, gh) + PADDING > atlas_h {
            new_h := atlas_h * 2
            new_data := cast([^]u8) rl.MemAlloc(cast(c.uint) (atlas_w * new_h))
            mem.copy(new_data, atlas_data, cast(int) (atlas_w * atlas_h))
            mem.zero(&new_data[atlas_w * atlas_h], cast(int) (atlas_w * (new_h - atlas_h)))
            rl.MemFree(atlas_data)
            atlas_data = new_data
            atlas_h = new_h
        }

        if glyph.image.data != nil {
            src := cast([^]u8) glyph.image.data
            for row in 0 ..< gh {
                mem.copy(
                    &atlas_data[(offset_y + row) * atlas_w + offset_x],
                    &src[row * gw],
                    cast(int) gw,
                )
            }
        }

        recs[k] = rl.Rectangle {
            x = cast(f32) offset_x,
            y = cast(f32) offset_y,
            width = cast(f32) gw,
            height = cast(f32) gh,
        }
        offset_x += gw + 2 * PADDING
    }

    return
}

@(private = "file")
font_load_worker :: proc(job: ^Font_Load_Job) {
    font_bake_job(job)
}

// Uploads a baked atlas and records the size. Main thread only: the upload
// needs GL. Writes the shaping map with the font, so a size in `cache` is
// always in `shaped` too — the drawing path skips shaping without it.
@(private = "file")
font_job_publish :: proc(job: ^Font_Load_Job) -> rl.Font {
    font := rl.Font {
        baseSize = job.size,
        glyphCount = job.glyph_count,
        glyphPadding = 4,
        glyphs = job.glyphs,
        recs = job.recs,
        texture = rl.LoadTextureFromImage(job.atlas),
    }
    rl.UnloadImage(job.atlas)
    job.family.cache[job.size] = font
    job.family.shaped[job.size] = job.shaped
    return font
}

// Rasterizes and packs the atlas with stb_truetype directly: raylib's font
// procs aren't thread-safe, and its LoadFontData binding corrupts memory.
// Buffers handed to raylib are libc-allocated so UnloadFont/UnloadImage free them.
// Touches no GL, so it runs on a worker thread at startup and inline on the
// main thread for a size the manifest never named.
@(private = "file")
font_bake_job :: proc(job: ^Font_Load_Job) {
    // Scratch goes into the font arena; its allocator is mutex-guarded, shareable.
    context.allocator = font_allocator

    file_data := job.family.file_data
    info: stbtt.fontinfo
    if !stbtt.InitFont(&info, raw_data(file_data), stbtt.GetFontOffsetForIndex(raw_data(file_data), 0)) {
        return
    }

    scale := stbtt.ScaleForPixelHeight(&info, cast(f32) job.size)
    ascent, descent, line_gap: c.int
    stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)

    baked := make([dynamic]Bake_Entry)
    seen := make(map[u32]bool)
    for cp in job.family.codepoints {
        gid := stbtt.FindGlyphIndex(&info, cp)
        if gid != 0 {
            append(&baked, Bake_Entry {value = cp, gid = cast(u32) gid})
            seen[cast(u32) gid] = true
        }
    }
    if len(baked) == 0 {
        return
    }

    // Ligature glyphs reach only through shaping; probe common sequences and
    // bake the new glyph ids. Icon fonts have none, so skip them.
    if !job.family.icon_font {
        for gid in shape_collect_ligature_glyphs(file_data, &seen) {
            append(&baked, Bake_Entry {value = -1, gid = gid})
        }
    }

    count := len(baked)
    glyphs := cast([^]rl.GlyphInfo) rl.MemAlloc(cast(c.uint) (count * size_of(rl.GlyphInfo)))
    // A glyph without a bitmap keeps its zeroed image; the packer tests image.data.
    mem.zero(glyphs, count * size_of(rl.GlyphInfo))

    for entry, k in baked {
        cp := entry.value
        glyph := &glyphs[k]
        glyph.value = cp

        advance: c.int
        stbtt.GetGlyphHMetrics(&info, cast(c.int) entry.gid, &advance, nil)
        glyph.advanceX = cast(c.int) (cast(f32) advance * scale)

        if cp == 0x20 || cp == 0x3000 {
            // Space has no bitmap; give it a blank image so atlas packing
            // reserves its advance width, exactly like raylib does.
            if glyph.advanceX > 0 {
                blank := rl.MemAlloc(cast(c.uint) (glyph.advanceX * job.size))
                mem.zero(blank, cast(int) (glyph.advanceX * job.size))
                glyph.image = rl.Image {
                    data = blank,
                    width = glyph.advanceX,
                    height = job.size,
                    mipmaps = 1,
                    format = .UNCOMPRESSED_GRAYSCALE,
                }
            } else {
                glyph.advanceX = 0
            }
            continue
        }

        width, height, offset_x, offset_y: c.int
        bitmap := stbtt.GetGlyphBitmap(&info, scale, scale, cast(c.int) entry.gid, &width, &height, &offset_x, &offset_y)
        glyph.offsetX = offset_x
        glyph.offsetY = offset_y + cast(c.int) (cast(f32) ascent * scale)

        if bitmap != nil && width > 0 && height > 0 {
            data := rl.MemAlloc(cast(c.uint) (width * height))
            mem.copy(data, bitmap, cast(int) (width * height))
            glyph.image = rl.Image {
                data = data,
                width = width,
                height = height,
                mipmaps = 1,
                format = .UNCOMPRESSED_GRAYSCALE,
            }
        }
        if bitmap != nil {
            stbtt.FreeBitmap(bitmap, nil)
        }
    }

    atlas_data, atlas_w, atlas_h, recs := pack_glyph_atlas(glyphs, count, job.size, job.family.name)

    // Convert GRAYSCALE to GRAY_ALPHA (gray=255, alpha=coverage).
    pixel_count := cast(int) (atlas_w * atlas_h)
    gray_alpha := cast([^]u8) rl.MemAlloc(cast(c.uint) (pixel_count * 2))
    for i in 0 ..< pixel_count {
        gray_alpha[2 * i] = 255
        gray_alpha[2 * i + 1] = atlas_data[i]
    }
    rl.MemFree(atlas_data)

    job.atlas = rl.Image {
        data = gray_alpha,
        width = atlas_w,
        height = atlas_h,
        mipmaps = 1,
        format = .UNCOMPRESSED_GRAY_ALPHA,
    }
    job.glyphs = glyphs
    job.recs = recs
    job.glyph_count = cast(i32) count

    job.shaped = make(map[u32]Shaped_Glyph, count)
    for entry, k in baked {
        job.shaped[entry.gid] = Shaped_Glyph {
            rect = recs[k],
            offset_x = cast(i32) glyphs[k].offsetX,
            offset_y = cast(i32) glyphs[k].offsetY,
            advance = cast(i32) glyphs[k].advanceX,
        }
    }

    job.ok = true
}

@(private = "file")
Bootstrap_Args :: struct {
    font_manifest: string,
    icon_manifest: string,
}

@(private = "file")
bootstrap_thread: ^thread.Thread

@(private = "file")
bootstrap_args: ^Bootstrap_Args

// Manifest parsing and TTF reads are pure CPU/IO work, so they run on the
// loader thread; the main thread only pays for spawning it.
@(private = "file")
bootstrap_worker :: proc(args: ^Bootstrap_Args) {
    // Persistent font allocations land in the arena, touched only by this
    // thread until text_finish_async_load joins it.
    context.allocator = font_allocator

    when ODIN_DEBUG {
        context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
        defer log.destroy_console_logger(context.logger)
    }

    text_load_font_manifest(args.font_manifest)
    text_load_icon_manifest(args.icon_manifest)

    for _, family in families {
        for size in family.preload_sizes {
            job := new(Font_Load_Job)
            job.family = family
            job.size = size
            job.worker = thread.create_and_start_with_poly_data(job, font_load_worker)
            append(&async_jobs, job)
        }
    }

    free_all(context.temp_allocator)
}

// Loads both manifests and rasterizes every family at its preload sizes on
// worker threads. Safe before InitWindow; nothing here touches GL.
text_begin_async_load :: proc(font_manifest, icon_manifest: string) {
    if arena_err := virtual.arena_init_growing(&font_arena); arena_err != nil {
        log.warnf("Font arena init failed: %v; fonts disabled", arena_err)
        return
    }
    font_allocator = virtual.arena_allocator(&font_arena)

    bootstrap_args = new(Bootstrap_Args, font_allocator)
    bootstrap_args.font_manifest = strings.clone(font_manifest, font_allocator)
    bootstrap_args.icon_manifest = strings.clone(icon_manifest, font_allocator)
    bootstrap_thread = thread.create_and_start_with_poly_data(bootstrap_args, bootstrap_worker)
}

// Joins the loader threads and uploads the atlases as textures.
// Must run on the main thread after InitWindow, before the first frame.
text_finish_async_load :: proc() {
    if bootstrap_thread != nil {
        thread.join(bootstrap_thread)
        thread.destroy(bootstrap_thread)
        bootstrap_thread = nil
        bootstrap_args = nil
    }

    for job in async_jobs {
        thread.join(job.worker)
        thread.destroy(job.worker)

        if job.ok {
            font_job_publish(job)
        } else {
            log.warnf("Failed to rasterize font %q at size %d", job.family.path, job.size)
        }
    }
    // Job records and the array itself are arena-owned; freed at shutdown.
    async_jobs = nil

    for _, family in families {
        shape_family_init(family)
    }

    if len(families) == 0 {
        log.warn("No font families registered, using raylib default font")
    }
}

// Sizes not preloaded at startup are baked on first use from the resident file
// data, the same way as a preloaded one: `preload_sizes` only decides what is
// ready before the first frame, never what shapes. Runs on the main thread
// (texture upload needs GL).
get_font :: proc(font_size: i32, family_name := "") -> rl.Font {
    name := family_name
    if name == "" {
        name = default_family_name
    }

    family, found := families[name]
    if !found {
        return rl.GetFontDefault()
    }

    if font, cached := family.cache[font_size]; cached {
        return font
    }

    job := Font_Load_Job{family = family, size = font_size}
    font_bake_job(&job)
    if !job.ok {
        log.warnf("Failed to rasterize font %q at size %d", family.path, font_size)
        // Recorded so a size that cannot bake is tried once, not every frame.
        fallback := rl.GetFontDefault()
        family.cache[font_size] = fallback
        return fallback
    }
    return font_job_publish(&job)
}

text_line_height :: proc(font_size: i32) -> i32 {
    return font_size + 6
}

// How much of a line the caller's stack scratch holds, NUL included. A label is
// far shorter; a longer one still draws, off the temp allocator.
@(private = "file")
LINE_SCRATCH :: 1024

// The text as a cstring the raylib procs take, in the caller's buffer. Only a
// line too long for it allocates.
@(private = "file")
line_cstring :: proc(text: string, buffer: []u8) -> cstring {
    if len(text) + 1 > len(buffer) {
        return strings.clone_to_cstring(text, context.temp_allocator)
    }
    copy(buffer, text)
    buffer[len(text)] = 0
    return cast(cstring) raw_data(buffer)
}

// Codepoint-path walk of one line, for a family/size with no shaping data.
// raylib has no tab handling and 0x09 is never baked, so a tab would draw '?';
// split at the tabs and snap the pen to the next stop between the pieces.
// Measuring and drawing share this, so the two cannot drift. Returns the width.
@(private = "file")
fallback_line :: proc(
    font: rl.Font,
    line: string,
    x, y: f32,
    origin: f32,
    font_size: i32,
    color: rl.Color,
    draw: bool,
) -> f32 {
    scratch: [LINE_SCRATCH]u8
    // No atlas (a headless run): every width is 0, and a 0 cell makes tab_stop
    // a no-op rather than a null dereference.
    cell: f32 = 0
    if font.glyphs != nil && font.glyphCount > 0 {
        cell = cast(f32) font.glyphs[rl.GetGlyphIndex(font, ' ')].advanceX
    }
    pen := origin
    rest := line
    for {
        piece := rest
        tab := strings.index_byte(rest, '\t')
        if tab >= 0 {
            piece = rest[:tab]
        }
        if piece != "" {
            if draw {
                rl.DrawTextEx(
                    font,
                    line_cstring(piece, scratch[:]),
                    rl.Vector2 {x - origin + pen, y},
                    cast(f32) font_size,
                    0,
                    color,
                )
            }
            pen += rl.MeasureTextEx(font, line_cstring(piece, scratch[:]), cast(f32) font_size, 0).x
        }
        if tab < 0 {
            break
        }
        pen = tab_stop(pen, cell)
        rest = rest[tab + 1:]
    }
    return pen - origin
}

// `tab_origin` is the pixel distance from the line origin to the start of
// `text`, for a caller measuring one line in pieces. It applies to the first
// line only, so pass single-line text with a non-zero origin.
measure_text :: proc(text: string, font_size: i32, family := "", tab_origin: i32 = 0) -> i32 {
    name := family
    if name == "" {
        name = default_family_name
    }
    fam := families[name]

    font := get_font(font_size, family)
    max_width: f32 = 0
    origin := cast(f32) tab_origin
    source := text

    for line in strings.split_lines_iterator(&source) {
        // Shaped path first, exactly like draw_text: a ligature has one advance
        // instead of the sum raylib measures per codepoint.
        width, shaped := measure_line_shaped(fam, font, font_size, line, origin)
        if !shaped {
            width = fallback_line(font, line, 0, 0, origin, font_size, rl.BLANK, false)
        }
        if width > max_width {
            max_width = width
        }
        origin = 0 // only the first line starts mid-line
    }

    if max_width == 0 && text != "" {
        scratch: [LINE_SCRATCH]u8
        size := rl.MeasureTextEx(font, line_cstring(text, scratch[:]), cast(f32) font_size, 0)
        max_width = size.x
    }

    return cast(i32) max_width
}

// Breaks `text` into lines no wider than `max_width`, at spaces. An embedded
// newline always breaks; a single word wider than the limit keeps its own line
// instead of being dropped. Lines point into `text`, so they live as long as it
// does; only the slice is allocated.
wrap_text :: proc(
    text: string,
    max_width: f32,
    font_size: i32,
    family := "",
    allocator := context.temp_allocator,
) -> []string {
    lines := make([dynamic]string, allocator)
    source := text

    for paragraph in strings.split_lines_iterator(&source) {
        if paragraph == "" {
            append(&lines, paragraph)
            continue
        }

        line_start := 0
        // Byte after the last word placed on the current line, so a break drops
        // the space between the two words instead of leading the next line.
        line_end := 0
        word_start := 0

        for i := 0; i <= len(paragraph); i += 1 {
            if i < len(paragraph) && paragraph[i] != ' ' {
                continue
            }

            word_end := i
            candidate := paragraph[line_start:word_end]
            if line_end > line_start && cast(f32) measure_text(candidate, font_size, family) > max_width {
                append(&lines, paragraph[line_start:line_end])
                line_start = word_start
            }
            line_end = word_end
            word_start = i + 1
        }

        append(&lines, paragraph[line_start:line_end])
    }

    return lines[:]
}

// See measure_text for `tab_origin`.
draw_text :: proc(text: string, x, y, font_size: i32, color: rl.Color, family := "", tab_origin: i32 = 0) {
    if text == "" {
        return
    }

    name := family
    if name == "" {
        name = default_family_name
    }
    fam := families[name]

    font := get_font(font_size, family)
    source := text
    line_y := cast(f32) y
    origin := cast(f32) tab_origin

    for line in strings.split_lines_iterator(&source) {
        // Shaped path first (ligatures); falls back to raylib's codepoint path
        // for sizes without shaping data.
        if !draw_line_shaped(fam, font, font_size, line, x, cast(i32) line_y, color, origin) {
            fallback_line(font, line, cast(f32) x, line_y, origin, font_size, color, true)
        }
        line_y += cast(f32) text_line_height(font_size)
        origin = 0
    }
}
