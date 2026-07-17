package widgets

import "core:strings"
import rl "vendor:raylib"

import "../ui"

// Fired with the option under the cursor. `preview` applies a choice live as the
// selection moves; `commit` applies and persists it on confirm.
Select_Choice_Proc :: #type proc(data: rawptr, choice: string)

// A centered modal that picks one string from a list (theme, font, ...). The
// selection previews live so the user sees the effect before confirming; Escape
// or an outside click reverts to the option that was active when it opened.
Select_Dialog :: struct {
    using widget: ui.Widget,
    title:        string,          // borrowed; owned by the caller
    // Row labels shown in the list, and the value handed to the callbacks for
    // each row. They differ when the display name isn't the persisted id (e.g.
    // a theme's "name" vs. its file base); values == options otherwise.
    options:      [dynamic]string, // owned copies
    values:       [dynamic]string, // owned copies; parallel to options
    selected:     int,
    scroll:       int,
    // Option active when the dialog opened; re-previewed on cancel.
    original:     int,
    preview:      Select_Choice_Proc,
    commit:       Select_Choice_Proc,
    data:         rawptr,
    // Focus handed back here when the dialog closes (the editor).
    return_focus: ^ui.Widget,
    box:          rl.Rectangle,
    width:        f32,
    row_height:   f32,
    header_height: f32,
    max_rows:     int,
    top_offset:   f32,
    backdrop_color:   rl.Color,
    background_color: rl.Color,
    border_color:     rl.Color,
    header_color:     rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    selected_color:   rl.Color,
    accent_color:     rl.Color,
}

select_dialog_vtable := ui.Widget_VTable {
    layout = select_dialog_layout,
    handle_event = select_dialog_handle_event,
    draw = select_dialog_draw,
    destroy = select_dialog_destroy,
}

select_dialog_create :: proc(id: string) -> ^Select_Dialog {
    dialog := new(Select_Dialog)
    ui.widget_init(&dialog.widget, id, select_dialog_vtable)
    dialog.visible = false
    dialog.options = make([dynamic]string)
    dialog.values = make([dynamic]string)
    dialog.width = 420
    dialog.row_height = 30
    dialog.header_height = 44
    dialog.max_rows = 12
    dialog.top_offset = 90
    dialog.backdrop_color = rl.Color {0, 0, 0, 120}
    dialog.background_color = rl.Color {24, 26, 31, 250}
    dialog.header_color = rl.Color {31, 34, 51, 255}
    dialog.border_color = rl.Color {132, 255, 255, 255}
    dialog.text_color = rl.Color {238, 255, 255, 255}
    dialog.muted_color = rl.Color {120, 128, 160, 255}
    dialog.selected_color = rl.Color {132, 255, 255, 40}
    dialog.accent_color = rl.Color {132, 255, 255, 255}
    return dialog
}

select_dialog_set_colors :: proc(
    dialog: ^Select_Dialog,
    background, border, header, text, muted, selected, accent: rl.Color,
) -> ^Select_Dialog {
    dialog.background_color = background
    dialog.border_color = border
    dialog.header_color = header
    dialog.text_color = text
    dialog.muted_color = muted
    dialog.selected_color = selected
    dialog.accent_color = accent
    return dialog
}

// Opens the picker over `labels`. `values` is the value passed to the callbacks
// for each label (defaults to the labels themselves); `current` is matched
// against it to pick the starting row. `preview` runs as the selection moves;
// `commit` runs on confirm. Items are copied, so the caller keeps its slices.
select_dialog_open :: proc(
    dialog: ^Select_Dialog,
    ctx: ^ui.Context,
    title: string,
    labels: []string,
    current: string,
    preview, commit: Select_Choice_Proc,
    data: rawptr,
    values: []string = nil,
) {
    for item in dialog.options {
        delete(item)
    }
    for item in dialog.values {
        delete(item)
    }
    clear(&dialog.options)
    clear(&dialog.values)
    for item, i in labels {
        append(&dialog.options, strings.clone(item))
        value := (values != nil && i < len(values)) ? values[i] : item
        append(&dialog.values, strings.clone(value))
    }

    dialog.title = title
    dialog.preview = preview
    dialog.commit = commit
    dialog.data = data
    dialog.selected = 0
    for value, i in dialog.values {
        if value == current {
            dialog.selected = i
            break
        }
    }
    dialog.original = dialog.selected
    dialog.scroll = 0
    select_dialog_scroll_into_view(dialog)

    dialog.visible = true
    dialog.return_focus = ctx.focused
    ctx.focused = &dialog.widget
    ui.widget_bring_to_front(&dialog.widget)
}

