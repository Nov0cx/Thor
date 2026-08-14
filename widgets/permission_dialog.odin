package widgets

import "core:strings"
import rl "vendor:raylib"

import "../ui"

// Fired when the prompt is answered. Allowing and dismissing are separate hooks
// because a dismissal has to leave the plugins unloaded and unrecorded.
Permission_Dialog_Proc :: #type proc(data: rawptr)

// One plugin as the prompt lists it.
Permission_Item :: struct {
    id:    string, // owned copy
    perms: string, // owned copy; "exec, read" or "no permissions"
}

// Which footer button the pointer is on.
Permission_Button :: enum {
    None,
    Allow,
    Cancel,
}

// A centered modal that asks for one answer over a list of plugins. The answer
// covers every row, matching the host's all-or-nothing grant, so the rows carry
// no controls of their own. The list scrolls, so a machine with many plugins
// still gets a box that fits the window.
Permission_Dialog :: struct {
    using widget:  ui.Widget,
    title:         string, // owned copy
    note:          string, // owned copy; footer hint
    items:         [dynamic]Permission_Item, // owned
    scroll:        int,
    // Rows the box has room for, set by layout and read by the draw and the
    // hit tests, so all three agree on the same geometry.
    visible_rows:  int,
    hot:           Permission_Button,
    on_allow:      Permission_Dialog_Proc,
    on_cancel:     Permission_Dialog_Proc,
    data:          rawptr,
    // Focus handed back here when the dialog closes (the editor).
    return_focus:  ^ui.Widget,
    box:           rl.Rectangle,
    width:         f32,
    row_height:    f32,
    header_height: f32,
    footer_height: f32,
    max_rows:      int,
    top_offset:    f32,
    backdrop_color:   rl.Color,
    background_color: rl.Color,
    border_color:     rl.Color,
    header_color:     rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    row_color:        rl.Color,
    accent_color:     rl.Color,
}

@(private = "file")
PERMISSION_PAD :: f32(16)

@(private = "file")
PERMISSION_BUTTON_HEIGHT :: f32(30)

@(private = "file")
PERMISSION_SCROLLBAR_STYLE :: ui.Scrollbar_Style {width = 5, min_thumb = 24, inset = 2}

permission_dialog_vtable := ui.Widget_VTable {
    layout = permission_dialog_layout,
    handle_event = permission_dialog_handle_event,
    draw = permission_dialog_draw,
    destroy = permission_dialog_destroy,
}

permission_dialog_create :: proc(id: string) -> ^Permission_Dialog {
    dialog := new(Permission_Dialog)
    ui.widget_init(&dialog.widget, id, permission_dialog_vtable)
    dialog.visible = false
    dialog.items = make([dynamic]Permission_Item)
    dialog.width = 580
    dialog.row_height = 30
    dialog.header_height = 48
    dialog.footer_height = 56
    dialog.max_rows = 8
    dialog.top_offset = 90
    dialog.backdrop_color = rl.Color {0, 0, 0, 140}
    dialog.background_color = rl.Color {24, 26, 31, 250}
    dialog.header_color = rl.Color {31, 34, 51, 255}
    dialog.border_color = rl.Color {132, 255, 255, 255}
    dialog.text_color = rl.Color {238, 255, 255, 255}
    dialog.muted_color = rl.Color {120, 128, 160, 255}
    dialog.row_color = rl.Color {255, 255, 255, 10}
    dialog.accent_color = rl.Color {132, 255, 255, 255}
    return dialog
}

permission_dialog_set_colors :: proc(
    dialog: ^Permission_Dialog,
    background, border, header, text, muted, row, accent: rl.Color,
) -> ^Permission_Dialog {
    dialog.background_color = background
    dialog.border_color = border
    dialog.header_color = header
    dialog.text_color = text
    dialog.muted_color = muted
    dialog.row_color = row
    dialog.accent_color = accent
    return dialog
}

