package widgets

import "core:strings"
import rl "vendor:raylib"

import "../ui"

// Fired on every change while the picker is open — a drag frame, or a hex the user
// committed. The host applies it live.
Color_Preview_Proc :: #type proc(data: rawptr, id: string, color: rl.Color)
// Fired on OK: apply and persist.
Color_Commit_Proc :: #type proc(data: rawptr, id: string, color: rl.Color)
// Fired on Escape, Cancel or an outside click; the host restores what it had.
Color_Cancel_Proc :: #type proc(data: rawptr, id: string)

// Which field the pointer is dragging.
Color_Drag :: enum {
    None,
    Square,
    Hue,
    Alpha,
}

@(private = "file")
COLOR_PICKER_PAD :: f32(16)
@(private = "file")
COLOR_PICKER_SQUARE_HEIGHT :: f32(200)
@(private = "file")
COLOR_PICKER_STRIP_HEIGHT :: f32(16)
@(private = "file")
COLOR_PICKER_STRIP_GAP :: f32(10)
@(private = "file")
COLOR_PICKER_FIELD_HEIGHT :: f32(28)
@(private = "file")
COLOR_PICKER_SWATCH_WIDTH :: f32(44)
@(private = "file")
COLOR_PICKER_HEX_WIDTH :: f32(120)
@(private = "file")
COLOR_PICKER_BUTTON_WIDTH :: f32(80)
@(private = "file")
COLOR_PICKER_BUTTON_HEIGHT :: f32(30)
@(private = "file")
COLOR_PICKER_CHECKER :: f32(8)
@(private = "file")
COLOR_PICKER_ROUNDNESS :: f32(0.04)

// A centered modal that edits one color. The pointer drags a saturation/value
// square, a hue strip and an alpha strip; a hex field takes a typed value. Every
// change previews live, and Escape or an outside click asks the host to put back
// what it had.
//
// HSV is the authority while the picker is open: RGB loses the hue at saturation 0
// and both hue and saturation at value 0, so a drag into a corner and back out
// would come back a different color.
Color_Picker :: struct {
    using widget: ui.Widget,
    title:    string, // owned
    key:      string, // owned; the host's key for what is being edited
    hue:      f32,    // 0 to 360
    sat:      f32,    // 0 to 1
    val:      f32,    // 0 to 1
    alpha:    f32,    // 0 to 1
    // The color at open: the old swatch, and what a cancel means.
    original: rl.Color,
    // The hex field. Append-only with the caret at the end, so a fixed buffer and
    // a length replace a text widget: "#RRGGBBAA" is nine bytes.
    hex_buf:     [9]u8,
    hex_len:     int,
    hex_editing: bool,
    drag:     Color_Drag,
    preview:  Color_Preview_Proc,
    commit:   Color_Commit_Proc,
    cancel:   Color_Cancel_Proc,
    data:     rawptr,
    // Focus handed back here when the picker closes.
    return_focus: ^ui.Widget,
    box:      rl.Rectangle,
    width:    f32,
    height:   f32,
    header_height: f32,
    footer_height: f32,
    backdrop_color:   rl.Color,
    background_color: rl.Color,
    border_color:     rl.Color,
    header_color:     rl.Color,
    field_color:      rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    accent_color:     rl.Color,
}

color_picker_vtable := ui.Widget_VTable {
    layout = color_picker_layout,
    handle_event = color_picker_handle_event,
    draw = color_picker_draw,
    destroy = color_picker_destroy,
}

color_picker_create :: proc(id: string) -> ^Color_Picker {
    picker := new(Color_Picker)
    ui.widget_init(&picker.widget, id, color_picker_vtable)
    picker.visible = false
    picker.width = 340
    picker.height = 452
    picker.header_height = 44
    picker.footer_height = 46
    picker.backdrop_color = rl.Color {0, 0, 0, 120}
    picker.background_color = rl.Color {24, 26, 31, 250}
    picker.header_color = rl.Color {31, 34, 51, 255}
    picker.field_color = rl.Color {18, 20, 24, 255}
    picker.border_color = rl.Color {51, 56, 70, 255}
    picker.text_color = rl.Color {238, 255, 255, 255}
    picker.muted_color = rl.Color {120, 128, 160, 255}
    picker.accent_color = rl.Color {132, 255, 255, 255}
    return picker
}

