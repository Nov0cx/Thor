package textedit

import "core:testing"

@(test)
test_undo_tree_keeps_branch :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "aa")
    insert_text(&state, "bb")
    bb := history_current(&state)
    bb_id := content_id(&state)
    undo(&state)
    insert_text(&state, "cc")
    testing.expect_value(t, text(&state), "aacc")

    undo(&state)
    redo(&state)
    testing.expect_value(t, text(&state), "aacc")

    testing.expect(t, undo_goto(&state, bb))
    testing.expect_value(t, text(&state), "aabb")
    testing.expect_value(t, content_id(&state), bb_id)
    testing.expect_value(t, primary_cursor(&state).caret, 4)
    testing.expect_value(t, undo_depth(&state), 2)

    // Redo follows the branch the last move came down.
    undo(&state)
    redo(&state)
    testing.expect_value(t, text(&state), "aabb")
}

@(test)
test_undo_earlier_later :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "aa")
    insert_text(&state, "bb")
    undo(&state)
    insert_text(&state, "cc")

    want_earlier := []string{"aabb", "aa", ""}
    for want in want_earlier {
        testing.expect(t, undo_earlier(&state))
        testing.expect_value(t, text(&state), want)
    }
    testing.expect(t, !undo_earlier(&state))

    want_later := []string{"aa", "aabb", "aacc"}
    for want in want_later {
        testing.expect(t, undo_later(&state))
        testing.expect_value(t, text(&state), want)
    }
    testing.expect(t, !undo_later(&state))
}

@(test)
test_undo_goto_change_log :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "aa")
    insert_text(&state, "cc")
    cc := history_current(&state)
    undo(&state)
    insert_text(&state, "bb")
    revision := state.revision

    testing.expect(t, undo_goto(&state, cc))
    change, ok := changes_since(&state, revision)
    testing.expect(t, ok)
    testing.expect_value(t, change.lo, 2)
    testing.expect_value(t, change.old_hi, 4)
    testing.expect_value(t, change.new_hi, 4)
}

// A node with a branch below it never grows by coalescing.
@(test)
test_undo_no_coalesce_into_branched_node :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "x")
    insert_text(&state, "zz")
    undo(&state)
    state.coalescing = true
    insert_text(&state, "y")
    testing.expect_value(t, text(&state), "xy")
    testing.expect_value(t, undo_depth(&state), 2)
    undo(&state)
    testing.expect_value(t, text(&state), "x")
}

@(test)
test_undo_join_last :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "aa")
    insert_text(&state, "bb")
    insert_text(&state, "cc")
    join_last_undo(&state)
    testing.expect_value(t, undo_depth(&state), 2)
    testing.expect_value(t, state.history.count, 2)
    undo(&state)
    testing.expect_value(t, text(&state), "aa")
    redo(&state)
    testing.expect_value(t, text(&state), "aabbcc")
}

// The trim drops a branch off the current path before it folds the root.
@(test)
test_undo_trim_drops_branch_first :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "aa")
    insert_text(&state, "bb")
    bb := history_current(&state)
    undo(&state)
    insert_text(&state, "cc")
    for i := 0; i < MAX_UNDO_ENTRIES - 2; i += 1 {
        insert_text(&state, "dd")
    }
    testing.expect(t, history_node(&state, bb) == nil)
    testing.expect_value(t, state.history.count, MAX_UNDO_ENTRIES)
    testing.expect_value(t, undo_depth(&state), MAX_UNDO_ENTRIES)
    for can_undo(&state) {
        undo(&state)
    }
    testing.expect_value(t, text(&state), "")

    for undo_later(&state) {
    }
    insert_text(&state, "ee")
    testing.expect_value(t, state.history.count, MAX_UNDO_ENTRIES)
    for can_undo(&state) {
        undo(&state)
    }
    // The root folded forward past "aa".
    testing.expect_value(t, text(&state), "aa")
}

@(test)
test_undo_set_text_clears_tree :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "aa")
    insert_text(&state, "bb")
    undo(&state)
    set_text(&state, "new")
    testing.expect(t, !can_undo(&state))
    testing.expect(t, !can_redo(&state))
    testing.expect_value(t, history_current(&state), NO_NODE)
    testing.expect_value(t, state.undo_bytes, 0)
}
