package widgets

import "core:c"
import rl "vendor:raylib"

import "../ui"

Titlebar :: struct {
    using widget: ui.Widget,
    gap:              f32,
    padding:          ui.Padding,
    background_color: rl.Color,
    dragging:         bool,
}

titlebar_vtable := ui.Widget_VTable {
    layout = titlebar_layout,
    handle_event = titlebar_handle_event,
    draw = titlebar_draw,
    destroy = titlebar_destroy,
}

titlebar_create :: proc(id: string) -> ^Titlebar {
    titlebar := new(Titlebar)
    ui.widget_init(&titlebar.widget, id, titlebar_vtable)
    titlebar.gap = 8
    titlebar.padding = ui.padding_xy(12, 8)
    return titlebar
}

titlebar_set_gap :: proc(titlebar: ^Titlebar, gap: f32) -> ^Titlebar {
    titlebar.gap = gap
    return titlebar
}

titlebar_set_padding :: proc(titlebar: ^Titlebar, padding: ui.Padding) -> ^Titlebar {
    titlebar.padding = padding
    return titlebar
}

titlebar_set_background :: proc(titlebar: ^Titlebar, background_color: rl.Color) -> ^Titlebar {
    titlebar.background_color = background_color
    return titlebar
}

titlebar_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    titlebar := cast(^Titlebar) widget
    titlebar.bounds = bounds

    inner_bounds := ui.shrink_rectangle(bounds, titlebar.padding)

    visible_children := 0
    min_width: f32 = 0
    total_grow: f32 = 0

    child := titlebar.first_child
    for child != nil {
        if child.visible {
            visible_children += 1
            min_width += child.min_size.x
            total_grow += child.grow
        }
        child = child.next_sibling
    }

    if visible_children == 0 {
        return
    }

    total_gap := titlebar.gap * cast(f32) (visible_children - 1)
    extra_width := inner_bounds.width - min_width - total_gap
    if extra_width < 0 {
        extra_width = 0
    }

    x := inner_bounds.x
    child = titlebar.first_child
    for child != nil {
        if child.visible {
            child_width := child.min_size.x
            if extra_width > 0 {
                if total_grow > 0 && child.grow > 0 {
                    child_width += extra_width * (child.grow / total_grow)
                } else if total_grow == 0 {
                    child_width += extra_width / cast(f32) visible_children
                }
            }

            ui.widget_layout_tree(child, rl.Rectangle {
                x = x,
                y = inner_bounds.y,
                width = child_width,
                height = inner_bounds.height,
            })
            x += child_width + titlebar.gap
        }
        child = child.next_sibling
    }
}

titlebar_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    titlebar := cast(^Titlebar) widget

    #partial switch event.kind {
    case .Mouse_Down:
        if event.target == widget || event.target.vtable.handle_event == nil {
            titlebar.dragging = true
            return true
        }
    case .Mouse_Move:
        if titlebar.dragging {
            pos := rl.GetWindowPosition()
            rl.SetWindowPosition(
                cast(c.int) (pos[0] + event.mouse_delta[0]),
                cast(c.int) (pos[1] + event.mouse_delta[1]),
            )
            return true
        }
    case .Mouse_Up:
        titlebar.dragging = false
    case .Click, .Key_Press, .None:
    }

    return false
}

titlebar_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    titlebar := cast(^Titlebar) widget
    rl.DrawRectangleRec(titlebar.bounds, titlebar.background_color)
}

titlebar_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Titlebar) widget)
}
