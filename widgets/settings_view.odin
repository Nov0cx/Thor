package widgets

import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

import "../ui"

// A centered modal that edits every setting in one place: the numeric editor
// preferences, the theme/font pickers, and the full keybinding list. The host
// (thor) fills it with rows and persists the callbacks' effects, so the widget
// stays free of any settings-format knowledge.

// Fired when a number stepper is nudged; `value` is the already-clamped result.
Settings_Number_Proc :: #type proc(data: rawptr, id: string, value: int)
// Fired when a choice row is clicked; the host opens its own picker for `id`.
Settings_Choice_Proc :: #type proc(data: rawptr, id: string)
// Fired when a keybinding is captured or cleared; key = .KEY_NULL means unbind.
Settings_Keybind_Proc :: #type proc(data: rawptr, id: string, key: rl.KeyboardKey, ctrl, shift, alt: bool)

Settings_Row_Kind :: enum {
    Header,  // a non-interactive section title
    Number,  // label + [-] value [+] stepper
    Choice,  // label + value; clicking asks the host to open a picker
    Keybind, // label + chord; clicking captures a new chord, a clear box unbinds
}

Settings_Row :: struct {
    kind:  Settings_Row_Kind,
    id:    string, // owned; stable key handed back to the callbacks
    label: string, // owned
    value: string, // owned; formatted display (number, choice, chord)
    number:            int,
    min, max, step:    int,
}

Settings_View :: struct {
    using widget: ui.Widget,
    rows:         [dynamic]Settings_Row,
    // Row currently capturing a chord (-1 = none). While set, the host suppresses
    // its global shortcuts so the press reaches this widget.
    capturing:    int,
    scroll:       f32,
    box:          rl.Rectangle,
    width:        f32,
    row_height:   f32,
    header_height: f32,
    // Callbacks into the host.
    on_number:    Settings_Number_Proc,
    on_choice:    Settings_Choice_Proc,
    on_keybind:   Settings_Keybind_Proc,
    data:         rawptr,
    return_focus: ^ui.Widget,
    background_color: rl.Color,
    border_color:     rl.Color,
    header_color:     rl.Color,
    field_color:      rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    accent_color:     rl.Color,
}

settings_view_vtable := ui.Widget_VTable {
    layout = settings_view_layout,
    handle_event = settings_view_handle_event,
    draw = settings_view_draw,
    destroy = settings_view_destroy,
}

settings_view_create :: proc(id: string) -> ^Settings_View {
    view := new(Settings_View)
    ui.widget_init(&view.widget, id, settings_view_vtable)
    view.visible = false
    view.rows = make([dynamic]Settings_Row)
    view.capturing = -1
    view.width = 640
    view.row_height = 34
    view.header_height = 46
    view.background_color = rl.Color {24, 26, 31, 250}
    view.header_color = rl.Color {31, 34, 51, 255}
    view.field_color = rl.Color {18, 20, 24, 255}
    view.border_color = rl.Color {132, 255, 255, 255}
    view.text_color = rl.Color {238, 255, 255, 255}
    view.muted_color = rl.Color {120, 128, 160, 255}
    view.accent_color = rl.Color {132, 255, 255, 255}
    return view
}

settings_view_set_colors :: proc(
    view: ^Settings_View,
    background, border, header, field, text, muted, accent: rl.Color,
) -> ^Settings_View {
    view.background_color = background
    view.border_color = border
    view.header_color = header
    view.field_color = field
    view.text_color = text
    view.muted_color = muted
    view.accent_color = accent
    return view
}

settings_view_set_callbacks :: proc(
    view: ^Settings_View,
    on_number: Settings_Number_Proc,
    on_choice: Settings_Choice_Proc,
    on_keybind: Settings_Keybind_Proc,
    data: rawptr,
) {
    view.on_number = on_number
    view.on_choice = on_choice
    view.on_keybind = on_keybind
    view.data = data
}

// Drops every row, keeping scroll/capture so a live repopulate (after a change
// persists and reloads) does not jump the view. settings_view_open resets those.
settings_view_clear :: proc(view: ^Settings_View) {
    for row in view.rows {
        delete(row.id)
        delete(row.label)
        delete(row.value)
    }
    clear(&view.rows)
}

settings_view_add_header :: proc(view: ^Settings_View, label: string) {
    append(&view.rows, Settings_Row {kind = .Header, label = strings.clone(label)})
}

