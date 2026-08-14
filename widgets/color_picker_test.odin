package widgets

import "core:testing"
import rl "vendor:raylib"

import "../ui"

@(private = "file")
Picker_Record :: struct {
    previews: int,
    commits:  int,
    cancels:  int,
    id:       string,
    color:    rl.Color,
}

@(private = "file")
picker_on_preview :: proc(data: rawptr, id: string, color: rl.Color) {
    record := cast(^Picker_Record) data
    record.previews += 1
    record.id = id
    record.color = color
}

@(private = "file")
picker_on_commit :: proc(data: rawptr, id: string, color: rl.Color) {
    record := cast(^Picker_Record) data
    record.commits += 1
    record.id = id
    record.color = color
}

@(private = "file")
picker_on_cancel :: proc(data: rawptr, id: string) {
    record := cast(^Picker_Record) data
    record.cancels += 1
    record.id = id
}

@(private = "file")
PICKER_TEST_BOUNDS :: rl.Rectangle {0, 0, 1280, 800}

// A picker laid out over the test screen, opened on `color`.
@(private = "file")
picker_open :: proc(ctx: ^ui.Context, record: ^Picker_Record, color: rl.Color) -> ^Color_Picker {
    picker := color_picker_create("color-picker")
    color_picker_open(
        picker, ctx, "Background", "theme_color:Background", color,
        picker_on_preview, picker_on_commit, picker_on_cancel, record,
    )
    color_picker_layout(&picker.widget, PICKER_TEST_BOUNDS)
    return picker
}

@(private = "file")
picker_send :: proc(picker: ^Color_Picker, ctx: ^ui.Context, kind: ui.Event_Type, point: rl.Vector2) {
    event := ui.Event {kind = kind, mouse_position = point}
    color_picker_handle_event(&picker.widget, ctx, &event)
}

@(private = "file")
picker_key :: proc(picker: ^Color_Picker, ctx: ^ui.Context, key: rl.KeyboardKey) {
    event := ui.Event {kind = .Key_Press, key = key}
    color_picker_handle_event(&picker.widget, ctx, &event)
}

@(private = "file")
picker_type :: proc(picker: ^Color_Picker, ctx: ^ui.Context, text: string) {
    for c in text {
        event := ui.Event {kind = .Text_Input, codepoint = c}
        color_picker_handle_event(&picker.widget, ctx, &event)
    }
}

@(private = "file")
picker_center :: proc(rect: rl.Rectangle) -> rl.Vector2 {
    return rl.Vector2 {rect.x + rect.width * 0.5, rect.y + rect.height * 0.5}
}

// The load-bearing one: RGB has no hue at saturation 0, so a drag to the left edge
// of the square and back has to come back the red it started as.
@(test)
test_color_picker_hue_survives_zero_saturation :: proc(t: ^testing.T) {
    ctx: ui.Context
    record: Picker_Record
    picker := picker_open(&ctx, &record, rl.Color {0xFF, 0x00, 0x00, 0xFF})
    defer color_picker_destroy(&picker.widget)

    square := color_picker_square_rect(picker)
    picker_send(picker, &ctx, .Mouse_Down, rl.Vector2 {square.x + 1, square.y + 1})
    testing.expect(t, picker.sat < 0.05, "the drag reached the grey edge")

    picker_send(picker, &ctx, .Mouse_Move, rl.Vector2 {square.x + square.width - 1, square.y + 1})
    picker_send(picker, &ctx, .Mouse_Up, rl.Vector2 {square.x + square.width - 1, square.y + 1})

    color := color_picker_color(picker)
    testing.expectf(t, color.r > 0xF0 && color.g < 0x10 && color.b < 0x10, "the hue came back, got %v", color)
}

// The framework routes a move to the widget the press landed on, so a drag that
// leaves the strip still moves the hue.
@(test)
test_color_picker_drag_follows_the_press_target :: proc(t: ^testing.T) {
    ctx: ui.Context
    record: Picker_Record
    picker := picker_open(&ctx, &record, rl.Color {0xFF, 0x00, 0x00, 0xFF})
    defer color_picker_destroy(&picker.widget)

    hue := color_picker_hue_rect(picker)
    picker_send(picker, &ctx, .Mouse_Down, rl.Vector2 {hue.x + 1, picker_center(hue).y})
    before := picker.hue

    // Well below the strip, and past its right edge.
    picker_send(picker, &ctx, .Mouse_Move, rl.Vector2 {hue.x + hue.width * 0.75, hue.y + 300})
    testing.expectf(t, picker.hue > before, "the hue followed the cursor, %v to %v", before, picker.hue)
    testing.expect(t, record.previews >= 2, "each drag frame previewed")
    testing.expect(t, record.id == "theme_color:Background", "the row id rides along")
}

