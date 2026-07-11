package widgets

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../settings"
import "../textedit"
import "../ui"

Editor_Save_Proc :: #type proc(data: rawptr)

// One on-screen row. Overflowing logical lines split into several; `first`
// marks the row carrying the line number. Rebuilt each layout.
Visual_Row :: struct {
    start: int, // byte offset of the row's first character
    end:   int, // byte offset one past its last character (before any newline)
    line:  int, // logical line index the row belongs to
    first: bool, // true for the first visual row of the logical line
}

Editor :: struct {
    using widget: ui.Widget,
    // Borrowed from the open file (thor/files.odin); nil when none open. Kept
    // outside the widget so undo history and cursors survive tab switches.
    state:              ^textedit.State,
    on_save:            Editor_Save_Proc,
    save_data:          rawptr,
    placeholder:        string,
    // Line-comment marker; empty disables comment toggling. Set per language.
    comment_prefix:     string,
    // Comment-toggle chord (from keybinds.json), defaults to Ctrl+K.
    comment_keybind:    settings.Keybind,
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
    // Soft-wrap: overflowing lines continue on the next visual row. The row
    // layout is rebuilt from the buffer every frame in editor_layout.
    wrap:               bool,
    visual_rows:        [dynamic]Visual_Row,
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
    editor.comment_prefix = "//"
    editor.comment_keybind = settings.Keybind {key = .K, ctrl = true}
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
    editor.wrap = true
    editor.visual_rows = make([dynamic]Visual_Row)
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

editor_set_comment_prefix :: proc(editor: ^Editor, prefix: string) {
    editor.comment_prefix = prefix
}

editor_set_state :: proc(editor: ^Editor, state: ^textedit.State) {
    editor.state = state
    editor.scroll_y = 0
    editor_clamp_scroll(editor)
}

editor_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    editor := cast(^Editor) widget
    editor.bounds = bounds
    editor_update_gutter(editor)
    editor_rebuild_visual_rows(editor)
    editor_clamp_scroll(editor)
}

// Sizes the line-number gutter to just fit the widest line number, so small
// files get a narrow gutter and large ones grow only as needed.
@(private = "file")
editor_update_gutter :: proc(editor: ^Editor) {
    if editor.state == nil {
        return
    }
    line_count := textedit.line_count(textedit.text(editor.state))
    digits := 1
    for n := line_count; n >= 10; n /= 10 {
        digits += 1
    }
    char_width := cast(f32) ui.measure_text("0", editor.font_size)
    // At least 2 digits wide, plus a little breathing room on each side.
    editor.gutter_width = char_width * cast(f32) max(digits, 2) + 14
}

// Width available for text (inside the gutter, padding and scrollbar).
@(private = "file")
editor_text_width :: proc(editor: ^Editor) -> f32 {
    return editor.bounds.width - editor.gutter_width - editor.padding.left - editor.padding.right - 10
}

// Rebuilds the visual-row list from the buffer. Wrapping uses the monospace
// advance width, so this stays a cheap rune walk (no per-line shaping).
editor_rebuild_visual_rows :: proc(editor: ^Editor) {
    clear(&editor.visual_rows)
    if editor.state == nil {
        return
    }

    text := textedit.text(editor.state)
    cols := max(int)
    if editor.wrap {
        char_width := ui.measure_text("0", editor.font_size)
        if char_width > 0 {
            cols = max(1, cast(int) (editor_text_width(editor) / cast(f32) char_width))
        }
    }

    line_start := 0
    line_index := 0
    for {
        line_end := textedit.line_end(text, line_start)
        editor_wrap_line(editor, text, line_start, line_end, cols, line_index)
        line_index += 1
        if line_end >= len(text) {
            break
        }
        line_start = line_end + 1
    }
}

// Appends the visual rows for one logical line, breaking at the last space that
// fits when a break is needed (falling back to a hard character break).
@(private = "file")
editor_wrap_line :: proc(editor: ^Editor, text: string, line_start, line_end, cols, line_index: int) {
    if line_start == line_end {
        append(&editor.visual_rows, Visual_Row {line_start, line_end, line_index, true})
        return
    }

    seg_start := line_start
    col := 0
    last_break := -1 // byte offset just after the most recent space in this segment
    first := true
    i := line_start
    for i < line_end {
        r, w := utf8.decode_rune_in_string(text[i:])
        if col >= cols {
            brk := last_break > seg_start ? last_break : i
            append(&editor.visual_rows, Visual_Row {seg_start, brk, line_index, first})
            first = false
            seg_start = brk
            col = 0
            last_break = -1
            i = brk
            continue
        }
        col += 1
        i += w
        if r == ' ' {
            last_break = i
        }
    }
    append(&editor.visual_rows, Visual_Row {seg_start, line_end, line_index, first})
}

