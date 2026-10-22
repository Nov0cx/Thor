package odinsyntax

import "core:mem"
import "core:strings"

// The changed range between two texts: [start, old_end) of the old text became [start, new_end) of the new one.
Text_Edit_Span :: struct {
    start, old_end, new_end: u32,
}

// How `reparse` made its tree.
Reparse_Kind :: enum u8 {
    Unchanged, // the text is the same; the old parse is given back
    Token,     // one token changed length
    Block,     // one `{ }` block was parsed again
    Full,      // the whole text was parsed again
}

// Base chain length at which `reparse` parses the whole text, so old arenas do not pile up.
MAX_GENERATIONS :: 32

// Spine depth plus block height above which a block is not parsed alone, so its nesting stays far below MAX_DEPTH.
@(private)
MAX_SPLICE_DEPTH :: 80

// The span between the common prefix and the common suffix of `old` and `new`.
text_diff :: proc "contextless" (old, new: string) -> Text_Edit_Span {
    n := min(len(old), len(new))
    start := 0
    for start < n && old[start] == new[start] {
        start += 1
    }
    tail := 0
    for tail < n - start && old[len(old) - 1 - tail] == new[len(new) - 1 - tail] {
        tail += 1
    }
    return {u32(start), u32(len(old) - tail), u32(len(new) - tail)}
}

// Parses `src` again from `old`, and gives the same parse as `parse(src)`.
// `old` is consumed: it becomes the base of the result or is destroyed. On an allocation error it is left as it was.
reparse :: proc(old: ^Parse, src: string, allocator := context.allocator) -> (result: Parse, how: Reparse_Kind, err: mem.Allocator_Error) {
    if old.tree == nil || old.tree.root == nil {
        result, err = parse(src, allocator)
        return result, .Full, err
    }
    if old.tree.text == src {
        result = old^
        old^ = {}
        return result, .Unchanged, nil
    }
    if old.tree.generation < MAX_GENERATIONS {
        edit := text_diff(old.tree.text, src)
        path := make([dynamic]Spine_Step, 0, 32, context.temp_allocator)
        starts := make([dynamic]u32, 0, 32, context.temp_allocator)
        descend(old.tree.root, edit.start, edit.old_end, &path, &starts)
        if patched, ok := patch_token(old, src, edit, path[:], starts[:], allocator); ok {
            old^ = {}
            return patched, .Token, nil
        }
        #reverse for step, i in path {
            child, is_node := element_node(green_children(step.node)[step.index])
            if !is_node || child.kind != .Block {
                continue
            }
            if reparsed, ok := reparse_block(old, src, edit, path[:i + 1], starts[i], allocator); ok {
                old^ = {}
                return reparsed, .Block, nil
            }
        }
    }
    result, err = parse(src, allocator)
    if err == nil {
        parse_destroy(old, allocator)
    }
    return result, .Full, err
}

// The path from `root` down to the deepest element that holds [start, end), and where each step's child starts.
@(private = "file")
descend :: proc(root: ^Green_Node, start, end: u32, path: ^[dynamic]Spine_Step, starts: ^[dynamic]u32) {
    node := root
    pos := u32(0)
    for {
        next: ^Green_Node
        for child, i in green_children(node) {
            n := element_len(child)
            if start >= pos && end <= pos + n {
                append(path, Spine_Step{node, i})
                append(starts, pos)
                next, _ = element_node(child)
                break
            }
            pos += n
        }
        if next == nil {
            return
        }
        node = next
    }
}