color_picker_set_colors :: proc(
    picker: ^Color_Picker,
    background, border, header, field, text, muted, accent: rl.Color,
) -> ^Color_Picker {
    picker.background_color = background
    picker.border_color = border
    picker.header_color = header
    picker.field_color = field
    picker.text_color = text
    picker.muted_color = muted
    picker.accent_color = accent
    return picker
}

// Opens the picker over `color`. `id` rides back out on every callback, so one
// picker serves every row. `title` and `id` are copied.
color_picker_open :: proc(
    picker: ^Color_Picker,
    ctx: ^ui.Context,
    title, id: string,
    color: rl.Color,
    preview: Color_Preview_Proc,
    commit: Color_Commit_Proc,
    cancel: Color_Cancel_Proc,
    data: rawptr,
) {
    // Cloned before the old ones are freed: a caller can pass these back.
    heading := strings.clone(title)
    delete(picker.title)
    picker.title = heading
    key := strings.clone(id)
    delete(picker.key)
    picker.key = key

    picker.preview = preview
    picker.commit = commit
    picker.cancel = cancel
    picker.data = data
    picker.original = color
    picker.drag = .None
    picker.hex_editing = false
    // Nothing to keep from a previous color, so the state starts neutral and
    // color_picker_set_from_color fills what the conversion can recover.
    picker.hue, picker.sat, picker.val, picker.alpha = 0, 0, 0, 1
    color_picker_set_from_color(picker, color)
    color_picker_sync_hex(picker)

    picker.visible = true
    // A second open while already up must not clobber the real target with the
    // picker's own widget.
    if ctx.focused != &picker.widget {
        picker.return_focus = ctx.focused
    }
    ctx.focused = &picker.widget
    ui.widget_bring_to_front(&picker.widget)
}

color_picker_is_open :: proc(picker: ^Color_Picker) -> bool {
    return picker.visible
}

// The HSV state as RGBA: the single conversion out.
color_picker_color :: proc(picker: ^Color_Picker) -> rl.Color {
    color := rl.ColorFromHSV(picker.hue, picker.sat, picker.val)
    color.a = u8(clamp(picker.alpha, 0, 1) * 255 + 0.5)
    return color
}

// Takes the HSV the conversion can recover and keeps the rest. A grey color has no
// hue and black has no saturation, so those stay as they were.
@(private = "file")
color_picker_set_from_color :: proc(picker: ^Color_Picker, color: rl.Color) {
    hsv := rl.ColorToHSV(color)
    if hsv.y > 0 {
        picker.hue = hsv.x
    }
    if hsv.z > 0 {
        picker.sat = hsv.y
    }
    picker.val = hsv.z
    picker.alpha = f32(color.a) / 255
}

@(private = "file")
color_picker_close :: proc(picker: ^Color_Picker, ctx: ^ui.Context) {
    picker.visible = false
    picker.drag = .None
    picker.hex_editing = false
    if ctx.focused == &picker.widget {
        ctx.focused = picker.return_focus
    }
}

// Confirms: hands the color to the host, then closes.
@(private = "file")
color_picker_confirm :: proc(picker: ^Color_Picker, ctx: ^ui.Context) {
    color := color_picker_color(picker)
    commit := picker.commit
    data := picker.data
    id := strings.clone(picker.key, context.temp_allocator)
    color_picker_close(picker, ctx)
    if commit != nil {
        commit(data, id, color)
    }
}

// Cancels: asks the host to put back what it had, then closes.
@(private = "file")
color_picker_dismiss :: proc(picker: ^Color_Picker, ctx: ^ui.Context) {
    cancel := picker.cancel
    data := picker.data
    id := strings.clone(picker.key, context.temp_allocator)
    color_picker_close(picker, ctx)
    if cancel != nil {
        cancel(data, id)
    }
}

@(private = "file")
color_picker_notify :: proc(picker: ^Color_Picker) {
    color_picker_sync_hex(picker)
    if picker.preview != nil {
        picker.preview(picker.data, picker.key, color_picker_color(picker))
    }
}

color_picker_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    picker := cast(^Color_Picker) widget
    // Cover the whole screen so clicks outside the box dismiss the picker.
    picker.bounds = bounds

    width := min(picker.width, bounds.width - 40)
    height := min(picker.height, bounds.height - 40)
    picker.box = rl.Rectangle {
        x = bounds.x + (bounds.width - width) * 0.5,
        y = bounds.y + (bounds.height - height) * 0.5,
        width = width,
        height = height,
    }
}

