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
