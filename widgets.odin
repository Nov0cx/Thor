package main

import rl "vendor:raylib"
import "core:fmt"
import "core:unicode/utf8"

PieceSource :: enum { Original, Added }

Piece :: struct {
    source: PieceSource,
    offset: int, // offset into original or added buffer
    length: int,
}

PieceTable :: struct {
    original: []u8,   // immutable
    added:    [dynamic]u8,
    pieces:   [dynamic]Piece,
}

piece_table_init :: proc(initial: string, allocator := context.allocator) -> PieceTable {
    pt: PieceTable
    pt.original = transmute([]u8)initial
    pt.added = make([dynamic]u8, allocator)
    pt.pieces = make([dynamic]Piece, allocator)
    if len(initial) > 0 {
        append(&pt.pieces, Piece{source = .Original, offset = 0, length = len(initial)})
    }
    return pt
}

piece_table_destroy :: proc(pt: ^PieceTable) {
    delete(pt.added)
    delete(pt.pieces)
}

piece_table_total_len :: proc(pt: ^PieceTable) -> int {
    total := 0
    for p in pt.pieces {
        total += p.length
    }
    return total
}

insert :: proc(array: [dynamic]$T, index: int, value: T) -> [dynamic]T {
    assert(index >= 0 && index <= len(array), "insert: index out of bounds")

    result := make([dynamic]T, len(array) + 1)

    copy(result[:index], array[:index])

    result[index] = value

    copy(result[index + 1:], array[index:])

    return result
}

delete_range :: proc(array: [dynamic]$T, start: int, end: int) -> [dynamic]T {
    assert(start >= 0 && end <= len(array) && start <= end,
           "delete_range: invalid range")

    count := end - start
    result := make([dynamic]T, len(array) - count)

    copy(result[:start], array[:start])
    copy(result[start:], array[end:])

    return result
}

piece_table_find_piece :: proc(pt: ^PieceTable, pos: int) -> (int, int) {
    total := piece_table_total_len(pt)
    if pos < 0 || pos > total do panic("piece_table: position out of bounds")
    if pos == total && len(pt.pieces) > 0 {
        last := len(pt.pieces) - 1
        return last, pt.pieces[last].length
    }
    cum := 0
    for i in 0 ..< len(pt.pieces) {
        p := pt.pieces[i]
        if pos < cum + p.length {
            return i, pos - cum
        }
        cum += p.length
    }
    return 0, 0
}

piece_table_split_at :: proc(pt: ^PieceTable, pos: int) -> int {
    total := piece_table_total_len(pt)
    if pos == 0 { return 0 }
    if pos == total { return len(pt.pieces) }

    idx, off := piece_table_find_piece(pt, pos)
    p := pt.pieces[idx]
    if off == 0 { return idx }
    if off == p.length { return idx + 1 }

    new_piece := Piece{source = p.source, offset = p.offset + off, length = p.length - off}
    pt.pieces[idx].length = off
    pt.pieces = insert(pt.pieces, idx + 1, new_piece)
    return idx + 1
}

piece_table_insert :: proc(pt: ^PieceTable, pos: int, bytes: []u8) {
    if len(bytes) == 0 do return
    idx := piece_table_split_at(pt, pos)
    added_start := len(pt.added)
    append(&pt.added, ..bytes)
    pt.pieces = insert(pt.pieces, idx, Piece{source = .Added, offset = added_start, length = len(bytes)})
}

piece_table_delete_range :: proc(pt: ^PieceTable, start: int, end: int) {
    if start >= end do return
    start_idx := piece_table_split_at(pt, start)
    end_idx   := piece_table_split_at(pt, end)
    if start_idx < end_idx {
        pt.pieces = delete_range(pt.pieces, start_idx, end_idx)
    }
}

piece_table_get_string :: proc(pt: ^PieceTable) -> string {
    total := piece_table_total_len(pt)
    if total == 0 do return ""
    buf := make([]u8, total)
    offset := 0
    for p in pt.pieces {
        src := pt.original if p.source == .Original else pt.added[:]
        copy(buf[offset:], src[p.offset:p.offset + p.length])
        offset += p.length
    }
    return string(buf)
}