// Changes the length of the one token the edit falls inside, when that cannot change the parse.
@(private = "file")
patch_token :: proc(old: ^Parse, src: string, edit: Text_Edit_Span, path: []Spine_Step, starts: []u32, allocator: mem.Allocator) -> (result: Parse, ok: bool) {
    if len(path) == 0 {
        return
    }
    last := path[len(path) - 1]
    tok, is_tok := element_token(green_children(last.node)[last.index])
    if !is_tok || tok.flags & {.Unterminated, .Malformed} != {} {
        return
    }
    start := starts[len(starts) - 1]
    old_end := start + tok.len
    if edit.start <= start || edit.old_end > old_end {
        return
    }
    new_len := u32(i64(tok.len) + i64(edit.new_end) - i64(edit.old_end))
    #partial switch tok.kind {
    case .Whitespace, .Line_Comment, .Block_Comment:
        // The parser reads newlines in trivia.
        if strings.index_byte(old.tree.text[start:old_end], '\n') >= 0 || strings.index_byte(src[start:][:new_len], '\n') >= 0 {
            return
        }
    case .Ident:
        // The parser reads the name of a directive.
        if after_hash(old.tree.text, start) {
            return
        }
    case .String, .Rune, .Integer, .Float, .Imag:
    case:
        return
    }
    l: Lexer
    lexer_init(&l, src, int(start))
    relexed := lex_next(&l)
    if relexed.kind != tok.kind || relexed.flags != tok.flags || relexed.len != new_len {
        return
    }

    tree, err := tree_create_on(old.tree, src, allocator)
    if err != nil {
        return
    }
    b: Green_Builder
    builder_init(&b, tree, context.temp_allocator)
    defer builder_destroy(&b)
    root: ^Green_Node
    if root, err = builder_splice(&b, path, token_element(tok.kind, tok.flags, new_len)); err != nil {
        discard_tree(tree, allocator)
        return
    }
    tree.root = root
    delta := i64(new_len) - i64(tok.len)
    errors: []Syntax_Error
    if errors, err = make([]Syntax_Error, len(old.errors), tree_allocator(tree)); err != nil {
        discard_tree(tree, allocator)
        return
    }
    for e, i in old.errors {
        errors[i] = e
        errors[i].offset = shift(e.offset, old_end, delta)
        errors[i].end = shift(e.end, old_end, delta)
    }
    return Parse{tree, errors}, true
}

// Parses the block the last step of `path` names alone, when the edit is inside its braces.
@(private = "file")
reparse_block :: proc(old: ^Parse, src: string, edit: Text_Edit_Span, path: []Spine_Step, start: u32, allocator: mem.Allocator) -> (result: Parse, ok: bool) {
    step := path[len(path) - 1]
    #partial switch step.node.kind {
    case .Switch_Stmt, .Type_Switch_Stmt, .Foreign_Block:
        return
    }
    block, _ := element_node(green_children(step.node)[step.index])
    kids := green_children(block)
    if len(kids) < 2 {
        return
    }
    open_tok, open_ok := element_token(kids[0])
    close_tok, close_ok := element_token(kids[len(kids) - 1])
    if !open_ok || !close_ok || open_tok.kind != .Open_Brace || close_tok.kind != .Close_Brace {
        return
    }
    old_end := start + block.text_len
    if edit.start <= start || edit.old_end >= old_end || !braces_nest(block) {
        return
    }
    delta := i64(edit.new_end) - i64(edit.old_end)
    new_end := u32(i64(old_end) + delta)
    toks := lex_from(src[:new_end], int(start), {}, context.temp_allocator)
    if len(toks) < 3 || toks[0].kind != .Open_Brace || toks[len(toks) - 2].kind != .Close_Brace || token_end(toks[len(toks) - 2]) != new_end {
        return
    }
    // Recovery reads `open_braces > 0`. A depth of 1 or more up to the last '}' gives that test the
    // same answer here as in the whole file, where the braces around the block are open too.
    depth := 0
    for t, i in toks[:len(toks) - 1] {
        if .Unterminated in t.flags {
            return
        }
        #partial switch t.kind {
        case .Open_Brace:
            depth += 1
        case .Close_Brace:
            depth -= 1
            if depth <= 0 && i < len(toks) - 2 {
                return
            }
        }
    }
    if depth != 0 {
        return
    }
    in_proc := false
    for s in path {
        if s.node.kind == .Proc_Lit {
            in_proc = true
            break
        }
    }

    tree, err := tree_create_on(old.tree, src, allocator)
    if err != nil {
        return
    }
    p: Parser
    parser_init(&p, src[:new_end], toks, tree)
    defer parser_destroy(&p)
    elem, parsed := parse_block_only(&p, in_proc)
    node, is_node := element_node(elem)
    if !parsed || !is_node || p.emitted != len(toks) - 1 || p.open_braces != 0 || node.text_len != new_end - start ||
       !ends_in_close_brace(node) || len(path) + green_height(node) > MAX_SPLICE_DEPTH {
        discard_tree(tree, allocator)
        return
    }
    for e in p.errors {
        if e.offset <= start || e.end > new_end {
            discard_tree(tree, allocator)
            return
        }
    }
    root: ^Green_Node
    if root, err = builder_splice(&p.b, path, elem); err != nil {
        discard_tree(tree, allocator)
        return
    }
    tree.root = root

    before, after := 0, len(old.errors)
    for before < len(old.errors) && old.errors[before].offset <= start {
        before += 1
    }
    for after > before && old.errors[after - 1].offset >= old_end {
        after -= 1
    }
    errors: []Syntax_Error
    if errors, err = make([]Syntax_Error, before + len(p.errors) + len(old.errors) - after, tree_allocator(tree)); err != nil {
        discard_tree(tree, allocator)
        return
    }
    n := copy(errors, old.errors[:before])
    n += copy(errors[n:], p.errors[:])
    for e in old.errors[after:] {
        errors[n] = e
        errors[n].offset = shift(e.offset, old_end, delta)
        errors[n].end = shift(e.end, old_end, delta)
        n += 1
    }
    return Parse{tree, errors}, true
}

