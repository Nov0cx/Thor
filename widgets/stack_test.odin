package widgets

import "core:testing"
import rl "vendor:raylib"

import "../ui"

// A stack cannot measure its children, so one that does not grow is laid out at
// its own min_size.y. Its rows still draw at their full height (widget_draw_tree
// never clips), but ui.widget_hit_test stops at the first widget the point
// misses — so rows under a zero-height parent are visible and unclickable. This
// is what the welcome page's recent list hit.
@(test)
test_stack_child_needs_its_content_height :: proc(t: ^testing.T) {
    root := stack_create("root", .Vertical)
    stack_set_gap(root, 0)
    stack_set_padding(root, ui.padding(0))
    defer ui.widget_destroy_tree(&root.widget)

    list := stack_create("list", .Vertical)
    stack_set_gap(list, 0)
    stack_set_padding(list, ui.padding(0))

    row := stack_create("row", .Vertical)
    row.min_size = rl.Vector2 {0, 36}
    append_child(&list.widget, &row.widget)

    // Holds all the grow, so the list gets nothing beyond its min_size.
    spacer := stack_create("spacer", .Vertical)
    ui.widget_set_grow(&spacer.widget, 1)

    append_child(&root.widget, &list.widget)
    append_child(&root.widget, &spacer.widget)

    bounds := rl.Rectangle {0, 0, 200, 400}
    point := rl.Vector2 {100, 10}

    stack_layout(&root.widget, bounds)
    testing.expectf(t, list.bounds.height == 0, "the list starts flat, got %v", list.bounds.height)
    testing.expectf(
        t, row.bounds.height == 36, "the row keeps its own height, got %v", row.bounds.height,
    )
    hit := ui.widget_hit_test(&root.widget, point)
    testing.expectf(
        t, hit != &row.widget, "a row under a flat parent must not be reachable, got %q", hit.id,
    )

    // The height the rows add up to is what makes them clickable.
    list.min_size.y = 36
    stack_layout(&root.widget, bounds)
    hit = ui.widget_hit_test(&root.widget, point)
    testing.expectf(t, hit == &row.widget, "expected the row, got %q", hit.id)
}
