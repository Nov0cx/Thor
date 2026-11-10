package odinsyntax

import "core:mem"
import "core:mem/virtual"
import "core:strings"

// A leaf of the green tree: one token. Its text is the tree text at the token's position.
Green_Token :: struct {
    kind:  Token_Kind,
    flags: Token_Flags,
    len:   u32,
}

// An inner node of the green tree. Holds no position and no text, so equal subtrees can be shared.
// The children follow the header in the same allocation; `green_children` reads them.
Green_Node :: struct {
    kind:     Syntax_Kind,
    count:    u16, // BIG_COUNT when the count is in the word after the header
    text_len: u32,
}

// A child of a green node: a ^Green_Node (bit 0 clear) or a token stored inline (bit 0 set,
// kind in bits 8..15, flags in bits 16..23, length in bits 32..63).
Green_Element :: distinct u64

// A green tree, the arena its nodes live in, and the source text its tokens read.
// A subtree shared with another tree reads the same text there, as both trees hold their whole source.
Green_Tree :: struct {
    arena:      virtual.Arena,
    root:       ^Green_Node,
    text:       string,       // in the arena or in `pages`; "" once a newer tree took the pages
    pages:      []byte,       // owned; the pages a reparsed tree keeps its text in, nil when none
    base:       ^Green_Tree, // owned; the older tree whose nodes this one shares, nil when none
    generation: u16,         // length of the base chain
}

// Builds a green tree bottom up: start_node, token, finish_node.
Green_Builder :: struct {
    tree:     ^Green_Tree,
    stack:    [dynamic]Builder_Frame, // owned
    children: [dynamic]Green_Element, // owned
    block:    []byte,                 // the rest of the arena block nodes are cut from
    next:     int,                    // bytes of the next block; NODE_BLOCK after the first
}

@(private)
NODE_BLOCK :: 64 * mem.Kilobyte

// Most node bytes a parse makes per token: 13 to 19.3 over Thor's sources.
@(private)
NODE_BYTES_PER_TOKEN :: 20

// Bytes of the nodes a splice along `path` makes.
@(private)
splice_bytes :: proc "contextless" (path: []Spine_Step) -> int {
    n := 0
    for step in path {
        kids := len(green_children(step.node))
        n += size_of(Green_Node) + (kids + (1 if kids >= int(BIG_COUNT) else 0)) * size_of(Green_Element)
    }
    return n
}

@(private)
BIG_COUNT :: max(u16)

@(private)
Builder_Frame :: struct {
    kind:  Syntax_Kind,
    first: int,
}

#assert(size_of(Green_Node) == 8 && size_of(Green_Element) == 8)

// Gives `tree` a copy of `text` in the pages of its base when they fit, else in new pages.
// The base keeps no text: red nodes read the text of the newest tree only.
tree_take_text :: proc(tree: ^Green_Tree, text: string) -> mem.Allocator_Error {
    base := tree.base
    pages: []byte
    if base != nil && len(base.pages) >= len(text) {
        pages = base.pages
        base.pages = nil
    } else {
        size := mem.align_forward_int(len(text) + TEXT_SLACK, mem.PAGE_SIZE)
        pages = virtual.reserve_and_commit(uint(size)) or_return
        if base != nil && base.pages != nil {
            virtual.release(raw_data(base.pages), uint(len(base.pages)))
            base.pages = nil
        }
    }
    copy(pages, text)
    tree.pages = pages
    tree.text = string(pages[:len(text)])
    if base != nil {
        base.text = ""
    }
    return nil
}

// Bytes a reparsed tree's text can grow by before it needs new pages.
@(private)
TEXT_SLACK :: 4 * mem.Kilobyte

// Makes an empty tree that holds a copy of `text`.
tree_create :: proc(text := "", allocator := context.allocator) -> (tree: ^Green_Tree, err: mem.Allocator_Error) {
    tree = new(Green_Tree, allocator) or_return
    if err = virtual.arena_init_growing(&tree.arena); err != nil {
        free(tree, allocator)
        return nil, err
    }
    if tree.text, err = strings.clone(text, tree_allocator(tree)); err != nil {
        tree_destroy(tree, allocator)
        return nil, err
    }
    return tree, nil
}

// Frees the tree and its base chain.
tree_destroy :: proc(tree: ^Green_Tree, allocator := context.allocator) {
    for cur := tree; cur != nil; {
        next := cur.base
        if cur.pages != nil {
            virtual.release(raw_data(cur.pages), uint(len(cur.pages)))
        }
        virtual.arena_destroy(&cur.arena)
        free(cur, allocator)
        cur = next
    }
}

// Makes a tree that shares the nodes of `base` and owns it. tree_take_text gives it its text.
tree_create_on :: proc(base: ^Green_Tree, allocator := context.allocator) -> (tree: ^Green_Tree, err: mem.Allocator_Error) {
    tree = tree_create("", allocator) or_return
    tree.base = base
    tree.generation = base.generation + 1
    return tree, nil
}

tree_allocator :: #force_inline proc(tree: ^Green_Tree) -> mem.Allocator {
    return virtual.arena_allocator(&tree.arena)
}

token_element :: #force_inline proc "contextless" (kind: Token_Kind, flags: Token_Flags, len: u32) -> Green_Element {
    return Green_Element(1 | u64(kind) << 8 | u64(transmute(u8)flags) << 16 | u64(len) << 32)
}

