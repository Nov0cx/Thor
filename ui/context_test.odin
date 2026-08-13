package ui

import "core:testing"

import rl "vendor:raylib"

import "../input"

// Counts what reached it. The tests run in parallel, so the tally lives on the
// widget rather than in a package variable.
@(private = "file")
Probe :: struct {
    using widget: Widget,
    left:         int,
    hovered:      int,
    scrolled:     int,
    released:     int,
    ups:          int,
    clicks:       int,
    mods:         input.Modifiers,
}

@(private = "file")
leaf_handler :: proc(widget: ^Widget, ctx: ^Context, event: ^Event) -> bool {
    probe := cast(^Probe) widget
    #partial switch event.kind {
    case .Mouse_Leave:
        probe.left += 1
    case .Mouse_Hover:
        probe.hovered += 1
    case .Scroll:
        probe.scrolled += 1
        probe.mods = event.mods
    case .Key_Release:
        probe.released += 1
    case .Mouse_Up:
        probe.ups += 1
    case .Click:
        probe.clicks += 1
    }
    return true
}

@(private = "file")
parent_handler :: proc(widget: ^Widget, ctx: ^Context, event: ^Event) -> bool {
    probe := cast(^Probe) widget
    if event.kind == .Mouse_Leave {
        probe.left += 1
    }
    return false
}

// A root holding two leaves side by side, each 10x10.
@(private = "file")
build_probe_tree :: proc(ctx: ^Context, root, left, right: ^Probe) {
    widget_init(root, "root", {handle_event = parent_handler})
    widget_init(left, "left", {handle_event = leaf_handler})
    widget_init(right, "right", {handle_event = leaf_handler})
    widget_append_child(root, left)
    widget_append_child(root, right)
    root.bounds = rl.Rectangle{0, 0, 20, 10}
    left.bounds = rl.Rectangle{0, 0, 10, 10}
    right.bounds = rl.Rectangle{10, 0, 10, 10}

    context_init(ctx)
    context_set_root(ctx, root)
}

// The tree is stack-allocated, so the root must not be destroyed with the context.
@(private = "file")
drop_probe_tree :: proc(ctx: ^Context) {
    ctx.root = nil
    context_destroy(ctx)
}

@(private = "file")
move_to :: proc(ctx: ^Context, x, y: f32) {
    event_queue_clear(&ctx.events)
    ctx.hit_valid = false
    event_queue_push(&ctx.events, Event{kind = .Mouse_Move, mouse_position = {x, y}})
    context_process_events(ctx)
}

@(private = "file")
button_event :: proc(ctx: ^Context, kind: Event_Type, button: rl.MouseButton, x, y: f32) {
    event_queue_clear(&ctx.events)
    ctx.hit_valid = false
    event_queue_push(&ctx.events, Event{kind = kind, mouse_button = button, mouse_position = {x, y}})
    context_process_events(ctx)
}

@(test)
test_leave_fires_once_when_hover_moves_on :: proc(t: ^testing.T) {
    ctx: Context
    root, left, right: Probe
    build_probe_tree(&ctx, &root, &left, &right)
    defer drop_probe_tree(&ctx)

    move_to(&ctx, 5, 5)
    testing.expect_value(t, left.left, 0)
    move_to(&ctx, 5, 6)
    testing.expect(t, left.left == 0, "leave fired though the hovered widget did not change")

    move_to(&ctx, 15, 5)
    testing.expect_value(t, left.left, 1)
    testing.expect(t, ctx.hot == &right.widget, "hot did not move to the second widget")
    testing.expect(t, root.left == 0, "leave reached the parent, which still holds the cursor")
    testing.expect_value(t, right.left, 0)
}

@(test)
test_leave_fires_when_hover_leaves_the_tree :: proc(t: ^testing.T) {
    ctx: Context
    root, left, right: Probe
    build_probe_tree(&ctx, &root, &left, &right)
    defer drop_probe_tree(&ctx)

    move_to(&ctx, 5, 5)
    move_to(&ctx, 100, 100)

    testing.expect_value(t, left.left, 1)
    testing.expect(t, ctx.hot == nil, "hot survived a move off the tree")
}

@(test)
test_scroll_carries_modifiers :: proc(t: ^testing.T) {
    ctx: Context
    root, left, right: Probe
    build_probe_tree(&ctx, &root, &left, &right)
    defer drop_probe_tree(&ctx)

    event_queue_push(
        &ctx.events,
        Event{kind = .Scroll, mouse_position = {5, 5}, wheel_delta = 1, mods = {.Ctrl}},
    )
    context_process_events(&ctx)

    testing.expect_value(t, left.scrolled, 1)
    testing.expect(t, .Ctrl in left.mods, "scroll reached the widget without its modifiers")
}

@(test)
test_drag_keeps_its_target_when_a_second_button_goes_down :: proc(t: ^testing.T) {
    ctx: Context
    root, left, right: Probe
    build_probe_tree(&ctx, &root, &left, &right)
    defer drop_probe_tree(&ctx)

    button_event(&ctx, .Mouse_Down, .LEFT, 5, 5)
    button_event(&ctx, .Mouse_Down, .RIGHT, 15, 5)
    button_event(&ctx, .Mouse_Up, .RIGHT, 15, 5)

    testing.expect(t, context_active(&ctx) == &left.widget, "the right button took the left drag")

    button_event(&ctx, .Mouse_Up, .LEFT, 5, 5)
    testing.expect_value(t, left.ups, 1)
    testing.expect_value(t, left.clicks, 1)
    testing.expect(t, context_active(&ctx) == nil, "a button stayed active after its release")
}

@(private = "file")
Key_Probe :: struct {
    seen: int,
}

@(private = "file")
count_global_key :: proc(data: rawptr, event: ^Event) -> bool {
    probe := cast(^Key_Probe) data
    if event.kind == .Key_Release {
        probe.seen += 1
    }
    return false
}

@(test)
test_key_release_reaches_global_hook_and_focus :: proc(t: ^testing.T) {
    ctx: Context
    root, left, right: Probe
    build_probe_tree(&ctx, &root, &left, &right)
    defer drop_probe_tree(&ctx)

    global: Key_Probe
    context_set_global_key(&ctx, count_global_key, &global)
    ctx.focused = &left.widget

    event_queue_push(&ctx.events, Event{kind = .Key_Release, key = .Z})
    context_process_events(&ctx)

    testing.expect_value(t, global.seen, 1)
    testing.expect_value(t, left.released, 1)
}