piece_table_get_lines :: proc(pt: ^PieceTable) -> []string {
    s := piece_table_get_string(pt)
    lines := make([dynamic]string, 0, 16)
    start := 0
    for i := 0; i < len(s); i += 1 {
        if s[i] == '\n' {
            append(&lines, s[start:i])
            start = i + 1
        }
    }
    append(&lines, s[start:])
    return lines[:]
}

UITextState :: struct {
    pt:              PieceTable,
    cursor:          int,
    selection_start: int,
    scroll_x:        f32,
    scroll_y:        f32,
    multiline:       bool,
}

init_text_state :: proc(initial: string, multiline: bool, allocator := context.allocator) -> UITextState {
    state: UITextState
    state.pt = piece_table_init(initial, allocator)
    state.cursor = len(initial)
    state.selection_start = len(initial)
    state.multiline = multiline
    return state
}

destroy_text_state :: proc(state: ^UITextState) {
    piece_table_destroy(&state.pt)
}

text_insert_char :: proc(state: ^UITextState, r: rune) {
    buf, n := utf8.encode_rune(r)
    bytes := buf[:n]

    if state.cursor != state.selection_start {
        start := min(state.cursor, state.selection_start)
        end   := max(state.cursor, state.selection_start)
        piece_table_delete_range(&state.pt, start, end)
        state.cursor = start
        state.selection_start = start
    }
    piece_table_insert(&state.pt, state.cursor, bytes)
    state.cursor += n
    state.selection_start = state.cursor
}

text_insert_spaces :: proc(state: ^UITextState, count: int) {
    for _ in 0 ..< count {
        text_insert_char(state, ' ')
    }
}

text_backspace :: proc(state: ^UITextState) {
    if state.cursor != state.selection_start {
        start := min(state.cursor, state.selection_start)
        end   := max(state.cursor, state.selection_start)
        piece_table_delete_range(&state.pt, start, end)
        state.cursor = start
        state.selection_start = start
    } else if state.cursor > 0 {
        str := piece_table_get_string(&state.pt)
        _, n := utf8.decode_last_rune(transmute([]u8)str[:state.cursor])
        if n > 0 {
            piece_table_delete_range(&state.pt, state.cursor - n, state.cursor)
            state.cursor -= n
            state.selection_start = state.cursor
        }
    }
}

text_delete :: proc(state: ^UITextState) {
    if state.cursor != state.selection_start {
        start := min(state.cursor, state.selection_start)
        end   := max(state.cursor, state.selection_start)
        piece_table_delete_range(&state.pt, start, end)
        state.cursor = start
        state.selection_start = start
    } else if state.cursor < piece_table_total_len(&state.pt) {
        str := piece_table_get_string(&state.pt)
        _, n := utf8.decode_rune(transmute([]u8)str[state.cursor:])
        if n > 0 {
            piece_table_delete_range(&state.pt, state.cursor, state.cursor + n)
        }
    }
}

text_move_cursor_left :: proc(state: ^UITextState, select: bool) {
    if !select && state.selection_start != state.cursor {
        state.cursor = min(state.cursor, state.selection_start)
        state.selection_start = state.cursor
        return
    }
    if state.cursor > 0 {
        str := piece_table_get_string(&state.pt)
        _, n := utf8.decode_last_rune(transmute([]u8)str[:state.cursor])
        state.cursor -= n
        if !select {
            state.selection_start = state.cursor
        }
    }
}

text_move_cursor_right :: proc(state: ^UITextState, select: bool) {
    if !select && state.selection_start != state.cursor {
        state.cursor = max(state.cursor, state.selection_start)
        state.selection_start = state.cursor
        return
    }
    if state.cursor < piece_table_total_len(&state.pt) {
        str := piece_table_get_string(&state.pt)
        _, n := utf8.decode_rune(transmute([]u8)str[state.cursor:])
        state.cursor += n
        if !select {
            state.selection_start = state.cursor
        }
    }
}

cursor_line_col :: proc(state: ^UITextState) -> (line, col: int) {
    str := piece_table_get_string(&state.pt)
    cursor := state.cursor
    line = 0
    col = 0
    for i := 0; i < cursor && i < len(str); i += 1 {
        if str[i] == '\n' {
            line += 1
            col = 0
        } else {
            col += 1
        }
    }
    return
}

