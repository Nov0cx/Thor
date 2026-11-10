package thor

import "core:testing"

import "../textedit"

@(test)
test_undo_graph_linear :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.insert_text(&state, "aa")
    textedit.insert_text(&state, "bb")

    rows := undo_graph_build(&state, context.temp_allocator)
    testing.expect_value(t, len(rows), 3)
    for row in rows {
        testing.expect_value(t, row.lane, 0)
        testing.expect_value(t, row.through, Undo_Lane_Set{})
    }
    testing.expect(t, !rows[0].top && rows[0].bottom)
    testing.expect(t, rows[2].top && !rows[2].bottom)
    testing.expect_value(t, rows[2].node, textedit.history_root(&state))
}

@(test)
test_undo_graph_branch_joins_parent :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.insert_text(&state, "aa")
    textedit.insert_text(&state, "bb")
    textedit.undo(&state)
    textedit.insert_text(&state, "cc")

    rows := undo_graph_build(&state, context.temp_allocator)
    testing.expect_value(t, len(rows), 4)
    // cc, bb, aa, root.
    testing.expect_value(t, rows[0].node, textedit.history_current(&state))
    testing.expect_value(t, rows[0].lane, 0)
    testing.expect_value(t, rows[1].lane, 1)
    testing.expect(t, !rows[1].top)
    testing.expect_value(t, rows[1].through, Undo_Lane_Set{0})
    testing.expect_value(t, rows[2].lane, 0)
    testing.expect_value(t, rows[2].joins, Undo_Lane_Set{1})
    testing.expect_value(t, rows[2].through, Undo_Lane_Set{})
    testing.expect_value(t, rows[3].lane, 0)
}

@(test)
test_undo_graph_three_branches :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    textedit.insert_text(&state, "a")
    textedit.undo(&state)
    textedit.insert_text(&state, "b")
    textedit.undo(&state)
    textedit.insert_text(&state, "c")

    rows := undo_graph_build(&state, context.temp_allocator)
    testing.expect_value(t, len(rows), 4)
    testing.expect_value(t, rows[0].lane, 0)
    testing.expect_value(t, rows[1].lane, 1)
    testing.expect_value(t, rows[2].lane, 2)
    testing.expect_value(t, rows[2].through, Undo_Lane_Set{0, 1})
    testing.expect_value(t, rows[3].lane, 0)
    testing.expect_value(t, rows[3].joins, Undo_Lane_Set{1, 2})
}

@(test)
test_undo_graph_lane_cap :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    for i in 0 ..< UNDO_GRAPH_LANES + 3 {
        textedit.insert_text(&state, "x")
        if i < UNDO_GRAPH_LANES + 2 {
            textedit.undo(&state)
        }
    }

    rows := undo_graph_build(&state, context.temp_allocator)
    testing.expect_value(t, len(rows), UNDO_GRAPH_LANES + 4)
    for row in rows {
        testing.expect(t, row.lane >= 0 && row.lane < UNDO_GRAPH_LANES)
    }
    testing.expect_value(t, rows[len(rows) - 1].lane, 0)
}
