package ui

import "core:testing"

@(private = "file")
Dispatch_Probe :: struct {
    child_seen:  bool,
    parent_seen: bool,
    root_seen:   bool,
}

@(private = "file")
probe: Dispatch_Probe

// Unlinks itself mid-event and declines it, as a plugin panel re-render does.
@(private = "file")
detach_handler :: proc(widget: ^Widget, ctx: ^Context, event: ^Event) -> bool {
    probe.child_seen = true
    widget_remove_child(widget)
    return false
}

@(private = "file")
parent_handler :: proc(widget: ^Widget, ctx: ^Context, event: ^Event) -> bool {
    probe.parent_seen = true
    return false
}

@(private = "file")
root_handler :: proc(widget: ^Widget, ctx: ^Context, event: ^Event) -> bool {
    probe.root_seen = true
    return true
}

@(test)
test_dispatch_bubbles_past_self_detaching_handler :: proc(t: ^testing.T) {
    probe = {}

    root, middle, leaf: Widget
    widget_init(&root, "root", {handle_event = root_handler})
    widget_init(&middle, "middle", {handle_event = parent_handler})
    widget_init(&leaf, "leaf", {handle_event = detach_handler})
    widget_append_child(&root, &middle)
    widget_append_child(&middle, &leaf)

    event := Event{kind = .Click}
    handled := widget_dispatch_event(&leaf, nil, &event)

    testing.expect(t, probe.child_seen, "leaf handler did not run")
    testing.expect(t, probe.parent_seen, "bubbling stopped at the detached leaf")
    testing.expect(t, probe.root_seen, "event never reached the root handler")
    testing.expect(t, handled, "root consumed the event but dispatch reported false")
    testing.expect(t, leaf.parent == nil, "leaf stayed linked to its parent")
}
