package widgets

import "core:testing"
import rl "vendor:raylib"

import "../ui"

@(private = "file")
Theme_Record :: struct {
    colors:  int,
    actions: int,
    id:      string,
}

@(private = "file")
theme_on_color :: proc(data: rawptr, key: string) {
    record := cast(^Theme_Record) data
    record.colors += 1
    record.id = key
}

@(private = "file")
theme_on_action :: proc(data: rawptr, action: string) {
    record := cast(^Theme_Record) data
    record.actions += 1
    record.id = action
}

@(private = "file")
THEME_TEST_BOUNDS :: rl.Rectangle {0, 0, 1280, 800}

// One action row in a folded group, then two color rows in an open one.
@(private = "file")
theme_populate :: proc(editor: ^Theme_Editor) {
    theme_editor_clear(editor)
    theme_editor_begin_group(editor, "theme.generate", "Generate From Colors", collapsed = true)
    theme_editor_add_action(editor, "generate", "Save Generated Theme", "Name it...")
    theme_editor_end_group(editor)
    theme_editor_begin_group(editor, "theme.surfaces", "Surfaces")
    theme_editor_add_color(editor, "Background", "Background", "#1A1C23", rl.Color {0x1A, 0x1C, 0x23, 0xFF})
    theme_editor_add_color(editor, "Tree", "Tree", "#3F4A5A50", rl.Color {0x3F, 0x4A, 0x5A, 0x50})
    theme_editor_end_group(editor)
}

@(private = "file")
theme_click :: proc(editor: ^Theme_Editor, ctx: ^ui.Context, point: rl.Vector2) {
    event := ui.Event {kind = .Mouse_Down, mouse_position = point}
    theme_editor_handle_event(&editor.widget, ctx, &event)
}

@(private = "file")
theme_center :: proc(rect: rl.Rectangle) -> rl.Vector2 {
    return rl.Vector2 {rect.x + rect.width * 0.5, rect.y + rect.height * 0.5}
}

@(test)
test_theme_editor_rows_reach_the_host :: proc(t: ^testing.T) {
    editor := theme_editor_create("theme-editor")
    defer theme_editor_destroy(&editor.widget)

    ctx: ui.Context
    record: Theme_Record
    theme_editor_set_callbacks(editor, theme_on_color, theme_on_action, &record)
    theme_populate(editor)
    theme_editor_open(editor, &ctx)
    theme_editor_layout(&editor.widget, THEME_TEST_BOUNDS)

    // The folded group hides its action row: two headers and two colors.
    testing.expectf(t, len(editor.visible_rows) == 4, "folded: expected 4 rows, got %d", len(editor.visible_rows))

    theme_click(editor, &ctx, theme_center(theme_editor_row_rect(editor, 2)))
    testing.expect(t, record.colors == 1 && record.id == "Background", "a color row reports its key")

    // Unfold the generator, and its action row reports its name.
    theme_click(editor, &ctx, theme_center(theme_editor_row_rect(editor, 0)))
    theme_editor_layout(&editor.widget, THEME_TEST_BOUNDS)
    testing.expectf(t, len(editor.visible_rows) == 5, "unfolded: expected 5 rows, got %d", len(editor.visible_rows))

    theme_click(editor, &ctx, theme_center(theme_editor_row_rect(editor, 1)))
    testing.expect(t, record.actions == 1 && record.id == "generate", "an action row reports its name")
}

// A repopulate after a committed color keeps the groups the user folded folded.
@(test)
test_theme_editor_repopulate_keeps_folds :: proc(t: ^testing.T) {
    editor := theme_editor_create("theme-editor")
    defer theme_editor_destroy(&editor.widget)

    ctx: ui.Context
    theme_populate(editor)
    theme_editor_open(editor, &ctx)
    theme_editor_layout(&editor.widget, THEME_TEST_BOUNDS)

    // Fold the Surfaces group, then rebuild every row.
    theme_click(editor, &ctx, theme_center(theme_editor_row_rect(editor, 1)))
    theme_editor_layout(&editor.widget, THEME_TEST_BOUNDS)
    testing.expectf(t, len(editor.visible_rows) == 2, "expected both groups folded, got %d", len(editor.visible_rows))

    theme_populate(editor)
    theme_editor_layout(&editor.widget, THEME_TEST_BOUNDS)
    testing.expectf(t, len(editor.visible_rows) == 2, "a repopulate unfolded a group, %d rows", len(editor.visible_rows))
}

@(test)
test_theme_editor_closes :: proc(t: ^testing.T) {
    editor := theme_editor_create("theme-editor")
    defer theme_editor_destroy(&editor.widget)

    ctx: ui.Context
    theme_populate(editor)
    theme_editor_open(editor, &ctx)
    theme_editor_layout(&editor.widget, THEME_TEST_BOUNDS)

    theme_click(editor, &ctx, theme_center(theme_editor_close_rect(editor)))
    testing.expect(t, !theme_editor_is_open(editor), "the close box closes the window")

    theme_editor_open(editor, &ctx)
    theme_editor_layout(&editor.widget, THEME_TEST_BOUNDS)
    theme_click(editor, &ctx, rl.Vector2 {editor.box.x - 20, editor.box.y - 20})
    testing.expect(t, !theme_editor_is_open(editor), "a click outside closes the window")

    theme_editor_open(editor, &ctx)
    theme_editor_layout(&editor.widget, THEME_TEST_BOUNDS)
    escape := ui.Event {kind = .Key_Press, key = .ESCAPE}
    theme_editor_handle_event(&editor.widget, &ctx, &escape)
    testing.expect(t, !theme_editor_is_open(editor), "escape closes the window")
}
