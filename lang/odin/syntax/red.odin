package odinsyntax

// A green node at a position in the file. Identify a node by its position, never by its green
// pointer: equal subtrees may be one green node.
Syntax_Node :: struct {
    green:  ^Green_Node,
    offset: u32,
    parent: ^Syntax_Node, // nil at the root
    tree:   ^Green_Tree,
}

// A green token at a position in the file.
Syntax_Token :: struct {
    green:  Green_Token,
    offset: u32,
    parent: ^Syntax_Node,
    tree:   ^Green_Tree,
}

Syntax_Element :: union {
    Syntax_Node,
    Syntax_Token,
}

node_root :: proc "contextless" (tree: ^Green_Tree) -> Syntax_Node {
    return {green = tree.root, tree = tree}
}

node_range :: #force_inline proc "contextless" (n: Syntax_Node) -> (start, end: u32) {
    return n.offset, n.offset + n.green.text_len
}

token_range :: #force_inline proc "contextless" (t: Syntax_Token) -> (start, end: u32) {
    return t.offset, t.offset + t.green.len
}

element_range :: proc "contextless" (e: Syntax_Element) -> (start, end: u32) {
    switch v in e {
    case Syntax_Node:  return node_range(v)
    case Syntax_Token: return token_range(v)
    }
    return 0, 0
}

// The source text of a node, trivia inside it included.
node_text :: #force_inline proc "contextless" (n: Syntax_Node) -> string {
    return n.tree.text[n.offset:][:n.green.text_len]
}

syntax_token_text :: #force_inline proc "contextless" (t: Syntax_Token) -> string {
    return t.tree.text[t.offset:][:t.green.len]
}

// The positioned form of `child`, a child of `parent` at `offset`.
child_element :: #force_inline proc "contextless" (parent: ^Syntax_Node, child: Green_Element, offset: u32) -> Syntax_Element {
    if n, is_node := element_node(child); is_node {
        return Syntax_Node{n, offset, parent, parent.tree}
    }
    tok, _ := element_token(child)
    return Syntax_Token{tok, offset, parent, parent.tree}
}

// The children of `n` with their positions. Each child's parent is `n`, so `n` must outlive them.
node_children :: proc(n: ^Syntax_Node, allocator := context.allocator) -> []Syntax_Element {
    kids := green_children(n.green)
    out := make([]Syntax_Element, len(kids), allocator)
    offset := n.offset
    for child, i in kids {
        out[i] = child_element(n, child, offset)
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
        kids := green_children(cur.green)
        for child, i in kids {
            child_len := element_len(child)
            last := i == len(kids) - 1
            if (offset >= pos && offset < pos + child_len) || (at_end && last) {
                if n, is_node := element_node(child); is_node {
                    next, next_pos = n, pos
                } else {
                    tok, _ := element_token(child)
                    return Syntax_Token{tok, pos, cur, cur.tree}, true
                }
                break
            }
            pos += child_len
        }
        if next == nil {
            return {}, false
        }
        cur = new_clone(Syntax_Node{next, next_pos, cur, cur.tree}, allocator)
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
        for child in green_children(cur.green) {
            child_len := element_len(child)
            if start >= pos && end <= pos + child_len && (child_len > 0 || start == pos) {
                next = child_element(new_clone(cur, allocator), child, pos)
                break
            }
            pos += child_len
        }
        switch v in next {
        case Syntax_Token:
            return v, true
        case Syntax_Node:
            cur = v
        case:
            return cur, true
        }
    }
}
