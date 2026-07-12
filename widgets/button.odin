package widgets

import rl "vendor:raylib"

import "../ui"

Button_Click_Proc :: #type proc(data: rawptr, ctx: ^ui.Context, widget: ^ui.Widget)

Button :: struct {
    using widget:      ui.Widget,
    text:              string,
    // When set, an icon glyph is drawn centered instead of the text.
    icon:              string,
    icon_size:         i32,
    on_click:          Button_Click_Proc,
    click_data:        rawptr,
    text_color:        rl.Color,
    background_color:  rl.Color,
    hover_color:       rl.Color,
    pressed_color:     rl.Color,
    border_color:      rl.Color,
    font_size:         i32,
    padding:           ui.Padding,
    border_thickness:  f32,
}

button_vtable := ui.Widget_VTable {
    layout = button_layout,
    handle_event = button_handle_event,
    draw = button_draw,
    destroy = button_destroy,
}

button_create :: proc(id, text: string) -> ^Button {
    button := new(Button)
    ui.widget_init(&button.widget, id, button_vtable)
    button.text = text
    button.text_color = rl.Color {241, 245, 249, 255}
    button.background_color = rl.Color {42, 91, 165, 255}
    button.hover_color = rl.Color {56, 110, 190, 255}
    button.pressed_color = rl.Color {31, 67, 125, 255}
    button.border_color = rl.Color {18, 38, 71, 255}
    button.font_size = 18
    button.padding = ui.padding_xy(14, 10)
    button.border_thickness = 1
    button.min_size = rl.Vector2 {180, 44}
    return button
}

button_set_icon :: proc(button: ^Button, icon: string, icon_size: i32) -> ^Button {
    button.icon = icon
    button.icon_size = icon_size
    return button
}

button_set_on_click :: proc(button: ^Button, on_click: Button_Click_Proc, data: rawptr) -> ^Button {
    button.on_click = on_click
    button.click_data = data
    return button
}

button_set_colors :: proc(button: ^Button, text_color, background_color, hover_color, pressed_color, border_color: rl.Color) -> ^Button {
    button.text_color = text_color
    button.background_color = background_color
    button.hover_color = hover_color
    button.pressed_color = pressed_color
    button.border_color = border_color
    return button
}

button_set_border_thickness :: proc(button: ^Button, border_thickness: f32) -> ^Button {
    button.border_thickness = border_thickness
    return button
}

button_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    button := cast(^Button) widget
    button.bounds = bounds
}

button_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    button := cast(^Button) widget

    if event.kind == .Click {
        if button.on_click != nil {
            button.on_click(button.click_data, ctx, widget)
        }

        return true
    }

    return false
}

button_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    button := cast(^Button) widget
    fill := button.background_color

    if ctx.active == widget {
        fill = button.pressed_color
    } else if ctx.hot == widget {
        fill = button.hover_color
    }

    rl.DrawRectangleRec(button.bounds, fill)
    if button.border_thickness > 0 {
        rl.DrawRectangleLinesEx(button.bounds, button.border_thickness, button.border_color)
    }

    ui.begin_clip(button.bounds)
    if button.icon != "" {
        icon_x := cast(i32) (button.bounds.x + (button.bounds.width - cast(f32) button.icon_size) * 0.5)
        icon_y := cast(i32) (button.bounds.y + (button.bounds.height - cast(f32) button.icon_size) * 0.5)
        ui.draw_icon(button.icon, icon_x, icon_y, button.icon_size, button.text_color)
    } else {
        text_width := ui.measure_text(button.text, button.font_size)
        text_x := cast(i32) (button.bounds.x + (button.bounds.width - cast(f32) text_width) * 0.5)
        text_y := cast(i32) (button.bounds.y + (button.bounds.height - cast(f32) button.font_size) * 0.5)
        ui.draw_text(button.text, text_x, text_y, button.font_size, button.text_color)
    }
    ui.end_clip()
}

button_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Button) widget)
}
