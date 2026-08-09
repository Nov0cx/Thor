package widgets

import "core:testing"
import rl "vendor:raylib"

import "../ui"

@(private = "file")
Settings_Record :: struct {
    number_calls: int,
    number_id:    string,
    number_value: int,
}

@(private = "file")
settings_on_number :: proc(data: rawptr, id: string, value: int) {
    record := cast(^Settings_Record) data
    record.number_calls += 1
    record.number_id = id
    record.number_value = value
}

@(private = "file")
settings_click :: proc(view: ^Settings_View, ctx: ^ui.Context, point: rl.Vector2) {
    event := ui.Event {kind = .Mouse_Down, mouse_position = point}
    settings_view_handle_event(&view.widget, ctx, &event)
}

@(private = "file")
settings_center :: proc(rect: rl.Rectangle) -> rl.Vector2 {
    return rl.Vector2 {rect.x + rect.width * 0.5, rect.y + rect.height * 0.5}
}

// A view with `categories` sidebar entries, each holding one number row.
@(private = "file")
settings_populate :: proc(view: ^Settings_View, categories: int) {
    ids := [?]string {"a", "b", "c", "d", "e", "f", "g", "h"}
    for i in 0 ..< categories {
        id := ids[i]
        settings_view_begin_category(view, id, id, "settings")
        settings_view_add_number(view, id, id, 4, 1, 9, 1)
    }
}

// One category holding a top-level row and a folded group of two rows.
@(private = "file")
settings_populate_group :: proc(view: ^Settings_View) {
    settings_view_begin_category(view, "language", "Language", "brain")
    settings_view_add_choice(view, "language", "Language Intelligence", "On")
    settings_view_begin_group(view, "language.odin", "Odin Analyzer", collapsed = true)
    settings_view_add_choice(view, "language.hover", "Hover", "On")
    settings_view_add_choice(view, "language.rename", "Rename Symbol", "Off")
    settings_view_end_group(view)
}

@(private = "file")
SETTINGS_TEST_BOUNDS :: rl.Rectangle {0, 0, 1280, 800}

// The search field ends clear of the list: a click in the space under it hits
// no row, and the first row starts below that space.
@(test)
test_settings_search_bottom_padding :: proc(t: ^testing.T) {
    view := settings_view_create("settings")
    defer settings_view_destroy(&view.widget)

    ctx: ui.Context
    settings_populate(view, 3)
    settings_view_open(view, &ctx)
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)

    testing.expectf(
        t,
        view.search_height > SETTINGS_SEARCH_PAD_TOP + SETTINGS_SEARCH_FIELD_HEIGHT,
        "expected clear space under the search field, got %v",
        view.search_height,
    )

    field := settings_view_search_rect(view)
    row := settings_view_row_rect(view, 0)
    testing.expectf(
        t,
        row.y >= field.y + field.height + SETTINGS_SEARCH_PAD_BOTTOM,
        "expected the first row under the padding, field ends %v, row starts %v",
        field.y + field.height,
        row.y,
    )

    view.selected = -1
    settings_click(view, &ctx, rl.Vector2 {field.x + 40, field.y + field.height + 2})
    testing.expectf(t, view.selected == -1, "a click in the padding selected row %d", view.selected)

    settings_click(view, &ctx, settings_center(row))
    testing.expectf(t, view.selected == 0, "expected row 0 selected, got %d", view.selected)
}

// Category entries start under a top pad; a click in that pad changes nothing.
@(test)
test_settings_sidebar_top_padding :: proc(t: ^testing.T) {
    view := settings_view_create("settings")
    defer settings_view_destroy(&view.widget)

    ctx: ui.Context
    settings_populate(view, 3)
    settings_view_open(view, &ctx)
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)

    first := settings_view_category_rect(view, 0)
    testing.expectf(
        t,
        first.y == view.sidebar.y + SETTINGS_SIDEBAR_PAD_TOP,
        "expected the first entry under the pad, got %v",
        first.y - view.sidebar.y,
    )

    settings_click(view, &ctx, rl.Vector2 {view.sidebar.x + 20, view.sidebar.y + 2})
    testing.expectf(t, view.selected_category == 0, "a click in the pad selected category %d", view.selected_category)

    settings_click(view, &ctx, settings_center(settings_view_category_rect(view, 2)))
    testing.expectf(t, view.selected_category == 2, "expected category 2, got %d", view.selected_category)
}

