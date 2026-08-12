package ui

import "core:testing"

import rl "vendor:raylib"

@(private = "file")
TEST_STYLE :: Scrollbar_Style {width = 6, min_thumb = 28, inset = 2}

@(private = "file")
TEST_AREA :: rl.Rectangle {10, 20, 200, 100}

// Content that fits shows no bar, so a widget that always draws one would put a
// full-height thumb over a document nobody can scroll.
@(test)
test_scrollbar_hidden_when_content_fits :: proc(t: ^testing.T) {
    _, _, ok := scrollbar_rects(TEST_AREA, 100, 0, TEST_STYLE)
    testing.expect(t, !ok, "content exactly filling the view needs no bar")

    _, _, shorter := scrollbar_rects(TEST_AREA, 40, 0, TEST_STYLE)
    testing.expect(t, !shorter, "content shorter than the view needs no bar")

    // A collapsed pane has no room for a track either.
    empty := rl.Rectangle {10, 20, 200, 0}
    _, _, degenerate := scrollbar_rects(empty, 500, 0, TEST_STYLE)
    testing.expect(t, !degenerate, "a zero-height area has no bar")
}

// The track sits inside the right edge, and the thumb never leaves it.
@(test)
test_scrollbar_track_and_thumb :: proc(t: ^testing.T) {
    // 100 of 200 visible, so half the track -- above min_thumb, which would
    // otherwise hide the proportion.
    track, thumb, ok := scrollbar_rects(TEST_AREA, 200, 0, TEST_STYLE)
    testing.expect(t, ok, "content taller than the view shows a bar")
    testing.expect_value(t, track.x, TEST_AREA.x + TEST_AREA.width - 6 - 2)
    testing.expect_value(t, track.y, TEST_AREA.y)
    testing.expect_value(t, track.width, f32(6))
    testing.expect_value(t, track.height, TEST_AREA.height)

    testing.expect_value(t, thumb.height, f32(50))
    testing.expect_value(t, thumb.x, track.x)
    testing.expect_value(t, thumb.y, track.y)

    // Scrolled to the end the thumb bottom meets the track bottom.
    _, bottom, _ := scrollbar_rects(TEST_AREA, 200, 100, TEST_STYLE)
    testing.expect_value(t, bottom.y + bottom.height, track.y + track.height)

    // Half way down, half the free span.
    _, middle, _ := scrollbar_rects(TEST_AREA, 200, 50, TEST_STYLE)
    testing.expect_value(t, middle.y, track.y + (track.height - thumb.height) * 0.5)
}

// A tall document would give a thumb too small to grab, so it stops at
// min_thumb; a scroll beyond the ends still lands inside the track.
@(test)
test_scrollbar_thumb_floor_and_clamp :: proc(t: ^testing.T) {
    _, thumb, ok := scrollbar_rects(TEST_AREA, 100_000, 0, TEST_STYLE)
    testing.expect(t, ok, "a long document shows a bar")
    testing.expect_value(t, thumb.height, f32(28))

    track, over, _ := scrollbar_rects(TEST_AREA, 400, 10_000, TEST_STYLE)
    testing.expect_value(t, over.y + over.height, track.y + track.height)

    _, under, _ := scrollbar_rects(TEST_AREA, 400, -50, TEST_STYLE)
    testing.expect_value(t, under.y, track.y)
}

// The grab strip is wider than the bar and grows to the left, so it covers the
// thumb it stands for.
@(test)
test_scrollbar_grab_rect :: proc(t: ^testing.T) {
    track, _, _ := scrollbar_rects(TEST_AREA, 400, 0, TEST_STYLE)
    grab := scrollbar_grab_rect(track, 14)
    testing.expect_value(t, grab.width, f32(14))
    testing.expect_value(t, grab.x + grab.width, track.x + track.width)
    testing.expect_value(t, grab.y, track.y)
    testing.expect_value(t, grab.height, track.height)
}

// Dragging the thumb reports the offset it stands for, held at the point inside
// the thumb where it was taken.
@(test)
test_scrollbar_scroll_at_round_trips :: proc(t: ^testing.T) {
    max_scroll: f32 = 300
    track, thumb, _ := scrollbar_rects(TEST_AREA, 400, 0, TEST_STYLE)

    // Taken at its top and dragged to the track top: back to the start.
    testing.expect_value(t, scrollbar_scroll_at(track, thumb, track.y, 0, max_scroll), 0)

    // Dragged past the bottom it stops at the end rather than running on.
    testing.expect_value(
        t, scrollbar_scroll_at(track, thumb, track.y + track.height + 500, 0, max_scroll), max_scroll,
    )

    // Halfway down the free span is halfway through the document.
    span := track.height - thumb.height
    middle := scrollbar_scroll_at(track, thumb, track.y + span * 0.5, 0, max_scroll)
    testing.expect_value(t, middle, max_scroll * 0.5)

    // The offset the drag was taken at is subtracted, so the thumb keeps its grip.
    held := scrollbar_scroll_at(track, thumb, track.y + span * 0.5 + 7, 7, max_scroll)
    testing.expect_value(t, held, middle)

    // A thumb that fills the track cannot move, whatever the cursor does.
    full := rl.Rectangle {0, 0, 6, 100}
    testing.expect_value(t, scrollbar_scroll_at(full, full, 999, 0, 300), 0)
}