// Geometry is fixed and never measures text: ui.measure_text needs the font atlas,
// and the tests drive layout and handle_event with no window.
@(private = "file")
color_picker_content_width :: proc(picker: ^Color_Picker) -> f32 {
    return picker.box.width - COLOR_PICKER_PAD * 2
}

@(private)
color_picker_square_rect :: proc(picker: ^Color_Picker) -> rl.Rectangle {
    return rl.Rectangle {
        picker.box.x + COLOR_PICKER_PAD,
        picker.box.y + picker.header_height + 12,
        color_picker_content_width(picker),
        COLOR_PICKER_SQUARE_HEIGHT,
    }
}

@(private)
color_picker_hue_rect :: proc(picker: ^Color_Picker) -> rl.Rectangle {
    square := color_picker_square_rect(picker)
    return rl.Rectangle {
        square.x, square.y + square.height + COLOR_PICKER_STRIP_GAP, square.width, COLOR_PICKER_STRIP_HEIGHT,
    }
}

@(private)
color_picker_alpha_rect :: proc(picker: ^Color_Picker) -> rl.Rectangle {
    hue := color_picker_hue_rect(picker)
    return rl.Rectangle {
        hue.x, hue.y + hue.height + COLOR_PICKER_STRIP_GAP, hue.width, COLOR_PICKER_STRIP_HEIGHT,
    }
}

// Top of the swatch and hex row.
@(private = "file")
color_picker_row_y :: proc(picker: ^Color_Picker) -> f32 {
    alpha := color_picker_alpha_rect(picker)
    return alpha.y + alpha.height + COLOR_PICKER_STRIP_GAP + 6
}

@(private = "file")
color_picker_old_rect :: proc(picker: ^Color_Picker) -> rl.Rectangle {
    return rl.Rectangle {
        picker.box.x + COLOR_PICKER_PAD, color_picker_row_y(picker),
        COLOR_PICKER_SWATCH_WIDTH, COLOR_PICKER_FIELD_HEIGHT,
    }
}

@(private = "file")
color_picker_new_rect :: proc(picker: ^Color_Picker) -> rl.Rectangle {
    old := color_picker_old_rect(picker)
    return rl.Rectangle {old.x + old.width, old.y, COLOR_PICKER_SWATCH_WIDTH, COLOR_PICKER_FIELD_HEIGHT}
}

@(private)
color_picker_hex_rect :: proc(picker: ^Color_Picker) -> rl.Rectangle {
    return rl.Rectangle {
        picker.box.x + picker.box.width - COLOR_PICKER_PAD - COLOR_PICKER_HEX_WIDTH,
        color_picker_row_y(picker),
        COLOR_PICKER_HEX_WIDTH,
        COLOR_PICKER_FIELD_HEIGHT,
    }
}

@(private)
color_picker_ok_rect :: proc(picker: ^Color_Picker) -> rl.Rectangle {
    return rl.Rectangle {
        picker.box.x + picker.box.width - COLOR_PICKER_PAD - COLOR_PICKER_BUTTON_WIDTH,
        picker.box.y + picker.box.height - picker.footer_height +
            (picker.footer_height - COLOR_PICKER_BUTTON_HEIGHT) * 0.5,
        COLOR_PICKER_BUTTON_WIDTH,
        COLOR_PICKER_BUTTON_HEIGHT,
    }
}

@(private)
color_picker_cancel_rect :: proc(picker: ^Color_Picker) -> rl.Rectangle {
    ok := color_picker_ok_rect(picker)
    return rl.Rectangle {ok.x - COLOR_PICKER_BUTTON_WIDTH - 10, ok.y, COLOR_PICKER_BUTTON_WIDTH, ok.height}
}

@(private = "file")
color_picker_close_rect :: proc(picker: ^Color_Picker) -> rl.Rectangle {
    return rl.Rectangle {picker.box.x + picker.box.width - 32, picker.box.y + 11, 22, 22}
}

