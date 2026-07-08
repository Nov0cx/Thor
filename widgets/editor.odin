package widgets

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

import "../ui"

Editor :: struct {
    using widget: ui.Widget,
    text:               [dynamic]u8,
    font_size:          i32,
    padding:            ui.Padding,
    gutter_width:       f32,
    scroll_y:           f32,
    background_color:   rl.Color,
    gutter_color:       rl.Color,
    border_color:       rl.Color,
    focus_border_color: rl.Color,
    text_color:         rl.Color,
    line_number_color:  rl.Color,
    caret_color:        rl.Color,
}

editor_vtable := ui.Widget_VTable {
    layout = editor_layout,
    handle_event = editor_handle_event,
    draw = editor_draw,
    destroy = editor_destroy,
}

editor_create :: proc(id: string) -> ^Editor {
    editor := new(Editor)
    ui.widget_init(&editor.widget, id, editor_vtable)
    editor.font_size = 18
    editor.padding = ui.padding_xy(14, 12)
    editor.gutter_width = 58
    editor.background_color = rl.Color {15, 17, 26, 255}
    editor.gutter_color = rl.Color {24, 26, 31, 255}
    editor.border_color = rl.Color {31, 34, 51, 255}
    editor.focus_border_color = rl.Color {132, 255, 255, 255}
    editor.text_color = rl.Color {238, 255, 255, 255}
    editor.line_number_color = rl.Color {113, 124, 180, 255}
    editor.caret_color = rl.Color {132, 255, 255, 255}
    editor.min_size = rl.Vector2 {0, 280}
    return editor
}

editor_set_colors :: proc(editor: ^Editor, text_color, line_number_color, background_color, gutter_color, border_color, focus_border_color, caret_color: rl.Color) -> ^Editor {
    editor.text_color = text_color
    editor.line_number_color = line_number_color
    editor.background_color = background_color
    editor.gutter_color = gutter_color
    editor.border_color = border_color
    editor.focus_border_color = focus_border_color
    editor.caret_color = caret_color
    return editor
}

editor_set_text :: proc(editor: ^Editor, text: string) {
    clear(&editor.text)
    for byte_value in text {
        append(&editor.text, byte(byte_value))
    }
    editor.scroll_y = 0
    editor_clamp_scroll(editor)
}

editor_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    editor := cast(^Editor) widget
    editor.bounds = bounds
    editor_clamp_scroll(editor)
}

editor_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    editor := cast(^Editor) widget

    #partial switch event.kind {
    case .Mouse_Down:
        return true
    case .Scroll:
        editor.scroll_y -= event.wheel_delta * cast(f32) ui.text_line_height(editor.font_size) * 2
        editor_clamp_scroll(editor)
        return true
    case .Text_Input:
        if event.codepoint >= 32 && event.codepoint < 127 {
            append(&editor.text, byte(event.codepoint))
            editor_scroll_to_end(editor)
            return true
        }
    case .Key_Press:
        #partial switch event.key {
        case .BACKSPACE:
            if len(editor.text) > 0 {
                resize(&editor.text, len(editor.text) - 1)
                editor_scroll_to_end(editor)
            }
            return true
        case .ENTER, .KP_ENTER:
            append(&editor.text, byte('\n'))
            editor_scroll_to_end(editor)
            return true
        case .TAB:
            append(&editor.text, byte('\t'))
            editor_scroll_to_end(editor)
            return true
        case .PAGE_UP:
            editor.scroll_y -= cast(f32) ui.text_line_height(editor.font_size) * 8
            editor_clamp_scroll(editor)
            return true
        case .PAGE_DOWN:
            editor.scroll_y += cast(f32) ui.text_line_height(editor.font_size) * 8
            editor_clamp_scroll(editor)
            return true
        case .HOME:
            editor.scroll_y = 0
            return true
        case .END:
            editor_scroll_to_end(editor)
            return true
        case:
        }
    case .Mouse_Move, .Mouse_Up, .Click, .None:
    }

    return false
}