// Moves a position at or after `from` by `delta`.
@(private = "file")
shift :: #force_inline proc "contextless" (pos, from: u32, delta: i64) -> u32 {
    return u32(i64(pos) + delta) if pos >= from else pos
}

// Reports whether the text before `offset` ends in a '#', or in a comment that may hide one.
@(private = "file")
after_hash :: proc "contextless" (text: string, offset: u32) -> bool {
    for i := int(offset) - 1; i >= 0; i -= 1 {
        switch text[i] {
        case ' ', '\t', '\r', '\n':
            continue
        case '#', '/':
            return true
        }
        return false
    }
    return false
}

// Destroys a tree `reparse` gave up on, and not the base it shares.
@(private = "file")
discard_tree :: proc(tree: ^Green_Tree, allocator: mem.Allocator) {
    tree.base = nil
    tree_destroy(tree, allocator)
}

// Reports whether the braces under `block` stay open from its first token to its last one and close
// there, so the parse after it starts with the same `open_braces` as before it.
@(private = "file")
braces_nest :: proc(block: ^Green_Node) -> bool {
    Walk :: struct {
        depth: int,
        zeros: int, // closes that left the depth at 0 or below
    }
    walk :: proc(w: ^Walk, node: ^Green_Node) {
        for child in green_children(node) {
            if n, is_node := element_node(child); is_node {
                walk(w, n)
                continue
            }
            tok, _ := element_token(child)
            #partial switch tok.kind {
            case .Open_Brace:
                w.depth += 1
            case .Close_Brace:
                w.depth -= 1
                if w.depth <= 0 {
                    w.zeros += 1
                }
            }
        }
    }
    w: Walk
    walk(&w, block)
    // The one close to 0 is the block's own last '}'.
    return w.depth == 0 && w.zeros == 1 && ends_in_close_brace(block)
}

// Reports whether the last child of `node` is a '}' token.
@(private = "file")
ends_in_close_brace :: proc "contextless" (node: ^Green_Node) -> bool {
    kids := green_children(node)
    if len(kids) == 0 {
        return false
    }
    tok, is_tok := element_token(kids[len(kids) - 1])
    return is_tok && tok.kind == .Close_Brace
}

// Levels of nodes in the subtree under `node`, `node` included.
@(private)
green_height :: proc(node: ^Green_Node) -> int {
    height := 0
    for child in green_children(node) {
        if n, is_node := element_node(child); is_node {
            height = max(height, green_height(n))
        }
    }
    return height + 1
}