// Opens the prompt over `ids` and `perms`, one row per entry and matched by
// index. Every string is copied, so the caller keeps its slices: the requests
// they came from are dropped inside the callbacks this fires.
permission_dialog_open :: proc(
    dialog: ^Permission_Dialog,
    ctx: ^ui.Context,
    title, note: string,
    ids, perms: []string,
    on_allow, on_cancel: Permission_Dialog_Proc,
    data: rawptr,
) {
    permission_dialog_clear(dialog)

    for id, i in ids {
        append(&dialog.items, Permission_Item {
            id = strings.clone(id),
            perms = strings.clone(i < len(perms) ? perms[i] : ""),
        })
    }
    dialog.title = strings.clone(title)
    dialog.note = strings.clone(note)
    dialog.on_allow = on_allow
    dialog.on_cancel = on_cancel
    dialog.data = data
    dialog.scroll = 0
    dialog.hot = .None

    dialog.visible = true
    dialog.return_focus = ctx.focused
    ctx.focused = &dialog.widget
    ui.widget_bring_to_front(&dialog.widget)
}

permission_dialog_is_open :: proc(dialog: ^Permission_Dialog) -> bool {
    return dialog.visible
}

// Frees the strings of the previous prompt. The two labels start as literals, so
// only a clone is freed.
@(private = "file")
permission_dialog_clear :: proc(dialog: ^Permission_Dialog) {
    for item in dialog.items {
        delete(item.id)
        delete(item.perms)
    }
    clear(&dialog.items)
    if len(dialog.title) > 0 {
        delete(dialog.title)
    }
    if len(dialog.note) > 0 {
        delete(dialog.note)
    }
    dialog.title = ""
    dialog.note = ""
}

@(private = "file")
permission_dialog_close :: proc(dialog: ^Permission_Dialog, ctx: ^ui.Context) {
    dialog.visible = false
    dialog.hot = .None
    if ctx.focused == &dialog.widget {
        ctx.focused = dialog.return_focus
    }
}

// Answers yes. The dismissal hook is cleared first: it unloads the plugins that
// were just granted.
@(private = "file")
permission_dialog_allow :: proc(dialog: ^Permission_Dialog, ctx: ^ui.Context) {
    run := dialog.on_allow
    data := dialog.data
    dialog.on_cancel = nil
    permission_dialog_close(dialog, ctx)
    if run != nil {
        run(data)
    }
}

@(private = "file")
permission_dialog_cancel :: proc(dialog: ^Permission_Dialog, ctx: ^ui.Context) {
    run := dialog.on_cancel
    data := dialog.data
    dialog.on_cancel = nil
    permission_dialog_close(dialog, ctx)
    if run != nil {
        run(data)
    }
}

// Rows past the end of the list, which is how far the scroll can go.
@(private = "file")
permission_dialog_max_scroll :: proc(dialog: ^Permission_Dialog) -> int {
    return max(0, len(dialog.items) - dialog.visible_rows)
}

@(private = "file")
permission_dialog_scroll_by :: proc(dialog: ^Permission_Dialog, delta: int) {
    dialog.scroll = clamp(dialog.scroll + delta, 0, permission_dialog_max_scroll(dialog))
}

permission_dialog_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    dialog := cast(^Permission_Dialog) widget
    // Cover the whole screen so clicks outside the box dismiss the dialog.
    dialog.bounds = bounds

    width := min(dialog.width, bounds.width - 80)
    chrome := dialog.header_height + dialog.footer_height
    // A short window gets fewer rows rather than a box taller than the screen.
    room := max(bounds.height - dialog.top_offset * 2, dialog.row_height)
    fits := cast(int) ((room - chrome) / dialog.row_height)
    dialog.visible_rows = clamp(min(len(dialog.items), dialog.max_rows), 1, max(fits, 1))

    height := chrome + cast(f32) dialog.visible_rows * dialog.row_height
    dialog.box = rl.Rectangle {
        x = bounds.x + (bounds.width - width) * 0.5,
        y = bounds.y + dialog.top_offset,
        width = width,
        height = height,
    }
    dialog.scroll = clamp(dialog.scroll, 0, permission_dialog_max_scroll(dialog))
}

// The list area, between the header and the footer.
@(private = "file")
permission_dialog_list_rect :: proc(dialog: ^Permission_Dialog) -> rl.Rectangle {
    return rl.Rectangle {
        dialog.box.x,
        dialog.box.y + dialog.header_height,
        dialog.box.width,
        cast(f32) dialog.visible_rows * dialog.row_height,
    }
}

