package widgets

import rl "vendor:raylib"

import "../ui"

Dialog :: struct {
    using widget: ui.Widget,
    title:            string,
    position:         rl.Vector2,
    size:             rl.Vector2,
    header_height:    f32,
    padding:          ui.Padding,
    dragging:         bool,
    drag_offset:      rl.Vector2,
    background_color: rl.Color,
    header_color:     rl.Color,
    border_color:     rl.Color,
    title_color:      rl.Color,
    close_size:       f32,
}

dialog_vtable := ui.Widget_VTable {
    layout = dialog_layout,
    handle_event = dialog_handle_event,
    draw = dialog_draw,
    destroy = dialog_destroy,
}

dialog_create :: proc(id, title: string, position, size: rl.Vector2) -> ^Dialog {
    dialog := new(Dialog)
    ui.widget_init(&dialog.widget, id, dialog_vtable)
    dialog.title = title
    dialog.position = position
    dialog.size = size
    dialog.header_height = 42
    dialog.padding = ui.padding(14)
    dialog.background_color = rl.Color {24, 26, 31, 245}
    dialog.header_color = rl.Color {31, 34, 51, 255}
    dialog.border_color = rl.Color {15, 17, 26, 255}
    dialog.title_color = rl.Color {238, 255, 255, 255}
    dialog.close_size = 22
    dialog.min_size = size
    return dialog
}

dialog_set_colors :: proc(dialog: ^Dialog, title_color, header_color, background_color, border_color: rl.Color) -> ^Dialog {
    dialog.title_color = title_color
    dialog.header_color = header_color
    dialog.background_color = background_color
    dialog.border_color = border_color
    return dialog
}

dialog_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    dialog := cast(^Dialog) widget

    max_x := bounds.x + bounds.width - dialog.size.x
    max_y := bounds.y + bounds.height - dialog.size.y

    if dialog.position.x < bounds.x {
        dialog.position.x = bounds.x
    }
    if dialog.position.y < bounds.y {
        dialog.position.y = bounds.y
    }
    if dialog.position.x > max_x {
        dialog.position.x = max_x
    }
    if dialog.position.y > max_y {
        dialog.position.y = max_y
    }

    dialog.bounds = rl.Rectangle {
        x = dialog.position.x,
        y = dialog.position.y,
        width = dialog.size.x,
        height = dialog.size.y,
    }

    content_bounds := ui.shrink_rectangle(
        rl.Rectangle {
            x = dialog.bounds.x,
            y = dialog.bounds.y + dialog.header_height,
            width = dialog.bounds.width,
            height = dialog.bounds.height - dialog.header_height,
        },
        dialog.padding,
    )

    child := dialog.first_child
    for child != nil {
        ui.widget_layout_tree(child, content_bounds)
        child = child.next_sibling
    }
}

dialog_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    dialog := cast(^Dialog) widget
    header_bounds := rl.Rectangle {
        x = dialog.bounds.x,
        y = dialog.bounds.y,
        width = dialog.bounds.width,
        height = dialog.header_height,
    }
    close_bounds := dialog_close_bounds(dialog)

    #partial switch event.kind {
    case .Mouse_Down:
        if ui.widget_contains_point(widget, event.mouse_position) {
            ui.widget_bring_to_front(widget)
        }

        if rl.CheckCollisionPointRec(event.mouse_position, close_bounds) {
            dialog.visible = false
            dialog.dragging = false
            return true
        }

        if rl.CheckCollisionPointRec(event.mouse_position, header_bounds) {
            dialog.dragging = true
            dialog.drag_offset = rl.Vector2 {
                event.mouse_position[0] - dialog.position[0],
                event.mouse_position[1] - dialog.position[1],
            }
            return true
        }

    case .Mouse_Move:
        if dialog.dragging {
            dialog.position = rl.Vector2 {
                event.mouse_position[0] - dialog.drag_offset[0],
                event.mouse_position[1] - dialog.drag_offset[1],
            }
            return true
        }

    case .Mouse_Up:
        dialog.dragging = false
    case .Click:
    case .Key_Press:
    case .None:
    }

    return false
}

dialog_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    dialog := cast(^Dialog) widget

    rl.DrawRectangleRec(dialog.bounds, dialog.background_color)
    rl.DrawRectangleRec(
        rl.Rectangle {
            x = dialog.bounds.x,
            y = dialog.bounds.y,
            width = dialog.bounds.width,
            height = dialog.header_height,
        },
        dialog.header_color,
    )
    rl.DrawRectangleLinesEx(dialog.bounds, 1, dialog.border_color)
    close_bounds := dialog_close_bounds(dialog)
    rl.DrawRectangleRec(close_bounds, dialog.border_color)

    ui.draw_text(
        dialog.title,
        cast(i32) (dialog.bounds.x + 14),
        cast(i32) (dialog.bounds.y + 11),
        18,
        dialog.title_color,
    )
    ui.draw_text(
        "x",
        cast(i32) (close_bounds.x + 6),
        cast(i32) (close_bounds.y + 2),
        18,
        dialog.title_color,
    )
}

dialog_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Dialog) widget)
}

dialog_close_bounds :: proc(dialog: ^Dialog) -> rl.Rectangle {
    return rl.Rectangle {
        x = dialog.bounds.x + dialog.bounds.width - dialog.close_size - 10,
        y = dialog.bounds.y + 10,
        width = dialog.close_size,
        height = dialog.close_size,
    }
}
