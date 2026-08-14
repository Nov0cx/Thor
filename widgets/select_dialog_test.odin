package widgets

import "core:fmt"
import "core:testing"
import rl "vendor:raylib"

import "../ui"

@(private = "file")
SELECT_TEST_OPTIONS :: [?]string {"On", "Off"}

// The title outlives the caller's storage: a temporary title stays readable
// after the temp allocator is reset, which the draw of the next frame needs.
@(test)
test_select_dialog_title_owned :: proc(t: ^testing.T) {
    dialog := select_dialog_create("select")
    defer select_dialog_destroy(&dialog.widget)
    ctx: ui.Context

    options := SELECT_TEST_OPTIONS
    title := fmt.tprintf("%s — %s", "gopls", "Hover")
    select_dialog_open(dialog, &ctx, title, options[:], "On", nil, nil, nil)
    free_all(context.temp_allocator)

    testing.expect_value(t, dialog.title, "gopls — Hover")
}

// A second open replaces the title and frees the first copy.
@(test)
test_select_dialog_title_replaced_on_reopen :: proc(t: ^testing.T) {
    dialog := select_dialog_create("select")
    defer select_dialog_destroy(&dialog.widget)
    ctx: ui.Context

    options := SELECT_TEST_OPTIONS
    select_dialog_open(dialog, &ctx, "Tooltips", options[:], "On", nil, nil, nil)
    select_dialog_open(dialog, &ctx, "Format on Save", options[:], "Off", nil, nil, nil)

    testing.expect_value(t, dialog.title, "Format on Save")
    testing.expect_value(t, dialog.selected, 1)
}

// The picker opens over the settings modal, so its box must stay inside that
// modal instead of floating above it over the editor.
@(test)
test_select_dialog_sits_inside_settings_modal :: proc(t: ^testing.T) {
    dialog := select_dialog_create("select")
    defer select_dialog_destroy(&dialog.widget)
    view := settings_view_create("settings")
    defer settings_view_destroy(&view.widget)
    ctx: ui.Context

    options := SELECT_TEST_OPTIONS
    select_dialog_open(dialog, &ctx, "Tooltips", options[:], "On", nil, nil, nil)

    bounds := rl.Rectangle {0, 0, 1280, 800}
    settings_view_layout(&view.widget, bounds)
    select_dialog_layout(&dialog.widget, bounds)

    testing.expectf(
        t,
        dialog.box.y >= view.box.y &&
        dialog.box.y + dialog.box.height <= view.box.y + view.box.height,
        "picker %v is not inside the settings modal %v",
        dialog.box,
        view.box,
    )
}

// A screen shorter than the box keeps the header on it.
@(test)
test_select_dialog_clamps_to_top :: proc(t: ^testing.T) {
    dialog := select_dialog_create("select")
    defer select_dialog_destroy(&dialog.widget)
    ctx: ui.Context

    options := SELECT_TEST_OPTIONS
    select_dialog_open(dialog, &ctx, "Tooltips", options[:], "On", nil, nil, nil)
    select_dialog_layout(&dialog.widget, rl.Rectangle {0, 0, 640, 60})

    testing.expect_value(t, dialog.box.y, dialog.top_margin)
}
