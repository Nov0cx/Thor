package ui

import rl "vendor:raylib"

Widget_Layout_Proc :: #type proc(widget: ^Widget, bounds: rl.Rectangle)
Widget_Event_Proc :: #type proc(widget: ^Widget, ctx: ^Context, event: ^Event) -> bool
Widget_Draw_Proc :: #type proc(widget: ^Widget, ctx: ^Context)
Widget_Destroy_Proc :: #type proc(widget: ^Widget)

Widget_VTable :: struct {
    layout:       Widget_Layout_Proc,
    handle_event: Widget_Event_Proc,
    draw:         Widget_Draw_Proc,
    destroy:      Widget_Destroy_Proc,
}

Widget :: struct {
    id:           string,
    bounds:       rl.Rectangle,
    min_size:     rl.Vector2,
    grow:         f32,
    visible:      bool,
    enabled:      bool,
    parent:       ^Widget,
    first_child:  ^Widget,
    last_child:   ^Widget,
    prev_sibling: ^Widget,
    next_sibling: ^Widget,
    vtable:       Widget_VTable,
}

widget_init :: proc(widget: ^Widget, id: string, vtable: Widget_VTable) {
    widget.id = id
    widget.grow = 0
    widget.visible = true
    widget.enabled = true
    widget.vtable = vtable
}

widget_set_grow :: proc(widget: ^Widget, grow: f32) {
    widget.grow = grow
}

widget_bring_to_front :: proc(widget: ^Widget) {
    if widget == nil || widget.parent == nil || widget.parent.last_child == widget {
        return
    }

    parent := widget.parent

    if widget.prev_sibling != nil {
        widget.prev_sibling.next_sibling = widget.next_sibling
    } else {
        parent.first_child = widget.next_sibling
    }

    if widget.next_sibling != nil {
        widget.next_sibling.prev_sibling = widget.prev_sibling
    } else {
        parent.last_child = widget.prev_sibling
    }

    widget.prev_sibling = parent.last_child
    widget.next_sibling = nil

    if parent.last_child != nil {
        parent.last_child.next_sibling = widget
    } else {
        parent.first_child = widget
    }

    parent.last_child = widget
}

widget_append_child :: proc(parent, child: ^Widget) {
    child.parent = parent
    child.prev_sibling = parent.last_child
    child.next_sibling = nil

    if parent.last_child != nil {
        parent.last_child.next_sibling = child
    } else {
        parent.first_child = child
    }

    parent.last_child = child
}

widget_contains_point :: proc(widget: ^Widget, point: rl.Vector2) -> bool {
    return rl.CheckCollisionPointRec(point, widget.bounds)
}

widget_hit_test :: proc(widget: ^Widget, point: rl.Vector2) -> ^Widget {
    if widget == nil || !widget.visible {
        return nil
    }

    if !widget_contains_point(widget, point) {
        return nil
    }

    child := widget.last_child
    for child != nil {
        hit := widget_hit_test(child, point)
        if hit != nil {
            return hit
        }
        child = child.prev_sibling
    }

    return widget
}

widget_layout_tree :: proc(widget: ^Widget, bounds: rl.Rectangle) {
    if widget == nil || !widget.visible {
        return
    }

    if widget.vtable.layout != nil {
        widget.vtable.layout(widget, bounds)
        return
    }

    widget.bounds = bounds

    child := widget.first_child
    for child != nil {
        widget_layout_tree(child, bounds)
        child = child.next_sibling
    }
}

widget_dispatch_event :: proc(start: ^Widget, ctx: ^Context, event: ^Event) -> bool {
    current := start
    for current != nil {
        if current.visible && current.enabled && current.vtable.handle_event != nil {
            if current.vtable.handle_event(current, ctx, event) {
                return true
            }
        }

        current = current.parent
    }

    return false
}

widget_draw_tree :: proc(widget: ^Widget, ctx: ^Context) {
    if widget == nil || !widget.visible {
        return
    }

    if widget.vtable.draw != nil {
        widget.vtable.draw(widget, ctx)
    }

    child := widget.first_child
    for child != nil {
        widget_draw_tree(child, ctx)
        child = child.next_sibling
    }
}

widget_destroy_tree :: proc(widget: ^Widget) {
    if widget == nil {
        return
    }

    child := widget.first_child
    for child != nil {
        next := child.next_sibling
        widget_destroy_tree(child)
        child = next
    }

    if widget.vtable.destroy != nil {
        widget.vtable.destroy(widget)
    }
}
