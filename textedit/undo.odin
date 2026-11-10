package textedit

import "core:strings"
import "core:time"
import "core:unicode/utf8"

// How an edit may fold into the entry below it in the history, so a typed
// word or a run of backspaces takes one step to undo instead of one per key.
Coalesce :: enum {
    None,
    Typing,
    Delete_Back,
    Delete_Forward,
}

Undo_Entry :: struct {
    ops:            [dynamic]Edit_Op, // owned, with the text of every op
    cursors_before: [dynamic]Cursor,  // owned
    cursors_after:  [dynamic]Cursor,  // owned
    coalesce:       Coalesce,
    // State.content_id before and after the entry.
    id_before:      u64,
    id_after:       u64,
}

// Bounds on the undo history. Past either, the oldest nodes are dropped; the current one always stays.
MAX_UNDO_ENTRIES :: 1024
MAX_UNDO_BYTES :: 16 * 1024 * 1024

// Node index that names no node.
NO_NODE :: -1

// One step of the undo tree. The root holds no ops; every other node is the edit
// that leads from its parent's content to its own.
Undo_Node :: struct {
    using entry: Undo_Entry,
    parent:      int,          // NO_NODE for the root
    children:    [dynamic]int, // owned, oldest first
    // The child redo goes to: the last one undone or made. NO_NODE when none.
    active:      int,
    // Creation order. Undo_earlier and undo_later step through it.
    seq:         int,
    // When the node was made or last grew by coalescing.
    stamp:       time.Time,
    // Zero-based line of the primary caret after the edit, in the node's own content.
    line:        int,
    live:        bool,
}

// One changed place of a node, in the node's own content: `inserted` bytes at
// `pos` took the place of `removed`.
Node_Hunk :: struct {
    pos:      int,
    inserted: int,
    removed:  string, // borrowed from the node's op
}

// The undo history as a tree: an edit after an undo starts a new branch, and the
// old branch stays reachable. Empty until the first edit.
Undo_Tree :: struct {
    nodes:    [dynamic]Undo_Node, // owned; slots of dropped nodes are reused
    free:     [dynamic]int,       // owned
    root:     int,
    // The node whose content the buffer holds.
    current:  int,
    next_seq: int,
    // Live nodes, the root not counted.
    count:    int,
}

can_undo :: proc(state: ^State) -> bool {
    tree := &state.history
    return len(tree.nodes) > 0 && tree.current != tree.root
}

can_redo :: proc(state: ^State) -> bool {
    tree := &state.history
    return len(tree.nodes) > 0 && tree.nodes[tree.current].active != NO_NODE
}

// Steps from the root to the current node: how many undos are left.
undo_depth :: proc(state: ^State) -> int {
    tree := &state.history
    if len(tree.nodes) == 0 {
        return 0
    }
    depth := 0
    for i := tree.current; i != tree.root; i = tree.nodes[i].parent {
        depth += 1
    }
    return depth
}

history_root :: proc(state: ^State) -> int {
    return len(state.history.nodes) > 0 ? state.history.root : NO_NODE
}

history_current :: proc(state: ^State) -> int {
    return len(state.history.nodes) > 0 ? state.history.current : NO_NODE
}

// The node at `index`, borrowed until the next edit or history move. Nil when no live node is there.
history_node :: proc(state: ^State, index: int) -> ^Undo_Node {
    tree := &state.history
    if index < 0 || index >= len(tree.nodes) || !tree.nodes[index].live {
        return nil
    }
    return &tree.nodes[index]
}

// Bytes the node inserts and deletes.
node_summary :: proc(node: ^Undo_Node) -> (inserted, deleted: int) {
    for op in node.ops {
        switch op.kind {
        case .Insert:
            inserted += len(op.text)
        case .Delete:
            deleted += len(op.text)
        }
    }
    return
}

