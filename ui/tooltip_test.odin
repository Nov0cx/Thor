package ui

import "core:testing"
import rl "vendor:raylib"

// A request held steady, as one frame of tooltip_frame would hand it over.
@(private = "file")
request :: proc(state: ^Tooltip_State, text: string, anchor: rl.Rectangle, hint := "") {
    state.text = text
    state.hint = hint
    state.anchor = anchor
    state.requested = true
}

@(private = "file")
ANCHOR :: rl.Rectangle {10, 20, 60, 24}

// The dwell: nothing shows before TOOLTIP_DELAY, and the box stays up once the
// same request has waited it out.
@(test)
test_tooltip_dwell :: proc(t: ^testing.T) {
    state: Tooltip_State
    tooltip_init(&state)
    defer tooltip_destroy(&state)

    request(&state, "Toggle Explorer", ANCHOR)
    testing.expect(t, !tooltip_step(&state, 0, false, false), "shown on the first frame")

    request(&state, "Toggle Explorer", ANCHOR)
    testing.expect(t, !tooltip_step(&state, TOOLTIP_DELAY - 0.01, false, false), "shown before the delay")

    request(&state, "Toggle Explorer", ANCHOR)
    testing.expect(t, tooltip_step(&state, TOOLTIP_DELAY, false, false), "not shown after the delay")
    testing.expect_value(t, tooltip_held_text(&state), "Toggle Explorer")

    // Once up, movement inside the same anchor must not take it back down.
    request(&state, "Toggle Explorer", ANCHOR)
    testing.expect(t, tooltip_step(&state, TOOLTIP_DELAY + 0.5, true, false), "movement hid a shown tooltip")
}

// Movement before the delay restarts it, so a cursor crossing a row of buttons
// flashes no tooltip on the ones it passes over.
@(test)
test_tooltip_movement_restarts_dwell :: proc(t: ^testing.T) {
    state: Tooltip_State
    tooltip_init(&state)
    defer tooltip_destroy(&state)

    request(&state, "Run Task", ANCHOR)
    tooltip_step(&state, 0, false, false)

    request(&state, "Run Task", ANCHOR)
    testing.expect(t, !tooltip_step(&state, TOOLTIP_DELAY - 0.05, true, false), "shown while still moving")

    // The clock restarted at that move, so the original delay is not enough.
    request(&state, "Run Task", ANCHOR)
    testing.expect(t, !tooltip_step(&state, TOOLTIP_DELAY, false, false), "the move did not restart the dwell")

    request(&state, "Run Task", ANCHOR)
    testing.expect(t, tooltip_step(&state, TOOLTIP_DELAY * 2, false, false), "never shown after the restart")
}

// A different text, hint or anchor is a different tooltip and starts over.
@(test)
test_tooltip_new_request_restarts_dwell :: proc(t: ^testing.T) {
    other := rl.Rectangle {200, 20, 60, 24}

    for step in 0 ..< 3 {
        state: Tooltip_State
        tooltip_init(&state)
        defer tooltip_destroy(&state)

        request(&state, "Close Tab", ANCHOR, "ctrl + w")
        tooltip_step(&state, 0, false, false)
        request(&state, "Close Tab", ANCHOR, "ctrl + w")
        testing.expect(t, tooltip_step(&state, TOOLTIP_DELAY, false, false), "first tooltip never showed")

        switch step {
        case 0:
            request(&state, "Close All Tabs", ANCHOR, "ctrl + w")
        case 1:
            request(&state, "Close Tab", ANCHOR, "ctrl + shift + w")
        case 2:
            request(&state, "Close Tab", other, "ctrl + w")
        }
        testing.expect(t, !tooltip_step(&state, TOOLTIP_DELAY, false, false), "a new request kept the old dwell")
    }
}

// No request, or a suppressed frame (a held button, no hovered widget), drops
// the tooltip at once instead of leaving it over the cursor.
@(test)
test_tooltip_suppressed :: proc(t: ^testing.T) {
    state: Tooltip_State
    tooltip_init(&state)
    defer tooltip_destroy(&state)

    request(&state, "Save", ANCHOR)
    tooltip_step(&state, 0, false, false)
    request(&state, "Save", ANCHOR)
    testing.expect(t, tooltip_step(&state, TOOLTIP_DELAY, false, false), "never shown")

    request(&state, "Save", ANCHOR)
    testing.expect(t, !tooltip_step(&state, TOOLTIP_DELAY + 0.1, false, true), "survived suppression")
    testing.expect_value(t, tooltip_held_text(&state), "")

    // A frame with no request at all does the same.
    request(&state, "Save", ANCHOR)
    tooltip_step(&state, 0, false, false)
    request(&state, "Save", ANCHOR)
    testing.expect(t, tooltip_step(&state, TOOLTIP_DELAY, false, false), "never shown again")
    state.requested = false
    testing.expect(t, !tooltip_step(&state, TOOLTIP_DELAY + 0.1, false, false), "survived an empty frame")
}

// Placement: under the anchor by default, over it when the space below is too
// small, and never outside the screen.
@(test)
test_tooltip_place :: proc(t: ^testing.T) {
    screen := rl.Vector2 {800, 600}
    size := rl.Vector2 {120, 40}

    below := tooltip_place(rl.Rectangle {100, 100, 60, 24}, size, screen)
    testing.expect_value(t, below, rl.Vector2 {100, 100 + 24 + TOOLTIP_GAP})

    above := tooltip_place(rl.Rectangle {100, 560, 60, 24}, size, screen)
    testing.expect_value(t, above, rl.Vector2 {100, 560 - TOOLTIP_GAP - 40})

    // A control at the right edge pulls the box back inside.
    right := tooltip_place(rl.Rectangle {780, 100, 20, 24}, size, screen)
    testing.expect_value(t, right.x, screen.x - size.x - TOOLTIP_MARGIN)

    left := tooltip_place(rl.Rectangle {-30, 100, 20, 24}, size, screen)
    testing.expect_value(t, left.x, TOOLTIP_MARGIN)

    // Too tall for either side: clamped, never pushed off the top.
    tall := tooltip_place(rl.Rectangle {100, 300, 60, 24}, rl.Vector2 {120, 590}, screen)
    testing.expect(t, tall.y >= TOOLTIP_MARGIN, "a tall box was pushed off the top")
}