// Index of the visual row that owns byte offset pos (the earliest row that
// contains it); 0 when there are no rows.
@(private = "file")
editor_visual_row_index :: proc(editor: ^Editor, pos: int) -> int {
    for row, index in editor.visual_rows {
        if pos >= row.start && pos <= row.end {
            return index
        }
    }
    return max(0, len(editor.visual_rows) - 1)
}

// Byte offset of the rune at column `col` within [start, end].
@(private = "file")
editor_byte_at_col :: proc(text: string, start, end, col: int) -> int {
    pos := start
    n := 0
    for pos < end && n < col {
        _, w := utf8.decode_rune_in_string(text[pos:])
        pos += w
        n += 1
    }
    return pos
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
        // Scroll events carry no modifier state; poll ctrl for zooming.
        if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) {
            editor_zoom(editor, event.wheel_delta > 0 ? 1 : -1)
            return true
        }
        editor.scroll_y -= event.wheel_delta * cast(f32) ui.text_line_height(editor.font_size) * 2
        editor_clamp_scroll(editor)
        return true
    case .Text_Input:
        // Skip Ctrl chords (AltGr is normalized to no modifiers upstream).
        if event.ctrl && !event.alt {
            return false
        }
        if event.codepoint >= 32 && event.codepoint != 127 {
            editor_type_rune(editor, event.codepoint)
            editor_scroll_to_caret(editor)
            return true
        }
    case .Key_Press:
        return editor_handle_key(editor, event)
    case .Mouse_Move, .Mouse_Up, .Click, .None:
    }

    return false
}

