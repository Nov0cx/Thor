package odinsyntax

import "core:fmt"
import "core:strings"
import "core:testing"

// What a test reads off a parse: the kinds of the root's nodes, of the first block's nodes,
// and the errors as `offset: message`.
@(private = "file")
Outline :: struct {
    top:    []Syntax_Kind,
    block:  []Syntax_Kind,
    errors: []string,
}

@(private = "file")
outline :: proc(t: ^testing.T, src: string, loc := #caller_location) -> Outline {
    result, err := parse(src)
    if !testing.expect_value(t, err, nil, loc) {
        return {}
    }
    defer parse_destroy(&result)
    testing.expect_value(t, tree_token_error(result.tree, lex_all(src, context.temp_allocator)), "", loc)
    out: Outline
    out.top = node_kinds(result.tree.root)
    if block := find_kind(result.tree.root, .Block); block != nil {
        out.block = node_kinds(block)
    }
    errors := make([]string, len(result.errors), context.temp_allocator)
    for e, i in result.errors {
        testing.expectf(t, e.offset <= e.end && int(e.end) <= len(src), "error range %d..%d outside the source", e.offset, e.end, loc = loc)
        errors[i] = fmt.tprintf("%d: %s", e.offset, error_message(e, context.temp_allocator))
    }
    out.errors = errors
    return out
}

@(private = "file")
node_kinds :: proc(node: ^Green_Node) -> []Syntax_Kind {
    out := make([dynamic]Syntax_Kind, 0, len(green_children(node)), context.temp_allocator)
    for child in green_children(node) {
        if n, ok := element_node(child); ok {
            append(&out, n.kind)
        }
    }
    return out[:]
}

@(private = "file")
find_kind :: proc(node: ^Green_Node, kind: Syntax_Kind) -> ^Green_Node {
    if node.kind == kind {
        return node
    }
    for child in green_children(node) {
        if n, ok := element_node(child); ok {
            if found := find_kind(n, kind); found != nil {
                return found
            }
        }
    }
    return nil
}

@(private = "file")
expect_kinds :: proc(t: ^testing.T, got, want: []Syntax_Kind, loc := #caller_location) {
    if !testing.expectf(t, len(got) == len(want), "got %v, want %v", got, want, loc = loc) {
        return
    }
    for k, i in want {
        testing.expectf(t, got[i] == k, "got %v, want %v", got, want, loc = loc)
    }
}

@(private = "file")
expect_errors :: proc(t: ^testing.T, got, want: []string, loc := #caller_location) {
    if !testing.expectf(t, len(got) == len(want), "got errors %v, want %v", got, want, loc = loc) {
        return
    }
    for e, i in want {
        testing.expect_value(t, got[i], e, loc = loc)
    }
}

@(test)
test_parse_valid_file_has_no_errors :: proc(t: ^testing.T) {
    src := `package demo

import "core:fmt"

Point :: struct {
    x, y: int,
}

@(private)
add :: proc(a, b: int) -> int {
    if a > b {
        return a + b * 2
    }
    for i in 0 ..< 10 do fmt.println(i)
    p := Point{x = 1, y = 2}
    return p.x
}
`
    o := outline(t, src)
    expect_kinds(t, o.top, {.Package_Decl, .Import_Decl, .Value_Decl, .Value_Decl})
    expect_kinds(t, o.block, {.If_Stmt, .Range_Stmt, .Value_Decl, .Return_Stmt})
    expect_errors(t, o.errors, {})
}

@(test)
test_recover_dangling_selector :: proc(t: ^testing.T) {
    o := outline(t, "package p\nf :: proc() {\n    a.\n    b := 1\n}\n")
    expect_kinds(t, o.block, {.Expr_Stmt, .Value_Decl})
    expect_errors(t, o.errors, {"30: expected a selector, got newline"})
}

@(test)
test_recover_two_dangling_selectors :: proc(t: ^testing.T) {
    o := outline(t, "package p\nf :: proc() {\n    a.\n    b.\n    c := 1\n}\n")
    expect_kinds(t, o.block, {.Expr_Stmt, .Expr_Stmt, .Value_Decl})
    expect_errors(t, o.errors, {"30: expected a selector, got newline", "37: expected a selector, got newline"})
}

@(test)
test_recover_missing_value :: proc(t: ^testing.T) {
    o := outline(t, "package p\nf :: proc() {\n    x :=\n    y := 2\n}\n")
    expect_kinds(t, o.block, {.Value_Decl, .Value_Decl})
    expect_errors(t, o.errors, {"32: expected an expression, got newline"})
}

@(test)
test_recover_unclosed_call_at_eof :: proc(t: ^testing.T) {
    o := outline(t, "package p\nf :: proc() {\n    foo(")
    expect_kinds(t, o.block, {.Expr_Stmt})
    expect_errors(t, o.errors, {"32: expected ')', got end of file"})
}