@(private = "file")
permission_dialog_cancel_rect :: proc(dialog: ^Permission_Dialog) -> rl.Rectangle {
    width := cast(f32) ui.measure_text("Not now", 16) + 28
    return rl.Rectangle {
        dialog.box.x + dialog.box.width - PERMISSION_PAD - width,
        dialog.box.y + dialog.box.height - dialog.footer_height +
            (dialog.footer_height - PERMISSION_BUTTON_HEIGHT) * 0.5,
        width,
        PERMISSION_BUTTON_HEIGHT,
    }
}

@(private = "file")
permission_dialog_allow_rect :: proc(dialog: ^Permission_Dialog) -> rl.Rectangle {
    cancel := permission_dialog_cancel_rect(dialog)
    width := cast(f32) ui.measure_text("Allow", 16) + 32
    return rl.Rectangle {cancel.x - 10 - width, cancel.y, width, PERMISSION_BUTTON_HEIGHT}
}

@(private = "file")
permission_dialog_button_at :: proc(dialog: ^Permission_Dialog, point: rl.Vector2) -> Permission_Button {
    if rl.CheckCollisionPointRec(point, permission_dialog_allow_rect(dialog)) {
        return .Allow
    }
    if rl.CheckCollisionPointRec(point, permission_dialog_cancel_rect(dialog)) {
        return .Cancel
    }
    return .None
}

permission_dialog_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    dialog := cast(^Permission_Dialog) widget
    if !dialog.visible {
        return false
    }

    #partial switch event.kind {
    case .Key_Press:
        #partial switch event.key {
        case .ESCAPE:
            permission_dialog_cancel(dialog, ctx)
        case .ENTER, .KP_ENTER:
            permission_dialog_allow(dialog, ctx)
        case .UP:
            permission_dialog_scroll_by(dialog, -1)
        case .DOWN:
            permission_dialog_scroll_by(dialog, 1)
        case .PAGE_UP:
            permission_dialog_scroll_by(dialog, -dialog.visible_rows)
        case .PAGE_DOWN:
            permission_dialog_scroll_by(dialog, dialog.visible_rows)
        case .HOME:
            permission_dialog_scroll_by(dialog, -len(dialog.items))
        case .END:
            permission_dialog_scroll_by(dialog, len(dialog.items))
        }
        return true

    case .Mouse_Move:
        dialog.hot = permission_dialog_button_at(dialog, event.mouse_position)
        return true

    case .Mouse_Down:
        if !rl.CheckCollisionPointRec(event.mouse_position, dialog.box) {
            permission_dialog_cancel(dialog, ctx)
            return true
        }
        switch permission_dialog_button_at(dialog, event.mouse_position) {
        case .Allow:
            permission_dialog_allow(dialog, ctx)
        case .Cancel:
            permission_dialog_cancel(dialog, ctx)
        case .None:
        }
        return true

    case .Scroll:
        permission_dialog_scroll_by(dialog, event.wheel_delta > 0 ? -1 : 1)
        return true
    }

    return true // block everything else from reaching widgets underneath
}

permission_dialog_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    dialog := cast(^Permission_Dialog) widget
    if !dialog.visible {
        return
    }

    rl.DrawRectangleRec(dialog.bounds, dialog.backdrop_color)
    rl.DrawRectangleRounded(dialog.box, SETTINGS_ROUNDNESS, 8, dialog.background_color)

    header := rl.Rectangle {dialog.box.x, dialog.box.y, dialog.box.width, dialog.header_height}
    rl.DrawRectangleRec(header, dialog.header_color)
    ui.draw_text(
        dialog.title,
        cast(i32) (dialog.box.x + PERMISSION_PAD),
        cast(i32) (dialog.box.y + (dialog.header_height - 18) * 0.5),
        18,
        dialog.text_color,
    )

    permission_dialog_draw_rows(dialog)
    permission_dialog_draw_footer(dialog)

    rl.DrawRectangleRoundedLinesEx(dialog.box, SETTINGS_ROUNDNESS, 8, 1, dialog.border_color)
}

