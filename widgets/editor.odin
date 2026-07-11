package widgets

import "core:fmt"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../textedit"
import "../ui"

Editor_Save_Proc :: #type proc(data: rawptr)

Editor :: struct {
    using widget: ui.Widget,
    // Borrowed from the owner of the open file (see thor/files.odin); nil
    // when no file is open. Keeping the buffer outside the widget preserves
    // undo history and cursors across tab switches.
    state:              ^textedit.State,
    on_save:            Editor_Save_Proc,
    save_data:          rawptr,
    placeholder:        string,
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
    selection_color:    rl.Color,
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
    editor.state = nil
    editor.placeholder = "No file open"
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
    editor.selection_color = rl.Color {132, 255, 255, 50}
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
    editor.selection_color = rl.Color {caret_color.r, caret_color.g, caret_color.b, 50}
    return editor
}

editor_set_on_save :: proc(editor: ^Editor, on_save: Editor_Save_Proc, data: rawptr) {
    editor.on_save = on_save
    editor.save_data = data
}

editor_set_state :: proc(editor: ^Editor, state: ^textedit.State) {
    editor.state = state
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
    if editor.state == nil {
        return false
    }

    #partial switch event.kind {
    case .Mouse_Down:
        editor_place_caret_at(editor, event.mouse_position)
        return true
    case .Scroll:
        editor.scroll_y -= event.wheel_delta * cast(f32) ui.text_line_height(editor.font_size) * 2
        editor_clamp_scroll(editor)
        return true
    case .Text_Input:
        // Skip control chords; ctrl+alt is AltGr and must pass through.
        if event.ctrl && !event.alt {
            return false
        }
        if event.codepoint >= 32 && event.codepoint != 127 {
            buffer, width := utf8.encode_rune(event.codepoint)
            textedit.insert_text(editor.state, string(buffer[:width]))
            editor_scroll_to_caret(editor)
            return true
        }
    case .Key_Press:
        return editor_handle_key(editor, event)
    case .Mouse_Move, .Mouse_Up, .Click, .None:
    }

    return false
}