line_start_offset :: proc(state: ^UITextState, line: int) -> int {
    str := piece_table_get_string(&state.pt)
    if line == 0 do return 0
    cur, cnt := 0, 0
    for cur < len(str) && cnt < line {
        if str[cur] == '\n' {
            cnt += 1
            cur += 1
        } else {
            cur += 1
        }
    }
    return cur
}

line_end_offset :: proc(state: ^UITextState, line: int) -> int {
    str := piece_table_get_string(&state.pt)
    cur := line_start_offset(state, line)
    for cur < len(str) && str[cur] != '\n' {
        cur += 1
    }
    return cur
}

move_cursor_vertical :: proc(state: ^UITextState, dir: int, select: bool) {
    line, col := cursor_line_col(state)
    target_line := line + dir
    if target_line < 0 { target_line = 0 }
    str := piece_table_get_string(&state.pt)
    total_lines := 0
    for ch in str {
        if ch == '\n' do total_lines += 1
    }
    total_lines += 1
    if target_line >= total_lines { target_line = total_lines - 1 }

    start := line_start_offset(state, target_line)
    end := line_end_offset(state, target_line)
    line_len := end - start
    if col > line_len do col = line_len
    state.cursor = start + col
    if !select do state.selection_start = state.cursor
}

get_selected_text :: proc(state: ^UITextState) -> string {
    start := min(state.cursor, state.selection_start)
    end   := max(state.cursor, state.selection_start)
    str := piece_table_get_string(&state.pt)
    return str[start:end]
}

get_font :: proc() -> rl.Font {
    if ui_ctx.font.texture.id != 0 {
        return ui_ctx.font
    }
    return rl.GetFontDefault()
}

font_size :: proc() -> f32 {
    if ui_ctx.font.texture.id != 0 {
        return f32(ui_ctx.font.baseSize)
    }
    return 16
}

