// The hex view: the raw bytes of a binary file as offset, hex and ASCII columns.
// Read-only. The bytes are borrowed from the open file.
package thor

import "core:fmt"
import "core:strings"

import "../font"
import ui "../vendor/loom/loom"

// Bytes shown in one row.
HEX_ROW_BYTES :: 16

// Character column where the hex block starts: 8 offset digits and two spaces.
HEX_COL_HEX :: 10

// Character column where the ASCII block starts.
HEX_COL_ASCII :: HEX_COL_HEX + HEX_ROW_BYTES * 3 + 2

// Characters in one row.
HEX_COLS :: HEX_COL_ASCII + HEX_ROW_BYTES

@(private = "file")
HEX_PAD :: f32(10)

@(private = "file")
HEX_BAR_WIDTH :: f32(10)

@(private = "file")
HEX_WHEEL_ROWS :: 3

// Scroll, caret and selection of one pane's hex view. Reset when the file changes.
Hex_View :: struct {
    file:    ^Open_File, // borrowed, the identity the state belongs to
    top_row: int,
    cursor:  int, // byte offset of the caret
    anchor:  int, // other end of the selection; equal to cursor when there is none
}

// Points the view at a file and resets it to the top.
@(private = "file")
hex_view_bind :: proc(view: ^Hex_View, file: ^Open_File) {
    if view.file == file {
        return
    }
    view^ = {file = file}
}

// Rows needed for `size` bytes.
hex_row_count :: proc(size: int) -> int {
    return (size + HEX_ROW_BYTES - 1) / HEX_ROW_BYTES
}

// Character column of byte `i` of a row in the hex block. A gap splits the two halves.
hex_byte_col :: proc(i: int) -> int {
    return HEX_COL_HEX + i * 3 + (i >= HEX_ROW_BYTES / 2 ? 1 : 0)
}

// Byte of a row under character column `col`, in the hex or the ASCII block.
hex_byte_at_col :: proc(col: int) -> (index: int, ok: bool) {
    if col >= HEX_COL_ASCII && col < HEX_COL_ASCII + HEX_ROW_BYTES {
        return col - HEX_COL_ASCII, true
    }
    for i in 0 ..< HEX_ROW_BYTES {
        start := hex_byte_col(i)
        if col >= start && col < start + 3 {
            return i, true
        }
    }
    return 0, false
}

// The printable form of a byte in the ASCII block.
@(private = "file")
hex_ascii :: proc(b: u8) -> u8 {
    return b >= 0x20 && b < 0x7f ? b : '.'
}

// One row as text: offset, hex block and ASCII block. A short last row pads its
// hex block, so the ASCII block stays aligned.
hex_row_text :: proc(bytes: []u8, row: int, allocator := context.temp_allocator) -> string {
    digits := "0123456789abcdef"
    start  := row * HEX_ROW_BYTES
    end    := min(start + HEX_ROW_BYTES, len(bytes))
    b      := strings.builder_make(0, HEX_COLS, allocator)
    fmt.sbprintf(&b, "%08x  ", start)
    for i in 0 ..< HEX_ROW_BYTES {
        if i == HEX_ROW_BYTES / 2 {
            strings.write_byte(&b, ' ')
        }
        if start + i < end {
            v := bytes[start + i]
            strings.write_byte(&b, digits[v >> 4])
            strings.write_byte(&b, digits[v & 0xf])
            strings.write_byte(&b, ' ')
        } else {
            strings.write_string(&b, "   ")
        }
    }
    strings.write_byte(&b, ' ')
    for i in start ..< end {
        strings.write_byte(&b, hex_ascii(bytes[i]))
    }
    return strings.to_string(b)
}

// The bytes in [lo, hi] as space-separated hex.
hex_selection_text :: proc(bytes: []u8, lo, hi: int, allocator := context.temp_allocator) -> string {
    if lo < 0 || hi >= len(bytes) || lo > hi {
        return ""
    }
    b := strings.builder_make(0, (hi - lo + 1) * 3, allocator)
    for i in lo ..= hi {
        if i > lo {
            strings.write_byte(&b, ' ')
        }
        fmt.sbprintf(&b, "%02x", bytes[i])
    }
    return strings.to_string(b)
}

// A byte count as B, KB, MB or GB.
@(private = "file")
hex_size_label :: proc(size: int) -> string {
    switch {
    case size < 1024:
        return fmt.tprintf("%d B", size)
    case size < 1024 * 1024:
        return fmt.tprintf("%.1f KB", f64(size) / 1024)
    case size < 1024 * 1024 * 1024:
        return fmt.tprintf("%.1f MB", f64(size) / (1024 * 1024))
    }
    return fmt.tprintf("%.2f GB", f64(size) / (1024 * 1024 * 1024))
}

