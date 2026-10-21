package odinsyntax

import "core:strings"
import "core:testing"

@(test)
test_text_diff :: proc(t: ^testing.T) {
    Case :: struct {
        old, new: string,
        want:     Text_Edit_Span,
    }
    cases := []Case {
        {"abc", "abc", {3, 3, 3}},
        {"abc", "abXc", {2, 2, 3}},
        {"abc", "ac", {1, 2, 1}},
        {"abc", "aXc", {1, 2, 2}},
        {"abc", "Xabc", {0, 0, 1}},
        {"abc", "abcX", {3, 3, 4}},
        {"", "abc", {0, 0, 3}},
        {"abc", "", {0, 3, 0}},
        {"aaa", "aa", {2, 3, 2}},
    }
    for c in cases {
        testing.expectf(t, text_diff(c.old, c.new) == c.want, "%q -> %q: got %v, want %v", c.old, c.new, text_diff(c.old, c.new), c.want)
    }
}

@(test)
test_splice_shares_siblings :: proc(t: ^testing.T) {
    src := "package p\nf :: proc() {\n\tx := 1\n}\ng :: 2\n"
    old, err := parse(src)
    if !testing.expect_value(t, err, nil) {
        return
    }
    // Lengthen the `1` token to `12` along the spine Root -> ... -> Literal.
    path := make([dynamic]Spine_Step, context.temp_allocator)
    node := old.tree.root
    offset := u32(strings.index(src, "1\n}"))
    pos := u32(0)
    found := false
    for !found {
        for child, i in green_children(node) {
            n := element_len(child)
            if offset >= pos && offset < pos + n {
                append(&path, Spine_Step{node, i})
                if inner, is_node := element_node(child); is_node {
                    node = inner
                } else {
                    found = true
                }
                break
            }
            pos += n
        }
    }
    new_src := "package p\nf :: proc() {\n\tx := 12\n}\ng :: 2\n"
    tree, terr := tree_create_on(old.tree, new_src)
    if !testing.expect_value(t, terr, nil) {
        parse_destroy(&old)
        return
    }
    defer tree_destroy(tree)
    b: Green_Builder
    builder_init(&b, tree)
    defer builder_destroy(&b)
    last := path[len(path) - 1]
    tok, _ := element_token(green_children(last.node)[last.index])
    root, serr := builder_splice(&b, path[:], token_element(tok.kind, tok.flags, 2))
    if !testing.expect_value(t, serr, nil) {
        return
    }
    tree.root = root
    testing.expect_value(t, tree.generation, 1)
    testing.expect_value(t, tree_token_error(tree, lex_all(new_src, context.temp_allocator)), "")
    // The declaration after the edited one is the old node itself.
    old_kids, new_kids := green_children(old.tree.root), green_children(root)
    g_old, old_is_node := element_node(old_kids[len(old_kids) - 3])
    g_new, _ := element_node(new_kids[len(new_kids) - 3])
    testing.expect(t, old_is_node && g_old.kind == .Value_Decl && g_new == g_old)
}