color_picker_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    picker := cast(^Color_Picker) widget
    if !picker.visible {
        return false
    }

    #partial switch event.kind {
    case .Key_Press:
        #partial switch event.key {
        case .ESCAPE:
            // A hex being typed is abandoned first, so one Escape does not also
            // throw the color away.
            if picker.hex_editing {
                picker.hex_editing = false
                color_picker_sync_hex(picker)
            } else {
                color_picker_dismiss(picker, ctx)
            }
        case .ENTER, .KP_ENTER:
            if picker.hex_editing {
                picker.hex_editing = false
                if color_picker_commit_hex(picker) {
                    color_picker_notify(picker)
                } else {
                    color_picker_sync_hex(picker)
                }
            } else {
                color_picker_confirm(picker, ctx)
            }
        case .BACKSPACE:
            color_picker_hex_backspace(picker)
        }
        return true

    case .Text_Input:
        if picker.hex_editing {
            color_picker_hex_input(picker, event.codepoint)
        }
        return true

    case .Mouse_Down:
        color_picker_press(picker, ctx, event.mouse_position)
        return true

    case .Mouse_Move:
        // Routed here by the press capture, wherever the cursor now is.
        if picker.drag != .None {
            color_picker_drag_to(picker, event.mouse_position)
            color_picker_notify(picker)
        }
        return true

    case .Mouse_Up:
        picker.drag = .None
        return true
    }

    return true // block everything else from reaching widgets underneath
}

@(private = "file")
color_picker_press :: proc(picker: ^Color_Picker, ctx: ^ui.Context, point: rl.Vector2) {
    if !rl.CheckCollisionPointRec(point, picker.box) {
        color_picker_dismiss(picker, ctx)
        return
    }
    if rl.CheckCollisionPointRec(point, color_picker_close_rect(picker)) ||
       rl.CheckCollisionPointRec(point, color_picker_cancel_rect(picker)) {
        color_picker_dismiss(picker, ctx)
        return
    }
    if rl.CheckCollisionPointRec(point, color_picker_ok_rect(picker)) {
        color_picker_confirm(picker, ctx)
        return
    }
    if rl.CheckCollisionPointRec(point, color_picker_hex_rect(picker)) {
        picker.hex_editing = true
        return
    }

    // Anywhere else in the box ends a hex edit, keeping what was typed if it parses.
    if picker.hex_editing {
        picker.hex_editing = false
        if !color_picker_commit_hex(picker) {
            color_picker_sync_hex(picker)
        }
    }

    switch {
    case rl.CheckCollisionPointRec(point, color_picker_square_rect(picker)):
        picker.drag = .Square
    case rl.CheckCollisionPointRec(point, color_picker_hue_rect(picker)):
        picker.drag = .Hue
    case rl.CheckCollisionPointRec(point, color_picker_alpha_rect(picker)):
        picker.drag = .Alpha
    case:
        return
    }
    color_picker_drag_to(picker, point)
    color_picker_notify(picker)
}

// Writes only the components the dragged field owns, never converting through
// RGB — that is what keeps the hue through a drag to saturation or value 0.
@(private = "file")
color_picker_drag_to :: proc(picker: ^Color_Picker, point: rl.Vector2) {
    switch picker.drag {
    case .Square:
        rect := color_picker_square_rect(picker)
        picker.sat = clamp((point.x - rect.x) / rect.width, 0, 1)
        picker.val = 1 - clamp((point.y - rect.y) / rect.height, 0, 1)
    case .Hue:
        rect := color_picker_hue_rect(picker)
        picker.hue = clamp((point.x - rect.x) / rect.width, 0, 1) * 360
    case .Alpha:
        rect := color_picker_alpha_rect(picker)
        picker.alpha = clamp((point.x - rect.x) / rect.width, 0, 1)
    case .None:
    }
}

// Rewrites the field from the current color.
@(private = "file")
color_picker_sync_hex :: proc(picker: ^Color_Picker) {
    hex := ui.color_to_hex(color_picker_color(picker), context.temp_allocator)
    picker.hex_len = min(len(hex), len(picker.hex_buf))
    copy(picker.hex_buf[:picker.hex_len], hex[:picker.hex_len])
}

// Takes the typed field as the color. A value that does not parse leaves the state
// alone, so a half-typed hex cannot wipe it.
@(private = "file")
color_picker_commit_hex :: proc(picker: ^Color_Picker) -> bool {
    color, ok := ui.parse_hex_color(string(picker.hex_buf[:picker.hex_len]))
    if !ok {
        return false
    }
    color_picker_set_from_color(picker, color)
    return true
}

