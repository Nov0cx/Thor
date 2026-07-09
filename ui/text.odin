package ui

import "core:log"
import "core:strings"
import rl "vendor:raylib"

// Fonts are rasterized per size: drawing a bitmap atlas at any size other
// than the one it was baked for gets scaled and turns blurry.
font_file_path: string
font_cache: map[i32]rl.Font
font_available := false

@(private = "file")
load_font_at_size :: proc(font_size: i32) -> (rl.Font, bool) {
    // Load ASCII, Latin-1 Supplement, and Latin Extended-A so characters
    // like äöüéè render instead of falling back to '?'.
    codepoints := make([dynamic]rune, context.temp_allocator)
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

text_init :: proc(font_path: string, font_size: i32 = 18) {
    font_file_path = strings.clone(font_path)
    font_cache = make(map[i32]rl.Font)

    font, ok := load_font_at_size(font_size)
    if !ok {
        log.warnf("Failed to load font %q, using raylib default font", font_path)
        return
    }

    font_available = true
    font_cache[font_size] = font
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