// One pane of the editor column, in the slot the file's tab owns.
thor_hex_view :: proc(thor: ^Thor, view: ^Hex_View, file: ^Open_File, key: string) {
    hex_view_bind(view, file)
    bytes := file.binary_bytes

    pane := ui.begin({
        key = key,
        flags = {.Clip, .Clickable, .Focusable, .Draggable, .Wheel},
        // Relative, so it is the containing block of the absolute rows.
        props = {position = .Relative, w = ui.Grow(1), h = ui.Grow(1), bg = thor.theme.background, cursor = .Text},
    })
    defer ui.end()
    pane = thor_mouse_only(thor, pane)

    if pane.focused {
        thor.focus_owner = key
    }
    if thor.focus_request == key {
        ui.set_focus(pane.id)
        thor.focus_request = ""
    }
    if pane.rect.w <= 0 || pane.rect.h <= 0 {
        return
    }

    size   := i32(max(thor.config.general.font_size, 8))
    cell_w := f32(max(font.measure("M", size, ""), 1))
    row_h  := f32(font.line_height(size))
    rows   := hex_row_count(len(bytes))
    // One row for the column header, one for the info line.
    shown  := max(int((pane.rect.h - HEX_PAD * 2) / row_h) - 2, 1)
    last   := max(rows - shown, 0)

    hex_view_mouse(view, pane, len(bytes), cell_w, row_h, shown)
    if pane.focused {
        hex_view_keys(view, bytes, shown)
    }
    view.top_row = clamp(view.top_row, 0, last)

    lo, hi := min(view.cursor, view.anchor), max(view.cursor, view.anchor)
    props := ui.Props{position = .Absolute, font = thor.font_mono, font_size = f32(size), color = thor.theme.foreground, text_wrap = .None}

    header := props
    header.inset = {l = HEX_PAD, t = HEX_PAD}
    header.color = thor.theme.muted_color
    ui.label(hex_header_text(), {key = "header", props = header})

    for r in 0 ..< shown {
        row := view.top_row + r
        if row >= rows {
            break
        }
        y := HEX_PAD + f32(r + 1) * row_h
        hex_paint_row_marks(thor, row, y, cell_w, row_h, lo, hi, view.cursor, pane.focused)
        line := props
        line.inset = {l = HEX_PAD, t = y}
        ui.push_id_int(i64(r))
        ui.label(hex_row_text(bytes, row), {key = "row", props = line})
        ui.pop_id()
    }

    hex_scrollbar(thor, view, pane, rows, shown)
    hex_info(thor, view, file, size)
}

// The column header: the low nibble of each byte's offset.
@(private = "file")
hex_header_text :: proc() -> string {
    b := strings.builder_make(0, HEX_COLS, context.temp_allocator)
    strings.write_string(&b, "offset    ")
    for i in 0 ..< HEX_ROW_BYTES {
        if i == HEX_ROW_BYTES / 2 {
            strings.write_byte(&b, ' ')
        }
        fmt.sbprintf(&b, "%02x ", i)
    }
    strings.write_byte(&b, ' ')
    for i in 0 ..< HEX_ROW_BYTES {
        fmt.sbprintf(&b, "%x", i)
    }
    return strings.to_string(b)
}

// The selection and caret backgrounds of one row, in both blocks.
@(private = "file")
hex_paint_row_marks :: proc(thor: ^Thor, row: int, y, cell_w, row_h: f32, lo, hi, cursor: int, focused: bool) {
    start := row * HEX_ROW_BYTES
    if hi < start || lo >= start + HEX_ROW_BYTES {
        return
    }
    for i in 0 ..< HEX_ROW_BYTES {
        offset := start + i
        if offset < lo || offset > hi {
            continue
        }
        color := thor.theme.selection_background
        if offset == cursor && lo == hi {
            color = focused ? thor.theme.highlight : thor.theme.contrast
        }
        ui.paint_rect({HEX_PAD + f32(hex_byte_col(i)) * cell_w, y, cell_w * 2, row_h}, color)
        ui.paint_rect({HEX_PAD + f32(HEX_COL_ASCII + i) * cell_w, y, cell_w, row_h}, color)
    }
}