node_element :: #force_inline proc "contextless" (node: ^Green_Node) -> Green_Element {
    return Green_Element(uintptr(node))
}

element_node :: #force_inline proc "contextless" (e: Green_Element) -> (^Green_Node, bool) {
    if e & 1 != 0 {
        return nil, false
    }
    return (^Green_Node)(uintptr(e)), true
}

element_token :: #force_inline proc "contextless" (e: Green_Element) -> (Green_Token, bool) {
    if e & 1 == 0 {
        return {}, false
    }
    return Green_Token{Token_Kind(e >> 8), transmute(Token_Flags)u8(e >> 16), u32(e >> 32)}, true
}

element_len :: #force_inline proc "contextless" (e: Green_Element) -> u32 {
    if e & 1 != 0 {
        return u32(e >> 32)
    }
    return (^Green_Node)(uintptr(e)).text_len
}

// The children of `node`.
green_children :: #force_inline proc "contextless" (node: ^Green_Node) -> []Green_Element {
    data := ([^]Green_Element)(uintptr(node) + size_of(Green_Node))
    if node.count == BIG_COUNT {
        return data[1:][:int(data[0])]
    }
    return data[:node.count]
}

// `first` is the size of the first node block: what the tree needs, so no block tail is left unused.
builder_init :: proc(b: ^Green_Builder, tree: ^Green_Tree, scratch := context.allocator, first := NODE_BLOCK) {
    b.tree = tree
    b.next = max(mem.align_forward_int(first, 64), 64)
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
        inject_at(&b.children, first, node_element(node)) or_return
        return nil
    }
    b.children[first] = node_element(node)
    n := copy(b.children[first + 1:], b.children[end:])
    resize(&b.children, first + 1 + n)
    return nil
}

// Adds a token of `len` bytes to the open node.
builder_token :: #force_inline proc(b: ^Green_Builder, kind: Token_Kind, flags: Token_Flags, len: u32) {
    append(&b.children, token_element(kind, flags, len))
}

// A node and its children array, in one arena allocation.
@(private)
make_node :: proc(b: ^Green_Builder, kind: Syntax_Kind, children: []Green_Element) -> (node: ^Green_Node, err: mem.Allocator_Error) {
    big := len(children) >= int(BIG_COUNT)
    slots := len(children) + (1 if big else 0)
    size := size_of(Green_Node) + slots * size_of(Green_Element)
    if size > len(b.block) {
        b.block = virtual.arena_alloc(&b.tree.arena, uint(max(size, b.next)), align_of(Green_Element)) or_return
        b.next = NODE_BLOCK
    }
    data := b.block[:size]
    b.block = b.block[size:]
    node = (^Green_Node)(raw_data(data))
    node.kind = kind
    node.text_len = 0
    kids := ([^]Green_Element)(raw_data(data[size_of(Green_Node):]))[:slots]
    if big {
        node.count = BIG_COUNT
        kids[0] = Green_Element(len(children))
        kids = kids[1:]
    } else {
        node.count = u16(len(children))
    }
    copy(kids, children)
    for child in kids {
        node.text_len += element_len(child)
    }
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
        append(&b.children, node_element(node))
    }
    return nil
}

// One step of a path down a green tree: child `index` of `node`.
Spine_Step :: struct {
    node:  ^Green_Node,
    index: int,
}

// A copy of `node` whose child `index` is `child`.
builder_replace_child :: proc(b: ^Green_Builder, node: ^Green_Node, index: int, child: Green_Element) -> (out: ^Green_Node, err: mem.Allocator_Error) {
    kids := green_children(node)
    assert(index >= 0 && index < len(kids))
    resize(&b.children, len(kids)) or_return
    copy(b.children[:], kids)
    b.children[index] = child
    out, err = make_node(b, node.kind, b.children[:])
    clear(&b.children)
    return
}

// The root of a tree that equals the one `path` walks down, with the child the last step names
// replaced by `child`. Nodes off the path are shared, not copied.
builder_splice :: proc(b: ^Green_Builder, path: []Spine_Step, child: Green_Element) -> (root: ^Green_Node, err: mem.Allocator_Error) {
    assert(len(path) > 0 && len(b.stack) == 0 && len(b.children) == 0)
    elem := child
    #reverse for step in path {
        root = builder_replace_child(b, step.node, step.index, elem) or_return
        elem = node_element(root)
    }
    return root, nil
}

// Builds a tree with every token directly under one Root node.
build_flat :: proc(src: string, toks: []Token, allocator := context.allocator) -> (tree: ^Green_Tree, err: mem.Allocator_Error) {
    tree = tree_create(src, allocator) or_return
    b: Green_Builder
    builder_init(&b, tree)
    defer builder_destroy(&b)
    builder_start_node(&b, .Root)
    for tok in toks {
        builder_token(&b, tok.kind, tok.flags, tok.len)
    }
    if err = builder_finish_node(&b); err != nil {
        tree_destroy(tree, allocator)
        return nil, err
    }
    return tree, nil
}

// The text under the tree's root. Equal to the source when the tree is whole.
tree_root_text :: proc "contextless" (tree: ^Green_Tree) -> string {
    if tree.root == nil {
        return ""
    }
    return tree.text[:min(int(tree.root.text_len), len(tree.text))]
}