ui_text_field :: proc(label: string, state: ^UITextState, width: f32, height: f32 = 0) -> bool {
    id := widget_id(label)
    font := get_font()
    fs := font_size()
    line_h := ui_ctx.line_height
    if line_h <= 0 do line_h = fs + 2

    rect: rl.Rectangle
    if height <= 0 {
        rect = { ui_ctx.cursor.x, ui_ctx.cursor.y, width, line_h }
        ui_ctx.cursor.y += line_h + 4
    } else {
        rect = { ui_ctx.cursor.x, ui_ctx.cursor.y, width, height }
        ui_ctx.cursor.y += height + 4
    }

    mouse := rl.GetMousePosition()
    inside := rl.CheckCollisionPointRec(mouse, rect)

    if inside && ui_ctx.interaction_ok {
        ui_ctx.hot_item = id
    }

    if inside && rl.IsMouseButtonPressed(.LEFT) && ui_ctx.interaction_ok {
        ui_ctx.active_item = id
        state.cursor = piece_table_total_len(&state.pt)
        state.selection_start = state.cursor
    }
    if !inside && rl.IsMouseButtonPressed(.LEFT) {
        ui_ctx.active_item = 0
    }

    is_focused := ui_ctx.active_item == id && ui_ctx.interaction_ok

    if is_focused {
        confirmed := false
        key := rl.GetKeyPressed()
        for key != .KEY_NULL {
            switch {
            case key == .BACKSPACE:
                text_backspace(state)
            case key == .DELETE:
                text_delete(state)
            case key == .LEFT:
                text_move_cursor_left(state, rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT))
            case key == .RIGHT:
                text_move_cursor_right(state, rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT))
            case key == .UP:
                if state.multiline {
                    move_cursor_vertical(state, -1, rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT))
                }
            case key == .DOWN:
                if state.multiline {
                    move_cursor_vertical(state, 1, rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT))
                }
            case key == .HOME:
                state.cursor = 0
                if !(rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)) {
                    state.selection_start = state.cursor
                }
            case key == .END:
                state.cursor = piece_table_total_len(&state.pt)
                if !(rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)) {
                    state.selection_start = state.cursor
                }
            case key == .A && (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)):
                state.selection_start = 0
                state.cursor = piece_table_total_len(&state.pt)
            case key == .C && (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)):
                selected := get_selected_text(state)
                rl.SetClipboardText(fmt.ctprintf("%s", selected))
            case key == .V && (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)):
                clip := rl.GetClipboardText()
                if clip != nil {
                    pasted := string(clip)
                    for r in pasted {
                        if r == '\r' && !state.multiline {
                            continue
                        }
                        text_insert_char(state, r)
                    }
                }
            case key == .X && (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)):
                selected := get_selected_text(state)
                rl.SetClipboardText(fmt.ctprintf("%s", selected))
                text_delete(state)
            case key == .ENTER:
                if state.multiline {
                    text_insert_char(state, '\n')
                } else {
                    confirmed = true
                }
            case:
                if int(key) >= 32 {
                    text_insert_char(state, rune(key))
                }
            }
            key = rl.GetKeyPressed()
        }

        if confirmed {
            return true
        }
    }

    bg := ui_theme.second_bg
    if is_focused { bg = ui_theme.active }
    rl.DrawRectangleRec(rect, bg)
    rl.DrawRectangleLinesEx(rect, 1, ui_theme.border)

    rl.BeginScissorMode(i32(rect.x)+1, i32(rect.y)+1, i32(rect.width)-2, i32(rect.height)-2)

    lines := piece_table_get_lines(&state.pt)
    text_x := rect.x + 4
    text_y := rect.y + 4 - state.scroll_y
    spacing : f32 = 1.0

    for line_str, i in lines {
        draw_y := text_y + f32(i) * line_h
        if draw_y + line_h < rect.y || draw_y > rect.y + rect.height do continue
        pos := rl.Vector2{ text_x, draw_y }
        rl.DrawTextEx(font, fmt.ctprintf("%s", line_str), pos, fs, spacing, ui_theme.text)
    }

    if is_focused {
        cursor_line, cursor_col := cursor_line_col(state)
        line_text := lines[cursor_line] if cursor_line < len(lines) else ""
        prefix := fmt.ctprintf("%s", line_text[:cursor_col])
        prefix_w := rl.MeasureTextEx(font, prefix, fs, spacing).x
        cursor_x := text_x + prefix_w
        cursor_y := text_y + f32(cursor_line) * line_h
        rl.DrawLine(i32(cursor_x), i32(cursor_y), i32(cursor_x), i32(cursor_y+line_h-4), ui_theme.accent)
    }

    rl.EndScissorMode()
    return is_focused
}

// Other widgets remain exactly as they were (they do not use the text buffer)

ui_checkbox :: proc(label: string, checked: ^bool) -> bool {
    id := widget_id(label)
    font := get_font()
    fs := font_size()
    size: f32 = fs
    rect := rl.Rectangle{ ui_ctx.cursor.x, ui_ctx.cursor.y, size, size }
    changed := ui_item(rect, id)
    if changed {
        checked^ = !checked^
    }

    col := ui_theme.button
    if ui_ctx.hot_item == id {
        col = ui_theme.highlight
    }
    if ui_ctx.active_item == id && rl.IsMouseButtonDown(.LEFT) {
        col = ui_theme.active
    }
    rl.DrawRectangleRec(rect, col)
    rl.DrawRectangleLinesEx(rect, 1, ui_theme.border)
    if checked^ {
        rl.DrawTextEx(font, "v", rl.Vector2{rect.x+2, rect.y-2}, fs, 1, ui_theme.green)
    }
    label_pos := rl.Vector2{ rect.x + size + 6, rect.y }
    rl.DrawTextEx(font, fmt.ctprintf("%s", label), label_pos, fs, 1, ui_theme.text)
    ui_ctx.cursor.y += size + 4
    return changed
}

