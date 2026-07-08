package widgets

import rl "vendor:raylib"

import "../ui"

Stack :: struct {
    using widget: ui.Widget,
    axis:             ui.Axis,
    gap:              f32,
    padding:          ui.Padding,
    background_color: rl.Color,
}

stack_vtable := ui.Widget_VTable {
    layout = stack_layout,
    draw = stack_draw,
    destroy = stack_destroy,
}

stack_create :: proc(id: string, axis: ui.Axis) -> ^Stack {
    stack := new(Stack)
    ui.widget_init(&stack.widget, id, stack_vtable)
    stack.axis = axis
    stack.gap = 12
    stack.padding = ui.padding(12)
    stack.background_color = rl.Color {0, 0, 0, 0}
    return stack
}

stack_set_gap :: proc(stack: ^Stack, gap: f32) -> ^Stack {
    stack.gap = gap
    return stack
}

stack_set_padding :: proc(stack: ^Stack, padding: ui.Padding) -> ^Stack {
    stack.padding = padding
    return stack
}

stack_set_background :: proc(stack: ^Stack, background_color: rl.Color) -> ^Stack {
    stack.background_color = background_color
    return stack
}

stack_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    stack := cast(^Stack) widget
    stack.bounds = bounds

    inner_bounds := ui.shrink_rectangle(bounds, stack.padding)

    visible_children := 0
    child := stack.first_child
    for child != nil {
        if child.visible {
            visible_children += 1
        }
        child = child.next_sibling
    }

    if visible_children == 0 {
        return
    }

    if stack.axis == .Vertical {
        total_gap := stack.gap * cast(f32) (visible_children - 1)
        min_height: f32 = 0
        total_grow: f32 = 0

        child = stack.first_child
        for child != nil {
            if child.visible {
                min_height += child.min_size.y
                total_grow += child.grow
            }
            child = child.next_sibling
        }

        extra_height := inner_bounds.height - min_height - total_gap
        if extra_height < 0 {
            extra_height = 0
        }

        y := inner_bounds.y

        child = stack.first_child
        for child != nil {
            if child.visible {
                child_height := child.min_size.y
                if extra_height > 0 {
                    if total_grow > 0 && child.grow > 0 {
                        child_height += extra_height * (child.grow / total_grow)
                    } else if total_grow == 0 {
                        child_height += extra_height / cast(f32) visible_children
                    }
                }
                child_bounds := rl.Rectangle {
                    x = inner_bounds.x,
                    y = y,
                    width = inner_bounds.width,
                    height = child_height,
                }

                ui.widget_layout_tree(child, child_bounds)
                y += child_height + stack.gap
            }

            child = child.next_sibling
        }
    } else {
        total_gap := stack.gap * cast(f32) (visible_children - 1)
        min_width: f32 = 0
        total_grow: f32 = 0

        child = stack.first_child
        for child != nil {
            if child.visible {
                min_width += child.min_size.x
                total_grow += child.grow
            }
            child = child.next_sibling
        }

        extra_width := inner_bounds.width - min_width - total_gap
        if extra_width < 0 {
            extra_width = 0
        }

        x := inner_bounds.x

        child = stack.first_child
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
                child_bounds := rl.Rectangle {
                    x = x,
                    y = inner_bounds.y,
                    width = child_width,
                    height = inner_bounds.height,
                }

                ui.widget_layout_tree(child, child_bounds)
                x += child_width + stack.gap
            }

            child = child.next_sibling
        }
    }
}

stack_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    stack := cast(^Stack) widget
    if stack.background_color.a == 0 {
        return
    }

    rl.DrawRectangleRec(stack.bounds, stack.background_color)
}

stack_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Stack) widget)
}
