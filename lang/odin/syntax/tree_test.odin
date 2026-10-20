package odinsyntax

import "core:fmt"
import "core:strings"
import "core:testing"

// Why the tree's tokens are not `toks` one for one, or "" when they are.
tree_token_error :: proc(tree: ^Green_Tree, toks: []Token) -> string {
    Walk :: struct {
        toks: []Token,
        next: int,
        msg:  string,
    }
    walk :: proc(w: ^Walk, node: ^Green_Node, offset: u32) {
        pos := offset
        for child in green_children(node) {
            if w.msg != "" {
                return
            }
            if n, is_node := element_node(child); is_node {
                walk(w, n, pos)
            } else {
                tok, _ := element_token(child)
                if w.next >= len(w.toks) {
                    w.msg = fmt.tprintf("extra token %v@%d", tok.kind, pos)
                    return
                }
                want := w.toks[w.next]
                if tok.kind != want.kind || tok.flags != want.flags || tok.len != want.len || pos != want.offset {
                    w.msg = fmt.tprintf("token %d is %v@%d+%d, lexer has %v@%d+%d", w.next, tok.kind, pos, tok.len, want.kind, want.offset, want.len)
                    return
                }
                w.next += 1
            }
            pos += element_len(child)
        }
    }
    if tree.root == nil {
        return "no root"
    }
    if int(tree.root.text_len) != len(tree.text) {
        return fmt.tprintf("root covers %d bytes of %d", tree.root.text_len, len(tree.text))
    }
    w := Walk{toks = toks}
    walk(&w, tree.root, 0)
    if w.msg == "" && w.next != len(toks) {
        w.msg = fmt.tprintf("%d tokens missing", len(toks) - w.next)
    }
    return w.msg
}

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
    got := debug_dump(tree, context.temp_allocator)
    testing.expect_value(t, got, want)
}

@(test)
test_builder_nesting :: proc(t: ^testing.T) {
    src := "a b c"
    toks := lex_all(src, context.temp_allocator)
    tree, err := tree_create(src)
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
        builder_token(&b, tok.kind, tok.flags, tok.len)
        if i == 2 {
            testing.expect_value(t, builder_finish_node(&b), nil)
        }
    }
    testing.expect_value(t, builder_finish_node(&b), nil)

    testing.expect_value(t, tree.root.text_len, 5)
    testing.expect_value(t, tree_token_error(tree, toks), "")
    inner, is_node := element_node(green_children(tree.root)[2])
    if testing.expect(t, is_node) {
        testing.expect_value(t, inner.kind, Syntax_Kind.Error)
        testing.expect_value(t, inner.text_len, 1)
    }

    root := node_root(tree)
    tok, found := node_token_at(root, 2, context.temp_allocator)
    if testing.expect(t, found) {
        testing.expect_value(t, syntax_token_text(tok), "b")
        testing.expect_value(t, tok.offset, 2)
        testing.expect(t, tok.parent != nil && tok.parent.green.kind == .Error)
        testing.expect(t, tok.parent.parent != nil && tok.parent.parent.green.kind == .Root)
    }
    cover, covered := node_covering(root, 2, 3, context.temp_allocator)
    if testing.expect(t, covered) {
        ct, is_tok := cover.(Syntax_Token)
        testing.expect(t, is_tok && syntax_token_text(ct) == "b")
    }
    wide, wide_ok := node_covering(root, 1, 4, context.temp_allocator)
    if testing.expect(t, wide_ok) {
        wn, is_n := wide.(Syntax_Node)
        testing.expect(t, is_n && wn.green.kind == .Root)
    }
}

@(test)
test_builder_checkpoint_and_wrap :: proc(t: ^testing.T) {
    src := "a+b c"
    toks := lex_all(src, context.temp_allocator)
    tree, err := tree_create(src)
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer tree_destroy(tree)
    b: Green_Builder
    builder_init(&b, tree)
    defer builder_destroy(&b)
    builder_start_node(&b, .Root)
    cp := builder_checkpoint(&b)
    for tok in toks[:3] {
        builder_token(&b, tok.kind, tok.flags, tok.len)
    }
    builder_start_node_at(&b, cp, .Binary_Expr)
    testing.expect_value(t, builder_finish_node(&b), nil)
    for tok in toks[3:] {
        builder_token(&b, tok.kind, tok.flags, tok.len)
    }
    testing.expect_value(t, builder_wrap(&b, 2, 3, .Ident), nil)
    testing.expect_value(t, builder_wrap(&b, 0, 0, .Error), nil)
    testing.expect_value(t, builder_finish_node(&b), nil)

    want := `Root@0..5
  Error@0..0
  Binary_Expr@0..3
    Ident@0..1 "a"
    Add@1..2 "+"
    Ident@2..3 "b"
  Whitespace@3..4 " "
  Ident@4..5
    Ident@4..5 "c"
  EOF@5..5 "" {Implicit_Semi}
`
    testing.expect_value(t, debug_dump(tree, context.temp_allocator), want)
    testing.expect_value(t, tree_token_error(tree, toks), "")
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

@(test)
test_node_with_many_children :: proc(t: ^testing.T) {
    src := strings.repeat("x;", 40_000, context.temp_allocator)
    toks := lex_all(src, context.temp_allocator)
    tree, err := build_flat(src, toks)
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer tree_destroy(tree)
    testing.expect_value(t, len(green_children(tree.root)), len(toks))
    testing.expect_value(t, tree_token_error(tree, toks), "")
    last, found := node_token_at(node_root(tree), u32(len(src) - 1), context.temp_allocator)
    testing.expect(t, found && last.green.kind == .Semicolon && last.offset == u32(len(src) - 1))
}

@(test)
test_token_element_round_trip :: proc(t: ^testing.T) {
    e := token_element(.Block_Comment, {.Unterminated, .Implicit_Semi}, max(u32))
    tok, is_tok := element_token(e)
    _, is_node := element_node(e)
    testing.expect(t, is_tok && !is_node)
    testing.expect_value(t, tok, Green_Token{.Block_Comment, {.Unterminated, .Implicit_Semi}, max(u32)})
    testing.expect_value(t, element_len(e), max(u32))
}
