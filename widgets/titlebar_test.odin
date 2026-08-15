package widgets

import "core:c"
import "core:testing"
import rl "vendor:raylib"

// The cursor as raylib reports it: relative to the window of this frame.
@(private = "file")
client_pos :: proc(screen_cursor, window_pos: rl.Vector2) -> rl.Vector2 {
    return rl.Vector2 {screen_cursor[0] - window_pos[0], screen_cursor[1] - window_pos[1]}
}

// The anchored drag puts the grabbed point under the cursor every frame, so the
// window position is a function of the cursor alone and cannot drift.
@(test)
test_titlebar_drag_tracks_cursor :: proc(t: ^testing.T) {
    grab := rl.Vector2 {120, 14}
    window := rl.Vector2 {300, 200}
    cursor := rl.Vector2 {420, 214}

    for _ in 0 ..< 32 {
        cursor += rl.Vector2 {7, 3}
        target := titlebar_drag_position(window, client_pos(cursor, window), grab)
        window = rl.Vector2 {cast(f32) target[0], cast(f32) target[1]}
        testing.expect_value(t, window, rl.Vector2 {cursor[0] - grab[0], cursor[1] - grab[1]})
    }
}

// A cursor that stands still asks for no move, whatever the frame rate.
@(test)
test_titlebar_drag_still_cursor_does_not_move :: proc(t: ^testing.T) {
    grab := rl.Vector2 {40, 10}
    window := rl.Vector2 {512, 64}
    cursor := rl.Vector2 {552, 74}

    for _ in 0 ..< 8 {
        target := titlebar_drag_position(window, client_pos(cursor, window), grab)
        testing.expect_value(t, target, [2]c.int {512, 64})
    }
}

// The old drag added the frame's client-relative delta to the window position.
// X11 sends no motion event when the window itself moves, so the move applied
// last frame is subtracted from this frame's delta: at a constant cursor speed
// the window advances 10, 0, 10, 0 and falls ever further behind the cursor.
@(test)
test_titlebar_delta_drag_oscillates :: proc(t: ^testing.T) {
    window := rl.Vector2 {300, 200}
    cursor := rl.Vector2 {420, 214}
    prev := client_pos(cursor, window)

    steps: [4]f32
    for i in 0 ..< 4 {
        cursor += rl.Vector2 {10, 0}
        client := client_pos(cursor, window)
        steps[i] = client[0] - prev[0]
        prev = client
        window[0] += steps[i]
    }

    testing.expect_value(t, steps, [4]f32 {10, 0, 10, 0})
    // 40 px of cursor travel, 20 px of window travel.
    testing.expect_value(t, window[0], 320)
}

// Sub-pixel offsets round to the nearest pixel instead of truncating, so a slow
// drag cannot lose a fraction of a pixel per frame.
@(test)
test_titlebar_drag_rounds :: proc(t: ^testing.T) {
    target := titlebar_drag_position(rl.Vector2 {100, 100}, rl.Vector2 {10.6, 10.4}, rl.Vector2 {10, 10})
    testing.expect_value(t, target, [2]c.int {101, 100})

    target = titlebar_drag_position(rl.Vector2 {-100, -100}, rl.Vector2 {10, 10}, rl.Vector2 {10.6, 10.4})
    testing.expect_value(t, target, [2]c.int {-101, -100})
}
