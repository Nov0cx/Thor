package ui

import "core:testing"

import rl "vendor:raylib"

import "../input"

@(private = "file")
Event_Probe :: struct {
    left:       int,
    left_mods:  input.Modifiers,
    hovered:    int,
    scrolled:   int,
    scroll_mods: input.Modifiers,
    released:   int,
    parent_left: int,
}

@(private = "file")
probe: Event_Probe

@(private = "file")
leaf_handler :: proc(widget: ^Widget, ctx: ^Context, event: ^Event) -> bool {
    #partial switch event.kind {
    case .Mouse_Leave:
        probe.left += 1
        probe.left_mods = event.mods
    case .Mouse_Hover:
        probe.hovered += 1
    case .Scroll:
        probe.scrolled += 1
        probe.scroll_mods = event.mods
    case .Key_Release:
        probe.released += 1
    }
    return true
}

@(private = "file")
parent_handler :: proc(widget: ^Widget, ctx: ^Context, event: ^Event) -> bool {
    if event.kind == .Mouse_Leave {
        probe.parent_left += 1
    }
    return false
}

// A root holding two leaves side by side, each 10x10.
@(private = "file")
build_probe_tree :: proc(ctx: ^Context, root, left, right: ^Widget) {
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

@(private = "file")
move_to :: proc(ctx: ^Context, x, y: f32) {
    event_queue_clear(&ctx.events)
    ctx.hit_valid = false
    event_queue_push(&ctx.events, Event{kind = .Mouse_Move, mouse_position = {x, y}})
    context_process_events(ctx)
}

@(test)
test_leave_fires_once_when_hover_moves_on :: proc(t: ^testing.T) {
    probe = {}
    ctx: Context
    root, left, right: Widget
    build_probe_tree(&ctx, &root, &left, &right)
    defer {
        ctx.root = nil
        context_destroy(&ctx)
    }

    move_to(&ctx, 5, 5)
    testing.expect_value(t, probe.left, 0)
    move_to(&ctx, 5, 6)
    testing.expect(t, probe.left == 0, "leave fired though the hovered widget did not change")

    move_to(&ctx, 15, 5)
    testing.expect_value(t, probe.left, 1)
    testing.expect(t, ctx.hot == &right, "hot did not move to the second widget")
    testing.expect(
        t,
        probe.parent_left == 0,
        "leave reached the parent, which still holds the cursor",
    )
}

@(test)
test_leave_fires_when_hover_leaves_the_tree :: proc(t: ^testing.T) {
    probe = {}
    ctx: Context
    root, left, right: Widget
    build_probe_tree(&ctx, &root, &left, &right)
    defer {
        ctx.root = nil
        context_destroy(&ctx)
    }

    move_to(&ctx, 5, 5)
    move_to(&ctx, 100, 100)

    testing.expect_value(t, probe.left, 1)
    testing.expect(t, ctx.hot == nil, "hot survived a move off the tree")
}

@(test)
test_scroll_carries_modifiers :: proc(t: ^testing.T) {
    probe = {}
    ctx: Context
    root, left, right: Widget
    build_probe_tree(&ctx, &root, &left, &right)
    defer {
        ctx.root = nil
        context_destroy(&ctx)
    }

    event_queue_push(
        &ctx.events,
        Event{kind = .Scroll, mouse_position = {5, 5}, wheel_delta = 1, mods = {.Ctrl}},
    )
    context_process_events(&ctx)

    testing.expect_value(t, probe.scrolled, 1)
    testing.expect(t, .Ctrl in probe.scroll_mods, "scroll reached the widget without its modifiers")
}

@(private = "file")
global_seen: int

@(private = "file")
count_global_key :: proc(data: rawptr, event: ^Event) -> bool {
    if event.kind == .Key_Release {
        global_seen += 1
    }
    return false
}

@(test)
test_key_release_reaches_global_hook_and_focus :: proc(t: ^testing.T) {
    probe = {}
    global_seen = 0
    ctx: Context
    root, left, right: Widget
    build_probe_tree(&ctx, &root, &left, &right)
    defer {
        ctx.root = nil
        context_destroy(&ctx)
    }

    context_set_global_key(&ctx, count_global_key, nil)
    ctx.focused = &left

    event_queue_push(&ctx.events, Event{kind = .Key_Release, key = .Z})
    context_process_events(&ctx)

    testing.expect_value(t, global_seen, 1)
    testing.expect_value(t, probe.released, 1)
}
