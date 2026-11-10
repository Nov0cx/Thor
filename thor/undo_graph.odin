package thor

import "../textedit"

// Lanes the undo graph draws. A branch past the last one shares the last lane.
UNDO_GRAPH_LANES :: 8

Undo_Lane_Set :: bit_set[0 ..< UNDO_GRAPH_LANES]

// One row of the undo graph: a node and the lines drawn beside it.
Undo_Graph_Row :: struct {
    node:    int,
    lane:    int,
    // The node's lane has a line above it (a newer child) and below it (its parent).
    top:     bool,
    bottom:  bool,
    // Lanes whose line passes the row.
    through: Undo_Lane_Set,
    // Lanes of other children that end at this node.
    joins:   Undo_Lane_Set,
}

// The live nodes of `state`, newest first, each placed on a lane. A parent is always below its children.
undo_graph_build :: proc(state: ^textedit.State, allocator := context.allocator) -> [dynamic]Undo_Graph_Row {
    rows := make([dynamic]Undo_Graph_Row, allocator)
    for i in 0 ..< len(state.history.nodes) {
        if textedit.history_node(state, i) != nil {
            append(&rows, Undo_Graph_Row{node = i})
        }
    }
    nodes := state.history.nodes[:]
    undo_graph_sort(rows[:], nodes)

    lanes: [UNDO_GRAPH_LANES]int
    for &l in lanes {
        l = textedit.NO_NODE
    }
    for &row in rows {
        waiting: Undo_Lane_Set
        for target, l in lanes {
            if target == row.node {
                waiting += {l}
            }
        }
        row.lane = -1
        for l in 0 ..< UNDO_GRAPH_LANES {
            if l in waiting {
                row.lane = l
                break
            }
        }
        if row.lane >= 0 {
            row.top = true
        } else {
            row.lane = UNDO_GRAPH_LANES - 1
            for target, l in lanes {
                if target == textedit.NO_NODE {
                    row.lane = l
                    break
                }
            }
        }
        row.joins = waiting - {row.lane}
        for l in row.joins {
            lanes[l] = textedit.NO_NODE
        }
        for target, l in lanes {
            if target != textedit.NO_NODE && l != row.lane {
                row.through += {l}
            }
        }
        parent := nodes[row.node].parent
        lanes[row.lane] = parent
        row.bottom = parent != textedit.NO_NODE
    }
    return rows
}

// Sorts the rows newest first by node seq.
@(private = "file")
undo_graph_sort :: proc(rows: []Undo_Graph_Row, nodes: []textedit.Undo_Node) {
    for i in 1 ..< len(rows) {
        j := i
        for j > 0 && nodes[rows[j - 1].node].seq < nodes[rows[j].node].seq {
            rows[j - 1], rows[j] = rows[j], rows[j - 1]
            j -= 1
        }
    }
}