editor_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    editor := cast(^Editor) widget

    rl.DrawRectangleRec(editor.bounds, editor.background_color)

    gutter_rect := rl.Rectangle {
        x = editor.bounds.x,
        y = editor.bounds.y,
        width = editor.gutter_width,
        height = editor.bounds.height,
    }
    rl.DrawRectangleRec(gutter_rect, editor.gutter_color)

    border_color := editor.border_color
    if ctx.focused == widget {
        border_color = editor.focus_border_color
    }
    rl.DrawRectangleLinesEx(editor.bounds, 1, border_color)

    line_height := cast(f32) ui.text_line_height(editor.font_size)
    inner_top := editor.bounds.y + editor.padding.top
    inner_bottom := editor.bounds.y + editor.bounds.height - editor.padding.bottom
    text_x := cast(i32) (editor.bounds.x + editor.gutter_width + editor.padding.left)
    line_number_x := cast(i32) (editor.bounds.x + 10)

    ui.begin_clip(editor.bounds)

    line_index := 0
    line_start := 0
    line_y := inner_top - editor.scroll_y
    source := editor.text[:]

    for i := 0; i <= len(source); i += 1 {
        is_break := i == len(source) || source[i] == '\n'
        if !is_break {
            continue
        }

        if line_y + line_height >= inner_top && line_y <= inner_bottom {
            line_number_text := fmt.tprintf("%d", line_index + 1)
            line_text := strings.clone_from_bytes(source[line_start:i], context.temp_allocator)
            ui.draw_text(line_number_text, line_number_x, cast(i32) line_y, editor.font_size, editor.line_number_color)
            ui.draw_text(line_text, text_x, cast(i32) line_y, editor.font_size, editor.text_color)
        }

        line_index += 1
        line_start = i + 1
        line_y += line_height

        if line_y > inner_bottom {
            break
        }
    }

    if ctx.focused == widget {
        caret_line := editor_line_count(editor) - 1
        caret_y := inner_top - editor.scroll_y + cast(f32) caret_line * line_height
        if caret_y >= inner_top && caret_y <= inner_bottom {
            last_line := editor_last_line_text(editor)
            caret_x := cast(f32) text_x + cast(f32) ui.measure_text(last_line, editor.font_size)
            rl.DrawRectangle(
                cast(i32) caret_x,
                cast(i32) caret_y,
                2,
                ui.text_line_height(editor.font_size),
                editor.caret_color,
            )
        }
    }

    ui.end_clip()
}

editor_destroy :: proc(widget: ^ui.Widget) {
    editor := cast(^Editor) widget
    clear(&editor.text)
    delete(editor.text)
    free(editor)
}

editor_clamp_scroll :: proc(editor: ^Editor) {
    content_height := cast(f32) editor_line_count(editor) * cast(f32) ui.text_line_height(editor.font_size)
    view_height := editor.bounds.height - editor.padding.top - editor.padding.bottom
    max_scroll := content_height - view_height
    if max_scroll < 0 {
        max_scroll = 0
    }

    if editor.scroll_y < 0 {
        editor.scroll_y = 0
    }
    if editor.scroll_y > max_scroll {
        editor.scroll_y = max_scroll
    }
}

editor_scroll_to_end :: proc(editor: ^Editor) {
    content_height := cast(f32) editor_line_count(editor) * cast(f32) ui.text_line_height(editor.font_size)
    view_height := editor.bounds.height - editor.padding.top - editor.padding.bottom
    editor.scroll_y = content_height - view_height
    editor_clamp_scroll(editor)
}

editor_line_count :: proc(editor: ^Editor) -> int {
    count := 1
    for byte_value in editor.text {
        if byte_value == '\n' {
            count += 1
        }
    }
    return count
}

editor_last_line_text :: proc(editor: ^Editor) -> string {
    source := editor.text[:]
    last_break := 0
    for i := 0; i < len(source); i += 1 {
        if source[i] == '\n' {
            last_break = i + 1
        }
    }
    return strings.clone_from_bytes(source[last_break:], context.temp_allocator)
}
