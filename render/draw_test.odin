package render

import "core:testing"

import rl "vendor:raylib"
import ui "../vendor/loom/loom"

@(test)
test_rrect_path_count_ignores_radius :: proc(t: ^testing.T) {
    b: Backend
    b.opts.arc_segments = DEFAULT_ARC_SEGMENTS
    defer delete(b.path_a)
    defer delete(b.path_b)

    box := rl.Rectangle{0, 0, 40, 20}
    rrect_path(&b, &b.path_a, box, {tl = 1, tr = 1, br = 1, bl = 1})
    // A 1 px border insets the radius to 0; the ring still pairs every point.
    rrect_path(&b, &b.path_b, {1, 1, 38, 18}, {})
    testing.expect_value(t, len(b.path_a), 4 * (DEFAULT_ARC_SEGMENTS + 1))
    testing.expect_value(t, len(b.path_b), len(b.path_a))

    rrect_path(&b, &b.path_b, box, ui.Radius{tl = 6})
    testing.expect_value(t, len(b.path_b), len(b.path_a))
}