@(private = "file")
color_picker_hex_input :: proc(picker: ^Color_Picker, codepoint: rune) {
    switch codepoint {
    case '#':
        // Only ever the first character, and the field always carries it.
        return
    case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
    case:
        return
    }
    if picker.hex_len >= len(picker.hex_buf) {
        return
    }
    // A field cleared to nothing regains its "#" with the first digit.
    if picker.hex_len == 0 {
        picker.hex_buf[0] = '#'
        picker.hex_len = 1
    }
    picker.hex_buf[picker.hex_len] = u8(codepoint)
    picker.hex_len += 1
}

@(private = "file")
color_picker_hex_backspace :: proc(picker: ^Color_Picker) {
    if !picker.hex_editing || picker.hex_len == 0 {
        return
    }
    picker.hex_len -= 1
    // The lone "#" goes too, so the field can be emptied.
    if picker.hex_len == 1 {
        picker.hex_len = 0
    }
}

color_picker_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    picker := cast(^Color_Picker) widget
    if !picker.visible {
        return
    }

    rl.DrawRectangleRec(picker.bounds, picker.backdrop_color)
    rl.DrawRectangleRounded(picker.box, COLOR_PICKER_ROUNDNESS, 8, picker.background_color)
    header := rl.Rectangle {picker.box.x, picker.box.y, picker.box.width, picker.header_height}
    rl.DrawRectangleRec(header, picker.header_color)
    rl.DrawRectangleRoundedLinesEx(picker.box, COLOR_PICKER_ROUNDNESS, 8, 1, picker.border_color)

    ui.draw_text(
        picker.title,
        cast(i32) (picker.box.x + 14),
        cast(i32) (picker.box.y + (picker.header_height - 18) * 0.5),
        18,
        picker.text_color,
    )
    ui.draw_text(
        "x",
        cast(i32) (color_picker_close_rect(picker).x + 7),
        cast(i32) (color_picker_close_rect(picker).y + 3),
        18,
        picker.muted_color,
    )

    color_picker_draw_square(picker)
    color_picker_draw_hue(picker)
    color_picker_draw_alpha(picker)
    color_picker_draw_swatches(picker)
    color_picker_draw_hex(picker)
    color_picker_draw_buttons(picker, ctx.mouse_pos)
}

@(private = "file")
color_picker_draw_square :: proc(picker: ^Color_Picker) {
    rect := color_picker_square_rect(picker)
    // raylib takes the corners top-left, bottom-left, bottom-right, top-right,
    // which is exactly the saturation/value square.
    rl.DrawRectangleGradientEx(rect, rl.WHITE, rl.BLACK, rl.BLACK, rl.ColorFromHSV(picker.hue, 1, 1))
    rl.DrawRectangleLinesEx(rect, 1, picker.border_color)
    color_picker_draw_marker(
        rl.Vector2 {rect.x + picker.sat * rect.width, rect.y + (1 - picker.val) * rect.height},
        6,
        rl.ColorFromHSV(picker.hue, picker.sat, picker.val),
    )
}

// Six exact segments, against one draw call per pixel column.
@(private = "file")
color_picker_draw_hue :: proc(picker: ^Color_Picker) {
    rect := color_picker_hue_rect(picker)
    step := rect.width / 6
    for i in 0 ..< 6 {
        left := rl.ColorFromHSV(f32(i) * 60, 1, 1)
        right := rl.ColorFromHSV(f32(i + 1) * 60, 1, 1)
        rl.DrawRectangleGradientH(
            cast(i32) (rect.x + f32(i) * step), cast(i32) rect.y,
            cast(i32) (step + 1), cast(i32) rect.height,
            left, right,
        )
    }
    rl.DrawRectangleLinesEx(rect, 1, picker.border_color)
    color_picker_draw_marker(
        rl.Vector2 {rect.x + picker.hue / 360 * rect.width, rect.y + rect.height * 0.5},
        6,
        rl.ColorFromHSV(picker.hue, 1, 1),
    )
}

@(private = "file")
color_picker_draw_alpha :: proc(picker: ^Color_Picker) {
    rect := color_picker_alpha_rect(picker)
    color_picker_draw_checker(picker, rect)
    solid := rl.ColorFromHSV(picker.hue, picker.sat, picker.val)
    rl.DrawRectangleGradientH(
        cast(i32) rect.x, cast(i32) rect.y, cast(i32) rect.width, cast(i32) rect.height,
        rl.Color {solid.r, solid.g, solid.b, 0}, rl.Color {solid.r, solid.g, solid.b, 255},
    )
    rl.DrawRectangleLinesEx(rect, 1, picker.border_color)
    color_picker_draw_marker(
        rl.Vector2 {rect.x + picker.alpha * rect.width, rect.y + rect.height * 0.5}, 6, color_picker_color(picker),
    )
}