editor_handle_key :: proc(editor: ^Editor, event: ^ui.Event) -> bool {
    state := editor.state
    ctrl_only := event.ctrl && !event.alt
    alt_only := event.alt && !event.ctrl

    // alt+number: relative line down, alt+shift+number: relative line up.
    if alt_only {
        if digit, is_digit := editor_key_digit(event.key); is_digit {
            textedit.move_vertical(state, event.shift ? -digit : digit, false)
            editor_scroll_to_caret(editor)
            return true
        }
    }

    #partial switch event.key {
    case .BACKSPACE:
        textedit.delete_backward(state)
        editor_scroll_to_caret(editor)
        return true
    case .DELETE:
        textedit.delete_forward(state)
        editor_scroll_to_caret(editor)
        return true
    case .ENTER, .KP_ENTER:
        textedit.insert_text(state, "\n")
        editor_scroll_to_caret(editor)
        return true
    case .TAB:
        textedit.insert_text(state, "\t")
        editor_scroll_to_caret(editor)
        return true
    case .LEFT:
        if ctrl_only {
            textedit.move_word(state, -1, event.shift)
        } else if alt_only {
            textedit.move_line_start(state, event.shift)
        } else {
            textedit.move_horizontal(state, -1, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .RIGHT:
        if ctrl_only {
            textedit.move_word(state, 1, event.shift)
        } else if alt_only {
            textedit.move_line_end(state, event.shift)
        } else {
            textedit.move_horizontal(state, 1, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .UP:
        if event.ctrl && event.alt {
            textedit.add_cursor_vertical(state, -1)
        } else if ctrl_only {
            textedit.move_document_start(state, event.shift)
        } else {
            textedit.move_vertical(state, -1, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .DOWN:
        if event.ctrl && event.alt {
            textedit.add_cursor_vertical(state, 1)
        } else if ctrl_only {
            textedit.move_document_end(state, event.shift)
        } else {
            textedit.move_vertical(state, 1, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .PAGE_UP:
        textedit.move_vertical(state, -8, event.shift)
        editor_scroll_to_caret(editor)
        return true
    case .PAGE_DOWN:
        textedit.move_vertical(state, 8, event.shift)
        editor_scroll_to_caret(editor)
        return true
    case .HOME:
        textedit.move_line_start(state, event.shift)
        editor_scroll_to_caret(editor)
        return true
    case .END:
        textedit.move_line_end(state, event.shift)
        editor_scroll_to_caret(editor)
        return true
    case .A:
        if ctrl_only {
            textedit.select_all(state)
            return true
        }
    case .Z:
        if ctrl_only {
            if event.shift {
                textedit.redo(state)
            } else {
                textedit.undo(state)
            }
            editor_scroll_to_caret(editor)
            return true
        }
    case .Y:
        if ctrl_only {
            textedit.redo(state)
            editor_scroll_to_caret(editor)
            return true
        }
    case .S:
        if ctrl_only && editor.on_save != nil {
            editor.on_save(editor.save_data)
            return true
        }
    case .P:
        if ctrl_only {
            textedit.move_to_matching_bracket(state, event.shift)
            editor_scroll_to_caret(editor)
            return true
        }
    case:
    }

    return false
}

editor_key_digit :: proc(key: rl.KeyboardKey) -> (int, bool) {
    #partial switch key {
    case .ZERO, .KP_0: return 0, true
    case .ONE, .KP_1: return 1, true
    case .TWO, .KP_2: return 2, true
    case .THREE, .KP_3: return 3, true
    case .FOUR, .KP_4: return 4, true
    case .FIVE, .KP_5: return 5, true
    case .SIX, .KP_6: return 6, true
    case .SEVEN, .KP_7: return 7, true
    case .EIGHT, .KP_8: return 8, true
    case .NINE, .KP_9: return 9, true
    }
    return 0, false
}

editor_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    editor := cast(^Editor) widget

    rl.DrawRectangleRec(editor.bounds, editor.background_color)

    if editor.state == nil {
        text_width := ui.measure_text(editor.placeholder, editor.font_size)
        text_x := cast(i32) (editor.bounds.x + (editor.bounds.width - cast(f32) text_width) * 0.5)
        text_y := cast(i32) (editor.bounds.y + (editor.bounds.height - cast(f32) editor.font_size) * 0.5)
        ui.draw_text(editor.placeholder, text_x, text_y, editor.font_size, editor.line_number_color)
        return
    }

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

    text := textedit.text(editor.state)
    line_height := cast(f32) ui.text_line_height(editor.font_size)
    inner_top := editor.bounds.y + editor.padding.top
    inner_bottom := editor.bounds.y + editor.bounds.height - editor.padding.bottom
    text_x := cast(i32) (editor.bounds.x + editor.gutter_width + editor.padding.left)
    line_number_x := cast(i32) (editor.bounds.x + 10)

    ui.begin_clip(editor.bounds)

    caret_line := textedit.line_index(text, textedit.primary_cursor(editor.state).caret)

    line_index := 0
    line_start := 0
    line_y := inner_top - editor.scroll_y

    for {
        line_end := textedit.line_end(text, line_start)

        if line_y + line_height >= inner_top && line_y <= inner_bottom {
            editor_draw_line_selections(editor, text, line_start, line_end, cast(f32) text_x, line_y, line_height)

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
        for cursor in editor.state.cursors {
            cursor_line := textedit.line_index(text, cursor.caret)
            caret_y := inner_top - editor.scroll_y + cast(f32) cursor_line * line_height
            if caret_y + line_height < inner_top || caret_y > inner_bottom {
                continue
            }
            cursor_line_start := textedit.line_start(text, cursor.caret)
            caret_x := cast(f32) text_x + cast(f32) ui.measure_text(text[cursor_line_start:cursor.caret], editor.font_size)
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

editor_draw_line_selections :: proc(editor: ^Editor, text: string, line_start, line_end: int, text_x, line_y, line_height: f32) {
    for cursor in editor.state.cursors {
        lo, hi := textedit.selection_range(cursor)
        if hi <= lo || hi <= line_start || lo > line_end {
            continue
        }

        seg_lo := max(lo, line_start)
        seg_hi := min(hi, line_end)
        x_start := cast(f32) ui.measure_text(text[line_start:seg_lo], editor.font_size)
        x_end := cast(f32) ui.measure_text(text[line_start:seg_hi], editor.font_size)
        width := x_end - x_start
        if hi > line_end {
            // Selection continues past the newline; show it.
            width += 8
        }
        if width <= 0 {
            continue
        }

        rl.DrawRectangleRec(
            rl.Rectangle {x = text_x + x_start, y = line_y, width = width, height = line_height},
            editor.selection_color,
        )
    }
}

editor_destroy :: proc(widget: ^ui.Widget) {
    // The textedit state is owned by whoever opened the file, not the widget.
    free(cast(^Editor) widget)
}

editor_place_caret_at :: proc(editor: ^Editor, position: rl.Vector2) {
    text := textedit.text(editor.state)
    line_height := cast(f32) ui.text_line_height(editor.font_size)
    inner_top := editor.bounds.y + editor.padding.top
    text_x := editor.bounds.x + editor.gutter_width + editor.padding.left

    target_line := cast(int) ((position.y - (inner_top - editor.scroll_y)) / line_height)
    if target_line < 0 {
        target_line = 0
    }

    line_start := textedit.line_start_of_index(text, target_line)
    line_end := textedit.line_end(text, line_start)
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

    textedit.set_single_cursor(editor.state, pos)
}

editor_scroll_to_caret :: proc(editor: ^Editor) {
    text := textedit.text(editor.state)
    line := textedit.line_index(text, textedit.primary_cursor(editor.state).caret)
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
    if editor.state == nil {
        editor.scroll_y = 0
        return
    }
    line_count := textedit.line_count(textedit.text(editor.state))
    content_height := cast(f32) line_count * cast(f32) ui.text_line_height(editor.font_size)
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