// Wheel scroll, and a click or drag that places the caret.
@(private = "file")
hex_view_mouse :: proc(view: ^Hex_View, pane: ui.Interaction, size: int, cell_w, row_h: f32, shown: int) {
    if pane.wheel.y != 0 {
        // Loom counts a wheel notch down as positive.
        view.top_row += pane.wheel.y > 0 ? HEX_WHEEL_ROWS : -HEX_WHEEL_ROWS
    }
    if !(pane.pressed || pane.dragging) || size == 0 {
        return
    }
    mouse     := ui.mouse_pos()
    col       := int((mouse.x - pane.rect.x - HEX_PAD) / cell_w)
    r         := int((mouse.y - pane.rect.y - HEX_PAD) / row_h) - 1
    index, ok := hex_byte_at_col(col)
    if !ok && pane.pressed {
        return
    }
    if !ok {
        index = col < HEX_COL_HEX ? 0 : HEX_ROW_BYTES - 1
    }
    // A drag past the top or bottom edge scrolls.
    if pane.dragging && r < 0 {
        view.top_row -= 1
    } else if pane.dragging && r >= shown {
        view.top_row += 1
    }
    offset := clamp((view.top_row + clamp(r, 0, shown - 1)) * HEX_ROW_BYTES + index, 0, size - 1)
    view.cursor = offset
    if pane.pressed && .Shift not_in ui.mods() {
        view.anchor = offset
    }
}

// Caret keys and copy. Shift extends the selection.
@(private = "file")
hex_view_keys :: proc(view: ^Hex_View, bytes: []u8, shown: int) {
    size := len(bytes)
    if size == 0 {
        return
    }
    if ui.take_key(.C, {.Ctrl}) {
        ui.set_clipboard_text(hex_selection_text(bytes, min(view.cursor, view.anchor), max(view.cursor, view.anchor)))
    }
    if ui.take_key(.A, {.Ctrl}) {
        view.anchor, view.cursor = 0, size - 1
    }
    for &ev in ui.keys() {
        if ev.consumed || ev.action == .Release || ev.mods - {.Shift} - {.Ctrl} != {} {
            continue
        }
        ctrl := .Ctrl in ev.mods
        next := view.cursor
        #partial switch ev.key {
        case .Left:
            next -= 1
        case .Right:
            next += 1
        case .Up:
            next -= HEX_ROW_BYTES
        case .Down:
            next += HEX_ROW_BYTES
        case .Page_Up:
            next -= shown * HEX_ROW_BYTES
        case .Page_Down:
            next += shown * HEX_ROW_BYTES
        case .Home:
            next = ctrl ? 0 : next - next % HEX_ROW_BYTES
        case .End:
            next = ctrl ? size - 1 : next - next % HEX_ROW_BYTES + HEX_ROW_BYTES - 1
        case:
            continue
        }
        ev.consumed = true
        view.cursor = clamp(next, 0, size - 1)
        if .Shift not_in ev.mods {
            view.anchor = view.cursor
        }
        row := view.cursor / HEX_ROW_BYTES
        if row < view.top_row {
            view.top_row = row
        } else if row >= view.top_row + shown {
            view.top_row = row - shown + 1
        }
    }
}

// A thumb on the right edge. A drag moves the view, a click on the track jumps there.
@(private = "file")
hex_scrollbar :: proc(thor: ^Thor, view: ^Hex_View, pane: ui.Interaction, rows, shown: int) {
    if rows <= shown {
        return
    }
    track   := ui.leaf(
        {
            key = "scrollbar",
            flags = {.Clickable, .Draggable},
            props = {position = .Absolute, inset = {r = 0, t = 0}, w = ui.Px(HEX_BAR_WIDTH), h = ui.Px(pane.rect.h)},
        },
    )
    track_h := pane.rect.h
    thumb_h := max(track_h * f32(shown) / f32(rows), 20)
    last    := rows - shown
    if track.pressed || track.dragging {
        y := ui.mouse_pos().y - pane.rect.y - thumb_h * 0.5
        view.top_row = clamp(int(y / max(track_h - thumb_h, 1) * f32(last) + 0.5), 0, last)
    }
    thumb_y := (track_h - thumb_h) * f32(view.top_row) / f32(last)
    ui.paint_rect({pane.rect.w - HEX_BAR_WIDTH, thumb_y, HEX_BAR_WIDTH, thumb_h}, track.hovered || track.dragging ? thor.theme.accent_color : thor.theme.border)
}

// Bottom-left overlay: name, size, the caret offset and the byte under it.
@(private = "file")
hex_info :: proc(thor: ^Thor, view: ^Hex_View, file: ^Open_File, size: i32) {
    bytes := file.binary_bytes
    text  := fmt.tprintf("%s   %s", file.name, hex_size_label(len(bytes)))
    if view.cursor < len(bytes) {
        v := bytes[view.cursor]
        text = fmt.tprintf("%s   offset 0x%x (%d)   value 0x%02x (%d)", text, view.cursor, view.cursor, v, v)
        if view.anchor != view.cursor {
            text = fmt.tprintf("%s   %d bytes selected", text, abs(view.cursor - view.anchor) + 1)
        }
    }
    ui.label(
        text,
        {
            key = "hex-info",
            props = {position = .Absolute, inset = {l = HEX_PAD, b = HEX_PAD * 0.5}, color = thor.theme.muted_color, font_size = f32(size), text_wrap = .None},
        },
    )
}
