package thor

import "core:testing"

// Run from the repository root: odin test thor

// The pick moves on once a day and stands still inside one, so every start of
// the same day shows the same tip.
@(test)
test_tip_index_moves_once_a_day :: proc(t: ^testing.T) {
    COUNT :: 5

    same, moved := thor_tip_index_for_day(20_000, 20_000, 2, COUNT)
    testing.expect_value(t, same, 2)
    testing.expect(t, !moved, "the same day rewrote the record")

    next, next_moved := thor_tip_index_for_day(20_000, 20_001, 2, COUNT)
    testing.expect_value(t, next, 3)
    testing.expect(t, next_moved, "a new day did not move the pick on")

    // A clock that moved backwards is another day, not a reason to stand still.
    back, back_moved := thor_tip_index_for_day(20_000, 19_999, 2, COUNT)
    testing.expect_value(t, back, 3)
    testing.expect(t, back_moved, "a backwards clock parked the pick")

    // The last tip of the list wraps to the first.
    wrapped, _ := thor_tip_index_for_day(20_000, 20_001, COUNT - 1, COUNT)
    testing.expect_value(t, wrapped, 0)
}

// The floating card opens once for each day, whichever way the clock moved.
@(test)
test_tip_popup_due_once_a_day :: proc(t: ^testing.T) {
    testing.expect(t, !thor_tip_popup_due(20_000, 20_000), "a second start of the day opened the card")
    testing.expect(t, thor_tip_popup_due(20_000, 20_001), "a new day did not open the card")
    testing.expect(t, thor_tip_popup_due(20_000, 19_999), "a backwards clock kept the card shut")
    // No record: the first start ever opens it.
    testing.expect(t, thor_tip_popup_due(0, 20_000), "the first start did not open the card")
}

// The arrows step both ways and wrap at both ends, and a record left by a
// longer tip list still lands inside the shorter one.
@(test)
test_tip_index_wraps :: proc(t: ^testing.T) {
    testing.expect_value(t, thor_wrap_tip(0, 5), 0)
    testing.expect_value(t, thor_wrap_tip(4, 5), 4)
    testing.expect_value(t, thor_wrap_tip(5, 5), 0)
    testing.expect_value(t, thor_wrap_tip(-1, 5), 4)
    testing.expect_value(t, thor_wrap_tip(-6, 5), 4)
    // A tips.json that shrank leaves an index past the end.
    testing.expect_value(t, thor_wrap_tip(11, 5), 1)
    // No tips at all: the caller hides the card, but the index must stay sane.
    testing.expect_value(t, thor_wrap_tip(3, 0), 0)
}
