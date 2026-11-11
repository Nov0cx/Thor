package textedit

import "core:testing"

@(test)
test_undo_tree_keeps_branch :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    insert_text(&state, "aa")
    insert_text(&state, "bb")
    bb    := history_current(&state)
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

    for undo_later(&state) {}
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

@(test)
test_undo_node_line :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)
    set_text(&state, "a\nb\nc\n")

    set_single_cursor(&state, 4)
    insert_text(&state, "x")
    insert_text(&state, "y")
    testing.expect_value(t, history_node(&state, history_current(&state)).line, 2)

    set_single_cursor(&state, 0)
    insert_text(&state, "z\n")
    testing.expect_value(t, history_node(&state, history_current(&state)).line, 1)
}

@(test)
test_undo_node_hunks :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)
    set_text(&state, "one two three")

    // A replace is one hunk.
    select_range(&state, 4, 7)
    insert_text(&state, "2")
    hunks := node_hunks(history_node(&state, history_current(&state)), context.temp_allocator)
    testing.expect_value(t, len(hunks), 1)
    testing.expect_value(t, hunks[0], Node_Hunk{pos = 4, inserted = 1, removed = "two"})

    // Two cursors: each hunk at its place in the final text.
    set_cursors(&state, {Cursor{caret = 0, anchor = 0}, Cursor{caret = 6, anchor = 6}})
    insert_text(&state, "ab")
    testing.expect_value(t, text(&state), "abone 2 abthree")
    hunks = node_hunks(history_node(&state, history_current(&state)), context.temp_allocator)
    testing.expect_value(t, len(hunks), 2)
    testing.expect_value(t, hunks[0], Node_Hunk{pos = 0, inserted = 2})
    testing.expect_value(t, hunks[1], Node_Hunk{pos = 8, inserted = 2})
}

@(test)
test_undo_node_hunks_delete_before_insert :: proc(t: ^testing.T) {
    node: Undo_Node
    append(&node.ops, Edit_Op{kind = .Insert, pos = 6, text = "xy"})
    append(&node.ops, Edit_Op{kind = .Delete, pos = 1, text = "abc"})
    defer delete(node.ops)
    hunks := node_hunks(&node, context.temp_allocator)
    testing.expect_value(t, len(hunks), 2)
    testing.expect_value(t, hunks[0], Node_Hunk{pos = 3, inserted = 2})
    testing.expect_value(t, hunks[1], Node_Hunk{pos = 1, removed = "abc"})
}

@(test)
test_undo_node_content_id :: proc(t: ^testing.T) {
    state: State
    init(&state)
    defer destroy(&state)

    opened := content_id(&state)
    insert_text(&state, "aa")
    aa := content_id(&state)
    testing.expect_value(t, node_content_id(&state, history_root(&state)), opened)
    testing.expect_value(t, node_content_id(&state, history_current(&state)), aa)
    testing.expect_value(t, node_content_id(&state, 99), 0)
}
