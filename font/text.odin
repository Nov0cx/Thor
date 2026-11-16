package font

import "base:runtime"
import "core:c"
import "core:log"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:unicode/utf8"
import stbtt "vendor:stb/truetype"

import "../platform"
import "../prof"

// Fonts are rasterized per size: drawing a bitmap atlas at any size other
// than the one it was baked for gets scaled and turns blurry.

// Rasterizing a glyph atlas is pure CPU work (stb_truetype), done on worker
// threads; only the texture upload needs GL, on the main thread.
@(private = "file")
Font_Load_Job :: struct {
    family:  ^Font_Family,
    size:    i32,
    glyphs:  []Glyph, // font arena
    atlas:   []u8,    // heap, gray-alpha; freed on publish or discard
    atlas_w: i32,
    atlas_h: i32,
    shaped:  map[u32]Shaped_Glyph,
    ok:      bool,
    worker:  ^thread.Thread,
    // The spawning thread's logger: a new thread has none.
    logger:  log.Logger,
    // Set by the worker when the bake ends; pump_async polls it so a
    // prebake job is joined only once finished.
    done:    bool,
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

// One rasterized glyph bitmap before packing: one byte of coverage per pixel.
@(private)
Glyph_Bitmap :: struct {
    value:  rune,
    data:   []u8, // nil for a glyph with no pixels
    width:  i32,
    height: i32,
}

// Row-packs rasterized glyphs into a new grayscale atlas (raylib packMethod 0),
// sized from their total area and grown taller on a row wrap that runs out of
// room. A glyph taller than the nominal row height grows the atlas further
// still; one wider than the atlas itself is skipped with a zero rect rather
// than packed, which would overrun into the next row or past the buffer
// entirely. The atlas is allocated with `allocator`, the rects with
// context.allocator. Returns a nil atlas when an allocation fails.
@(private)
pack_glyph_atlas :: proc(bitmaps: []Glyph_Bitmap, size: i32, family_name: string, allocator := context.allocator) -> (
    atlas: []u8,
    atlas_w, atlas_h: i32,
    rects: []platform.Rect,
) {
    PADDING :: 4

    total_width: i32 = 0
    for b in bitmaps {
        total_width += b.width + 2 * PADDING
    }
    padded_font_size := size + 2 * PADDING
    total_area       := cast(f32)total_width * cast(f32)padded_font_size * 1.2
    image_min_size   := math.sqrt(total_area)
    image_size       := cast(i32)math.pow(2, math.ceil(math.ln(image_min_size) / math.ln(cast(f32)2)))

    atlas_w = image_size
    atlas_h = image_size
    if total_area < cast(f32)((image_size * image_size) / 2) {
        atlas_h = image_size / 2
    }

    // Zeroed: the padding between packed glyphs stays fully transparent.
    err: runtime.Allocator_Error
    atlas, err = make([]u8, int(atlas_w * atlas_h), allocator)
    if err != nil {
        log.errorf("font %s: no memory for a %dx%d atlas", family_name, atlas_w, atlas_h)
        return nil, 0, 0, nil
    }
    rects, err = make([]platform.Rect, len(bitmaps))
    if err != nil {
        log.errorf("font %s: no memory for %d glyph rects", family_name, len(bitmaps))
        delete(atlas, allocator)
        return nil, 0, 0, nil
    }

    offset_x: i32 = PADDING
    offset_y: i32 = PADDING
    // Tallest glyph placed in the current row: a row advances by that, not by
    // the nominal size, or a glyph taller than the row overlaps the next one.
    row_h := size
    for b, k in bitmaps {
        gw, gh := b.width, b.height

        // Wider than a whole row: no wrap ever fits it, and packing it anyway
        // would overrun into the next row or past the buffer. Leaves a zero
        // rect, so this glyph draws nothing instead of corrupting the atlas.
        if gw + 2 * PADDING > atlas_w {
            log.warnf("font %s: glyph %d is %dpx wide, wider than the %dpx atlas; skipped", family_name, b.value, gw, atlas_w)
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
            new_h           := atlas_h * 2
            grown, grow_err := make([]u8, int(atlas_w * new_h), allocator)
            if grow_err != nil {
                log.errorf("font %s: no memory to grow the atlas to %dx%d", family_name, atlas_w, new_h)
                delete(atlas, allocator)
                delete(rects)
                return nil, 0, 0, nil
            }
            copy(grown, atlas)
            delete(atlas, allocator)
            atlas = grown
            atlas_h = new_h
        }

        if b.data != nil {
            for row in 0 ..< gh {
                copy(atlas[(offset_y + row) * atlas_w + offset_x:][:gw], b.data[row * gw:][:gw])
            }
        }

        rects[k] = {x = cast(f32)offset_x, y = cast(f32)offset_y, w = cast(f32)gw, h = cast(f32)gh}
        offset_x += gw + 2 * PADDING
    }

    return
}

// Frees the glyph bitmaps of a bake.
@(private = "file")
free_bitmaps :: proc(bitmaps: []Glyph_Bitmap) {
    for b in bitmaps {
        delete(b.data, runtime.heap_allocator())
    }
    delete(bitmaps, runtime.heap_allocator())
}

@(private = "file")
font_load_worker :: proc(job: ^Font_Load_Job) {
    prof.thread_scope("font load")
    prof.scope("font bake")
    context.logger = job.logger
    font_bake_job(job)
    sync.atomic_store(&job.done, true)
}

// Uploads a baked atlas and records the size. Main thread only: the upload
// needs GL. Writes the shaping map with the font, so a size in `cache` is
// always in `shaped` too — the drawing path skips shaping without it.
@(private = "file")
font_job_publish :: proc(job: ^Font_Load_Job) -> Glyph_Set {
    set := Glyph_Set{size = job.size, glyphs = job.glyphs}
    // Without a window (a test) there is no GL context; the metrics still count.
    if platform.window_ready() {
        if tex, ok := platform.texture_from_pixels(raw_data(job.atlas), job.atlas_w, job.atlas_h, .Gray_Alpha); ok {
            set.texture = tex
        } else {
            log.errorf("font %s: could not upload the %dx%d atlas at size %d", job.family.name, job.atlas_w, job.atlas_h, job.size)
        }
    }
    delete(job.atlas, runtime.heap_allocator())
    job.atlas = nil
    {
        context.allocator = font_allocator
        glyph_set_index(&set)
    }
    job.family.cache[job.size] = set
    job.family.shaped[job.size] = job.shaped
    return set
}

// Rasterizes and packs the atlas with stb_truetype directly: raylib's font
// procs aren't thread-safe, and its LoadFontData binding corrupts memory.
// The bitmaps and the atlas are on the heap; the glyphs go with the font arena.
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

    scale := stbtt.ScaleForPixelHeight(&info, cast(f32)job.size)
    ascent, descent, line_gap: c.int
    stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)

    baked := make([dynamic]Bake_Entry)
    seen  := make(map[u32]bool)
    for cp in job.family.codepoints {
        gid := stbtt.FindGlyphIndex(&info, cp)
        if gid != 0 {
            append(&baked, Bake_Entry{value = cp, gid = cast(u32)gid})
            seen[cast(u32)gid] = true
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
            append(&baked, Bake_Entry{value = -1, gid = gid})
        }
    }

    count              := len(baked)
    glyphs, glyphs_err := make([]Glyph, count)
    if glyphs_err != nil {
        log.errorf("font %s: no memory for %d glyphs", job.family.name, count)
        return
    }
    // A glyph without pixels keeps a nil bitmap and packs as a zero rect.
    bitmaps, bitmaps_err := make([]Glyph_Bitmap, count, runtime.heap_allocator())
    if bitmaps_err != nil {
        log.errorf("font %s: no memory for %d glyph bitmaps", job.family.name, count)
        return
    }

    for entry, k in baked {
        cp    := entry.value
        glyph := &glyphs[k]
        glyph.value = cp
        bitmaps[k].value = cp

        advance: c.int
        stbtt.GetGlyphHMetrics(&info, cast(c.int)entry.gid, &advance, nil)
        glyph.advance = cast(i32)(cast(f32)advance * scale)

        if cp == 0x20 || cp == 0x3000 {
            // Space has no bitmap; give it a blank image so atlas packing
            // reserves its advance width, exactly like raylib does.
            if glyph.advance > 0 {
                // Without the bitmap the space only loses its reserved atlas
                // width; its advance still counts.
                if blank, err := make([]u8, int(glyph.advance * job.size), runtime.heap_allocator()); err == nil {
                    bitmaps[k] = {value = cp, data = blank, width = glyph.advance, height = job.size}
                }
            } else {
                glyph.advance = 0
            }
            continue
        }

        width, height, offset_x, offset_y: c.int
        bitmap := stbtt.GetGlyphBitmap(&info, scale, scale, cast(c.int)entry.gid, &width, &height, &offset_x, &offset_y)
        glyph.offset_x = offset_x
        glyph.offset_y = offset_y + cast(i32)math.round(cast(f32)ascent * scale)

        if bitmap != nil && width > 0 && height > 0 {
            // A failed copy leaves a nil bitmap, so this one glyph draws
            // nothing rather than losing the whole font.
            if data, err := make([]u8, int(width * height), runtime.heap_allocator()); err == nil {
                mem.copy(raw_data(data), bitmap, cast(int)(width * height))
                bitmaps[k] = {value = cp, data = data, width = width, height = height}
            }
        }
        if bitmap != nil {
            stbtt.FreeBitmap(bitmap, nil)
        }
    }

    atlas, atlas_w, atlas_h, rects := pack_glyph_atlas(bitmaps, job.size, job.family.name, runtime.heap_allocator())
    free_bitmaps(bitmaps)
    if atlas == nil {
        return
    }

    // Convert GRAYSCALE to GRAY_ALPHA (gray=255, alpha=coverage).
    gray_alpha, gray_err := make([]u8, len(atlas) * 2, runtime.heap_allocator())
    if gray_err != nil {
        log.errorf("font %s: no memory for the %dx%d gray-alpha atlas", job.family.name, atlas_w, atlas_h)
        delete(atlas, runtime.heap_allocator())
        return
    }
    for coverage, i in atlas {
        gray_alpha[2 * i] = 255
        gray_alpha[2 * i + 1] = coverage
    }
    delete(atlas, runtime.heap_allocator())

    for &glyph, k in glyphs {
        glyph.rect = rects[k]
    }
    job.atlas = gray_alpha
    job.atlas_w = atlas_w
    job.atlas_h = atlas_h
    job.glyphs = glyphs

    job.shaped = make(map[u32]Shaped_Glyph, count)
    for entry, k in baked {
        job.shaped[entry.gid] = Shaped_Glyph{rect = rects[k], offset_x = glyphs[k].offset_x, offset_y = glyphs[k].offset_y, advance = glyphs[k].advance}
    }

    job.ok = true
}

