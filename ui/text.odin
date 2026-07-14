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

// Rasterizes and packs the atlas with stb_truetype directly: raylib's font
// procs aren't thread-safe, and its LoadFontData binding corrupts memory.
// Buffers handed to raylib are libc-allocated so UnloadFont/UnloadImage free them.
@(private = "file")
font_load_worker :: proc(job: ^Font_Load_Job) {
    // Scratch goes into the font arena; its allocator is mutex-guarded, shareable.
    context.allocator = font_allocator

    PADDING :: 4

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
                glyph.image = rl.Image {
                    data = rl.MemAlloc(cast(c.uint) (glyph.advanceX * job.size)),
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

    // Row-pack the glyphs into a grayscale atlas (raylib packMethod 0).
    total_width: c.int = 0
    for k in 0 ..< count {
        total_width += glyphs[k].image.width + 2 * PADDING
    }
    padded_font_size := job.size + 2 * PADDING
    total_area := cast(f32) total_width * cast(f32) padded_font_size * 1.2
    image_min_size := math.sqrt(total_area)
    image_size := cast(c.int) math.pow(2, math.ceil(math.ln(image_min_size) / math.ln(cast(f32) 2)))

    atlas_w := image_size
    atlas_h := image_size
    if total_area < cast(f32) ((image_size * image_size) / 2) {
        atlas_h = image_size / 2
    }

    atlas_data := cast([^]u8) rl.MemAlloc(cast(c.uint) (atlas_w * atlas_h))
    recs := cast([^]rl.Rectangle) rl.MemAlloc(cast(c.uint) (count * size_of(rl.Rectangle)))

    offset_x: c.int = PADDING
    offset_y: c.int = PADDING
    for k in 0 ..< count {
        glyph := glyphs[k]

        if offset_x >= atlas_w - glyph.image.width - 2 * PADDING {
            offset_x = PADDING
            offset_y += job.size + 2 * PADDING

            if offset_y > atlas_h - job.size - PADDING {
                new_h := atlas_h * 2
                new_data := cast([^]u8) rl.MemAlloc(cast(c.uint) (atlas_w * new_h))
                mem.copy(new_data, atlas_data, cast(int) (atlas_w * atlas_h))
                rl.MemFree(atlas_data)
                atlas_data = new_data
                atlas_h = new_h
            }
        }

        if glyph.image.data != nil {
            src := cast([^]u8) glyph.image.data
            for row in 0 ..< glyph.image.height {
                mem.copy(
                    &atlas_data[(offset_y + row) * atlas_w + offset_x],
                    &src[row * glyph.image.width],
                    cast(int) glyph.image.width,
                )
            }
        }

        recs[k] = rl.Rectangle {
            x = cast(f32) offset_x,
            y = cast(f32) offset_y,
            width = cast(f32) glyph.image.width,
            height = cast(f32) glyph.image.height,
        }
        offset_x += glyph.image.width + 2 * PADDING
    }

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

// Sizes not preloaded at startup are rasterized on first use from the
// resident file data. Runs on the main thread (texture upload needs GL).
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

    font := rl.LoadFontFromMemory(
        ".ttf",
        raw_data(family.file_data),
        cast(i32) len(family.file_data),
        font_size,
        raw_data(family.codepoints),
        cast(i32) len(family.codepoints),
    )
    if !rl.IsFontReady(font) {
        return rl.GetFontDefault()
    }

    family.cache[font_size] = font
    return font
}

text_line_height :: proc(font_size: i32) -> i32 {
    return font_size + 6
}

measure_text :: proc(text: string, font_size: i32, family := "") -> i32 {
    font := get_font(font_size, family)
    max_width: f32 = 0
    source := text

    for line in strings.split_lines_iterator(&source) {
        line_c := strings.clone_to_cstring(line, context.temp_allocator)
        size := rl.MeasureTextEx(font, line_c, cast(f32) font_size, 0)
        if size.x > max_width {
            max_width = size.x
        }
    }

    if max_width == 0 && text != "" {
        text_c := strings.clone_to_cstring(text, context.temp_allocator)
        size := rl.MeasureTextEx(font, text_c, cast(f32) font_size, 0)
        max_width = size.x
    }

    return cast(i32) max_width
}

draw_text :: proc(text: string, x, y, font_size: i32, color: rl.Color, family := "") {
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

    for line in strings.split_lines_iterator(&source) {
        // Shaped path first (ligatures); falls back to raylib's codepoint path
        // for sizes without shaping data.
        if !draw_line_shaped(fam, font, font_size, line, x, cast(i32) line_y, color) {
            line_c := strings.clone_to_cstring(line, context.temp_allocator)
            rl.DrawTextEx(
                font,
                line_c,
                rl.Vector2 {cast(f32) x, line_y},
                cast(f32) font_size,
                0,
                color,
            )
        }
        line_y += cast(f32) text_line_height(font_size)
    }
}