// The content id of the state node `index` stands for. 0 when no live node is there.
node_content_id :: proc(state: ^State, index: int) -> u64 {
    node := history_node(state, index)
    if node == nil {
        return 0
    }
    if node.parent != NO_NODE {
        return node.id_after
    }
    for child in node.children {
        if c := history_node(state, child); c != nil {
            return c.id_before
        }
    }
    return state.content_id
}

// The changed places of `node`, in the order of its ops, at their positions in the node's content.
node_hunks :: proc(node: ^Undo_Node, allocator := context.allocator) -> []Node_Hunk {
    Span :: struct {
        lo, hi:  int,
        removed: string,
    }
    spans := make([dynamic]Span, 0, len(node.ops), context.temp_allocator)
    for op, i in node.ops {
        n := len(op.text)
        // Every span made so far moves through this op.
        for &s in spans {
            switch op.kind {
            case .Insert:
                s.lo = s.lo < op.pos ? s.lo : s.lo + n
                s.hi = s.hi <= op.pos ? s.hi : s.hi + n
            case .Delete:
                s.lo = hunk_map_delete(s.lo, op.pos, n)
                s.hi = hunk_map_delete(s.hi, op.pos, n)
            }
            s.hi = max(s.hi, s.lo)
        }
        switch op.kind {
        case .Insert:
            // An insert where the op before it deleted is one replace.
            if i > 0 && node.ops[i - 1].kind == .Delete && node.ops[i - 1].pos == op.pos && len(spans) > 0 {
                last := &spans[len(spans) - 1]
                if last.lo == op.pos + n && last.hi == last.lo && last.removed != "" {
                    last.lo = op.pos
                    continue
                }
            }
            append(&spans, Span{lo = op.pos, hi = op.pos + n})
        case .Delete:
            append(&spans, Span{lo = op.pos, hi = op.pos, removed = op.text})
        }
    }
    out := make([]Node_Hunk, len(spans), allocator)
    for s, i in spans {
        out[i] = Node_Hunk {
            pos      = s.lo,
            inserted = s.hi - s.lo,
            removed  = s.removed,
        }
    }
    return out
}

@(private)
hunk_map_delete :: proc(x, pos, n: int) -> int {
    if x <= pos {
        return x
    }
    if x >= pos + n {
        return x - n
    }
    return pos
}

undo :: proc(state: ^State) {
    tree := &state.history
    if !can_undo(state) {
        return
    }
    index := tree.current
    node := &tree.nodes[index]
    apply_backward(state, node)
    tree.nodes[node.parent].active = index
    tree.current = node.parent
}

redo :: proc(state: ^State) {
    tree := &state.history
    if !can_redo(state) {
        return
    }
    index := tree.nodes[tree.current].active
    apply_forward(state, &tree.nodes[index])
    tree.current = index
}

// Moves the buffer to the content of node `target`: undo up to the common
// ancestor, then redo down. False when `target` is no live node.
undo_goto :: proc(state: ^State, target: int) -> bool {
    tree := &state.history
    if history_node(state, target) == nil {
        return false
    }
    ancestor := common_ancestor(tree, tree.current, target)
    for tree.current != ancestor {
        undo(state)
    }
    path := make([dynamic]int, context.temp_allocator)
    for i := target; i != ancestor; i = tree.nodes[i].parent {
        append(&path, i)
    }
    #reverse for index in path {
        tree.nodes[tree.current].active = index
        redo(state)
    }
    return true
}

// Moves to the content made just before the current one, across branches. False at the oldest.
undo_earlier :: proc(state: ^State) -> bool {
    tree := &state.history
    if len(tree.nodes) == 0 {
        return false
    }
    seq := tree.nodes[tree.current].seq
    best := NO_NODE
    for &node, i in tree.nodes {
        if node.live && node.seq < seq && (best == NO_NODE || node.seq > tree.nodes[best].seq) {
            best = i
        }
    }
    return best != NO_NODE && undo_goto(state, best)
}