ui_slider_int :: proc(label: string, value: ^int, min, max: int, width: f32) -> bool {
    id := widget_id(label)
    font := get_font()
    fs := font_size()
    h: f32 = fs + 4
    rect := rl.Rectangle{ ui_ctx.cursor.x, ui_ctx.cursor.y, width, h }
    changed := false

    mouse := rl.GetMousePosition()
    inside := rl.CheckCollisionPointRec(mouse, rect)
    if inside && ui_ctx.interaction_ok {
        ui_ctx.hot_item = id
        if rl.IsMouseButtonDown(.LEFT) {
            ui_ctx.active_item = id
        }
    }
    if ui_ctx.active_item == id && rl.IsMouseButtonDown(.LEFT) {
        frac := clamp((mouse.x - rect.x) / width, 0, 1)
        new_val := min + int(frac * f32(max - min))
        if new_val != value^ {
            value^ = new_val
            changed = true
        }
    }
    if rl.IsMouseButtonReleased(.LEFT) {
        ui_ctx.active_item = 0
    }

    rl.DrawRectangleRec(rect, ui_theme.second_bg)
    rl.DrawRectangleLinesEx(rect, 1, ui_theme.border)
    fill := f32(value^ - min) / f32(max - min) * width
    rl.DrawRectangle(i32(rect.x), i32(rect.y), i32(fill), i32(h), ui_theme.accent)
    label_text := fmt.ctprintf("%s: %d", label, value^)
    rl.DrawTextEx(font, label_text, rl.Vector2{rect.x+4, rect.y+2}, fs, 1, ui_theme.text)

    ui_ctx.cursor.y += h + 4
    return changed
}

ui_combo :: proc(label: string, items: []string, selected_index: ^int, width: f32) -> bool {
    id := widget_id(label)
    font := get_font()
    fs := font_size()
    h: f32 = fs + 4
    rect := rl.Rectangle{ ui_ctx.cursor.x, ui_ctx.cursor.y, width, h }
    changed := false

    mouse := rl.GetMousePosition()
    inside := rl.CheckCollisionPointRec(mouse, rect)
    if inside && ui_ctx.interaction_ok {
        ui_ctx.hot_item = id
    }
    if rl.IsMouseButtonPressed(.LEFT) && inside && ui_ctx.interaction_ok {
        ui_ctx.active_item = id
    }

    if ui_ctx.active_item == id {
        list_h := f32(len(items)) * h
        list_rect := rl.Rectangle{ rect.x, rect.y + h, width, list_h }
        rl.DrawRectangleRec(list_rect, ui_theme.button)
        rl.DrawRectangleLinesEx(list_rect, 1, ui_theme.border)
        for item, i in items {
            item_rect := rl.Rectangle{ rect.x, rect.y + h + f32(i)*h, width, h }
            if rl.CheckCollisionPointRec(mouse, item_rect) && rl.IsMouseButtonPressed(.LEFT) {
                selected_index^ = i
                changed = true
                ui_ctx.active_item = 0
            }
            col := ui_theme.button
            if i == selected_index^ {
                col = ui_theme.highlight
            }
            rl.DrawRectangleRec(item_rect, col)
            rl.DrawTextEx(font, fmt.ctprintf("%s", item), rl.Vector2{item_rect.x+4, item_rect.y+2}, fs, 1, ui_theme.text)
        }
        if rl.IsMouseButtonPressed(.LEFT) && !rl.CheckCollisionPointRec(mouse, list_rect) && !inside {
            ui_ctx.active_item = 0
        }
    }

    rl.DrawRectangleRec(rect, ui_theme.second_bg)
    rl.DrawRectangleLinesEx(rect, 1, ui_theme.border)
    txt := ""
    if selected_index^ >= 0 && selected_index^ < len(items) {
        txt = items[selected_index^]
    }
    rl.DrawTextEx(font, fmt.ctprintf("%s", txt), rl.Vector2{rect.x+4, rect.y+2}, fs, 1, ui_theme.text)
    rl.DrawTextEx(font, "v", rl.Vector2{rect.x+width-16, rect.y+2}, fs, 1, ui_theme.foreground)

    ui_ctx.cursor.y += h + 4
    return changed
}

ui_label :: proc(text: string) {
    font := get_font()
    fs := font_size()
    h := ui_ctx.line_height
    if h <= 0 do h = fs + 2
    pos := ui_ctx.cursor
    rl.DrawTextEx(font, fmt.ctprintf("%s", text), rl.Vector2{pos.x, pos.y}, fs, 1, ui_theme.text)
    ui_ctx.cursor.y += h + 2
}

