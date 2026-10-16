package thor

import "core:testing"

// A jump between frames keeps its scroll; a drag or a clamp in Loom wins.
@(test)
test_pane_scroll_adopt :: proc(t: ^testing.T) {
    // Jump: Loom still holds what the pane pushed, the editor moved.
    testing.expect_value(t, thor_pane_scroll_adopt(0, 0, 480), 480)
    // Drag: Loom moved since the push.
    testing.expect_value(t, thor_pane_scroll_adopt(200, 120, 120), 200)
    // Clamp: content shrank under the pushed value.
    testing.expect_value(t, thor_pane_scroll_adopt(300, 900, 900), 300)
    // Idle.
    testing.expect_value(t, thor_pane_scroll_adopt(64, 64, 64), 64)
}
