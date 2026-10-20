package odinsyntax

import "core:testing"

@(test)
test_dump_flat :: proc(t: ^testing.T) {
    src := "x := 1\n"
    tree, err := build_flat(src, lex_all(src, context.temp_allocator))
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer tree_destroy(tree)
    want := `Root@0..7
  Ident@0..1 "x"
  Whitespace@1..2 " "
  Colon@2..3 ":"
  Eq@3..4 "="
  Whitespace@4..5 " "
  Integer@5..6 "1"
  Newline@6..7 "\n" {Implicit_Semi}
  EOF@7..7 ""
`
    got := debug_dump(tree.root, context.temp_allocator)
    testing.expect_value(t, got, want)
}

@(test)
test_builder_nesting :: proc(t: ^testing.T) {
    src := "a b c"
    toks := lex_all(src, context.temp_allocator)
    tree, err := tree_create()
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer tree_destroy(tree)
    b: Green_Builder
    builder_init(&b, tree)
    defer builder_destroy(&b)
    builder_start_node(&b, .Root)
    for tok, i in toks {
        if i == 2 {
            builder_start_node(&b, .Error)
        }
        testing.expect_value(t, builder_token(&b, tok.kind, tok.flags, token_text(src, tok)), nil)
        if i == 2 {
            testing.expect_value(t, builder_finish_node(&b), nil)
        }
    }
    testing.expect_value(t, builder_finish_node(&b), nil)

    testing.expect_value(t, tree.root.text_len, 5)
    testing.expect_value(t, green_text(tree.root, context.temp_allocator), src)
    inner, is_node := tree.root.children[2].(^Green_Node)
    if testing.expect(t, is_node) {
        testing.expect_value(t, inner.kind, Syntax_Kind.Error)
        testing.expect_value(t, inner.text_len, 1)
    }

    root := node_root(tree)
    tok, found := node_token_at(root, 2, context.temp_allocator)
    if testing.expect(t, found) {
        testing.expect_value(t, tok.green.text, "b")
        testing.expect_value(t, tok.offset, 2)
        testing.expect(t, tok.parent != nil && tok.parent.green.kind == .Error)
        testing.expect(t, tok.parent.parent != nil && tok.parent.parent.green.kind == .Root)
    }
    cover, covered := node_covering(root, 2, 3, context.temp_allocator)
    if testing.expect(t, covered) {
        ct, is_tok := cover.(Syntax_Token)
        testing.expect(t, is_tok && ct.green.text == "b")
    }
    wide, wide_ok := node_covering(root, 1, 4, context.temp_allocator)
    if testing.expect(t, wide_ok) {
        wn, is_n := wide.(Syntax_Node)
        testing.expect(t, is_n && wn.green.kind == .Root)
    }
}

@(test)
test_token_at_every_offset :: proc(t: ^testing.T) {
    src := "package p\n\nf :: proc() { /* c */ return }\n"
    toks := lex_all(src, context.temp_allocator)
    tree, err := build_flat(src, toks)
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer tree_destroy(tree)
    root := node_root(tree)
    for off in 0 ..< u32(len(src)) {
        want: Token
        for tok in toks {
            if tok.offset <= off && off < token_end(tok) {
                want = tok
                break
            }
        }
        got, found := node_token_at(root, off, context.temp_allocator)
        if !testing.expectf(t, found, "no token at %d", off) {
            return
        }
        testing.expectf(t, got.offset == want.offset && got.green.kind == want.kind,
            "offset %d: got %v@%d, want %v@%d", off, got.green.kind, got.offset, want.kind, want.offset)
    }
    last, found := node_token_at(root, u32(len(src)), context.temp_allocator)
    testing.expect(t, found && last.green.kind == .EOF)
    _, past := node_token_at(root, u32(len(src)) + 1, context.temp_allocator)
    testing.expect(t, !past)
}

@(test)
test_children_positions :: proc(t: ^testing.T) {
    src := "a+b"
    tree, err := build_flat(src, lex_all(src, context.temp_allocator))
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer tree_destroy(tree)
    root := node_root(tree)
    kids := node_children(&root, context.temp_allocator)
    testing.expect_value(t, len(kids), 4)
    for kid, i in kids {
        s, _ := element_range(kid)
        testing.expect_value(t, s, u32(min(i, 3)))
    }
}