settings_view_add_number :: proc(view: ^Settings_View, id, label: string, value, min, max, step: int) {
    buf: [32]u8
    append(&view.rows, Settings_Row {
        kind = .Number,
        id = strings.clone(id),
        label = strings.clone(label),
        value = strings.clone(strconv.write_int(buf[:], cast(i64) value, 10)),
        number = value,
        min = min,
        max = max,
        step = step,
    })
}

settings_view_add_choice :: proc(view: ^Settings_View, id, label, value: string) {
    append(&view.rows, Settings_Row {
        kind = .Choice,
        id = strings.clone(id),
        label = strings.clone(label),
        value = strings.clone(value),
    })
}

// `chord` is the display string ("Ctrl+K"), or "" for an unbound action.
settings_view_add_keybind :: proc(view: ^Settings_View, id, label, chord: string) {
    append(&view.rows, Settings_Row {
        kind = .Keybind,
        id = strings.clone(id),
        label = strings.clone(label),
        value = strings.clone(chord),
    })
}

settings_view_open :: proc(view: ^Settings_View, ctx: ^ui.Context) {
    view.scroll = 0
    view.capturing = -1
    view.visible = true
    view.return_focus = ctx.focused
    ctx.focused = &view.widget
    ui.widget_bring_to_front(&view.widget)
}

settings_view_is_open :: proc(view: ^Settings_View) -> bool {
    return view != nil && view.visible
}

// True while a keybinding row is waiting for a chord; the host checks this to
// step aside so the next press reaches the widget instead of firing a shortcut.
settings_view_is_capturing :: proc(view: ^Settings_View) -> bool {
    return view != nil && view.visible && view.capturing >= 0
}

@(private = "file")
settings_view_close :: proc(view: ^Settings_View, ctx: ^ui.Context) {
    view.visible = false
    view.capturing = -1
    if ctx.focused == &view.widget {
        ctx.focused = view.return_focus
    }
}

settings_view_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    view := cast(^Settings_View) widget
    // Cover the whole screen so clicks outside the box dismiss the dialog.
    view.bounds = bounds

    width := min(view.width, bounds.width - 80)
    content := cast(f32) len(view.rows) * view.row_height
    max_height := bounds.height * 0.82
    height := min(view.header_height + content + 12, max_height)

    view.box = rl.Rectangle {
        x = bounds.x + (bounds.width - width) * 0.5,
        y = bounds.y + (bounds.height - height) * 0.5,
        width = width,
        height = height,
    }
    settings_view_clamp_scroll(view)
}

// Height of the scrollable list area below the header.
@(private = "file")
settings_view_list_height :: proc(view: ^Settings_View) -> f32 {
    return view.box.height - view.header_height - 12
}

@(private = "file")
settings_view_max_scroll :: proc(view: ^Settings_View) -> f32 {
    content := cast(f32) len(view.rows) * view.row_height
    return max(0, content - settings_view_list_height(view))
}

@(private = "file")
settings_view_clamp_scroll :: proc(view: ^Settings_View) {
    view.scroll = clamp(view.scroll, 0, settings_view_max_scroll(view))
}

// Screen rect of row `i` accounting for scroll; may fall outside the list area.
@(private = "file")
settings_view_row_rect :: proc(view: ^Settings_View, i: int) -> rl.Rectangle {
    top := view.box.y + view.header_height + cast(f32) i * view.row_height - view.scroll
    return rl.Rectangle {view.box.x, top, view.box.width, view.row_height}
}

// Row under `point`, or -1 when the point is outside the list area or its rows.
@(private = "file")
settings_view_row_at :: proc(view: ^Settings_View, point: rl.Vector2) -> int {
    list_top := view.box.y + view.header_height
    list := rl.Rectangle {view.box.x, list_top, view.box.width, settings_view_list_height(view)}
    if !rl.CheckCollisionPointRec(point, list) {
        return -1
    }
    row := cast(int) ((point.y - list_top + view.scroll) / view.row_height)
    if row < 0 || row >= len(view.rows) {
        return -1
    }
    return row
}

