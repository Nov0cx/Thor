package odinsyntax

import "core:mem"
import "core:mem/virtual"
import "core:strings"

// A leaf of the green tree: one token and its text.
Green_Token :: struct {
    kind:  Token_Kind,
    flags: Token_Flags,
    text:  string,
}

// An inner node of the green tree. Holds no position, so equal subtrees can be shared.
Green_Node :: struct {
    kind:     Syntax_Kind,
    text_len: u32,
    children: []Green_Element,
}

Green_Element :: union {
    ^Green_Node,
    ^Green_Token,
}

// A green tree and the arena its nodes and token text live in.
Green_Tree :: struct {
    arena: virtual.Arena,
    root:  ^Green_Node,
}

// Builds a green tree bottom up: start_node, token, finish_node.
Green_Builder :: struct {
    tree:     ^Green_Tree,
    stack:    [dynamic]Builder_Frame, // owned
    children: [dynamic]Green_Element, // owned
    block:    []byte,                 // the rest of the arena block nodes are cut from
}

@(private)
NODE_BLOCK :: 64 * mem.Kilobyte

@(private)
Builder_Frame :: struct {
    kind:  Syntax_Kind,
    first: int,
}

tree_create :: proc(allocator := context.allocator) -> (tree: ^Green_Tree, err: mem.Allocator_Error) {
    tree = new(Green_Tree, allocator) or_return
    if err = virtual.arena_init_growing(&tree.arena); err != nil {
        free(tree, allocator)
        return nil, err
    }
    return tree, nil
}

tree_destroy :: proc(tree: ^Green_Tree, allocator := context.allocator) {
    if tree == nil {
        return
    }
    virtual.arena_destroy(&tree.arena)
    free(tree, allocator)
}

tree_allocator :: #force_inline proc(tree: ^Green_Tree) -> mem.Allocator {
    return virtual.arena_allocator(&tree.arena)
}

builder_init :: proc(b: ^Green_Builder, tree: ^Green_Tree, scratch := context.allocator) {
    b.tree = tree
    b.stack = make([dynamic]Builder_Frame, 0, 32, scratch)
    b.children = make([dynamic]Green_Element, 0, 256, scratch)
}

builder_destroy :: proc(b: ^Green_Builder) {
    delete(b.stack)
    delete(b.children)
}

builder_start_node :: proc(b: ^Green_Builder, kind: Syntax_Kind) {
    append(&b.stack, Builder_Frame{kind, len(b.children)})
}

// A point among the open node's children that a later node can start at.
builder_checkpoint :: #force_inline proc "contextless" (b: ^Green_Builder) -> int {
    return len(b.children)
}

// Opens a node whose first child is the one added at `checkpoint`.
builder_start_node_at :: proc(b: ^Green_Builder, checkpoint: int, kind: Syntax_Kind) {
    assert(checkpoint <= len(b.children))
    assert(len(b.stack) == 0 || checkpoint >= b.stack[len(b.stack) - 1].first)
    append(&b.stack, Builder_Frame{kind, checkpoint})
}

// Puts the children in [first, end) of the open node into one new node of `kind`.
builder_wrap :: proc(b: ^Green_Builder, first, end: int, kind: Syntax_Kind) -> mem.Allocator_Error {
    assert(first <= end && end <= len(b.children))
    assert(len(b.stack) == 0 || first >= b.stack[len(b.stack) - 1].first)
    node := make_node(b, kind, b.children[first:end]) or_return
    if first == end {
        inject_at(&b.children, first, node) or_return
        return nil
    }
    b.children[first] = node
    n := copy(b.children[first + 1:], b.children[end:])
    resize(&b.children, first + 1 + n)
    return nil
}

// Adds a token to the open node. Text with a fixed spelling is not copied.
builder_token :: proc(b: ^Green_Builder, kind: Token_Kind, flags: Token_Flags, text: string) -> mem.Allocator_Error {
    alloc := tree_allocator(b.tree)
    tok := new(Green_Token, alloc) or_return
    tok.kind = kind
    tok.flags = flags
    if fixed := TOKEN_TEXT[kind]; fixed == text {
        tok.text = fixed
    } else {
        tok.text = strings.clone(text, alloc) or_return
    }
    append(&b.children, tok)
    return nil
}

// Adds a token that lives in the tree arena already.
builder_add_token :: #force_inline proc(b: ^Green_Builder, tok: ^Green_Token) {
    append(&b.children, tok)
}

// A node and its children array, in one arena allocation.
@(private)
make_node :: proc(b: ^Green_Builder, kind: Syntax_Kind, children: []Green_Element) -> (node: ^Green_Node, err: mem.Allocator_Error) {
    #assert(size_of(Green_Node) % align_of(Green_Node) == 0 && size_of(Green_Element) % align_of(Green_Node) == 0)
    size := size_of(Green_Node) + len(children) * size_of(Green_Element)
    if size > len(b.block) {
        b.block = virtual.arena_alloc(&b.tree.arena, uint(max(size, NODE_BLOCK)), align_of(Green_Node)) or_return
    }
    data := b.block[:size]
    b.block = b.block[size:]
    node = (^Green_Node)(raw_data(data))
    node.kind = kind
    kids := ([^]Green_Element)(raw_data(data[size_of(Green_Node):]))[:len(children)]
    copy(kids, children)
    for child in kids {
        node.text_len += element_len(child)
    }
    node.children = kids
    return node, nil
}

// Closes the open node and adds it to its parent, or makes it the root.
builder_finish_node :: proc(b: ^Green_Builder) -> mem.Allocator_Error {
    frame := pop(&b.stack)
    node := make_node(b, frame.kind, b.children[frame.first:]) or_return
    resize(&b.children, frame.first)
    if len(b.stack) == 0 {
        b.tree.root = node
    } else {
        append(&b.children, node)
    }
    return nil
}

element_len :: proc "contextless" (e: Green_Element) -> u32 {
    switch v in e {
    case ^Green_Node:  return v.text_len
    case ^Green_Token: return u32(len(v.text))
    }
    return 0
}

// Builds a tree with every token directly under one Root node.
build_flat :: proc(src: string, toks: []Token, allocator := context.allocator) -> (tree: ^Green_Tree, err: mem.Allocator_Error) {
    tree = tree_create(allocator) or_return
    b: Green_Builder
    builder_init(&b, tree)
    defer builder_destroy(&b)
    builder_start_node(&b, .Root)
    for tok in toks {
        if err = builder_token(&b, tok.kind, tok.flags, token_text(src, tok)); err != nil {
            tree_destroy(tree, allocator)
            return nil, err
        }
    }
    if err = builder_finish_node(&b); err != nil {
        tree_destroy(tree, allocator)
        return nil, err
    }
    return tree, nil
}

// Writes the text of every token under `node`, in order.
green_write_text :: proc(sb: ^strings.Builder, node: ^Green_Node) {
    for child in node.children {
        switch v in child {
        case ^Green_Node:  green_write_text(sb, v)
        case ^Green_Token: strings.write_string(sb, v.text)
        }
    }
}

green_text :: proc(node: ^Green_Node, allocator := context.allocator) -> string {
    sb := strings.builder_make_len_cap(0, int(node.text_len), allocator)
    green_write_text(&sb, node)
    return strings.to_string(sb)
}
