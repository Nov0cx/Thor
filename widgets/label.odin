package widgets

import rl "vendor:raylib"

import "../ui"
import "core:strings"

// Where the text sits across the widget width.
Label_Align :: enum {
    Left,
    Center,
}

Label :: struct {
    using widget: ui.Widget,
    text:             string,
    text_color:       rl.Color,
    background_color: rl.Color,
    font_size:        i32,
    padding:          ui.Padding,
    top_align:        bool,
    align:            Label_Align,
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

label_set_text_color :: proc(label: ^Label, text_color: rl.Color) -> ^Label {
    label.text_color = text_color
    return label
}

label_set_top_align :: proc(label: ^Label, top_align: bool) -> ^Label {
    label.top_align = top_align
    return label
}

label_set_align :: proc(label: ^Label, align: Label_Align) -> ^Label {
    label.align = align
    return label
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

    text := label.text
    text_width := ui.measure_text(text, label.font_size)
    inner_width := label.bounds.width - label.padding.left - label.padding.right
    text_x := cast(i32) (label.bounds.x + label.padding.left)
    // Text too wide to center would be cut on both sides, so it keeps the
    // left-aligned clip below.
    if label.align == .Center && cast(f32) text_width <= inner_width {
        text_x = cast(i32) (label.bounds.x + (label.bounds.width - cast(f32) text_width) * 0.5)
    }
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
