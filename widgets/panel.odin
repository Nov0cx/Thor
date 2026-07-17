package widgets

import rl "vendor:raylib"

import "../ui"

Panel :: struct {
    using widget: ui.Widget,
    background_color: rl.Color,
    padding:          ui.Padding,
}

panel_vtable := ui.Widget_VTable {
    layout = panel_layout,
    draw = panel_draw,
    destroy = panel_destroy,
}

panel_create :: proc(id: string, background_color: rl.Color) -> ^Panel {
    panel := new(Panel)
    ui.widget_init(&panel.widget, id, panel_vtable)
    panel.background_color = background_color
    panel.padding = ui.padding(0)
    return panel
}

panel_set_background :: proc(panel: ^Panel, background_color: rl.Color) -> ^Panel {
    panel.background_color = background_color
    return panel
}

panel_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    panel := cast(^Panel) widget
    panel.bounds = bounds

    inner_bounds := ui.shrink_rectangle(bounds, panel.padding)

    child := panel.first_child
    for child != nil {
        ui.widget_layout_tree(child, inner_bounds)
        child = child.next_sibling
    }
}

panel_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    panel := cast(^Panel) widget
    rl.DrawRectangleRec(panel.bounds, panel.background_color)
}

panel_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Panel) widget)
}
