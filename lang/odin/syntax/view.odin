package odinsyntax

// The typed views in views.odin are distinct Syntax_Nodes. Their accessors read direct children
// through a Child_Query and give the child a parent pointer to the view they were called on,
// so the view must outlive what they return. A missing child is `false`, never a crash.

Token_Set :: bit_set[Token_Kind; u128]

// Which direct children an accessor takes: nodes of `kinds` (or tokens of `tokens`) that come
// after the first token in `after` and before the next token in `before`.
Child_Query :: struct {
    kinds:  Kind_Set,
    tokens: Token_Set,
    after:  Token_Set, // empty: from the first child
    before: Token_Set, // empty: to the last child
    last:   bool,      // the last match, not the first
}

// The children of one node that a query matches, in order.
Child_Iter :: struct {
    parent:  ^Syntax_Node,
    query:   Child_Query,
    index:   int,
    offset:  u32,
    started: bool,
}

child_iter :: proc "contextless" (n: ^Syntax_Node, q: Child_Query) -> Child_Iter {
    return {parent = n, query = q, offset = n.offset, started = q.after == {}}
}

child_iter_next :: proc "contextless" (it: ^Child_Iter) -> (Syntax_Node, bool) {
    e, ok := next_match(it, false)
    if !ok {
        return {}, false
    }
    return e.(Syntax_Node)
}

find_child_node :: proc "contextless" (n: ^Syntax_Node, q: Child_Query) -> (found: Syntax_Node, ok: bool) {
    it := child_iter(n, q)
    for c in child_iter_next(&it) {
        found, ok = c, true
        if !q.last {
            break
        }
    }
    return
}

find_child_token :: proc "contextless" (n: ^Syntax_Node, q: Child_Query) -> (found: Syntax_Token, ok: bool) {
    it := child_iter(n, q)
    for {
        e, more := next_match(&it, true)
        if !more {
            return
        }
        found, ok = e.(Syntax_Token)
        if !q.last {
            return
        }
    }
}

@(private)
next_match :: proc "contextless" (it: ^Child_Iter, want_token: bool) -> (Syntax_Element, bool) {
    kids := green_children(it.parent.green)
    for it.index < len(kids) {
        child := kids[it.index]
        pos := it.offset
        it.index += 1
        it.offset += element_len(child)
        if n, is_node := element_node(child); is_node {
            if it.started && !want_token && n.kind in it.query.kinds {
                return Syntax_Node{n, pos, it.parent, it.parent.tree}, true
            }
            continue
        }
        tok, _ := element_token(child)
        if !it.started {
            it.started = tok.kind in it.query.after
            continue
        }
        if tok.kind in it.query.before {
            it.index = len(kids)
            break
        }
        if want_token && tok.kind in it.query.tokens {
            return Syntax_Token{tok, pos, it.parent, it.parent.tree}, true
        }
    }
    return nil, false
}

// The type of a field: after the ':' when there is one, else the only type it holds.
field_type :: proc "contextless" (n: ^Field) -> (Syntax_Node, bool) {
    if _, has_colon := find_child_token((^Syntax_Node)(n), {tokens = {.Colon}}); has_colon {
        return find_child_node((^Syntax_Node)(n), {kinds = KINDS_EXPR - {.Directive}, after = {.Colon}, before = {.Eq}})
    }
    return find_child_node((^Syntax_Node)(n), {kinds = KINDS_EXPR - {.Directive}, last = true})
}