// One row per plugin: the id, then what it asks for. Both are clipped to the
// list, so a long permission set cannot run out of the box the way the old
// single-line prompt did.
@(private = "file")
permission_dialog_draw_rows :: proc(dialog: ^Permission_Dialog) {
    list := permission_dialog_list_rect(dialog)
    ui.begin_clip(list)

    for i in 0 ..< dialog.visible_rows {
        row := dialog.scroll + i
        if row >= len(dialog.items) {
            break
        }
        item := dialog.items[row]
        row_y := list.y + cast(f32) i * dialog.row_height
        if row % 2 == 1 {
            rl.DrawRectangleRec(
                rl.Rectangle {list.x, row_y, list.width, dialog.row_height}, dialog.row_color,
            )
        }

        text_y := cast(i32) (row_y + (dialog.row_height - 17) * 0.5)
        ui.draw_text(item.id, cast(i32) (list.x + PERMISSION_PAD), text_y, 17, dialog.text_color)

        perms_width := ui.measure_text(item.perms, 15)
        perms_x := list.x + list.width - PERMISSION_PAD - cast(f32) perms_width
        ui.draw_text(
            item.perms,
            cast(i32) perms_x,
            cast(i32) (row_y + (dialog.row_height - 15) * 0.5),
            15,
            dialog.muted_color,
        )
    }

    ui.end_clip()
    permission_dialog_draw_scrollbar(dialog, list)
}

@(private = "file")
permission_dialog_draw_scrollbar :: proc(dialog: ^Permission_Dialog, list: rl.Rectangle) {
    content := cast(f32) len(dialog.items) * dialog.row_height
    track, thumb, ok := ui.scrollbar_rects(
        list, content, cast(f32) dialog.scroll * dialog.row_height, PERMISSION_SCROLLBAR_STYLE,
    )
    if !ok {
        return
    }
    rl.DrawRectangleRec(track, dialog.header_color)
    rl.DrawRectangleRec(thumb, dialog.muted_color)
}

@(private = "file")
permission_dialog_draw_footer :: proc(dialog: ^Permission_Dialog) {
    allow := permission_dialog_allow_rect(dialog)
    cancel := permission_dialog_cancel_rect(dialog)

    allow_fill := dialog.hot == .Allow ? ui.color_shade(dialog.accent_color, 0.10) : dialog.accent_color
    rl.DrawRectangleRounded(allow, 0.3, 6, allow_fill)
    permission_dialog_draw_button_label(dialog, allow, "Allow", ui.color_on(dialog.accent_color))

    cancel_fill := dialog.hot == .Cancel ? dialog.header_color : rl.Color {0, 0, 0, 0}
    rl.DrawRectangleRounded(cancel, 0.3, 6, cancel_fill)
    permission_dialog_draw_button_label(dialog, cancel, "Not now", dialog.muted_color)

    // The hint takes what the buttons leave, and is clipped to it.
    note_area := rl.Rectangle {
        dialog.box.x + PERMISSION_PAD,
        allow.y,
        max(allow.x - 10 - (dialog.box.x + PERMISSION_PAD), 0),
        PERMISSION_BUTTON_HEIGHT,
    }
    ui.begin_clip(note_area)
    ui.draw_text(
        dialog.note,
        cast(i32) note_area.x,
        cast(i32) (note_area.y + (note_area.height - 14) * 0.5),
        14,
        dialog.muted_color,
    )
    ui.end_clip()
}

@(private = "file")
permission_dialog_draw_button_label :: proc(
    dialog: ^Permission_Dialog, rect: rl.Rectangle, label: string, color: rl.Color,
) {
    width := ui.measure_text(label, 16)
    ui.draw_text(
        label,
        cast(i32) (rect.x + (rect.width - cast(f32) width) * 0.5),
        cast(i32) (rect.y + (rect.height - 16) * 0.5),
        16,
        color,
    )
}

permission_dialog_destroy :: proc(widget: ^ui.Widget) {
    dialog := cast(^Permission_Dialog) widget
    permission_dialog_clear(dialog)
    delete(dialog.items)
    free(dialog)
}
