package ui

import "core:c"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import rl "vendor:raylib"
import stbtt "vendor:stb/truetype"

// Fonts are rasterized per size: drawing a bitmap atlas at any size other
// than the one it was baked for gets scaled and turns blurry.
font_file_path: string
font_cache: map[i32]rl.Font
font_available := false

// Rasterizing a glyph atlas is pure CPU work (stb_truetype) and is done on
// worker threads overlapping window creation; only the texture upload needs
// the GL context and happens on the main thread in text_finish_async_load.
@(private = "file")
Font_Load_Job :: struct {
    size:        i32,
    glyphs:      [^]rl.GlyphInfo,
    recs:        [^]rl.Rectangle,
    glyph_count: i32,
    atlas:       rl.Image,
    ok:          bool,
    worker:      ^thread.Thread,
}

@(private = "file")
async_jobs: [dynamic]^Font_Load_Job

@(private = "file")
async_file_data: []u8

@(private = "file")
async_codepoints: [dynamic]rune

// Load ASCII, Latin-1 Supplement, and Latin Extended-A so characters
// like äöüéè render instead of falling back to '?'.
@(private = "file")
build_codepoint_list :: proc(allocator := context.temp_allocator) -> [dynamic]rune {
    codepoints := make([dynamic]rune, allocator)
    for c: rune = 0x0020; c <= 0x007E; c += 1 {
        append(&codepoints, c)
    }
    for c: rune = 0x00A0; c <= 0x017F; c += 1 {
        append(&codepoints, c)
    }
    extras := [?]rune {'€', '–', '—', '‘', '’', '“', '”', '…'}
    for c in extras {
        append(&codepoints, c)
    }
    return codepoints
}

// Rasterizes glyphs and packs the atlas with stb_truetype directly, mirroring
// raylib's LoadFontData/GenImageFontAtlas. raylib is deliberately not called
// here: its font procs are not thread-safe to use off the main thread (and the
// vendor binding of LoadFontData is missing raylib 6.0's glyphCount out-param,
// so calling it corrupts memory). All buffers handed to raylib structs are
// libc-allocated so UnloadFont/UnloadImage can free them.
@(private = "file")
font_load_worker :: proc(job: ^Font_Load_Job) {
    PADDING :: 4

    info: stbtt.fontinfo
    if !stbtt.InitFont(&info, raw_data(async_file_data), stbtt.GetFontOffsetForIndex(raw_data(async_file_data), 0)) {
        return
    }

    scale := stbtt.ScaleForPixelHeight(&info, cast(f32) job.size)
    ascent, descent, line_gap: c.int
    stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)

    found := make([dynamic]rune)
    defer delete(found)
    for cp in async_codepoints {
        if stbtt.FindGlyphIndex(&info, cp) != 0 {
            append(&found, cp)
        }
    }
    count := len(found)
    if count == 0 {
        return
    }

    glyphs := cast([^]rl.GlyphInfo) rl.MemAlloc(cast(c.uint) (count * size_of(rl.GlyphInfo)))

    for cp, k in found {
        glyph := &glyphs[k]
        glyph.value = cp

        advance: c.int
        stbtt.GetCodepointHMetrics(&info, cp, &advance, nil)
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
        bitmap := stbtt.GetCodepointBitmap(&info, scale, scale, cp, &width, &height, &offset_x, &offset_y)
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
    job.ok = true
}

// Starts rasterizing the given font sizes on worker threads. Safe to call
// before InitWindow; nothing here touches the GL context.
text_begin_async_load :: proc(font_path: string, sizes: []i32) {
    font_file_path = strings.clone(font_path)
    font_cache = make(map[i32]rl.Font)

    data, read_err := os.read_entire_file_from_path(font_path, context.allocator)
    if read_err != nil {
        return
    }
    async_file_data = data
    async_codepoints = build_codepoint_list(context.allocator)

    for size in sizes {
        job := new(Font_Load_Job)
        job.size = size
        job.worker = thread.create_and_start_with_poly_data(job, font_load_worker)
        append(&async_jobs, job)
    }
}

// Joins the rasterizer threads and uploads the atlases as textures.
// Must run on the main thread after InitWindow, before the first frame.
text_finish_async_load :: proc() {
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
            font_cache[job.size] = font
            font_available = true
        } else {
            log.warnf("Failed to rasterize font %q at size %d", font_file_path, job.size)
        }
        free(job)
    }
    delete(async_jobs)
    async_jobs = nil
    delete(async_file_data)
    async_file_data = nil
    delete(async_codepoints)
    async_codepoints = nil

    if !font_available {
        log.warnf("Failed to load font %q, using raylib default font", font_file_path)
    }
}

// Synchronous fallback for sizes not prepared at startup.
@(private = "file")
load_font_at_size :: proc(font_size: i32) -> (rl.Font, bool) {
    codepoints := build_codepoint_list(context.temp_allocator)
    path_c := strings.clone_to_cstring(font_file_path, context.temp_allocator)
    font := rl.LoadFontEx(path_c, font_size, raw_data(codepoints[:]), cast(i32) len(codepoints))
    if rl.IsFontReady(font) {
        return font, true
    }
    return rl.GetFontDefault(), false
}

@(private = "file")
get_font :: proc(font_size: i32) -> rl.Font {
    if !font_available {
        return rl.GetFontDefault()
    }

    if font, ok := font_cache[font_size]; ok {
        return font
    }

    font, ok := load_font_at_size(font_size)
    if !ok {
        return rl.GetFontDefault()
    }

    font_cache[font_size] = font
    return font
}

text_shutdown :: proc() {
    default_texture_id := rl.GetFontDefault().texture.id
    for _, font in font_cache {
        if font.texture.id != default_texture_id {
            rl.UnloadFont(font)
        }
    }
    delete(font_cache)
    delete(font_file_path)
    font_file_path = ""
    font_available = false
}

text_line_height :: proc(font_size: i32) -> i32 {
    return font_size + 6
}

measure_text :: proc(text: string, font_size: i32) -> i32 {
    font := get_font(font_size)
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

draw_text :: proc(text: string, x, y, font_size: i32, color: rl.Color) {
    if text == "" {
        return
    }

    font := get_font(font_size)
    source := text
    line_y := cast(f32) y

    for line in strings.split_lines_iterator(&source) {
        line_c := strings.clone_to_cstring(line, context.temp_allocator)
        rl.DrawTextEx(
            font,
            line_c,
            rl.Vector2 {cast(f32) x, line_y},
            cast(f32) font_size,
            0,
            color,
        )
        line_y += cast(f32) text_line_height(font_size)
    }
}
