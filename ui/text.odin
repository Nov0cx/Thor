package ui

import "base:runtime"
import "core:c"
import "core:log"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
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
    // Set by the worker when the bake ends; text_pump_async polls it so a
    // prebake job is joined only once finished.
    done:        bool,
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
// with rl.MemFree. Returns a nil atlas_data when an allocation fails.
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
    if atlas_data == nil {
        log.errorf("font %s: no memory for a %dx%d atlas", family_name, atlas_w, atlas_h)
        return nil, 0, 0, nil
    }
    mem.zero(atlas_data, cast(int) (atlas_w * atlas_h))
    recs = cast([^]rl.Rectangle) rl.MemAlloc(cast(c.uint) (count * size_of(rl.Rectangle)))
    if recs == nil {
        log.errorf("font %s: no memory for %d glyph rects", family_name, count)
        rl.MemFree(atlas_data)
        return nil, 0, 0, nil
    }

    offset_x: c.int = PADDING
    offset_y: c.int = PADDING
    // Tallest glyph placed in the current row: a row advances by that, not by
    // the nominal size, or a glyph taller than the row overlaps the next one.
    row_h := size
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
            offset_y += row_h + 2 * PADDING
            row_h = size
        }
        row_h = max(row_h, gh)

        // Grow past whichever is taller: the nominal row height or this
        // glyph's own bitmap (an accent or icon glyph can exceed size).
        // Loops since one doubling may still be short for a very tall glyph;
        // checked every row, not only a wrap, so a tall first glyph is covered.
        for offset_y + row_h + PADDING > atlas_h {
            new_h := atlas_h * 2
            new_data := cast([^]u8) rl.MemAlloc(cast(c.uint) (atlas_w * new_h))
            if new_data == nil {
                log.errorf("font %s: no memory to grow the atlas to %dx%d", family_name, atlas_w, new_h)
                rl.MemFree(atlas_data)
                rl.MemFree(recs)
                return nil, 0, 0, nil
            }
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

// Frees baked glyphs and their bitmaps. Used only before a font is published;
// after that rl.UnloadFont does the same walk.
@(private = "file")
free_glyphs :: proc(glyphs: [^]rl.GlyphInfo, count: int) {
    for k in 0 ..< count {
        if glyphs[k].image.data != nil {
            rl.MemFree(glyphs[k].image.data)
        }
    }
    rl.MemFree(glyphs)
}

@(private = "file")
font_load_worker :: proc(job: ^Font_Load_Job) {
    font_bake_job(job)
    sync.atomic_store(&job.done, true)
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

    // Ligature glyphs reach only through shaping. The probe set is per family,
    // not per size, so it is collected once; it is empty for an icon font.
    shape_family_probe_ligatures(job.family)
    for gid in job.family.ligature_gids {
        if !seen[gid] {
            seen[gid] = true
            append(&baked, Bake_Entry {value = -1, gid = gid})
        }
    }

    count := len(baked)
    glyphs := cast([^]rl.GlyphInfo) rl.MemAlloc(cast(c.uint) (count * size_of(rl.GlyphInfo)))
    if glyphs == nil {
        log.errorf("font %s: no memory for %d glyphs", job.family.name, count)
        return
    }
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
                // Without the image the space keeps its zeroed one and only
                // loses its reserved atlas width; its advance still counts.
                if blank := rl.MemAlloc(cast(c.uint) (glyph.advanceX * job.size)); blank != nil {
                    mem.zero(blank, cast(int) (glyph.advanceX * job.size))
                    glyph.image = rl.Image {
                        data = blank,
                        width = glyph.advanceX,
                        height = job.size,
                        mipmaps = 1,
                        format = .UNCOMPRESSED_GRAYSCALE,
                    }
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
            // A failed copy leaves the zeroed image, so this one glyph draws
            // nothing rather than losing the whole font.
            if data := rl.MemAlloc(cast(c.uint) (width * height)); data != nil {
                mem.copy(data, bitmap, cast(int) (width * height))
                glyph.image = rl.Image {
                    data = data,
                    width = width,
                    height = height,
                    mipmaps = 1,
                    format = .UNCOMPRESSED_GRAYSCALE,
                }
            }
        }
        if bitmap != nil {
            stbtt.FreeBitmap(bitmap, nil)
        }
    }

    atlas_data, atlas_w, atlas_h, recs := pack_glyph_atlas(glyphs, count, job.size, job.family.name)
    if atlas_data == nil {
        free_glyphs(glyphs, count)
        return
    }

    // Convert GRAYSCALE to GRAY_ALPHA (gray=255, alpha=coverage).
    pixel_count := cast(int) (atlas_w * atlas_h)
    gray_alpha := cast([^]u8) rl.MemAlloc(cast(c.uint) (pixel_count * 2))
    if gray_alpha == nil {
        log.errorf("font %s: no memory for the %dx%d gray-alpha atlas", job.family.name, atlas_w, atlas_h)
        rl.MemFree(atlas_data)
        rl.MemFree(recs)
        free_glyphs(glyphs, count)
        return
    }
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

// What the startup load bakes. Empty slices mean everything, which keeps
// headless callers and tests on the full pipeline. Families outside the set
// register without their TTF and bake on first use (get_font) or ahead of a
// picker (text_prebake_async).
Text_Preload :: struct {
    families:    []string, // text families to bake now; the manifest default is always added
    icon_packs:  []string, // icon families to bake now
    extra_sizes: []i32,    // extra sizes for every baked text family
}

@(private = "file")
Bootstrap_Args :: struct {
    font_manifest: string,
    icon_manifest: string,
    preload:       Text_Preload,
}

@(private = "file")
preload_clone :: proc(preload: Text_Preload, allocator: runtime.Allocator) -> Text_Preload {
    clone := Text_Preload {
        families    = make([]string, len(preload.families), allocator),
        icon_packs  = make([]string, len(preload.icon_packs), allocator),
        extra_sizes = slice.clone(preload.extra_sizes, allocator),
    }
    for name, i in preload.families {
        clone.families[i] = strings.clone(name, allocator)
    }
    for name, i in preload.icon_packs {
        clone.icon_packs[i] = strings.clone(name, allocator)
    }
    return clone
}

// A baked text family covers its manifest sizes plus the caller's extras (the
// configured font_size, the welcome title); icon fonts keep their own sizes.
@(private = "file")
bake_sizes :: proc(family: ^Font_Family, extra: []i32) -> []i32 {
    sizes := make([dynamic]i32, context.temp_allocator)
    append(&sizes, ..family.preload_sizes)
    if !family.icon_font {
        for size in extra {
            if size > 0 && !slice.contains(sizes[:], size) {
                append(&sizes, size)
            }
        }
    }
    return sizes[:]
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

    text_load_font_manifest(args.font_manifest, args.preload.families)
    text_load_icon_manifest(args.icon_manifest, args.preload.icon_packs)

    for _, family in families {
        // Outside the preload set: registered for the pickers, baked on first use.
        if len(family.file_data) == 0 {
            continue
        }
        // Probe here, on one thread: the per-size jobs below share the result
        // and would otherwise race to write it.
        shape_family_probe_ligatures(family)
        for size in bake_sizes(family, args.preload.extra_sizes) {
            job := new(Font_Load_Job)
            job.family = family
            job.size = size
            job.worker = thread.create_and_start_with_poly_data(job, font_load_worker)
            append(&async_jobs, job)
        }
    }

    free_all(context.temp_allocator)
}

// Loads both manifests and rasterizes the preload set at its sizes on worker
// threads. Safe before InitWindow; nothing here touches GL. No measure_text or
// get_font may run before text_finish_async_load: the bootstrap thread still
// writes the family table.
text_begin_async_load :: proc(font_manifest, icon_manifest: string, preload := Text_Preload{}) {
    if arena_err := virtual.arena_init_growing(&font_arena); arena_err != nil {
        log.warnf("Font arena init failed: %v; fonts disabled", arena_err)
        return
    }
    font_allocator = virtual.arena_allocator(&font_arena)

    bootstrap_args = new(Bootstrap_Args, font_allocator)
    bootstrap_args.font_manifest = strings.clone(font_manifest, font_allocator)
    bootstrap_args.icon_manifest = strings.clone(icon_manifest, font_allocator)
    bootstrap_args.preload = preload_clone(preload, font_allocator)
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

    if !family_ensure_loaded(family) {
        // Recorded so a file that cannot load is tried once, not every frame.
        fallback := rl.GetFontDefault()
        family.cache[font_size] = fallback
        return fallback
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
    font := font_job_publish(&job)
    // A family loaded lazily gets its draw-time shaping font with its first bake.
    shape_family_init(family)
    return font
}

@(private = "file")
prebake_jobs: [dynamic]^Font_Load_Job

@(private = "file")
prebake_pending :: proc(family: ^Font_Family, size: i32) -> bool {
    for job in prebake_jobs {
        if job.family == family && job.size == size {
            return true
        }
    }
    return false
}

// Frees a baked-but-unpublished job's raylib buffers; Odin-side memory is
// arena-owned.
@(private = "file")
prebake_discard :: proc(job: ^Font_Load_Job) {
    rl.UnloadImage(job.atlas)
    rl.MemFree(job.recs)
    free_glyphs(job.glyphs, cast(int) job.glyph_count)
}

// Bakes the missing sizes of `family_names` on worker threads, so a later
// switch (font or icon-pack picker) draws without a main-thread bake. Sizes
// baked are each family's preload_sizes plus `sizes`; cached and in-flight
// ones are skipped. Main thread only; text_pump_async publishes the results.
// Returns the number of jobs spawned.
text_prebake_async :: proc(family_names: []string, sizes: []i32 = nil) -> int {
    if font_allocator.procedure == nil {
        return 0
    }
    // The probe below allocates the family's ligature gids; they live as long
    // as the family, so they go in the arena.
    context.allocator = font_allocator
    spawned := 0
    for name in family_names {
        family, found := families[name]
        if !found || !family_ensure_loaded(family) {
            continue
        }
        // Probed before the spawn, same as the bootstrap thread: the workers
        // share the result and must never write it.
        shape_family_probe_ligatures(family)
        for size in bake_sizes(family, sizes) {
            if _, cached := family.cache[size]; cached {
                continue
            }
            if prebake_pending(family, size) {
                continue
            }
            if prebake_jobs == nil {
                prebake_jobs = make([dynamic]^Font_Load_Job, font_allocator)
            }
            job := new(Font_Load_Job, font_allocator)
            job.family = family
            job.size = size
            job.worker = thread.create_and_start_with_poly_data(job, font_load_worker)
            append(&prebake_jobs, job)
            spawned += 1
        }
    }
    return spawned
}

// Publishes finished prebake atlases; cheap when none are in flight. Main
// thread only (the texture upload needs GL). Returns the number published.
text_pump_async :: proc() -> int {
    published := 0
    for i := 0; i < len(prebake_jobs); {
        job := prebake_jobs[i]
        if !sync.atomic_load(&job.done) {
            i += 1
            continue
        }
        thread.join(job.worker)
        thread.destroy(job.worker)
        if !job.ok {
            log.warnf("Failed to rasterize font %q at size %d", job.family.path, job.size)
        } else if _, cached := job.family.cache[job.size]; cached {
            // A sync bake (get_font) won the race; drop the duplicate.
            prebake_discard(job)
        } else {
            font_job_publish(job)
            shape_family_init(job.family)
            published += 1
        }
        unordered_remove(&prebake_jobs, i)
    }
    return published
}

// Joins and discards every in-flight prebake job. Part of text_shutdown; runs
// before the family teardown so no worker outlives the arena.
@(private)
prebake_drain :: proc() {
    for job in prebake_jobs {
        thread.join(job.worker)
        thread.destroy(job.worker)
        if job.ok {
            prebake_discard(job)
        }
    }
    prebake_jobs = nil
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