// Moves to the content made just after the current one, across branches. False at the newest.
undo_later :: proc(state: ^State) -> bool {
    tree := &state.history
    if len(tree.nodes) == 0 {
        return false
    }
    seq := tree.nodes[tree.current].seq
    best := NO_NODE
    for &node, i in tree.nodes {
        if node.live && node.seq > seq && (best == NO_NODE || node.seq < tree.nodes[best].seq) {
            best = i
        }
    }
    return best != NO_NODE && undo_goto(state, best)
}

// Folds the current node into its parent, so one undo takes both back. For an
// edit that only follows from the edit before it. No-op when the parent is the
// root or has other branches.
join_last_undo :: proc(state: ^State) {
    tree := &state.history
    if !can_undo(state) {
        return
    }
    index := tree.current
    parent_index := tree.nodes[index].parent
    if parent_index == tree.root || len(tree.nodes[parent_index].children) != 1 {
        return
    }
    top := &tree.nodes[index]
    prev := &tree.nodes[parent_index]
    append(&prev.ops, ..top.ops[:])
    delete(top.ops)
    delete(top.cursors_before)
    delete(prev.cursors_after)
    prev.cursors_after = top.cursors_after
    prev.id_after = top.id_after
    prev.coalesce = .None
    prev.stamp = top.stamp
    prev.line = top.line
    for child in top.children {
        tree.nodes[child].parent = parent_index
    }
    delete(prev.children)
    prev.children = top.children
    prev.active = top.active
    top^ = Undo_Node {
        parent = NO_NODE,
        active = NO_NODE,
    }
    append(&tree.free, index)
    tree.count -= 1
    tree.current = parent_index
    state.coalescing = false
}

@(private)
apply_backward :: proc(state: ^State, node: ^Undo_Node) {
    state.coalescing = false
    #reverse for op in node.ops {
        switch op.kind {
        case .Insert:
            table_delete(state, op.pos, len(op.text))
        case .Delete:
            table_insert(state, op.pos, op.text)
        }
    }
    clear(&state.cursors)
    append(&state.cursors, ..node.cursors_before[:])
    state.content_id = node.id_before
    state.revision += 1
    record_change(state, state.revision, node.ops[:], true)
}

@(private)
apply_forward :: proc(state: ^State, node: ^Undo_Node) {
    state.coalescing = false
    for op in node.ops {
        switch op.kind {
        case .Insert:
            table_insert(state, op.pos, op.text)
        case .Delete:
            table_delete(state, op.pos, len(op.text))
        }
    }
    clear(&state.cursors)
    append(&state.cursors, ..node.cursors_after[:])
    state.content_id = node.id_after
    state.revision += 1
    record_change(state, state.revision, node.ops[:])
}

@(private)
node_depth :: proc(tree: ^Undo_Tree, index: int) -> int {
    depth := 0
    for i := index; i != tree.root; i = tree.nodes[i].parent {
        depth += 1
    }
    return depth
}

@(private)
common_ancestor :: proc(tree: ^Undo_Tree, a, b: int) -> int {
    a, b := a, b
    da, db := node_depth(tree, a), node_depth(tree, b)
    for da > db {
        a = tree.nodes[a].parent
        da -= 1
    }
    for db > da {
        b = tree.nodes[b].parent
        db -= 1
    }
    for a != b {
        a = tree.nodes[a].parent
        b = tree.nodes[b].parent
    }
    return a
}

@(private)
tree_ensure :: proc(tree: ^Undo_Tree) {
    if len(tree.nodes) > 0 {
        return
    }
    append(&tree.nodes, Undo_Node {parent = NO_NODE, active = NO_NODE, stamp = time.now(), live = true})
    tree.root = 0
    tree.current = 0
    tree.next_seq = 1
    tree.count = 0
}

// Adds `entry` as a new child of the current node and moves to it. The tree takes the entry.
@(private)
tree_push :: proc(tree: ^Undo_Tree, entry: Undo_Entry) {
    node := Undo_Node {
        entry  = entry,
        parent = tree.current,
        active = NO_NODE,
        seq    = tree.next_seq,
        stamp  = time.now(),
        live   = true,
    }
    tree.next_seq += 1
    index: int
    if n := len(tree.free); n > 0 {
        index = tree.free[n - 1]
        pop(&tree.free)
        tree.nodes[index] = node
    } else {
        index = len(tree.nodes)
        append(&tree.nodes, node)
    }
    parent := &tree.nodes[tree.current]
    append(&parent.children, index)
    parent.active = index
    tree.current = index
    tree.count += 1
}

