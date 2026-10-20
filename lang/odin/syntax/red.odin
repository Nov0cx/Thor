package odinsyntax

// A green node at a position in the file.
Syntax_Node :: struct {
    green:  ^Green_Node,
    offset: u32,
    parent: ^Syntax_Node, // nil at the root
}

// A green token at a position in the file.
Syntax_Token :: struct {
    green:  ^Green_Token,
    offset: u32,
    parent: ^Syntax_Node,
}

Syntax_Element :: union {
    Syntax_Node,
    Syntax_Token,
}

node_root :: proc "contextless" (tree: ^Green_Tree) -> Syntax_Node {
    return {green = tree.root}
}

node_range :: #force_inline proc "contextless" (n: Syntax_Node) -> (start, end: u32) {
    return n.offset, n.offset + n.green.text_len
}

token_range :: #force_inline proc "contextless" (t: Syntax_Token) -> (start, end: u32) {
    return t.offset, t.offset + u32(len(t.green.text))
}

element_range :: proc "contextless" (e: Syntax_Element) -> (start, end: u32) {
    switch v in e {
    case Syntax_Node:  return node_range(v)
    case Syntax_Token: return token_range(v)
    }
    return 0, 0
}

// The children of `n` with their positions. Each child's parent is `n`, so `n` must outlive them.
node_children :: proc(n: ^Syntax_Node, allocator := context.allocator) -> []Syntax_Element {
    out := make([]Syntax_Element, len(n.green.children), allocator)
    offset := n.offset
    for child, i in n.green.children {
        switch v in child {
        case ^Green_Node:  out[i] = Syntax_Node{v, offset, n}
        case ^Green_Token: out[i] = Syntax_Token{v, offset, n}
        }
        offset += element_len(child)
    }
    return out
}

// The token that holds byte `offset`; at the end of the file, the last token.
// The parent chain is allocated with `allocator`.
node_token_at :: proc(root: Syntax_Node, offset: u32, allocator := context.allocator) -> (Syntax_Token, bool) {
    start, end := node_range(root)
    if offset < start || offset > end {
        return {}, false
    }
    at_end := offset == end
    cur := new_clone(root, allocator)
    for {
        pos := cur.offset
        next: ^Green_Node
        next_pos: u32
        for child, i in cur.green.children {
            child_len := element_len(child)
            last := i == len(cur.green.children) - 1
            if (offset >= pos && offset < pos + child_len) || (at_end && last) {
                switch v in child {
                case ^Green_Token:
                    return Syntax_Token{v, pos, cur}, true
                case ^Green_Node:
                    next, next_pos = v, pos
                }
                break
            }
            pos += child_len
        }
        if next == nil {
            return {}, false
        }
        cur = new_clone(Syntax_Node{next, next_pos, cur}, allocator)
    }
}

// The smallest element that covers [start, end).
// The parent chain is allocated with `allocator`.
node_covering :: proc(root: Syntax_Node, start, end: u32, allocator := context.allocator) -> (Syntax_Element, bool) {
    rs, re := node_range(root)
    if start > end || start < rs || end > re {
        return nil, false
    }
    cur := root
    for {
        pos := cur.offset
        next: Syntax_Element
        for child in cur.green.children {
            child_len := element_len(child)
            if start >= pos && end <= pos + child_len && (child_len > 0 || start == pos) {
                parent := new_clone(cur, allocator)
                switch v in child {
                case ^Green_Token: return Syntax_Token{v, pos, parent}, true
                case ^Green_Node:  next = Syntax_Node{v, pos, parent}
                }
                break
            }
            pos += child_len
        }
        node, is_node := next.(Syntax_Node)
        if !is_node {
            return cur, true
        }
        cur = node
    }
}