// The three hit rects on a Number row: minus button, value box, plus button.
@(private = "file")
settings_view_number_rects :: proc(view: ^Settings_View, row: rl.Rectangle) -> (minus, value, plus: rl.Rectangle) {
    btn: f32 = 28
    val_w: f32 = 58
    pad: f32 = 14
    cy := row.y + (row.height - btn) * 0.5
    plus = rl.Rectangle {row.x + row.width - pad - btn, cy, btn, btn}
    value = rl.Rectangle {plus.x - val_w, cy, val_w, btn}
    minus = rl.Rectangle {value.x - btn, cy, btn, btn}
    return
}

// The clear ("unbind") box on a Keybind row, at its right edge.
@(private = "file")
settings_view_clear_rect :: proc(view: ^Settings_View, row: rl.Rectangle) -> rl.Rectangle {
    btn: f32 = 28
    pad: f32 = 14
    cy := row.y + (row.height - btn) * 0.5
    return rl.Rectangle {row.x + row.width - pad - btn, cy, btn, btn}
}

settings_view_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    view := cast(^Settings_View) widget
    if !view.visible {
        return false
    }

    #partial switch event.kind {
    case .Key_Press:
        if view.capturing >= 0 {
            settings_view_capture_key(view, event)
        } else if event.key == .ESCAPE {
            settings_view_close(view, ctx)
        }
        return true

    case .Text_Input:
        return true // swallow so a bound letter never types underneath

    case .Scroll:
        view.scroll -= event.wheel_delta * view.row_height
        settings_view_clamp_scroll(view)
        return true

    case .Mouse_Down:
        if !rl.CheckCollisionPointRec(event.mouse_position, view.box) {
            settings_view_close(view, ctx)
            return true
        }
        // A press anywhere else cancels an in-progress capture.
        if view.capturing >= 0 {
            view.capturing = -1
            return true
        }
        settings_view_click(view, event.mouse_position)
        return true
    }

    return true // block everything underneath while open
}

// Commits or cancels a chord capture. Modifier-only presses are ignored so the
// widget waits for the real key; Escape cancels without changing the binding.
@(private = "file")
settings_view_capture_key :: proc(view: ^Settings_View, event: ^ui.Event) {
    #partial switch event.key {
    case .LEFT_CONTROL, .RIGHT_CONTROL, .LEFT_SHIFT, .RIGHT_SHIFT, .LEFT_ALT, .RIGHT_ALT:
        return
    case .ESCAPE:
        view.capturing = -1
        return
    }
    row := view.capturing
    view.capturing = -1
    if row >= 0 && row < len(view.rows) && view.on_keybind != nil {
        view.on_keybind(view.data, view.rows[row].id, event.key, event.ctrl, event.shift, event.alt)
    }
}

// Routes a click inside the box to the row control under it. May trigger a
// callback that repopulates the rows, so it reads nothing from the row afterward.
@(private = "file")
settings_view_click :: proc(view: ^Settings_View, point: rl.Vector2) {
    row := settings_view_row_at(view, point)
    if row < 0 {
        return
    }
    rect := settings_view_row_rect(view, row)
    item := &view.rows[row]

    switch item.kind {
    case .Header:
        // Not interactive.
    case .Number:
        minus, _, plus := settings_view_number_rects(view, rect)
        delta := 0
        if rl.CheckCollisionPointRec(point, minus) {
            delta = -item.step
        } else if rl.CheckCollisionPointRec(point, plus) {
            delta = item.step
        }
        if delta != 0 {
            next := clamp(item.number + delta, item.min, item.max)
            if next != item.number && view.on_number != nil {
                view.on_number(view.data, item.id, next)
            }
        }
    case .Choice:
        if view.on_choice != nil {
            view.on_choice(view.data, item.id)
        }
    case .Keybind:
        if rl.CheckCollisionPointRec(point, settings_view_clear_rect(view, rect)) {
            if view.on_keybind != nil {
                view.on_keybind(view.data, item.id, .KEY_NULL, false, false, false)
            }
        } else {
            view.capturing = row
        }
    }
}