// Inserts a typed character, auto-pairing brackets and quotes.
editor_type_rune :: proc(editor: ^Editor, r: rune) {
    state := editor.state
    if close, ok := textedit.auto_close_for(r); ok {
        textedit.insert_pair(state, r, close)
    } else if textedit.is_close_bracket(r) {
        textedit.insert_or_step(state, r)
    } else if textedit.is_quote(r) {
        textedit.insert_quote(state, r)
    } else {
        buffer, width := utf8.encode_rune(r)
        textedit.insert_text(state, string(buffer[:width]))
    }
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

    // The comment-toggle chord is configurable (keybinds.json), so it is
    // matched here rather than as a fixed case in the switch below.
    if editor.comment_prefix != "" &&
       settings.keybind_matches(editor.comment_keybind, event.key, event.ctrl, event.shift, event.alt) {
        textedit.toggle_comment(state, editor.comment_prefix)
        editor_scroll_to_caret(editor)
        return true
    }

    #partial switch event.key {
    case .BACKSPACE:
        if ctrl_only {
            textedit.delete_word_backward(state)
        } else {
            textedit.delete_backward(state)
        }
        editor_scroll_to_caret(editor)
        return true
    case .DELETE:
        if ctrl_only {
            textedit.delete_word_forward(state)
        } else {
            textedit.delete_forward(state)
        }
        editor_scroll_to_caret(editor)
        return true
    case .ENTER, .KP_ENTER:
        if ctrl_only {
            if event.shift {
                textedit.insert_line_above(state)
            } else {
                textedit.insert_line_below(state)
            }
        } else {
            textedit.insert_newline(state)
        }
        editor_scroll_to_caret(editor)
        return true
    case .TAB:
        if event.shift {
            textedit.outdent_lines(state)
        } else if textedit.has_any_selection(state) {
            textedit.indent_lines(state)
        } else {
            textedit.insert_soft_tab(state)
        }
        editor_scroll_to_caret(editor)
        return true
    case .ESCAPE:
        textedit.clear_selections(state)
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
        } else if alt_only {
            if event.shift {
                textedit.duplicate_lines(state, -1)
            } else {
                textedit.move_lines(state, -1)
            }
        } else {
            editor_move_visual(editor, -1, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .DOWN:
        if event.ctrl && event.alt {
            textedit.add_cursor_vertical(state, 1)
        } else if ctrl_only {
            textedit.move_document_end(state, event.shift)
        } else if alt_only {
            if event.shift {
                textedit.duplicate_lines(state, 1)
            } else {
                textedit.move_lines(state, 1)
            }
        } else {
            editor_move_visual(editor, 1, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .PAGE_UP:
        editor_move_visual(editor, -8, event.shift)
        editor_scroll_to_caret(editor)
        return true
    case .PAGE_DOWN:
        editor_move_visual(editor, 8, event.shift)
        editor_scroll_to_caret(editor)
        return true
    case .HOME:
        if ctrl_only {
            textedit.move_document_start(state, event.shift)
        } else {
            textedit.move_line_start(state, event.shift)
        }
        editor_scroll_to_caret(editor)
        return true
    case .END:
        if ctrl_only {
            textedit.move_document_end(state, event.shift)
        } else {
            textedit.move_line_end(state, event.shift)
        }
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
    case .C:
        if ctrl_only {
            editor_copy(editor)
            return true
        }
    case .X:
        if ctrl_only {
            editor_cut(editor)
            editor_scroll_to_caret(editor)
            return true
        }
    case .V:
        if ctrl_only {
            editor_paste(editor)
            editor_scroll_to_caret(editor)
            return true
        }
    case .D:
        if ctrl_only {
            textedit.select_word_or_next(state)
            editor_scroll_to_caret(editor)
            return true
        }
    case .L:
        if ctrl_only {
            textedit.select_line(state)
            editor_scroll_to_caret(editor)
            return true
        }
    case .K:
        // ctrl+k (no shift) is the comment toggle, handled above via the
        // configurable keybind; ctrl+shift+k deletes the line.
        if ctrl_only && event.shift {
            textedit.delete_lines(state)
            editor_scroll_to_caret(editor)
            return true
        }
    case .P:
        // ctrl+p jumps to the matching/enclosing bracket; ctrl+shift+p
        // selects everything between the brackets (excluding them).
        if ctrl_only {
            if event.shift {
                textedit.select_between_brackets(state)
            } else {
                textedit.move_to_matching_bracket(state, false)
            }
            editor_scroll_to_caret(editor)
            return true
        }
    case .BACKSLASH:
        // Physical key right of the home row: \ on US layouts, # on QWERTZ.
        if ctrl_only && event.shift {
            textedit.move_to_matching_bracket(state, true)
            editor_scroll_to_caret(editor)
            return true
        }
    case .KP_ADD:
        if ctrl_only {
            editor_zoom(editor, 1)
            return true
        }
    case .KP_SUBTRACT:
        if ctrl_only {
            editor_zoom(editor, -1)
            return true
        }
    case:
    }

    return false
}

editor_zoom :: proc(editor: ^Editor, delta: i32) {
    editor_set_font_size(editor, editor.font_size + delta)
}

editor_set_font_size :: proc(editor: ^Editor, size: i32) {
    editor.font_size = clamp(size, 10, 32)
    editor_clamp_scroll(editor)
}

editor_toggle_wrap :: proc(editor: ^Editor) {
    editor.wrap = !editor.wrap
    editor_rebuild_visual_rows(editor)
    editor_clamp_scroll(editor)
}

editor_copy :: proc(editor: ^Editor) {
    payload, _ := textedit.copy_payload(editor.state, context.temp_allocator)
    if payload != "" {
        rl.SetClipboardText(strings.clone_to_cstring(payload, context.temp_allocator))
    }
}

editor_cut :: proc(editor: ^Editor) {
    payload, had_selection := textedit.copy_payload(editor.state, context.temp_allocator)
    if payload == "" {
        return
    }
    rl.SetClipboardText(strings.clone_to_cstring(payload, context.temp_allocator))
    if !had_selection {
        textedit.select_line(editor.state)
    }
    textedit.delete_backward(editor.state)
}

editor_paste :: proc(editor: ^Editor) {
    clip := rl.GetClipboardText()
    if clip == nil {
        return
    }
    // The buffer stores \n only; Windows clipboard text arrives as \r\n.
    normalized, _ := strings.replace_all(string(clip), "\r\n", "\n", context.temp_allocator)
    normalized, _ = strings.replace_all(normalized, "\r", "\n", context.temp_allocator)
    if normalized != "" {
        textedit.insert_text(editor.state, normalized)
    }
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

    ui.begin_clip(editor.bounds)

    caret_line := textedit.line_index(text, textedit.primary_cursor(editor.state).caret)

    for row, index in editor.visual_rows {
        row_y := inner_top - editor.scroll_y + cast(f32) index * line_height
        if row_y + line_height < inner_top {
            continue
        }
        if row_y > inner_bottom {
            break
        }

        editor_draw_line_selections(editor, text, row.start, row.end, cast(f32) text_x, row_y, line_height)

        // Line number is drawn once per logical line, on its first visual row.
        if row.first {
            displayed_number := row.line == caret_line ? row.line + 1 : abs(row.line - caret_line)
            line_number_text := fmt.tprintf("%d", displayed_number)
            // Right-align the number against the text so the gutter stays tight.
            number_width := ui.measure_text(line_number_text, editor.font_size)
            number_x := cast(i32) (editor.bounds.x + editor.gutter_width - 8) - number_width
            ui.draw_text(line_number_text, number_x, cast(i32) row_y, editor.font_size, editor.line_number_color)
        }
        ui.draw_text(text[row.start:row.end], text_x, cast(i32) row_y, editor.font_size, editor.text_color)
    }

    if ctx.focused == widget {
        for cursor in editor.state.cursors {
            row_index := editor_visual_row_index(editor, cursor.caret)
            row := editor.visual_rows[row_index]
            caret_y := inner_top - editor.scroll_y + cast(f32) row_index * line_height
            if caret_y + line_height < inner_top || caret_y > inner_bottom {
                continue
            }
            caret_x := cast(f32) text_x + cast(f32) ui.measure_text(text[row.start:cursor.caret], editor.font_size)
            // Text is top-aligned, so anchor the caret to the line top and
            // size it to the glyph height (not the full line height).
            rl.DrawRectangle(
                cast(i32) caret_x,
                cast(i32) caret_y,
                2,
                editor.font_size,
                editor.caret_color,
            )
        }
    }

    ui.end_clip()

    editor_draw_scrollbar(editor, line_height)
}

// Vertical scrollbar on the right edge, shown only when the document is taller
// than the view. The thumb size and position track scroll_y.
editor_draw_scrollbar :: proc(editor: ^Editor, line_height: f32) {
    view_height := editor.bounds.height - editor.padding.top - editor.padding.bottom
    content_height := cast(f32) len(editor.visual_rows) * line_height
    if content_height <= view_height {
        return
    }

    width: f32 = 6
    track_x := editor.bounds.x + editor.bounds.width - width - 2
    track_y := editor.bounds.y + editor.padding.top
    rl.DrawRectangleRec(rl.Rectangle {track_x, track_y, width, view_height}, editor.gutter_color)

    thumb_height := max(view_height * view_height / content_height, 28)
    max_scroll := content_height - view_height
    t := max_scroll > 0 ? editor.scroll_y / max_scroll : 0
    thumb_y := track_y + (view_height - thumb_height) * t
    rl.DrawRectangleRec(rl.Rectangle {track_x, thumb_y, width, thumb_height}, editor.line_number_color)
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
    editor := cast(^Editor) widget
    delete(editor.visual_rows)
    free(editor)
}

editor_place_caret_at :: proc(editor: ^Editor, position: rl.Vector2) {
    if len(editor.visual_rows) == 0 {
        return
    }
    text := textedit.text(editor.state)
    line_height := cast(f32) ui.text_line_height(editor.font_size)
    inner_top := editor.bounds.y + editor.padding.top
    text_x := editor.bounds.x + editor.gutter_width + editor.padding.left

    target := cast(int) ((position.y - (inner_top - editor.scroll_y)) / line_height)
    target = clamp(target, 0, len(editor.visual_rows) - 1)
    row := editor.visual_rows[target]
    target_x := position.x - text_x

    pos := row.start
    for pos < row.end {
        _, width := utf8.decode_rune_in_string(text[pos:])
        width_before := cast(f32) ui.measure_text(text[row.start:pos], editor.font_size)
        width_after := cast(f32) ui.measure_text(text[row.start:pos + width], editor.font_size)
        if target_x < (width_before + width_after) / 2 {
            break
        }
        pos += width
    }

    textedit.set_single_cursor(editor.state, pos)
}

editor_scroll_to_caret :: proc(editor: ^Editor) {
    // The buffer may have changed since the last layout (e.g. a keystroke), so
    // refresh the row map before locating the caret.
    editor_rebuild_visual_rows(editor)
    row_index := editor_visual_row_index(editor, textedit.primary_cursor(editor.state).caret)
    line_height := cast(f32) ui.text_line_height(editor.font_size)
    view_height := editor.bounds.height - editor.padding.top - editor.padding.bottom
    caret_top := cast(f32) row_index * line_height

    if caret_top < editor.scroll_y {
        editor.scroll_y = caret_top
    }
    if caret_top + line_height > editor.scroll_y + view_height {
        editor.scroll_y = caret_top + line_height - view_height
    }
    editor_clamp_scroll(editor)
}

// Moves every cursor by `delta` visual rows, keeping its column. Used for plain
// Up/Down and Page so vertical motion follows wrapped rows.
editor_move_visual :: proc(editor: ^Editor, delta: int, extend: bool) {
    editor_rebuild_visual_rows(editor)
    if len(editor.visual_rows) == 0 {
        return
    }
    text := textedit.text(editor.state)
    for &cursor in editor.state.cursors {
        row_index := editor_visual_row_index(editor, cursor.caret)
        row := editor.visual_rows[row_index]
        col := utf8.rune_count_in_string(text[row.start:cursor.caret])

        target := clamp(row_index + delta, 0, len(editor.visual_rows) - 1)
        trow := editor.visual_rows[target]
        cursor.caret = editor_byte_at_col(text, trow.start, trow.end, col)
        if !extend {
            cursor.anchor = cursor.caret
        }
    }
    textedit.normalize(editor.state)
}

editor_clamp_scroll :: proc(editor: ^Editor) {
    if editor.state == nil {
        editor.scroll_y = 0
        return
    }
    content_height := cast(f32) len(editor.visual_rows) * cast(f32) ui.text_line_height(editor.font_size)
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
