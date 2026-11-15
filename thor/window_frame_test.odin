package thor

import "core:testing"

@(test)
test_window_resize_rect_moves_only_grabbed_edges :: proc(t: ^testing.T) {
    start    := [4]f32{100, 100, 800, 600}
    min_size := [2]f32{480, 320}

    testing.expect_value(t, window_resize_rect(start, {50, 40}, {.Right, .Bottom}, min_size), [4]f32{100, 100, 850, 640})
    testing.expect_value(t, window_resize_rect(start, {-30, -20}, {.Left, .Top}, min_size), [4]f32{70, 80, 830, 620})
    testing.expect_value(t, window_resize_rect(start, {10, 999}, {.Left}, min_size), [4]f32{110, 100, 790, 600})
}

@(test)
test_window_resize_rect_holds_the_minimum :: proc(t: ^testing.T) {
    start    := [4]f32{100, 100, 800, 600}
    min_size := [2]f32{480, 320}

    // A left edge pulled past the minimum stops; the right edge does not move.
    testing.expect_value(t, window_resize_rect(start, {700, 0}, {.Left}, min_size), [4]f32{420, 100, 480, 600})
    testing.expect_value(t, window_resize_rect(start, {0, -700}, {.Bottom}, min_size), [4]f32{100, 100, 800, 320})
}