// Tiles the squares a translucent color is read against.
@(private = "file")
color_picker_draw_checker :: proc(picker: ^Color_Picker, rect: rl.Rectangle) {
    ui.begin_clip(rect)
    defer ui.end_clip()

    dark := picker.field_color
    light := ui.color_mix(picker.field_color, picker.muted_color, 0.35)
    rows := int(rect.height / COLOR_PICKER_CHECKER) + 1
    columns := int(rect.width / COLOR_PICKER_CHECKER) + 1
    for row in 0 ..< rows {
        for column in 0 ..< columns {
            rl.DrawRectangleRec(
                rl.Rectangle {
                    rect.x + f32(column) * COLOR_PICKER_CHECKER,
                    rect.y + f32(row) * COLOR_PICKER_CHECKER,
                    COLOR_PICKER_CHECKER,
                    COLOR_PICKER_CHECKER,
                },
                (row + column) % 2 == 0 ? dark : light,
            )
        }
    }
}

// A two-ring circle, so the marker reads on any value under it.
@(private = "file")
color_picker_draw_marker :: proc(center: rl.Vector2, radius: f32, under: rl.Color) {
    inner := ui.color_on(under)
    outer := inner == ui.COLOR_ON_LIGHT ? ui.COLOR_ON_DARK : ui.COLOR_ON_LIGHT
    rl.DrawCircleLinesV(center, radius, outer)
    rl.DrawCircleLinesV(center, radius - 1, inner)
}

@(private = "file")
color_picker_draw_swatches :: proc(picker: ^Color_Picker) {
    old := color_picker_old_rect(picker)
    new_rect := color_picker_new_rect(picker)
    current := color_picker_color(picker)

    if picker.original.a < 0xFF {
        color_picker_draw_checker(picker, old)
    }
    if current.a < 0xFF {
        color_picker_draw_checker(picker, new_rect)
    }
    rl.DrawRectangleRec(old, picker.original)
    rl.DrawRectangleRec(new_rect, current)
    rl.DrawRectangleLinesEx(rl.Rectangle {old.x, old.y, old.width + new_rect.width, old.height}, 1, picker.border_color)
}

@(private = "file")
color_picker_draw_hex :: proc(picker: ^Color_Picker) {
    rect := color_picker_hex_rect(picker)
    rl.DrawRectangleRec(rect, picker.field_color)
    rl.DrawRectangleLinesEx(rect, 1, picker.hex_editing ? picker.accent_color : picker.border_color)
    ui.draw_text(
        string(picker.hex_buf[:picker.hex_len]),
        cast(i32) (rect.x + 8),
        cast(i32) (rect.y + (rect.height - 16) * 0.5),
        16,
        picker.text_color,
    )
}

@(private = "file")
color_picker_draw_buttons :: proc(picker: ^Color_Picker, mouse: rl.Vector2) {
    cancel := color_picker_cancel_rect(picker)
    hovered := rl.CheckCollisionPointRec(mouse, cancel)
    rl.DrawRectangleRounded(cancel, 0.2, 6, hovered ? picker.header_color : picker.field_color)
    ui.draw_text(
        "Cancel", cast(i32) (cancel.x + 16), cast(i32) (cancel.y + (cancel.height - 16) * 0.5), 16, picker.muted_color,
    )

    ok := color_picker_ok_rect(picker)
    hovered = rl.CheckCollisionPointRec(mouse, ok)
    rl.DrawRectangleRounded(ok, 0.2, 6, hovered ? ui.color_shade(picker.accent_color, 0.10) : picker.accent_color)
    ui.draw_text(
        "OK", cast(i32) (ok.x + 30), cast(i32) (ok.y + (ok.height - 16) * 0.5), 16, ui.color_on(picker.accent_color),
    )
}

color_picker_destroy :: proc(widget: ^ui.Widget) {
    picker := cast(^Color_Picker) widget
    delete(picker.title)
    delete(picker.key)
    free(picker)
}