// What the startup load bakes. Empty slices mean everything, which keeps
// headless callers and tests on the full pipeline. Families outside the set
// register without their TTF and bake on first use (get_font) or ahead of a
// picker (prebake_async).
Preload :: struct {
    families:      []string, // text families to bake now; the manifest default is always added
    icon_packs:    []string, // icon families to bake now
    extra_sizes:   []i32,    // extra sizes for every baked text family
    user_manifest: string,   // a second font manifest, loaded after the first; may be absent
}

@(private = "file")
Bootstrap_Args :: struct {
    font_manifest: string,
    icon_manifest: string,
    preload:       Preload,
    // Only the logger is passed: the rest of the caller's context is its own.
    logger:        log.Logger,
}

@(private = "file")
preload_clone :: proc(preload: Preload, allocator: runtime.Allocator) -> Preload {
    clone := Preload{
        families = make([]string, len(preload.families), allocator),
        icon_packs = make([]string, len(preload.icon_packs), allocator),
        extra_sizes = slice.clone(preload.extra_sizes, allocator),
        user_manifest = strings.clone(preload.user_manifest, allocator),
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
    // thread until finish_async_load joins it.
    context.allocator = font_allocator
    context.logger = args.logger

    if !load_font_manifest(args.font_manifest, args.preload.families) {
        log.errorf("Font manifest %q registered no family", args.font_manifest)
    }
    if args.preload.user_manifest != "" && os.exists(args.preload.user_manifest) {
        if !load_font_manifest(args.preload.user_manifest, args.preload.families, optional = true) {
            log.errorf("Font manifest %q registered no family", args.preload.user_manifest)
        }
    }
    if !load_icon_manifest(args.icon_manifest, args.preload.icon_packs) {
        log.errorf("Icon manifest %q registered no family; icons are blank", args.icon_manifest)
    }

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
            job.logger = context.logger
            job.worker = thread.create_and_start_with_poly_data(job, font_load_worker)
            append(&async_jobs, job)
        }
    }

    free_all(context.temp_allocator)
}