select_dialog_is_open :: proc(dialog: ^Select_Dialog) -> bool {
    return dialog.visible
}

@(private = "file")
select_dialog_close :: proc(dialog: ^Select_Dialog, ctx: ^ui.Context) {
    dialog.visible = false
    if ctx.focused == &dialog.widget {
        ctx.focused = dialog.return_focus
    }
}

// Cancels: restores the option active at open, then closes.
@(private = "file")
select_dialog_cancel :: proc(dialog: ^Select_Dialog, ctx: ^ui.Context) {
    if dialog.original != dialog.selected && dialog.preview != nil &&
       dialog.original >= 0 && dialog.original < len(dialog.values) {
        dialog.preview(dialog.data, dialog.values[dialog.original])
    }
    select_dialog_close(dialog, ctx)
}

// Confirms the current selection: applies and persists it, then closes.
@(private = "file")
select_dialog_confirm :: proc(dialog: ^Select_Dialog, ctx: ^ui.Context) {
    if dialog.selected < 0 || dialog.selected >= len(dialog.values) {
        select_dialog_close(dialog, ctx)
        return
    }
    choice := strings.clone(dialog.values[dialog.selected], context.temp_allocator)
    commit := dialog.commit
    data := dialog.data
    select_dialog_close(dialog, ctx)
    if commit != nil {
        commit(data, choice)
    }
}

// Moves the selection by `delta`, keeps it on screen, and previews it live.
@(private = "file")
select_dialog_move :: proc(dialog: ^Select_Dialog, delta: int) {
    count := len(dialog.options)
    if count == 0 {
        return
    }
    next := clamp(dialog.selected + delta, 0, count - 1)
    if next == dialog.selected {
        return
    }
    dialog.selected = next
    select_dialog_scroll_into_view(dialog)
    if dialog.preview != nil {
        dialog.preview(dialog.data, dialog.values[dialog.selected])
    }
}

@(private = "file")
select_dialog_scroll_into_view :: proc(dialog: ^Select_Dialog) {
    if dialog.selected < dialog.scroll {
        dialog.scroll = dialog.selected
    } else if dialog.selected >= dialog.scroll + dialog.max_rows {
        dialog.scroll = dialog.selected - dialog.max_rows + 1
    }
}

select_dialog_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    dialog := cast(^Select_Dialog) widget
    // Cover the whole screen so clicks outside the box dismiss the dialog.
    dialog.bounds = bounds

    visible_rows := min(len(dialog.options), dialog.max_rows)
    width := min(dialog.width, bounds.width - 80)
    height := dialog.header_height + cast(f32) visible_rows * dialog.row_height + 10

    dialog.box = rl.Rectangle {
        x = bounds.x + (bounds.width - width) * 0.5,
        y = bounds.y + dialog.top_offset,
        width = width,
        height = height,
    }
}

select_dialog_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    dialog := cast(^Select_Dialog) widget
    if !dialog.visible {
        return false
    }

    #partial switch event.kind {
    case .Key_Press:
        #partial switch event.key {
        case .ESCAPE:
            select_dialog_cancel(dialog, ctx)
        case .ENTER, .KP_ENTER:
            select_dialog_confirm(dialog, ctx)
        case .UP:
            select_dialog_move(dialog, -1)
        case .DOWN:
            select_dialog_move(dialog, 1)
        case .PAGE_UP:
            select_dialog_move(dialog, -dialog.max_rows)
        case .PAGE_DOWN:
            select_dialog_move(dialog, dialog.max_rows)
        case .HOME:
            select_dialog_move(dialog, -len(dialog.options))
        case .END:
            select_dialog_move(dialog, len(dialog.options))
        }
        return true

    case .Mouse_Move:
        // Hovering a row previews it, so the whole list is browsable by mouse.
        row := select_dialog_row_at(dialog, event.mouse_position)
        if row >= 0 {
            select_dialog_move(dialog, row - dialog.selected)
        }
        return true

    case .Mouse_Down:
        if !rl.CheckCollisionPointRec(event.mouse_position, dialog.box) {
            select_dialog_cancel(dialog, ctx)
            return true
        }
        row := select_dialog_row_at(dialog, event.mouse_position)
        if row >= 0 {
            dialog.selected = row
            select_dialog_confirm(dialog, ctx)
        }
        return true

    case .Scroll:
        select_dialog_move(dialog, event.wheel_delta > 0 ? -1 : 1)
        return true
    }

    return true // block everything else from reaching widgets underneath
}

