package widgets

import "core:fmt"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../piecetable"
import "../ui"

Editor :: struct {
    using widget: ui.Widget,
    text:               piecetable.Piece_Table,
    caret:              int,
    preferred_column:   int,
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
    piecetable.piecetable_set_text(&editor.text, text)
    editor.caret = 0
    editor.preferred_column = 0
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
        editor_place_caret_at(editor, event.mouse_position)
        return true
    case .Scroll:
        editor.scroll_y -= event.wheel_delta * cast(f32) ui.text_line_height(editor.font_size) * 2
        editor_clamp_scroll(editor)
        return true
    case .Text_Input:
        if event.codepoint >= 32 && event.codepoint != 127 {
            buffer, width := utf8.encode_rune(event.codepoint)
            editor_insert_at_caret(editor, string(buffer[:width]))
            return true
        }
    case .Key_Press:
        #partial switch event.key {
        case .BACKSPACE:
            if editor.caret > 0 {
                text := editor_text(editor)
                _, width := utf8.decode_last_rune_in_string(text[:editor.caret])
                piecetable.piecetable_delete(&editor.text, editor.caret - width, width)
                editor.caret -= width
                editor.preferred_column = editor_column(editor_text(editor), editor.caret)
                editor_scroll_to_caret(editor)
            }
            return true
        case .DELETE:
            text := editor_text(editor)
            if editor.caret < len(text) {
                _, width := utf8.decode_rune_in_string(text[editor.caret:])
                piecetable.piecetable_delete(&editor.text, editor.caret, width)
                editor.preferred_column = editor_column(editor_text(editor), editor.caret)
            }
            return true
        case .ENTER, .KP_ENTER:
            editor_insert_at_caret(editor, "\n")
            return true
        case .TAB:
            editor_insert_at_caret(editor, "\t")
            return true
        case .LEFT:
            editor_move_caret_horizontal(editor, -1)
            return true
        case .RIGHT:
            editor_move_caret_horizontal(editor, 1)
            return true
        case .UP:
            editor_move_caret_vertical(editor, -1)
            return true
        case .DOWN:
            editor_move_caret_vertical(editor, 1)
            return true
        case .PAGE_UP:
            editor_move_caret_vertical(editor, -8)
            return true
        case .PAGE_DOWN:
            editor_move_caret_vertical(editor, 8)
            return true
        case .HOME:
            text := editor_text(editor)
            editor.caret = editor_line_start(text, editor.caret)
            editor.preferred_column = 0
            editor_scroll_to_caret(editor)
            return true
        case .END:
            text := editor_text(editor)
            editor.caret = editor_line_end(text, editor.caret)
            editor.preferred_column = editor_column(text, editor.caret)
            editor_scroll_to_caret(editor)
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

    text := editor_text(editor)
    line_height := cast(f32) ui.text_line_height(editor.font_size)
    inner_top := editor.bounds.y + editor.padding.top
    inner_bottom := editor.bounds.y + editor.bounds.height - editor.padding.bottom
    text_x := cast(i32) (editor.bounds.x + editor.gutter_width + editor.padding.left)
    line_number_x := cast(i32) (editor.bounds.x + 10)

    ui.begin_clip(editor.bounds)

    caret_line := editor_line_index(text, editor.caret)

    line_index := 0
    line_start := 0
    line_y := inner_top - editor.scroll_y

    for {
        line_end := editor_line_end(text, line_start)

        if line_y + line_height >= inner_top && line_y <= inner_bottom {
            displayed_number := line_index == caret_line ? line_index + 1 : abs(line_index - caret_line)
            line_number_text := fmt.tprintf("%d", displayed_number)
            ui.draw_text(line_number_text, line_number_x, cast(i32) line_y, editor.font_size, editor.line_number_color)
            ui.draw_text(text[line_start:line_end], text_x, cast(i32) line_y, editor.font_size, editor.text_color)
        }

        line_index += 1
        line_y += line_height

        if line_end >= len(text) || line_y > inner_bottom {
            break
        }
        line_start = line_end + 1
    }

    if ctx.focused == widget {
        caret_y := inner_top - editor.scroll_y + cast(f32) caret_line * line_height
        if caret_y + line_height >= inner_top && caret_y <= inner_bottom {
            caret_line_start := editor_line_start(text, editor.caret)
            caret_x := cast(f32) text_x + cast(f32) ui.measure_text(text[caret_line_start:editor.caret], editor.font_size)
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
    piecetable.piecetable_destroy(&editor.text)
    free(editor)
}

// Materializes the buffer into the temp allocator; valid for the current frame.
editor_text :: proc(editor: ^Editor) -> string {
    return piecetable.piecetable_to_string(&editor.text, context.temp_allocator)
}

editor_insert_at_caret :: proc(editor: ^Editor, s: string) {
    piecetable.piecetable_insert(&editor.text, editor.caret, s)
    editor.caret += len(s)
    editor.preferred_column = editor_column(editor_text(editor), editor.caret)
    editor_scroll_to_caret(editor)
}

editor_move_caret_horizontal :: proc(editor: ^Editor, delta: int) {
    text := editor_text(editor)
    if delta < 0 && editor.caret > 0 {
        _, width := utf8.decode_last_rune_in_string(text[:editor.caret])
        editor.caret -= width
    } else if delta > 0 && editor.caret < len(text) {
        _, width := utf8.decode_rune_in_string(text[editor.caret:])
        editor.caret += width
    }
    editor.preferred_column = editor_column(text, editor.caret)
    editor_scroll_to_caret(editor)
}

editor_move_caret_vertical :: proc(editor: ^Editor, delta: int) {
    text := editor_text(editor)
    target_line := editor_line_index(text, editor.caret) + delta
    if target_line < 0 {
        target_line = 0
    }

    line_start := 0
    line_index := 0
    for line_index < target_line {
        line_end := editor_line_end(text, line_start)
        if line_end >= len(text) {
            break
        }
        line_start = line_end + 1
        line_index += 1
    }

    editor.caret = editor_offset_for_column(text, line_start, editor.preferred_column)
    editor_scroll_to_caret(editor)
}

editor_place_caret_at :: proc(editor: ^Editor, position: rl.Vector2) {
    text := editor_text(editor)
    line_height := cast(f32) ui.text_line_height(editor.font_size)
    inner_top := editor.bounds.y + editor.padding.top
    text_x := editor.bounds.x + editor.gutter_width + editor.padding.left

    target_line := cast(int) ((position.y - (inner_top - editor.scroll_y)) / line_height)
    if target_line < 0 {
        target_line = 0
    }

    line_start := 0
    line_index := 0
    for line_index < target_line {
        line_end := editor_line_end(text, line_start)
        if line_end >= len(text) {
            break
        }
        line_start = line_end + 1
        line_index += 1
    }

    line_end := editor_line_end(text, line_start)
    target_x := position.x - text_x

    pos := line_start
    for pos < line_end {
        _, width := utf8.decode_rune_in_string(text[pos:])
        width_before := cast(f32) ui.measure_text(text[line_start:pos], editor.font_size)
        width_after := cast(f32) ui.measure_text(text[line_start:pos + width], editor.font_size)
        if target_x < (width_before + width_after) / 2 {
            break
        }
        pos += width
    }

    editor.caret = pos
    editor.preferred_column = editor_column(text, pos)
}

editor_scroll_to_caret :: proc(editor: ^Editor) {
    text := editor_text(editor)
    line := editor_line_index(text, editor.caret)
    line_height := cast(f32) ui.text_line_height(editor.font_size)
    view_height := editor.bounds.height - editor.padding.top - editor.padding.bottom
    caret_top := cast(f32) line * line_height

    if caret_top < editor.scroll_y {
        editor.scroll_y = caret_top
    }
    if caret_top + line_height > editor.scroll_y + view_height {
        editor.scroll_y = caret_top + line_height - view_height
    }
    editor_clamp_scroll(editor)
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

editor_line_count :: proc(editor: ^Editor) -> int {
    count := 1
    it := piecetable.piecetable_iterator(&editor.text)
    for {
        byte_value, ok := piecetable.piecetable_iterator_next(&it)
        if !ok {
            break
        }
        if byte_value == '\n' {
            count += 1
        }
    }
    return count
}

// Byte offset of the start of the line containing `pos`.
editor_line_start :: proc(text: string, pos: int) -> int {
    start := pos
    for start > 0 && text[start - 1] != '\n' {
        start -= 1
    }
    return start
}

// Byte offset of the '\n' terminating the line containing `pos` (or len(text)).
editor_line_end :: proc(text: string, pos: int) -> int {
    end := pos
    for end < len(text) && text[end] != '\n' {
        end += 1
    }
    return end
}

// Zero-based index of the line containing `pos`.
editor_line_index :: proc(text: string, pos: int) -> int {
    count := 0
    for i in 0 ..< pos {
        if text[i] == '\n' {
            count += 1
        }
    }
    return count
}

// Rune column of `pos` within its line.
editor_column :: proc(text: string, pos: int) -> int {
    start := editor_line_start(text, pos)
    return utf8.rune_count_in_string(text[start:pos])
}

// Byte offset of `column` runes into the line starting at `line_start`,
// clamped to the end of that line.
editor_offset_for_column :: proc(text: string, line_start: int, column: int) -> int {
    pos := line_start
    current := 0
    for pos < len(text) && text[pos] != '\n' && current < column {
        _, width := utf8.decode_rune_in_string(text[pos:])
        pos += width
        current += 1
    }
    return pos
}