ui_button :: proc(label: string) -> bool {
    font := get_font()
    fs := font_size()
    text_width := rl.MeasureTextEx(font, fmt.ctprintf("%s", label), fs, 1).x
    w := text_width + 16
    h := ui_ctx.line_height + 8
    if h <= 0 do h = fs + 8
    rect := rl.Rectangle{ ui_ctx.cursor.x, ui_ctx.cursor.y, w, h }

    id := widget_id(label)
    pressed := ui_item(rect, id)

    col := ui_theme.button
    if ui_ctx.hot_item == id {
        col = ui_theme.highlight
    }
    if ui_ctx.active_item == id && rl.IsMouseButtonDown(.LEFT) {
        col = ui_theme.active
    }

    rl.DrawRectangleRec(rect, col)
    rl.DrawRectangleLinesEx(rect, 1, ui_theme.border)
    text_pos := rl.Vector2{ rect.x + 8, rect.y + 4 }
    rl.DrawTextEx(font, fmt.ctprintf("%s", label), text_pos, fs, 1, ui_theme.text)

    ui_ctx.cursor.y += h + 4
    return pressed
}

ui_editor :: proc(
    state: ^UITextState,
    rect:  rl.Rectangle,
    show_line_numbers := true,
) {
    if ui_ctx.interaction_ok == false do return

    font := get_font()
    fs := font_size()
    line_h := ui_ctx.line_height
    if line_h <= 0 do line_h = fs + 2
    if ui_ctx.line_height <= 0 {
        ui_ctx.line_height = fs + 2
        line_h = ui_ctx.line_height
    }

    mouse := rl.GetMousePosition()
    inside := rl.CheckCollisionPointRec(mouse, rect)

    id := widget_id("editor")
    if inside && ui_ctx.interaction_ok {
        ui_ctx.hot_item = id
    }
    if inside && rl.IsMouseButtonPressed(.LEFT) && ui_ctx.interaction_ok {
        ui_ctx.active_item = id
    }
    if !inside && rl.IsMouseButtonPressed(.LEFT) {
        ui_ctx.active_item = 0
    }
    is_focused := ui_ctx.active_item == id && ui_ctx.interaction_ok

    if is_focused {
        handle_editor_input(state)
    }

    gutter_w: f32 = 40 if show_line_numbers else 0
    text_area_w := rect.width - gutter_w - 8
    text_area_h := rect.height - 8

    cursor_line, cursor_col := cursor_line_col(state)
    total_len := piece_table_total_len(&state.pt)
    visible_first_line := int(state.scroll_y / line_h)
    if cursor_line < visible_first_line {
        state.scroll_y = f32(cursor_line) * line_h
    } else if f32(cursor_line+1) * line_h > state.scroll_y + text_area_h {
        state.scroll_y = f32(cursor_line+1) * line_h - text_area_h
    }
    str := piece_table_get_string(&state.pt)
    total_lines := 0
    for ch in str {
        if ch == '\n' do total_lines += 1
    }
    total_lines += 1
    max_scroll := f32(total_lines) * line_h - text_area_h
    if max_scroll < 0 do max_scroll = 0
    if state.scroll_y > max_scroll do state.scroll_y = max_scroll
    if state.scroll_y < 0 do state.scroll_y = 0

    rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))
    defer rl.EndScissorMode()

    rl.DrawRectangleRec(rect, ui_theme.second_bg)
    rl.DrawRectangleLinesEx(rect, 1, ui_theme.border)

    if show_line_numbers {
        gutter_rect := rl.Rectangle{ rect.x, rect.y, gutter_w, rect.height }
        rl.DrawRectangleRec(gutter_rect, ui_theme.button)
        rl.DrawRectangleLinesEx(gutter_rect, 0, ui_theme.border)
    }

    lines := piece_table_get_lines(&state.pt)
    spacing : f32 = 1.0

    for i in 0 ..< len(lines) {
        line_y := rect.y + 4 + f32(i) * line_h - state.scroll_y
        if line_y + line_h < rect.y || line_y > rect.y + rect.height {
            continue
        }
        if show_line_numbers {
            num_text := fmt.ctprintf("%d", i+1)
            rl.DrawTextEx(font, num_text,
                rl.Vector2{ rect.x + 4, line_y },
                fs, spacing, ui_theme.gray,
            )
        }
        text_x := rect.x + gutter_w + 4
        rl.DrawTextEx(font, fmt.ctprintf("%s", lines[i]),
            rl.Vector2{ text_x, line_y },
            fs, spacing, ui_theme.text,
        )
    }

    if is_focused {
        cursor_line, cursor_col := cursor_line_col(state)
        line_str := lines[cursor_line] if cursor_line < len(lines) else ""
        prefix := fmt.ctprintf("%s", line_str[:cursor_col])
        cursor_x := rect.x + gutter_w + 4 + rl.MeasureTextEx(font, prefix, fs, spacing).x
        cursor_y := rect.y + 4 + f32(cursor_line) * line_h - state.scroll_y
        if cursor_y >= rect.y && cursor_y + line_h <= rect.y + rect.height {
            rl.DrawLine(
                i32(cursor_x), i32(cursor_y),
                i32(cursor_x), i32(cursor_y + line_h - 4),
                ui_theme.accent,
            )
        }
    }

    if total_lines > 0 {
        thumb_h := max(10, text_area_h * text_area_h / (f32(total_lines) * line_h))
        thumb_y := rect.y + 4 + (state.scroll_y / max_scroll) * (text_area_h - thumb_h) if max_scroll > 0 else rect.y + 4
        scrollbar_rect := rl.Rectangle{ rect.x + rect.width - 8, rect.y + 4, 6, text_area_h }
        rl.DrawRectangleRec(scrollbar_rect, ui_theme.border)
        thumb_rect := rl.Rectangle{ rect.x + rect.width - 8, thumb_y, 6, thumb_h }
        rl.DrawRectangleRec(thumb_rect, ui_theme.foreground)
    }
}