@(private = "file")
select_dialog_row_at :: proc(dialog: ^Select_Dialog, point: rl.Vector2) -> int {
    list_top := dialog.box.y + dialog.header_height
    if !rl.CheckCollisionPointRec(point, dialog.box) || point.y < list_top {
        return -1
    }
    row := dialog.scroll + cast(int) ((point.y - list_top) / dialog.row_height)
    if row < 0 || row >= len(dialog.options) {
        return -1
    }
    return row
}

select_dialog_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    dialog := cast(^Select_Dialog) widget
    if !dialog.visible {
        return
    }

    rl.DrawRectangleRec(dialog.bounds, dialog.backdrop_color)
    rl.DrawRectangleRec(dialog.box, dialog.background_color)

    header := rl.Rectangle {dialog.box.x, dialog.box.y, dialog.box.width, dialog.header_height}
    rl.DrawRectangleRec(header, dialog.header_color)
    ui.draw_text(
        dialog.title,
        cast(i32) (dialog.box.x + 14),
        cast(i32) (dialog.box.y + (dialog.header_height - 18) * 0.5),
        18,
        dialog.text_color,
    )
    rl.DrawRectangleLinesEx(dialog.box, 1, dialog.border_color)

    ui.begin_clip(dialog.box)
    defer ui.end_clip()

    pad: f32 = 14
    list_top := dialog.box.y + dialog.header_height
    visible := min(len(dialog.options), dialog.max_rows)
    for i in 0 ..< visible {
        row := dialog.scroll + i
        if row >= len(dialog.options) {
            break
        }
        row_y := list_top + cast(f32) i * dialog.row_height
        if row == dialog.selected {
            rl.DrawRectangleRec(
                rl.Rectangle {dialog.box.x, row_y, dialog.box.width, dialog.row_height},
                dialog.selected_color,
            )
            rl.DrawRectangleRec(rl.Rectangle {dialog.box.x, row_y, 3, dialog.row_height}, dialog.accent_color)
        }
        color := row == dialog.selected ? dialog.text_color : dialog.muted_color
        ui.draw_text(
            dialog.options[row],
            cast(i32) (dialog.box.x + pad),
            cast(i32) (row_y + (dialog.row_height - 17) * 0.5),
            17,
            color,
        )
    }

    select_dialog_draw_scrollbar(dialog, list_top)
}

@(private = "file")
select_dialog_draw_scrollbar :: proc(dialog: ^Select_Dialog, list_top: f32) {
    total := len(dialog.options)
    if total <= dialog.max_rows {
        return
    }

    track_height := cast(f32) dialog.max_rows * dialog.row_height
    width: f32 = 5
    x := dialog.box.x + dialog.box.width - width - 2
    rl.DrawRectangleRec(rl.Rectangle {x, list_top, width, track_height}, dialog.header_color)

    thumb_height := max(track_height * cast(f32) dialog.max_rows / cast(f32) total, 24)
    max_scroll := total - dialog.max_rows
    t := max_scroll > 0 ? cast(f32) dialog.scroll / cast(f32) max_scroll : 0
    thumb_y := list_top + (track_height - thumb_height) * t
    rl.DrawRectangleRec(rl.Rectangle {x, thumb_y, width, thumb_height}, dialog.muted_color)
}

select_dialog_destroy :: proc(widget: ^ui.Widget) {
    dialog := cast(^Select_Dialog) widget
    for item in dialog.options {
        delete(item)
    }
    for item in dialog.values {
        delete(item)
    }
    delete(dialog.options)
    delete(dialog.values)
    free(dialog)
}
