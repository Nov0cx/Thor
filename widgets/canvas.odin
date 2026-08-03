package widgets

import rl "vendor:raylib"

import "../ui"

// Called once per frame with the canvas's screen bounds, already clipped.
Canvas_Draw_Proc :: #type proc(data: rawptr, bounds: rl.Rectangle)

// A widget that draws nothing itself and hands its bounds to a callback. Backs
// a plugin's immediate-mode drawing (see plugin.manager_panel_draw).
Canvas :: struct {
    using widget: ui.Widget,
    on_draw:      Canvas_Draw_Proc,
    data:         rawptr,
}

canvas_vtable := ui.Widget_VTable {
    layout = canvas_layout,
    draw = canvas_draw,
    destroy = canvas_destroy,
}

canvas_create :: proc(id: string) -> ^Canvas {
    canvas := new(Canvas)
    ui.widget_init(&canvas.widget, id, canvas_vtable)
    return canvas
}

canvas_set_on_draw :: proc(canvas: ^Canvas, on_draw: Canvas_Draw_Proc, data: rawptr) -> ^Canvas {
    canvas.on_draw = on_draw
    canvas.data = data
    return canvas
}

canvas_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    widget.bounds = bounds
}

// Clips to the canvas, so a callback drawing out of range cannot paint over the
// rest of the editor.
canvas_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    canvas := cast(^Canvas) widget
    if canvas.on_draw == nil || canvas.bounds.width <= 0 || canvas.bounds.height <= 0 {
        return
    }
    rl.BeginScissorMode(
        i32(canvas.bounds.x),
        i32(canvas.bounds.y),
        i32(canvas.bounds.width),
        i32(canvas.bounds.height),
    )
    canvas.on_draw(canvas.data, canvas.bounds)
    rl.EndScissorMode()
}

canvas_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Canvas) widget)
}
