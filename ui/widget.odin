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
    // Pixels the hit area grows past bounds on every side. Lets a thin divider
    // draw as a 1px line yet stay grabbable over a wider zone.
    hit_expand:   f32,
    grow:         f32,
    visible:      bool,
    enabled:      bool,
    parent:       ^Widget, // borrowed
    // The child list. widget_destroy_tree walks first_child and next_sibling,
    // so those two links own; last_child and prev_sibling only point back.
    first_child:  ^Widget, // owned
    last_child:   ^Widget, // borrowed
    prev_sibling: ^Widget, // borrowed
    next_sibling: ^Widget, // owned
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

// Links `child` in immediately after `anchor` among its parent's children.
widget_insert_after :: proc(anchor, child: ^Widget) {
    child.parent = anchor.parent
    child.prev_sibling = anchor
    child.next_sibling = anchor.next_sibling

    if anchor.next_sibling != nil {
        anchor.next_sibling.prev_sibling = child
    } else if anchor.parent != nil {
        anchor.parent.last_child = child
    }
    anchor.next_sibling = child
}

// Unlinks `child` from its parent. The caller owns it after this, and destroys
// it with widget_destroy_tree. Used where the tree changes at runtime, as when a
// plugin re-renders a panel.
widget_remove_child :: proc(child: ^Widget) {
    parent := child.parent
    if parent == nil {
        return
    }

    if child.prev_sibling != nil {
        child.prev_sibling.next_sibling = child.next_sibling
    } else {
        parent.first_child = child.next_sibling
    }

    if child.next_sibling != nil {
        child.next_sibling.prev_sibling = child.prev_sibling
    } else {
        parent.last_child = child.prev_sibling
    }

    child.parent = nil
    child.prev_sibling = nil
    child.next_sibling = nil
}

// True when `widget` is `root` or one of its descendants.
widget_contains :: proc(root, widget: ^Widget) -> bool {
    for current := widget; current != nil; current = current.parent {
        if current == root {
            return true
        }
    }
    return false
}

widget_contains_point :: proc(widget: ^Widget, point: rl.Vector2) -> bool {
    bounds := widget.bounds
    if widget.hit_expand != 0 {
        bounds.x -= widget.hit_expand
        bounds.y -= widget.hit_expand
        bounds.width += widget.hit_expand * 2
        bounds.height += widget.hit_expand * 2
    }
    return rl.CheckCollisionPointRec(point, bounds)
}

widget_hit_test :: proc(widget: ^Widget, point: rl.Vector2) -> ^Widget {
    if widget == nil || !widget.visible {
        return nil
    }

    if !widget_contains_point(widget, point) {
        return nil
    }

    // Widgets that expand their hit area (dividers) win first, so a grab zone
    // straddling a neighbor still catches the divider instead of the panel.
    child := widget.last_child
    for child != nil {
        if child.visible && child.hit_expand != 0 && widget_contains_point(child, point) {
            return child
        }
        child = child.prev_sibling
    }

    child = widget.last_child
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

// Sends `event` to one widget only. For an event that names a single widget,
// like the hover it just lost, where an ancestor must not hear it.
widget_send_event :: proc(widget: ^Widget, ctx: ^Context, event: ^Event) -> bool {
    if widget == nil || !widget.visible || !widget.enabled || widget.vtable.handle_event == nil {
        return false
    }
    return widget.vtable.handle_event(widget, ctx, event)
}

// Sends `event` to `start`, then up to each ancestor until one consumes it. The
// parent is read before the handler runs, so a handler that unlinks or destroys
// its own widget still bubbles along the chain it had at dispatch time.
widget_dispatch_event :: proc(start: ^Widget, ctx: ^Context, event: ^Event) -> bool {
    current := start
    for current != nil {
        parent := current.parent

        if current.visible && current.enabled && current.vtable.handle_event != nil {
            if current.vtable.handle_event(current, ctx, event) {
                return true
            }
        }

        current = parent
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