settings_view_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    view := cast(^Settings_View) widget
    if !view.visible {
        return
    }

    rl.DrawRectangleRec(view.bounds, rl.Color {0, 0, 0, 120})
    rl.DrawRectangleRec(view.box, view.background_color)

    header := rl.Rectangle {view.box.x, view.box.y, view.box.width, view.header_height}
    rl.DrawRectangleRec(header, view.header_color)
    ui.draw_text(
        "Settings",
        cast(i32) (view.box.x + 16),
        cast(i32) (view.box.y + (view.header_height - 20) * 0.5),
        20,
        view.text_color,
    )
    rl.DrawRectangleLinesEx(view.box, 1, view.border_color)

    list := rl.Rectangle {
        view.box.x, view.box.y + view.header_height, view.box.width, settings_view_list_height(view),
    }
    ui.begin_clip(list)
    for _, i in view.rows {
        rect := settings_view_row_rect(view, i)
        if rect.y + rect.height < list.y || rect.y > list.y + list.height {
            continue // fully scrolled out
        }
        settings_view_draw_row(view, &view.rows[i], rect, i)
    }
    ui.end_clip()

    settings_view_draw_scrollbar(view, list)
}

@(private = "file")
settings_view_draw_row :: proc(view: ^Settings_View, item: ^Settings_Row, rect: rl.Rectangle, index: int) {
    pad: f32 = 16
    label_y := cast(i32) (rect.y + (rect.height - 17) * 0.5)

    if item.kind == .Header {
        ui.draw_text(
            item.label,
            cast(i32) (rect.x + pad),
            cast(i32) (rect.y + rect.height - 20),
            15,
            view.accent_color,
        )
        return
    }

    ui.draw_text(item.label, cast(i32) (rect.x + pad), label_y, 17, view.text_color)

    switch item.kind {
    case .Header:
    case .Number:
        minus, value, plus := settings_view_number_rects(view, rect)
        settings_view_draw_button(view, minus, "-")
        settings_view_draw_button(view, plus, "+")
        rl.DrawRectangleRec(value, view.field_color)
        tw := ui.measure_text(item.value, 17)
        ui.draw_text(
            item.value,
            cast(i32) (value.x + (value.width - cast(f32) tw) * 0.5),
            cast(i32) (value.y + (value.height - 17) * 0.5),
            17,
            view.text_color,
        )
    case .Choice:
        tw := ui.measure_text(item.value, 17)
        ui.draw_text(
            item.value,
            cast(i32) (rect.x + rect.width - pad - cast(f32) tw),
            label_y,
            17,
            view.accent_color,
        )
    case .Keybind:
        clear := settings_view_clear_rect(view, rect)
        if item.value != "" {
            settings_view_draw_button(view, clear, "x")
        }
        chord := item.value != "" ? item.value : "unbound"
        color := item.value != "" ? view.text_color : view.muted_color
        if view.capturing == index {
            chord = "Press shortcut..."
            color = view.accent_color
        }
        tw := ui.measure_text(chord, 16)
        right := clear.x - 10
        ui.draw_text(
            chord,
            cast(i32) (right - cast(f32) tw),
            cast(i32) (rect.y + (rect.height - 16) * 0.5),
            16,
            color,
        )
    }
}

@(private = "file")
settings_view_draw_button :: proc(view: ^Settings_View, rect: rl.Rectangle, glyph: string) {
    hover := rl.CheckCollisionPointRec(rl.GetMousePosition(), rect)
    rl.DrawRectangleRec(rect, hover ? view.header_color : view.field_color)
    rl.DrawRectangleLinesEx(rect, 1, view.muted_color)
    tw := ui.measure_text(glyph, 18)
    ui.draw_text(
        glyph,
        cast(i32) (rect.x + (rect.width - cast(f32) tw) * 0.5),
        cast(i32) (rect.y + (rect.height - 18) * 0.5),
        18,
        hover ? view.accent_color : view.text_color,
    )
}

@(private = "file")
settings_view_draw_scrollbar :: proc(view: ^Settings_View, list: rl.Rectangle) {
    max_scroll := settings_view_max_scroll(view)
    if max_scroll <= 0 {
        return
    }
    width: f32 = 5
    x := list.x + list.width - width - 2
    rl.DrawRectangleRec(rl.Rectangle {x, list.y, width, list.height}, view.header_color)

    content := cast(f32) len(view.rows) * view.row_height
    thumb_h := max(list.height * list.height / content, 24)
    t := view.scroll / max_scroll
    thumb_y := list.y + (list.height - thumb_h) * t
    rl.DrawRectangleRec(rl.Rectangle {x, thumb_y, width, thumb_h}, view.muted_color)
}

settings_view_destroy :: proc(widget: ^ui.Widget) {
    view := cast(^Settings_View) widget
    settings_view_clear(view)
    delete(view.rows)
    free(view)
}
