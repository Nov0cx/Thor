package widgets

import rl "vendor:raylib"

import "../ui"

Splitter_Drag_Proc :: #type proc(data: rawptr, delta: f32)

Splitter :: struct {
    using widget: ui.Widget,
    axis:               ui.Axis,
    drag_data:          rawptr,
    on_drag:            Splitter_Drag_Proc,
    dragging:           bool,
    background_color:   rl.Color,
    hover_color:        rl.Color,
    active_color:       rl.Color,
}

splitter_vtable := ui.Widget_VTable {
    layout = splitter_layout,
    handle_event = splitter_handle_event,
    draw = splitter_draw,
    destroy = splitter_destroy,
}

splitter_create :: proc(id: string, axis: ui.Axis) -> ^Splitter {
    splitter := new(Splitter)
    ui.widget_init(&splitter.widget, id, splitter_vtable)
    splitter.axis = axis
    splitter.background_color = rl.Color {15, 17, 26, 255}
    splitter.hover_color = rl.Color {31, 34, 51, 255}
    splitter.active_color = rl.Color {130, 170, 255, 255}

    // A 1px seam that sits flush between panels, with the hit area grown so it
    // stays easy to grab.
    if axis == .Horizontal {
        splitter.min_size = rl.Vector2 {0, 1}
    } else {
        splitter.min_size = rl.Vector2 {1, 0}
    }
    splitter.hit_expand = 3

    return splitter
}

splitter_set_on_drag :: proc(splitter: ^Splitter, on_drag: Splitter_Drag_Proc, data: rawptr) -> ^Splitter {
    splitter.on_drag = on_drag
    splitter.drag_data = data
    return splitter
}

splitter_set_colors :: proc(splitter: ^Splitter, background_color, hover_color, active_color: rl.Color) -> ^Splitter {
    splitter.background_color = background_color
    splitter.hover_color = hover_color
    splitter.active_color = active_color
    return splitter
}

splitter_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    splitter := cast(^Splitter) widget
    splitter.bounds = bounds
}

splitter_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    splitter := cast(^Splitter) widget

    #partial switch event.kind {
    case .Mouse_Down:
        splitter.dragging = true
        return true
    case .Mouse_Move:
        if splitter.dragging && splitter.on_drag != nil {
            delta: f32 = event.mouse_delta[0]
            if splitter.axis == .Horizontal {
                delta = event.mouse_delta[1]
            }
            splitter.on_drag(splitter.drag_data, delta)
            return true
        }
    case .Mouse_Up:
        splitter.dragging = false
    case .Click, .Key_Press, .None:
    }

    return false
}

splitter_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    splitter := cast(^Splitter) widget
    color := splitter.background_color

    if splitter.dragging || ctx.active == widget {
        color = splitter.active_color
    } else if ctx.hot == widget {
        color = splitter.hover_color
    }

    rl.DrawRectangleRec(splitter.bounds, color)
}

splitter_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Splitter) widget)
}