@(private)
node_destroy :: proc(node: ^Undo_Node) {
    entry_destroy(&node.entry)
    delete(node.children)
    node^ = Undo_Node {
        parent = NO_NODE,
        active = NO_NODE,
    }
}

@(private)
tree_clear :: proc(tree: ^Undo_Tree) {
    for &node in tree.nodes {
        if node.live {
            node_destroy(&node)
        }
    }
    clear(&tree.nodes)
    clear(&tree.free)
    tree.root = 0
    tree.current = 0
    tree.count = 0
    tree.next_seq = 0
}

@(private)
tree_destroy :: proc(tree: ^Undo_Tree) {
    tree_clear(tree)
    delete(tree.nodes)
    delete(tree.free)
    tree.nodes = nil
    tree.free = nil
}

@(private)
finish_edit :: proc(state: ^State, entry: ^Undo_Entry, coalesce := Coalesce.None) {
    txt := text(state)
    for &cursor in state.cursors {
        cursor.preferred_column = cursor_column(state, txt, cursor.caret)
    }
    normalize_cursors(state)
    entry.cursors_after = clone_cursors(state)
    entry.coalesce = coalesce
    entry.id_before = state.content_id
    entry.id_after = state.revision + 1
    record_change(state, state.revision + 1, entry.ops[:])

    tree_ensure(&state.history)
    if !coalesce_into_previous(state, entry) {
        state.undo_bytes += entry_bytes(entry)
        tree_push(&state.history, entry^)
    }
    trim_undo_history(state)
    state.coalescing = coalesce != .None
    state.revision += 1
    state.content_id = state.revision
    tree := &state.history
    if tree.current != tree.root {
        tree.nodes[tree.current].line = state_line_index(state, primary_cursor(state).caret)
    }
}

@(private)
entry_bytes :: proc(entry: ^Undo_Entry) -> int {
    total := 0
    for op in entry.ops {
        total += len(op.text)
    }
    return total
}

// Drops the oldest nodes while the history is over a bound: first leaves off
// the path to the current node, then the root edge of that path.
@(private)
trim_undo_history :: proc(state: ^State) {
    tree := &state.history
    for tree.count > 1 && (tree.count > MAX_UNDO_ENTRIES || state.undo_bytes > MAX_UNDO_BYTES) {
        if !drop_oldest_leaf(state) && !fold_root(state) {
            return
        }
    }
}

// Drops the oldest leaf that is not the current node. False when there is none.
@(private)
drop_oldest_leaf :: proc(state: ^State) -> bool {
    tree := &state.history
    oldest := NO_NODE
    for &node, i in tree.nodes {
        if !node.live || i == tree.root || i == tree.current || len(node.children) > 0 {
            continue
        }
        if oldest == NO_NODE || node.seq < tree.nodes[oldest].seq {
            oldest = i
        }
    }
    if oldest == NO_NODE {
        return false
    }
    node := &tree.nodes[oldest]
    parent := &tree.nodes[node.parent]
    for child, k in parent.children {
        if child == oldest {
            ordered_remove(&parent.children, k)
            break
        }
    }
    if parent.active == oldest {
        n := len(parent.children)
        parent.active = n > 0 ? parent.children[n - 1] : NO_NODE
    }
    state.undo_bytes -= entry_bytes(&node.entry)
    node_destroy(node)
    append(&tree.free, oldest)
    tree.count -= 1
    return true
}

