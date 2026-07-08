package ui

import "core:log"
import "core:strings"
import rl "vendor:raylib"

current_font: rl.Font
custom_font_loaded := false

text_init :: proc(font_path: string, font_size: i32 = 18) {
    current_font = rl.GetFontDefault()

    path_c := strings.clone_to_cstring(font_path, context.temp_allocator)
    loaded_font := rl.LoadFontEx(path_c, font_size, nil, 0)
    if rl.IsFontReady(loaded_font) {
        current_font = loaded_font
        custom_font_loaded = true
        return
    }

    log.warnf("Failed to load font %q, using raylib default font", font_path)
}

text_shutdown :: proc() {
    if custom_font_loaded {
        rl.UnloadFont(current_font)
        custom_font_loaded = false
    }

    current_font = rl.GetFontDefault()
}

text_line_height :: proc(font_size: i32) -> i32 {
    return font_size + 6
}

measure_text :: proc(text: string, font_size: i32) -> i32 {
    max_width: f32 = 0
    source := text

    for line in strings.split_lines_iterator(&source) {
        line_c := strings.clone_to_cstring(line, context.temp_allocator)
        size := rl.MeasureTextEx(current_font, line_c, cast(f32) font_size, 0)
        if size.x > max_width {
            max_width = size.x
        }
    }

    if max_width == 0 && text != "" {
        text_c := strings.clone_to_cstring(text, context.temp_allocator)
        size := rl.MeasureTextEx(current_font, text_c, cast(f32) font_size, 0)
        max_width = size.x
    }

    return cast(i32) max_width
}

draw_text :: proc(text: string, x, y, font_size: i32, color: rl.Color) {
    if text == "" {
        return
    }

    source := text
    line_y := cast(f32) y

    for line in strings.split_lines_iterator(&source) {
        line_c := strings.clone_to_cstring(line, context.temp_allocator)
        rl.DrawTextEx(
            current_font,
            line_c,
            rl.Vector2 {cast(f32) x, line_y},
            cast(f32) font_size,
            0,
            color,
        )
        line_y += cast(f32) text_line_height(font_size)
    }
}