// The stepper parts are spaced: -/+ report a clamped value, the gap reports nothing.
@(test)
test_settings_stepper_hit_rects :: proc(t: ^testing.T) {
    view := settings_view_create("settings")
    defer settings_view_destroy(&view.widget)

    record: Settings_Record
    ctx: ui.Context
    settings_view_set_callbacks(view, settings_on_number, nil, nil, nil, nil, &record)
    settings_populate(view, 1)
    settings_view_open(view, &ctx)
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)

    row := settings_view_row_rect(view, 0)
    minus, value, plus := settings_view_number_rects(view, row)
    testing.expectf(t, minus.x + minus.width < value.x, "minus touches the value box")
    testing.expectf(t, value.x + value.width < plus.x, "the value box touches plus")

    settings_click(view, &ctx, settings_center(minus))
    testing.expectf(t, record.number_calls == 1, "expected one call for minus, got %d", record.number_calls)
    testing.expectf(t, record.number_value == 3, "expected 3 from minus, got %d", record.number_value)

    settings_click(view, &ctx, settings_center(plus))
    testing.expectf(t, record.number_calls == 2, "expected two calls after plus, got %d", record.number_calls)
    testing.expectf(t, record.number_value == 5, "expected 5 from plus, got %d", record.number_value)

    settings_click(view, &ctx, rl.Vector2 {minus.x + minus.width + 3, settings_center(minus).y})
    testing.expectf(t, record.number_calls == 2, "a click in the gap stepped the value")
}

// The box keeps its size whatever the category count is.
@(test)
test_settings_fixed_height :: proc(t: ^testing.T) {
    small := settings_view_create("settings-small")
    defer settings_view_destroy(&small.widget)
    large := settings_view_create("settings-large")
    defer settings_view_destroy(&large.widget)

    ctx: ui.Context
    settings_populate(small, 3)
    settings_view_open(small, &ctx)
    settings_view_layout(&small.widget, SETTINGS_TEST_BOUNDS)

    settings_populate(large, 8)
    settings_view_open(large, &ctx)
    settings_view_layout(&large.widget, SETTINGS_TEST_BOUNDS)

    testing.expectf(
        t,
        small.box.height == large.box.height,
        "expected one height, got %v and %v",
        small.box.height,
        large.box.height,
    )
    testing.expectf(t, small.box.height == small.height, "expected %v tall, got %v", small.height, small.box.height)
}

// A folded group hides its rows, the header unfolds them, and a repopulate
// keeps the state the user set.
@(test)
test_settings_group_folds :: proc(t: ^testing.T) {
    view := settings_view_create("settings")
    defer settings_view_destroy(&view.widget)

    ctx: ui.Context
    settings_populate_group(view)
    settings_view_open(view, &ctx)
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)
    testing.expectf(t, len(view.visible_rows) == 2, "folded: expected 2 rows, got %d", len(view.visible_rows))

    settings_click(view, &ctx, settings_center(settings_view_row_rect(view, 1)))
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)
    testing.expectf(t, len(view.visible_rows) == 4, "unfolded: expected 4 rows, got %d", len(view.visible_rows))

    settings_view_clear(view)
    settings_populate_group(view)
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)
    testing.expectf(t, len(view.visible_rows) == 4, "a repopulate refolded the group, %d rows", len(view.visible_rows))

    settings_click(view, &ctx, settings_center(settings_view_row_rect(view, 1)))
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)
    testing.expectf(t, len(view.visible_rows) == 2, "refolded: expected 2 rows, got %d", len(view.visible_rows))
}

// A search reaches into a folded group and lists no group headers.
@(test)
test_settings_group_search :: proc(t: ^testing.T) {
    view := settings_view_create("settings")
    defer settings_view_destroy(&view.widget)

    ctx: ui.Context
    settings_populate_group(view)
    settings_view_open(view, &ctx)
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)

    append(&view.search, ..transmute([]u8) string("hover"))
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)
    testing.expectf(t, len(view.visible_rows) == 1, "expected one match, got %d", len(view.visible_rows))
    testing.expect(t, view.rows[view.visible_rows[0]].id == "language.hover", "the folded row did not match")

    clear(&view.search)
    append(&view.search, ..transmute([]u8) string("analyzer"))
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)
    testing.expectf(t, len(view.visible_rows) == 0, "a group header matched the search, %d rows", len(view.visible_rows))
}

// The close box closes the view, and so does a click outside the box.
@(test)
test_settings_close_button :: proc(t: ^testing.T) {
    view := settings_view_create("settings")
    defer settings_view_destroy(&view.widget)

    ctx: ui.Context
    settings_populate(view, 3)
    settings_view_open(view, &ctx)
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)

    close := settings_view_close_rect(view)
    testing.expect(t, rl.CheckCollisionPointRec(settings_center(close), view.box), "the close box left the header")

    settings_click(view, &ctx, settings_center(close))
    testing.expect(t, !view.visible, "the close box did not close the view")

    settings_view_open(view, &ctx)
    settings_view_layout(&view.widget, SETTINGS_TEST_BOUNDS)
    settings_click(view, &ctx, rl.Vector2 {view.box.x - 20, view.box.y - 20})
    testing.expect(t, !view.visible, "a click outside did not close the view")
}
