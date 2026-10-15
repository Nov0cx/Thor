package font

import "core:c"
import "core:log"
import "core:mem"
import "core:os"
import rl "vendor:raylib"
import stbtt "vendor:stb/truetype"

// Fonts asked for a character the family's atlas lacks, after the family's
// own file. The first file of each row that exists is used.
when ODIN_OS == .Windows {
    @(private = "file")
    SYSTEM_FALLBACKS := [][]string {
        {"C:/Windows/Fonts/seguisym.ttf"},
        {"C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/msyh.ttf", "C:/Windows/Fonts/simsun.ttc"},
        {"C:/Windows/Fonts/meiryo.ttc", "C:/Windows/Fonts/msgothic.ttc"},
        {"C:/Windows/Fonts/malgun.ttf"},
        {"C:/Windows/Fonts/seguiemj.ttf"},
        {"C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf"},
    }
} else when ODIN_OS == .Darwin {
    @(private = "file")
    SYSTEM_FALLBACKS := [][]string {
        {"/System/Library/Fonts/Apple Symbols.ttf"},
        {"/System/Library/Fonts/PingFang.ttc", "/System/Library/Fonts/STHeiti Light.ttc"},
        {"/System/Library/Fonts/Hiragino Sans GB.ttc"},
        {"/System/Library/Fonts/AppleSDGothicNeo.ttc"},
        {"/Library/Fonts/Arial Unicode.ttf", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"},
        {"/System/Library/Fonts/Helvetica.ttc"},
    }
} else {
    @(private = "file")
    SYSTEM_FALLBACKS := [][]string {
        {
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
            "/usr/share/fonts/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        },
        {
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc",
            "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        },
        {
            "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
            "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
        },
        {
            "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
            "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        },
    }
}

// Side of one fallback atlas page, in pixels.
@(private = "file")
PAGE_SIZE :: 1024

// A font file the fallback reads glyphs from. The file is read on first need.
@(private = "file")
Fallback_Face :: struct {
    path:   string,
    data:   []u8, // owned by the font arena
    info:   stbtt.fontinfo,
    tried:  bool,
    loaded: bool,
}

// A glyph rasterized from a fallback face. `page` is 0 when no face has the
// character, which draws as a blank of `advance`.
Fallback_Glyph :: struct {
    page:     i32, // 1-based page of the sheet
    rect:     rl.Rectangle,
    offset_x: i32,
    offset_y: i32,
    advance:  i32,
}

// The glyphs one family and size took from the fallback faces, packed in
// shelves onto pages that grow on demand.
Fallback_Sheet :: struct {
    glyphs:   map[rune]Fallback_Glyph,
    pages:    [dynamic]rl.Texture2D,
    pen_x:    i32,
    pen_y:    i32,
    row_h:    i32,
    baseline: i32, // the family's baseline below the line top, in pixels
    blank:    i32, // the advance of a character no face has
}

@(private = "file")
system_faces: [dynamic]Fallback_Face

// Lists the system fallback faces that exist. Reads no font file.
@(private)
fallback_init :: proc() {
    system_faces = make([dynamic]Fallback_Face, font_allocator)
    for row in SYSTEM_FALLBACKS {
        for path in row {
            if os.exists(path) {
                append(&system_faces, Fallback_Face {path = path})
                break
            }
        }
    }
}

// Frees the pages of every sheet. The rest goes with the font arena.
@(private)
fallback_shutdown :: proc() {
    for _, family in families {
        for _, sheet in family.fallback {
            for page in sheet.pages {
                if page.id != 0 {
                    rl.UnloadTexture(page)
                }
            }
        }
    }
    system_faces = nil
}

// The fallback glyph of `r` for `family` at `size`, rasterized on first use.
// An icon outside the preload list comes here too. False when there is no
// family or no font state.
@(private)
fallback_glyph :: proc(family: ^Font_Family, size: i32, r: rune) -> (Fallback_Glyph, bool) {
    if family == nil || size <= 0 || font_allocator.procedure == nil {
        return {}, false
    }
    context.allocator = font_allocator
    sheet := fallback_sheet(family, size)
    if glyph, ok := sheet.glyphs[r]; ok {
        return glyph, true
    }
    glyph := fallback_rasterize(family, sheet, size, r)
    sheet.glyphs[r] = glyph
    return glyph, true
}

// The texture of 1-based page `page` of the family's sheet at `size`.
@(private)
fallback_page :: proc(family: ^Font_Family, size: i32, page: i32) -> rl.Texture2D {
    sheet, ok := family.fallback[size]
    if !ok || page < 1 || int(page) > len(sheet.pages) {
        return {}
    }
    return sheet.pages[page - 1]
}

@(private = "file")
fallback_sheet :: proc(family: ^Font_Family, size: i32) -> ^Fallback_Sheet {
    if sheet, ok := family.fallback[size]; ok {
        return sheet
    }
    if family.fallback == nil {
        family.fallback = make(map[i32]^Fallback_Sheet)
    }
    sheet := new(Fallback_Sheet)
    sheet.glyphs = make(map[rune]Fallback_Glyph)
    sheet.pages = make([dynamic]rl.Texture2D)
    sheet.baseline = size
    sheet.blank = size / 2
    info: stbtt.fontinfo
    if len(family.file_data) > 0 && stbtt.InitFont(&info, raw_data(family.file_data), stbtt.GetFontOffsetForIndex(raw_data(family.file_data), 0)) {
        scale := stbtt.ScaleForPixelHeight(&info, f32(size))
        ascent, descent, gap: c.int
        stbtt.GetFontVMetrics(&info, &ascent, &descent, &gap)
        sheet.baseline = i32(f32(ascent) * scale)
        space_advance: c.int
        stbtt.GetCodepointHMetrics(&info, ' ', &space_advance, nil)
        sheet.blank = max(i32(f32(space_advance) * scale), 1)
    }
    family.fallback[size] = sheet
    return sheet
}

// Rasterizes `r` from the first face that has it: the family's own file, then
// the system faces. An icon font uses its own file only: a system glyph is no
// icon. A character no face has gets a blank glyph.
@(private = "file")
fallback_rasterize :: proc(family: ^Font_Family, sheet: ^Fallback_Sheet, size: i32, r: rune) -> Fallback_Glyph {
    own: stbtt.fontinfo
    if len(family.file_data) > 0 && stbtt.InitFont(&own, raw_data(family.file_data), stbtt.GetFontOffsetForIndex(raw_data(family.file_data), 0)) {
        if gid := stbtt.FindGlyphIndex(&own, r); gid != 0 {
            return fallback_bake(&own, sheet, size, gid)
        }
    }
    if family.icon_font {
        return Fallback_Glyph {advance = sheet.blank}
    }
    for &face in system_faces {
        if !face_load(&face) {
            continue
        }
        if gid := stbtt.FindGlyphIndex(&face.info, r); gid != 0 {
            return fallback_bake(&face.info, sheet, size, gid)
        }
    }
    return Fallback_Glyph {advance = sheet.blank}
}

@(private = "file")
face_load :: proc(face: ^Fallback_Face) -> bool {
    if face.tried {
        return face.loaded
    }
    face.tried = true
    data, err := os.read_entire_file_from_path(face.path, font_allocator)
    if err != nil {
        log.warnf("Fallback font %q cannot be read: %v", face.path, err)
        return false
    }
    face.data = data
    if !stbtt.InitFont(&face.info, raw_data(data), stbtt.GetFontOffsetForIndex(raw_data(data), 0)) {
        log.warnf("Fallback font %q cannot be parsed", face.path)
        return false
    }
    face.loaded = true
    return true
}

// Rasterizes glyph `gid` of `info` onto the sheet's current page, with the
// family's baseline.
@(private = "file")
fallback_bake :: proc(info: ^stbtt.fontinfo, sheet: ^Fallback_Sheet, size: i32, gid: c.int) -> Fallback_Glyph {
    scale := stbtt.ScaleForPixelHeight(info, f32(size))
    advance: c.int
    stbtt.GetGlyphHMetrics(info, gid, &advance, nil)
    glyph := Fallback_Glyph {advance = max(i32(f32(advance) * scale), 1)}

    width, height, xoff, yoff: c.int
    bitmap := stbtt.GetGlyphBitmap(info, scale, scale, gid, &width, &height, &xoff, &yoff)
    if bitmap == nil {
        return glyph
    }
    defer stbtt.FreeBitmap(bitmap, nil)
    if width <= 0 || height <= 0 || width > PAGE_SIZE || height > PAGE_SIZE {
        return glyph
    }

    if sheet.pen_x + width + 1 > PAGE_SIZE {
        sheet.pen_x = 0
        sheet.pen_y += sheet.row_h + 1
        sheet.row_h = 0
    }
    if len(sheet.pages) == 0 || sheet.pen_y + height > PAGE_SIZE {
        if !page_add(sheet) {
            return glyph
        }
    }

    page := sheet.pages[len(sheet.pages) - 1]
    rect := rl.Rectangle {f32(sheet.pen_x), f32(sheet.pen_y), f32(width), f32(height)}
    if page.id != 0 {
        // Gray is full, alpha is coverage, the format of the main atlas.
        pixels := make([]u8, int(width * height) * 2, context.temp_allocator)
        for i in 0 ..< int(width * height) {
            pixels[2 * i] = 255
            pixels[2 * i + 1] = bitmap[i]
        }
        rl.UpdateTextureRec(page, rect, raw_data(pixels))
    }
    sheet.pen_x += width + 1
    sheet.row_h = max(sheet.row_h, height)

    glyph.page = i32(len(sheet.pages))
    glyph.rect = rect
    glyph.offset_x = xoff
    glyph.offset_y = sheet.baseline + yoff
    return glyph
}

// Opens a new empty page. Without a GL context the page has no texture, and
// the glyphs keep their places and advances.
@(private = "file")
page_add :: proc(sheet: ^Fallback_Sheet) -> bool {
    texture: rl.Texture2D
    if rl.IsWindowReady() {
        bytes := PAGE_SIZE * PAGE_SIZE * 2
        data := rl.MemAlloc(c.uint(bytes))
        if data == nil {
            log.errorf("No memory for a %dx%d fallback glyph page", PAGE_SIZE, PAGE_SIZE)
            return false
        }
        mem.zero(data, bytes)
        image := rl.Image {
            data    = data,
            width   = PAGE_SIZE,
            height  = PAGE_SIZE,
            mipmaps = 1,
            format  = .UNCOMPRESSED_GRAY_ALPHA,
        }
        texture = rl.LoadTextureFromImage(image)
        rl.MemFree(data)
        if texture.id == 0 {
            log.errorf("Could not upload a fallback glyph page")
            return false
        }
        rl.SetTextureFilter(texture, .BILINEAR)
    }
    append(&sheet.pages, texture)
    sheet.pen_x, sheet.pen_y, sheet.row_h = 0, 0, 0
    return true
}
