package widgets

import rl "vendor:raylib"

import "../ui"
import "core:strings"

Label_Text_Proc :: #type proc(data: rawptr) -> string

Label :: struct {
    using widget: ui.Widget,
    text:             string,
    text_proc:        Label_Text_Proc,
    text_data:        rawptr,
    text_color:       rl.Color,
    background_color: rl.Color,
    font_size:        i32,
    padding:          ui.Padding,
    top_align:        bool,
}

label_vtable := ui.Widget_VTable {
    layout = label_layout,
    draw = label_draw,
    destroy = label_destroy,
}

label_create :: proc(id, text: string) -> ^Label {
    label := new(Label)
    ui.widget_init(&label.widget, id, label_vtable)
    label.text = text
    label.text_color = rl.Color {225, 228, 232, 255}
    label.background_color = rl.Color {0, 0, 0, 0}
    label.font_size = 20
    label.padding = ui.padding_xy(14, 10)
    label.min_size = rl.Vector2 {160, 44}
    return label
}

label_bind_text :: proc(label: ^Label, text_proc: Label_Text_Proc, data: rawptr) -> ^Label {
    label.text_proc = text_proc
    label.text_data = data
    return label
}

label_set_text_color :: proc(label: ^Label, text_color: rl.Color) -> ^Label {
    label.text_color = text_color
    return label
}

label_set_background :: proc(label: ^Label, background_color: rl.Color) -> ^Label {
    label.background_color = background_color
    return label
}

label_set_top_align :: proc(label: ^Label, top_align: bool) -> ^Label {
    label.top_align = top_align
    return label
}

label_current_text :: proc(label: ^Label) -> string {
    if label.text_proc != nil {
        return label.text_proc(label.text_data)
    }

    return label.text
}

label_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    label := cast(^Label) widget
    label.bounds = bounds
}

label_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    label := cast(^Label) widget
    if label.background_color.a > 0 {
        rl.DrawRectangleRec(label.bounds, label.background_color)
    }

    text := label_current_text(label)
    text_width := ui.measure_text(text, label.font_size)
    text_x := cast(i32) (label.bounds.x + label.padding.left)
    text_y := cast(i32) (label.bounds.y + (label.bounds.height - cast(f32) label.font_size) * 0.5)

    if label.top_align || strings.contains(text, "\n") || cast(f32) text_width > label.bounds.width - label.padding.left - label.padding.right {
        text_y = cast(i32) (label.bounds.y + label.padding.top)
    }

    ui.begin_clip(label.bounds)
    ui.draw_text(text, text_x, text_y, label.font_size, label.text_color)
    ui.end_clip()
}

label_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Label) widget)
}
