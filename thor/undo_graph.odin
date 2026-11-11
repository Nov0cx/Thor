package thor

import "core:strings"
import "core:time"

import "../textedit"

// Lanes the undo graph draws. A branch past the last one shares the last lane.
UNDO_GRAPH_LANES :: 8

Undo_Lane_Set :: bit_set[0 ..< UNDO_GRAPH_LANES]

// Seconds between two keystroke steps that still join into one row.
UNDO_GROUP_GAP :: 30

// One row of the undo graph: a run of nodes, `first` the oldest and `node` the newest, and the lines drawn beside it.
Undo_Graph_Row :: struct {
    node:    int,
    first:   int,
    count:   int,
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
            append(&rows, Undo_Graph_Row{node = i, first = i, count = 1})
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

// Joins each run of keystroke steps on one line into one row: same kind, one op each,
// each the only child of the one before, adjacent in the buffer and close in time.
// A node in `keep` or with the content id `saved` stays the newest of its row.
undo_graph_group :: proc(state: ^textedit.State, rows: ^[dynamic]Undo_Graph_Row, saved: u64, keep: ..int) {
    nodes := state.history.nodes[:]
    out   := 0
    for i := 0; i < len(rows); i += 1 {
        row := rows[i]
        for i + 1 < len(rows) {
            older := rows[i + 1]
            if !undo_graph_joins(state, nodes, row.first, older.node, saved, keep) || older.joins != {} {
                break
            }
            row.first = older.first
            row.count += older.count
            row.bottom = older.bottom
            i += 1
        }
        rows[out] = row
        out += 1
    }
    resize(rows, out)
}

// True when node `newer` continues the run of its parent `older`.
@(private = "file")
undo_graph_joins :: proc(state: ^textedit.State, nodes: []textedit.Undo_Node, newer, older: int, saved: u64, keep: []int) -> bool {
    a, b := &nodes[newer], &nodes[older]
    if a.parent != older || b.parent == textedit.NO_NODE || len(b.children) != 1 {
        return false
    }
    if a.coalesce == .None || a.coalesce != b.coalesce || len(a.ops) != 1 || len(b.ops) != 1 || a.line != b.line {
        return false
    }
    if time.duration_seconds(time.diff(b.stamp, a.stamp)) > UNDO_GROUP_GAP {
        return false
    }
    for k in keep {
        if k == older {
            return false
        }
    }
    if textedit.node_content_id(state, older) == saved {
        return false
    }
    x, y := a.ops[0], b.ops[0]
    switch a.coalesce {
    case .None:
        return false
    case .Typing:
        return x.pos == y.pos + len(y.text)
    case .Delete_Back:
        return x.pos + len(x.text) == y.pos
    case .Delete_Forward:
        return x.pos == y.pos
    }
    return false
}

// The single changed place of a row's run: the whole typed or deleted text.
undo_graph_run_hunk :: proc(state: ^textedit.State, row: Undo_Graph_Row, allocator := context.temp_allocator) -> (textedit.Node_Hunk, bool) {
    if row.count <= 1 {
        return {}, false
    }
    nodes := state.history.nodes[:]
    top   := &nodes[row.node]
    if len(top.ops) != 1 {
        return {}, false
    }
    parts := make([dynamic]string, 0, row.count, context.temp_allocator)
    for i := row.node; ; i = nodes[i].parent {
        append(&parts, nodes[i].ops[0].text)
        if i == row.first {
            break
        }
    }
    // `parts` runs newest first.
    first := &nodes[row.first]
    switch top.coalesce {
    case .None:
    case .Typing:
        total := 0
        for p in parts {
            total += len(p)
        }
        return {pos = first.ops[0].pos, inserted = total}, true
    case .Delete_Back:
        return {pos = top.ops[0].pos, removed = strings.concatenate(parts[:], allocator)}, true
    case .Delete_Forward:
        ordered := make([]string, len(parts), context.temp_allocator)
        for p, k in parts {
            ordered[len(parts) - 1 - k] = p
        }
        return {pos = top.ops[0].pos, removed = strings.concatenate(ordered, allocator)}, true
    }
    return {}, false
}

// The text a typing run inserted, oldest first.
undo_graph_run_text :: proc(state: ^textedit.State, row: Undo_Graph_Row) -> string {
    nodes := state.history.nodes[:]
    parts := make([dynamic]string, 0, row.count, context.temp_allocator)
    for i := row.node; ; i = nodes[i].parent {
        if len(nodes[i].ops) == 1 {
            inject_at(&parts, 0, nodes[i].ops[0].text)
        }
        if i == row.first {
            break
        }
    }
    return strings.concatenate(parts[:], context.temp_allocator)
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