@(test)
test_recover_unclosed_call_keeps_next_line :: proc(t: ^testing.T) {
    o := outline(t, "package p\nf :: proc() {\n    foo(a, b\n    bar()\n}\ng :: 1\n")
    expect_kinds(t, o.top, {.Package_Decl, .Value_Decl, .Value_Decl})
    expect_kinds(t, o.block, {.Expr_Stmt, .Expr_Stmt})
    expect_errors(t, o.errors, {"41: expected ')', got identifier"})
}

@(test)
test_recover_bad_expr_keeps_braces :: proc(t: ^testing.T) {
    o := outline(t, "package p\nf :: proc() { x := (1 + ; y := 2 }\ng :: proc() {}\n")
    expect_kinds(t, o.top, {.Package_Decl, .Value_Decl, .Value_Decl})
    expect_kinds(t, o.block, {.Value_Decl, .Value_Decl})
    expect_errors(t, o.errors, {"34: expected an operand, got ';'"})
}

@(test)
test_recover_stray_close_brace :: proc(t: ^testing.T) {
    o := outline(t, "package p\n}\nx :: 1\n")
    expect_kinds(t, o.top, {.Package_Decl, .Error, .Value_Decl})
    expect_errors(t, o.errors, {"10: expected a statement, got '}'"})
}

@(test)
test_recover_missing_field_colon :: proc(t: ^testing.T) {
    o := outline(t, "package p\nS :: struct {\n    a: int\n    b int,\n}\nT :: 2\n")
    expect_kinds(t, o.top, {.Package_Decl, .Value_Decl, .Value_Decl})
    expect_errors(t, o.errors, {"34: expected ',', got newline", "41: expected ':', got identifier"})
}

@(test)
test_recover_missing_brace_keeps_file :: proc(t: ^testing.T) {
    o := outline(t, "package p\nf :: proc()\nx := 1\ng :: proc() {}\n")
    expect_kinds(t, o.top, {.Package_Decl, .Value_Decl, .Value_Decl, .Value_Decl})
}

@(test)
test_missing_package_still_parses :: proc(t: ^testing.T) {
    o := outline(t, "x :: 1\ny :: 2\n")
    expect_kinds(t, o.top, {.Value_Decl, .Value_Decl})
    expect_errors(t, o.errors, {"0: expected a package declaration at the start of the file"})
    empty := outline(t, "")
    expect_errors(t, empty.errors, {})
    comment := outline(t, "// only a comment\n")
    expect_errors(t, comment.errors, {})
}

@(test)
test_lexer_errors_are_reported :: proc(t: ^testing.T) {
    o := outline(t, "package p\nx := \"abc\ny :: 1\n")
    expect_kinds(t, o.top, {.Package_Decl, .Value_Decl, .Value_Decl})
    expect_errors(t, o.errors, {"15: unterminated string"})
    c := outline(t, "package p\n/* open")
    expect_errors(t, c.errors, {"10: unterminated block comment"})
}

@(test)
test_deep_nesting_does_not_overflow :: proc(t: ^testing.T) {
    for open in ([]string{"(", "[", "{", "^", "!", "proc(", "a.", "1+", "#type "}) {
        src := strings.concatenate({"package p\nf :: proc() {\n x := ", strings.repeat(open, 20000, context.temp_allocator), "\n}\n"}, context.temp_allocator)
        o := outline(t, src)
        testing.expectf(t, len(o.errors) > 0, "%q nested: no error", open)
        found := false
        for e in o.errors {
            found ||= strings.contains(e, "nested too deep")
        }
        testing.expectf(t, found, "%q nested: no depth error in %v", open, o.errors[:min(len(o.errors), 3)])
        free_all(context.temp_allocator)
    }
}

@(test)
test_trivia_stays_outside_nodes :: proc(t: ^testing.T) {
    src := "package p\n\n// doc\nx :: 1 // trailing\n"
    result, err := parse(src)
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer parse_destroy(&result)
    root := node_root(result.tree)
    kids := node_children(&root, context.temp_allocator)
    for kid in kids {
        node, is_node := kid.(Syntax_Node)
        if !is_node {
            continue
        }
        kids := green_children(node.green)
        for e in ([]Green_Element{kids[0], kids[len(kids) - 1]}) {
            if tok, is_tok := element_token(e); is_tok {
                testing.expectf(t, !token_is_trivia(tok.kind), "%v starts or ends with trivia %v", node.green.kind, tok.kind)
            }
        }
    }
    decl, found := node_covering(root, 18, 19, context.temp_allocator)
    if testing.expect(t, found) {
        tok, is_tok := decl.(Syntax_Token)
        testing.expect(t, is_tok && syntax_token_text(tok) == "x" && tok.parent.green.kind == .Ident)
    }
}
