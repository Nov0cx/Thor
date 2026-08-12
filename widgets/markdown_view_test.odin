package widgets

import "core:testing"

import rl "vendor:raylib"

import "../ui"

// Run from the repository root: odin test widgets
//
// There is no font atlas in a headless run, so ui.measure_text reports 0 and
// every laid-out box is zero-wide. That makes a positive hit test impossible to
// stage here, so these cover what the layout carries rather than where it lands.

// The target of the first laid-out link, "" when the page holds none.
@(private = "file")
markdown_test_first_url :: proc(view: ^Markdown_View, source: string) -> string {
    markdown_view_set_source(view, source, view.source_rev + 1)
    markdown_ensure_layout(view)
    for item in view.items {
        if item.url != "" {
            return item.url
        }
    }
    return ""
}

// Anything that is not a full [text](url) is prose, so nothing in it opens. An
// empty target is a link with nowhere to go, which is the same thing here.
@(test)
test_markdown_partial_link_has_no_target :: proc(t: ^testing.T) {
    view := markdown_view_create("md-test")
    defer markdown_view_destroy(&view.widget)
    markdown_view_layout(&view.widget, rl.Rectangle {0, 0, 600, 400})

    for source in ([]string {"[docs\n", "[docs]\n", "[docs] (x)\n", "[docs](x\n", "[docs]()\n"}) {
        testing.expect_value(t, markdown_test_first_url(view, source), "")
    }

    // The complete form does resolve, so the cases above fail on their shape and
    // not because the fixture never finds anything.
    testing.expect_value(t, markdown_test_first_url(view, "[docs](x)\n"), "x")
}

// The url has to survive parsing and layout: it is what the click opens, and it
// used to be dropped the moment the span was bounded.
@(test)
test_markdown_layout_keeps_link_url :: proc(t: ^testing.T) {
    view := markdown_view_create("md-test")
    defer markdown_view_destroy(&view.widget)

    markdown_view_layout(&view.widget, rl.Rectangle {0, 0, 600, 400})
    markdown_view_set_source(view, "see [docs](building.md) here\n", 1)
    markdown_ensure_layout(view)

    found := false
    for item in view.items {
        if item.url == "" {
            continue
        }
        testing.expect_value(t, item.kind, Md_Item_Kind.Text)
        testing.expect_value(t, item.text, "docs")
        testing.expect_value(t, item.url, "building.md")
        found = true
    }
    testing.expect(t, found, "the laid-out link carries its target")
}

// Plain prose carries no target, so nothing in it can be clicked.
@(test)
test_markdown_layout_plain_text_has_no_url :: proc(t: ^testing.T) {
    view := markdown_view_create("md-test")
    defer markdown_view_destroy(&view.widget)

    markdown_view_layout(&view.widget, rl.Rectangle {0, 0, 600, 400})
    markdown_view_set_source(view, "just some words\n", 1)
    markdown_ensure_layout(view)

    for item in view.items {
        testing.expect_value(t, item.url, "")
    }
}

// A click outside the pane is not a link click, whatever the page holds.
@(test)
test_markdown_click_outside_bounds :: proc(t: ^testing.T) {
    view := markdown_view_create("md-test")
    defer markdown_view_destroy(&view.widget)

    markdown_view_layout(&view.widget, rl.Rectangle {0, 0, 600, 400})
    markdown_view_set_source(view, "see [docs](building.md) here\n", 1)

    testing.expect_value(t, markdown_link_index_at(view, rl.Vector2 {900, 900}), -1)

    // With no owner hooked up the widget stays quiet rather than reaching for a
    // nil callback.
    click := ui.Event {kind = .Click, mouse_button = .LEFT, mouse_position = rl.Vector2 {10, 10}}
    testing.expect(t, !markdown_view_handle_event(&view.widget, nil, &click), "no owner, no link")
}