handle_editor_input :: proc(state: ^UITextState) {
    key := rl.GetKeyPressed()
    for key != .KEY_NULL {
        shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
        ctrl  := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)

        switch {
        case key == .BACKSPACE:
            text_backspace(state)
        case key == .DELETE:
            text_delete(state)
        case key == .LEFT:
            text_move_cursor_left(state, shift)
        case key == .RIGHT:
            text_move_cursor_right(state, shift)
        case key == .UP:
            move_cursor_vertical(state, -1, shift)
        case key == .DOWN:
            move_cursor_vertical(state, 1, shift)
        case key == .HOME:
            if ctrl {
                state.cursor = 0
            } else {
                line, _ := cursor_line_col(state)
                state.cursor = line_start_offset(state, line)
            }
            if !shift do state.selection_start = state.cursor
        case key == .END:
            if ctrl {
                state.cursor = piece_table_total_len(&state.pt)
            } else {
                line, _ := cursor_line_col(state)
                state.cursor = line_end_offset(state, line)
            }
            if !shift do state.selection_start = state.cursor
        case key == .PAGE_UP:
            for i in 0 ..< 20 do move_cursor_vertical(state, -1, shift)
        case key == .PAGE_DOWN:
            for i in 0 ..< 20 do move_cursor_vertical(state, 1, shift)
        case key == .A && ctrl:
            state.selection_start = 0
            state.cursor = piece_table_total_len(&state.pt)
        case key == .C && ctrl:
            selected := get_selected_text(state)
            rl.SetClipboardText(fmt.ctprintf("%s", selected))
        case key == .X && ctrl:
            selected := get_selected_text(state)
            rl.SetClipboardText(fmt.ctprintf("%s", selected))
            text_delete(state)
        case key == .V && ctrl:
            clip := rl.GetClipboardText()
            if clip != nil {
                for r in string(clip) do text_insert_char(state, r)
            }
        case key == .Z && ctrl:
            // undo not implemented
        case key == .ENTER:
            text_insert_char(state, '\n')
        case key == .TAB:
            text_insert_spaces(state, 4)
        case:
            if int(key) >= 32 && !ctrl {
                text_insert_char(state, rune(key))
            }
        }
        key = rl.GetKeyPressed()
    }
}