// Loads both manifests and rasterizes the preload set at its sizes on worker
// threads. Safe before InitWindow; nothing here touches GL. No measure or
// get_font may run before finish_async_load: the bootstrap thread still
// writes the family table.
begin_async_load :: proc(font_manifest, icon_manifest: string, preload := Preload{}) {
    if arena_err := virtual.arena_init_growing(&font_arena); arena_err != nil {
        log.warnf("Font arena init failed: %v; fonts disabled", arena_err)
        return
    }
    font_allocator = virtual.arena_allocator(&font_arena)

    bootstrap_args = new(Bootstrap_Args, font_allocator)
    bootstrap_args.font_manifest = strings.clone(font_manifest, font_allocator)
    bootstrap_args.icon_manifest = strings.clone(icon_manifest, font_allocator)
    bootstrap_args.preload = preload_clone(preload, font_allocator)
    bootstrap_args.logger = context.logger
    bootstrap_thread = thread.create_and_start_with_poly_data(bootstrap_args, bootstrap_worker)
}

// Joins the loader threads and uploads the atlases as textures.
// Must run on the main thread after InitWindow, before the first frame.
finish_async_load :: proc() {
    if bootstrap_thread != nil {
        thread.join(bootstrap_thread)
        thread.destroy(bootstrap_thread)
        bootstrap_thread = nil
        bootstrap_args = nil
    }
    if font_allocator.procedure != nil {
        fallback_init()
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
get_font :: proc(font_size: i32, family_name := "") -> Glyph_Set {
    name := family_name
    if name == "" {
        name = default_family_name
    }

    family, found := families[name]
    if !found {
        return builtin_set()
    }

    if font, cached := family.cache[font_size]; cached {
        return font
    }

    if !family_ensure_loaded(family) {
        // Recorded so a file that cannot load is tried once, not every frame.
        fallback := builtin_set()
        family.cache[font_size] = fallback
        return fallback
    }

    job := Font_Load_Job{family = family, size = font_size}
    font_bake_job(&job)
    if !job.ok {
        log.warnf("Failed to rasterize font %q at size %d", family.path, font_size)
        // Recorded so a size that cannot bake is tried once, not every frame.
        fallback := builtin_set()
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

// Frees a baked-but-unpublished job's atlas; the rest is arena-owned.
@(private = "file")
prebake_discard :: proc(job: ^Font_Load_Job) {
    delete(job.atlas, runtime.heap_allocator())
    job.atlas = nil
}

// Bakes the missing sizes of `family_names` on worker threads, so a later
// switch (font or icon-pack picker) draws without a main-thread bake. Sizes
// baked are each family's preload_sizes plus `sizes`; cached and in-flight
// ones are skipped. Main thread only; pump_async publishes the results.
// Returns the number of jobs spawned.
prebake_async :: proc(family_names: []string, sizes: []i32 = nil) -> int {
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
            job.logger = context.logger
            job.worker = thread.create_and_start_with_poly_data(job, font_load_worker)
            append(&prebake_jobs, job)
            spawned += 1
        }
    }
    return spawned
}

// Publishes finished prebake atlases; cheap when none are in flight. Main
// thread only (the texture upload needs GL). Returns the number published.
pump_async :: proc() -> int {
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

// Joins and discards every in-flight prebake job. Part of shutdown; runs
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

line_height :: proc(font_size: i32) -> i32 {
    return font_size + 6
}

// Walks `text` glyph by glyph on the codepoint path, scaled from the size the
// set was baked at to `font_size`, and draws it when `draw`. Returns the width.
@(private = "file")
codepoint_run :: proc(set: Glyph_Set, text: string, x, y: f32, font_size: i32, color: platform.Color, draw: bool) -> f32 {
    if len(set.glyphs) == 0 || set.size <= 0 {
        return 0
    }
    scale := f32(font_size) / f32(set.size)
    pen: f32 = 0
    for r in text {
        index, _ := glyph_index(set, r)
        g        := set.glyphs[index]
        if draw && r != ' ' && g.rect.w > 0 && set.texture.id != 0 {
            dst := platform.Rect{x + pen + f32(g.offset_x) * scale, y + f32(g.offset_y) * scale, g.rect.w * scale, g.rect.h * scale}
            platform.draw_texture(set.texture, g.rect, dst, color)
        }
        advance := g.advance != 0 ? f32(g.advance) : g.rect.w
        pen += advance * scale
    }
    return pen
}

// Codepoint-path walk of one line, for a family/size with no shaping data.
// 0x09 is never baked, so a tab would draw '?'; split at the tabs and snap the
// pen to the next stop between the pieces. Measuring and drawing share this,
// so the two cannot drift. Returns the width.
@(private = "file")
fallback_line :: proc(set: Glyph_Set, line: string, x, y: f32, origin: f32, font_size: i32, color: platform.Color, draw: bool) -> f32 {
    // No atlas (a headless run): every width is 0, and a 0 cell makes tab_stop
    // a no-op rather than a null dereference.
    cell: f32 = 0
    if set.size > 0 {
        cell = f32(space_advance(set)) * f32(font_size) / f32(set.size)
    }
    pen  := origin
    rest := line
    for {
        piece := rest
        tab   := strings.index_byte(rest, '\t')
        if tab >= 0 {
            piece = rest[:tab]
        }
        if piece != "" {
            pen += codepoint_run(set, piece, x - origin + pen, y, font_size, color, draw)
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
measure :: proc(text: string, font_size: i32, family := "", tab_origin: i32 = 0, style: Style = {}) -> i32 {
    face, synthetic := resolve_style(family, style)
    name            := face
    if name == "" {
        name = default_family_name
    }
    fam := families[name]

    font := get_font(font_size, face)
    max_width: f32 = 0
    origin := cast(f32)tab_origin
    source := text

    for line in strings.split_lines_iterator(&source) {
        // Shaped path first, exactly like draw: a ligature has one advance
        // instead of the sum raylib measures per codepoint.
        width, shaped := measure_line_shaped(fam, font, font_size, line, origin)
        if !shaped {
            width = fallback_line(font, line, 0, 0, origin, font_size, {}, false)
        }
        if width > max_width {
            max_width = width
        }
        origin = 0 // only the first line starts mid-line
    }

    if max_width == 0 && text != "" {
        max_width = codepoint_run(font, text, 0, 0, font_size, {}, false)
    }

    if max_width > 0 {
        max_width += f32(style_extra(synthetic, font_size))
    }
    return cast(i32)max_width
}

// See measure for `tab_origin`.
draw :: proc(text: string, x, y, font_size: i32, color: platform.Color, family := "", tab_origin: i32 = 0, style: Style = {}) {
    if text == "" {
        return
    }
    face, synthetic := resolve_style(family, style)

    name := face
    if name == "" {
        name = default_family_name
    }
    fam := families[name]

    font   := get_font(font_size, face)
    source := text
    line_y := cast(f32)y
    origin := cast(f32)tab_origin

    for line in strings.split_lines_iterator(&source) {
        // Shaped path first (ligatures); falls back to raylib's codepoint path
        // for sizes without shaping data.
        if !draw_line_shaped(fam, font, font_size, line, x, cast(i32)line_y, color, origin, synthetic) {
            // The codepoint path has no glyph quads to shear, so it keeps bold only.
            passes := .Bold in synthetic ? bold_extra(font_size) : 0
            for pass in 0 ..= passes {
                fallback_line(font, line, f32(x + pass), line_y, origin, font_size, color, true)
            }
        }
        line_y += cast(f32)line_height(font_size)
        origin = 0
    }
}

// The x of byte offset `at` in one line of text. Right across a ligature,
// where measuring the prefix on its own is not.
offset_at :: proc(text: string, at: int, font_size: i32, family := "", tab_origin: i32 = 0) -> f32 {
    i    := clamp(at, 0, len(text))
    name := family != "" ? family : default_family_name
    font := get_font(font_size, family)
    if x, ok := offset_x_shaped(families[name], font, font_size, text, i, cast(f32)tab_origin); ok {
        return x
    }
    return f32(measure(text[:i], font_size, family, tab_origin))
}

// The rune boundary in one line of text nearest `x`, rounded to the closer side.
index_at :: proc(text: string, x: f32, font_size: i32, family := "", tab_origin: i32 = 0) -> int {
    if text == "" || x <= 0 {
        return 0
    }
    name := family != "" ? family : default_family_name
    font := get_font(font_size, family)
    if index, ok := index_at_shaped(families[name], font, font_size, text, x, cast(f32)tab_origin); ok {
        return index
    }
    prev, prev_w := 0, f32(0)
    i := 0
    for i < len(text) {
        _, n := utf8.decode_rune_in_string(text[i:])
        i += max(n, 1)
        w := f32(measure(text[:i], font_size, family, tab_origin))
        if w >= x {
            return x - prev_w > w - x ? i : prev
        }
        prev, prev_w = i, w
    }
    return len(text)
}