@(test)
test_color_picker_alpha_drag :: proc(t: ^testing.T) {
    ctx: ui.Context
    record: Picker_Record
    picker := picker_open(&ctx, &record, rl.Color {0x40, 0x80, 0xC0, 0xFF})
    defer color_picker_destroy(&picker.widget)

    alpha := color_picker_alpha_rect(picker)
    picker_send(picker, &ctx, .Mouse_Down, rl.Vector2 {alpha.x + 1, picker_center(alpha).y})
    testing.expect(t, color_picker_color(picker).a < 8, "the left edge is transparent")

    picker_send(picker, &ctx, .Mouse_Move, rl.Vector2 {alpha.x + alpha.width - 1, picker_center(alpha).y})
    testing.expect(t, color_picker_color(picker).a > 0xF0, "the right edge is opaque")
}

@(test)
test_color_picker_cancel_restores :: proc(t: ^testing.T) {
    ctx: ui.Context
    record: Picker_Record
    picker := picker_open(&ctx, &record, rl.Color {0xFF, 0x00, 0x00, 0xFF})
    defer color_picker_destroy(&picker.widget)

    picker_key(picker, &ctx, .ESCAPE)
    testing.expect(t, record.cancels == 1 && record.commits == 0, "escape cancels")
    testing.expect(t, !color_picker_is_open(picker), "escape closes")

    picker2 := picker_open(&ctx, &record, rl.Color {0xFF, 0x00, 0x00, 0xFF})
    defer color_picker_destroy(&picker2.widget)
    picker_send(picker2, &ctx, .Mouse_Down, rl.Vector2 {2, 2})
    testing.expect(t, record.cancels == 2 && record.commits == 0, "a click outside the box cancels")

    picker3 := picker_open(&ctx, &record, rl.Color {0xFF, 0x00, 0x00, 0xFF})
    defer color_picker_destroy(&picker3.widget)
    picker_send(picker3, &ctx, .Mouse_Down, picker_center(color_picker_cancel_rect(picker3)))
    testing.expect(t, record.cancels == 3 && record.commits == 0, "the Cancel button cancels")
}

@(test)
test_color_picker_confirm_reports_the_dragged_color :: proc(t: ^testing.T) {
    ctx: ui.Context
    record: Picker_Record
    picker := picker_open(&ctx, &record, rl.Color {0xFF, 0x00, 0x00, 0xFF})
    defer color_picker_destroy(&picker.widget)

    hue := color_picker_hue_rect(picker)
    picker_send(picker, &ctx, .Mouse_Down, rl.Vector2 {hue.x + hue.width * 0.5, picker_center(hue).y})
    picker_send(picker, &ctx, .Mouse_Up, rl.Vector2 {hue.x + hue.width * 0.5, picker_center(hue).y})
    dragged := color_picker_color(picker)

    picker_send(picker, &ctx, .Mouse_Down, picker_center(color_picker_ok_rect(picker)))
    testing.expect(t, record.commits == 1 && record.cancels == 0, "OK commits")
    testing.expect(t, record.color == dragged, "the committed color is the one on screen")
    testing.expect(t, !color_picker_is_open(picker), "OK closes")
}

@(test)
test_color_picker_hex_field :: proc(t: ^testing.T) {
    ctx: ui.Context
    record: Picker_Record
    picker := picker_open(&ctx, &record, rl.Color {0x40, 0x80, 0xC0, 0xFF})
    defer color_picker_destroy(&picker.widget)

    picker_send(picker, &ctx, .Mouse_Down, picker_center(color_picker_hex_rect(picker)))
    for _ in 0 ..< 9 {
        picker_key(picker, &ctx, .BACKSPACE)
    }
    picker_type(picker, &ctx, "#FF0000")
    picker_key(picker, &ctx, .ENTER)

    color := color_picker_color(picker)
    testing.expectf(t, color == rl.Color {0xFF, 0x00, 0x00, 0xFF}, "a typed hex takes, got %v", color)
    testing.expect(t, color_picker_is_open(picker), "committing a hex does not close the picker")

    // A half-typed value leaves the color alone.
    picker_send(picker, &ctx, .Mouse_Down, picker_center(color_picker_hex_rect(picker)))
    for _ in 0 ..< 9 {
        picker_key(picker, &ctx, .BACKSPACE)
    }
    picker_type(picker, &ctx, "#FF00")
    picker_key(picker, &ctx, .ENTER)
    testing.expect(t, color_picker_color(picker) == color, "a malformed hex changes nothing")
}
