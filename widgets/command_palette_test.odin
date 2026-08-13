package widgets

import "core:testing"
import rl "vendor:raylib"

import "../ui"

@(private = "file")
type_rune :: proc(palette: ^Command_Palette, ctx: ^ui.Context, r: rune) {
    event := ui.Event {kind = .Text_Input, codepoint = r}
    command_palette_handle_event(&palette.widget, ctx, &event)
}

@(private = "file")
press :: proc(palette: ^Command_Palette, ctx: ^ui.Context, key: rl.KeyboardKey) {
    event := ui.Event {kind = .Key_Press, key = key}
    command_palette_handle_event(&palette.widget, ctx, &event)
}

// A prompt (rename) starts with the caret after the prefilled name, and the
// arrows and Home/End move it; text goes in where the caret is.
@(test)
test_prompt_caret :: proc(t: ^testing.T) {
    palette := command_palette_create("palette")
    defer command_palette_destroy(&palette.widget)

    ctx: ui.Context
    command_palette_prompt(palette, &ctx, "Rename symbol", nil, nil, "name")
    testing.expectf(t, palette.caret == 4, "expected the caret after the prefill, got %d", palette.caret)

    press(palette, &ctx, .LEFT)
    press(palette, &ctx, .LEFT)
    type_rune(palette, &ctx, 'X')
    testing.expectf(t, string(palette.query[:]) == "naXme", "expected \"naXme\", got %q", string(palette.query[:]))

    // Home, then Delete takes the first rune; End, then Backspace the last.
    press(palette, &ctx, .HOME)
    press(palette, &ctx, .DELETE)
    press(palette, &ctx, .END)
    press(palette, &ctx, .BACKSPACE)
    testing.expectf(t, string(palette.query[:]) == "aXm", "expected \"aXm\", got %q", string(palette.query[:]))
    testing.expectf(t, palette.caret == 3, "expected the caret at the end, got %d", palette.caret)
}

// An empty rich pick that landed under a hint (a server that needs a typed
// query) shows it instead of a bare blank list, and a later set of real rows
// clears it so it never lingers over them.
@(test)
test_pick_rich_hint :: proc(t: ^testing.T) {
    palette := command_palette_create("palette")
    defer command_palette_destroy(&palette.widget)

    ctx: ui.Context
    command_palette_pick_rich_loading(palette, &ctx, "Workspace symbols", nil, nil)
    testing.expect(t, command_palette_pick_loading(palette))

    command_palette_pick_rich_set(palette, {}, "Type to search workspace symbols…")
    testing.expect(t, !command_palette_pick_loading(palette))
    testing.expectf(t, palette.pick_hint != "", "expected a hint, got none")
    testing.expect(t, len(palette.pick_items) == 0)

    command_palette_set_loading(palette)
    command_palette_pick_rich_set(palette, {{text = "add", name_len = 3}})
    testing.expectf(t, palette.pick_hint == "", "expected the hint cleared once real rows landed, got %q", palette.pick_hint)
    testing.expect(t, len(palette.pick_items) == 1)
}

@(private = "file")
count_query_changed :: proc(data: rawptr, query: string) {
    seen := cast(^int) data
    seen^ += 1
}

// The query hook of a picker that re-dispatches (workspace symbols) belongs to
// that picker alone: the next one opened must not inherit it.
@(test)
test_query_hook_does_not_outlive_its_picker :: proc(t: ^testing.T) {
    palette := command_palette_create("palette")
    defer command_palette_destroy(&palette.widget)

    ctx: ui.Context
    seen: int
    command_palette_pick_rich_loading(palette, &ctx, "Workspace symbols", nil, nil, count_query_changed, &seen)
    type_rune(palette, &ctx, 'a')
    testing.expect_value(t, seen, 1)

    command_palette_pick(palette, &ctx, "Run task", {"build"}, nil, nil)
    type_rune(palette, &ctx, 'b')
    testing.expectf(t, seen == 1, "the stale hook fired from the next picker, %d calls", seen)
}

// Backspace at the start of the input is a no-op, not a wrap to the end.
@(test)
test_prompt_backspace_at_start :: proc(t: ^testing.T) {
    palette := command_palette_create("palette")
    defer command_palette_destroy(&palette.widget)

    ctx: ui.Context
    command_palette_prompt(palette, &ctx, "Rename symbol", nil, nil, "name")

    press(palette, &ctx, .HOME)
    press(palette, &ctx, .BACKSPACE)
    testing.expectf(t, string(palette.query[:]) == "name", "expected \"name\", got %q", string(palette.query[:]))
    testing.expectf(t, palette.caret == 0, "expected the caret at the start, got %d", palette.caret)
}