// Makes the root's only child the new root, so its content can no longer be
// undone past. False when the root has branches or its child is the current node.
@(private)
fold_root :: proc(state: ^State) -> bool {
    tree := &state.history
    old_root := tree.root
    if len(tree.nodes[old_root].children) != 1 {
        return false
    }
    child_index := tree.nodes[old_root].children[0]
    if child_index == tree.current {
        return false
    }
    child := &tree.nodes[child_index]
    state.undo_bytes -= entry_bytes(&child.entry)
    entry_destroy(&child.entry)
    child.entry = {}
    child.parent = NO_NODE
    node_destroy(&tree.nodes[old_root])
    append(&tree.free, old_root)
    tree.root = child_index
    tree.count -= 1
    return true
}

// Character classes that keep a coalescing run going: a typed letter joins the
// word so far and a space the run of spaces, while punctuation and newlines
// always start a fresh undo step.
@(private)
Run_Class :: enum {
    Word,
    Space,
    Other,
}

@(private)
run_class :: proc(r: rune) -> Run_Class {
    switch {
    case is_word_rune(r):
        return .Word
    case r == ' ' || r == '\t':
        return .Space
    }
    return .Other
}

// True when `next` continues the run `run` belongs to, the two being adjacent
// in the buffer in that order.
@(private)
same_run :: proc(run, next: string) -> bool {
    if len(run) == 0 || len(next) == 0 {
        return false
    }
    last, _ := utf8.decode_last_rune_in_string(run)
    first, _ := utf8.decode_rune_in_string(next)
    class := run_class(last)
    return class != .Other && class == run_class(first)
}

@(private)
join_op_text :: proc(first, second: string) -> string {
    joined := strings.concatenate({first, second})
    delete(first)
    delete(second)
    return joined
}

// Folds `entry` into the current node when both are consecutive keystrokes of
// the same kind, and reports the merge. A node with branches below it never
// grows. The ops must line up one for one, each continuing the run of its
// partner: for typing, after it; for a delete, before.
@(private)
coalesce_into_previous :: proc(state: ^State, entry: ^Undo_Entry) -> bool {
    tree := &state.history
    if !state.coalescing || entry.coalesce == .None || !can_undo(state) {
        return false
    }
    prev := &tree.nodes[tree.current]
    if len(prev.children) > 0 || prev.coalesce != entry.coalesce || len(prev.ops) != len(entry.ops) || len(entry.ops) == 0 {
        return false
    }

    // Bytes the already-merged ops add ahead of this one, which move the
    // positions recorded against the older entry.
    shift := 0
    for op, i in entry.ops {
        old := prev.ops[i]
        if old.kind != op.kind {
            return false
        }
        expected: int
        continues: bool
        switch entry.coalesce {
        case .None:
            return false
        case .Typing:
            expected = old.pos + len(old.text) + shift
            continues = same_run(old.text, op.text)
        case .Delete_Back:
            expected = old.pos - len(op.text) - shift
            continues = same_run(op.text, old.text)
        case .Delete_Forward:
            expected = old.pos - shift
            continues = same_run(old.text, op.text)
        }
        if op.pos != expected || !continues {
            return false
        }
        shift += len(op.text)
    }

    shift = 0
    for op, i in entry.ops {
        old := &prev.ops[i]
        switch entry.coalesce {
        case .None:
        case .Typing:
            old.pos += shift
            old.text = join_op_text(old.text, op.text)
        case .Delete_Back:
            old.pos = op.pos
            old.text = join_op_text(op.text, old.text)
        case .Delete_Forward:
            old.pos = op.pos
            old.text = join_op_text(old.text, op.text)
        }
        shift += len(op.text)
    }
    state.undo_bytes += shift

    prev.id_after = entry.id_after
    prev.stamp = time.now()
    delete(prev.cursors_after)
    prev.cursors_after = entry.cursors_after
    entry.cursors_after = nil
    delete(entry.cursors_before)
    entry.cursors_before = nil
    delete(entry.ops) // the op texts were consumed by the merge above
    entry.ops = nil
    return true
}

@(private)
entry_destroy :: proc(entry: ^Undo_Entry) {
    for op in entry.ops {
        delete(op.text)
    }
    delete(entry.ops)
    delete(entry.cursors_before)
    delete(entry.cursors_after)
}
