package odinsyntax

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

// Rounds of random edits per file in `test_reparse_random_edits_match_cold`.
@(private = "file")
REPARSE_ROUNDS :: #config(SYNTAX_REPARSE_ROUNDS, 400)

@(private = "file")
REPARSE_SEED :: #config(SYNTAX_REPARSE_SEED, 0x7265_7061)

// Why `got` is not the parse `parse(src)` makes, or "" when it is.
@(private = "file")
cold_mismatch :: proc(got: Parse, src: string) -> string {
    cold, err := parse(src)
    if err != nil {
        return "cold parse failed"
    }
    defer parse_destroy(&cold)
    if got.tree.text != src {
        return "tree text is not the source"
    }
    if msg := green_diff(got.tree.root, cold.tree.root, 0); msg != "" {
        return msg
    }
    if len(got.errors) != len(cold.errors) {
        return fmt.tprintf("%d errors, cold parse has %d: %v vs %v", len(got.errors), len(cold.errors), got.errors, cold.errors)
    }
    for e, i in got.errors {
        if e != cold.errors[i] {
            return fmt.tprintf("error %d is %v, cold parse has %v", i, e, cold.errors[i])
        }
    }
    return ""
}

// The first difference between two green trees, or "" when they are equal.
@(private = "file")
green_diff :: proc(a, b: ^Green_Node, offset: u32) -> string {
    if a.kind != b.kind || a.text_len != b.text_len {
        return fmt.tprintf("node %v+%d at %d, cold parse has %v+%d", a.kind, a.text_len, offset, b.kind, b.text_len)
    }
    ak, bk := green_children(a), green_children(b)
    if len(ak) != len(bk) {
        return fmt.tprintf("%v at %d has %d children, cold parse has %d", a.kind, offset, len(ak), len(bk))
    }
    pos := offset
    for child, i in ak {
        an, a_node := element_node(child)
        bn, b_node := element_node(bk[i])
        switch {
        case a_node && b_node:
            if msg := green_diff(an, bn, pos); msg != "" {
                return msg
            }
        case a_node != b_node:
            return fmt.tprintf("child %d of %v at %d is a node in one tree only", i, a.kind, offset)
        case child != bk[i]:
            at, _ := element_token(child)
            bt, _ := element_token(bk[i])
            return fmt.tprintf("token %v at %d, cold parse has %v", at, pos, bt)
        }
        pos += element_len(child)
    }
    return ""
}

// s with the first `old` replaced by `new`, in the temp allocator.
@(private = "file")
swap :: proc(s, old, new: string) -> string {
    out, _ := strings.replace(s, old, new, 1, context.temp_allocator)
    return out
}

@(private = "file")
read_lf :: proc(path: string) -> (string, bool) {
    data, err := os.read_entire_file(path, context.allocator)
    if err != nil {
        return "", false
    }
    src := string(data)
    if !strings.contains(src, "\r\n") {
        return src, true
    }
    out, _ := strings.replace_all(src, "\r\n", "\n")
    delete(data)
    return out, true
}

@(test)
test_reparse_paths :: proc(t: ^testing.T) {
    Case :: struct {
        name:     string,
        old, new: string,
        want:     Reparse_Kind,
    }
    BODY :: "package p\n\nf :: proc() {\n\tabc := \"ab\" // note\n\tswitch abc {\n\tcase \"x\":\n\t}\n\t#partial switch x {}\n}\n"
    cases := []Case {
        {"same text", BODY, BODY, .Unchanged},
        {"inside an identifier", BODY, swap(BODY, "abc :=", "aXbc :="), .Token},
        {"end of an identifier", BODY, swap(BODY, "abc :=", "abcd :="), .Token},
        {"inside a string", BODY, swap(BODY, "\"ab\"", "\"aXb\""), .Token},
        {"inside a comment", BODY, swap(BODY, "// note", "// noXte"), .Token},
        {"directive name", BODY, swap(BODY, "#partial", "#partiXal"), .Block},
        {"new statement", BODY, swap(BODY, "// note\n", "// note\n\ty := 2\n"), .Block},
        {"newline in whitespace", BODY, swap(BODY, "abc := ", "abc :=\n"), .Block},
        {"new case", BODY, swap(BODY, "\tcase \"x\":\n", "\tcase \"x\":\n\tcase \"y\":\n"), .Block},
        {"signature", BODY, swap(BODY, "proc()", "proc(a: int)"), .Full},
        {"open comment", BODY, swap(BODY, "// note", "/* note"), .Full},
        {"top level", BODY, strings.concatenate({BODY, "g :: 1\n"}, context.temp_allocator), .Full},
    }
    for c in cases {
        old, err := parse(c.old)
        if !testing.expect_value(t, err, nil) {
            return
        }
        got, how, rerr := reparse(&old, c.new)
        if !testing.expect_value(t, rerr, nil) {
            parse_destroy(&old)
            return
        }
        testing.expectf(t, how == c.want, "%s: reparse took the %v path, want %v", c.name, how, c.want)
        testing.expectf(t, old.tree == nil, "%s: the old parse is not consumed", c.name)
        msg := cold_mismatch(got, c.new)
        testing.expectf(t, msg == "", "%s: %s", c.name, msg)
        parse_destroy(&got)
    }
}

// Retypes a procedure body one byte at a time, then deletes it again; each step must equal a cold parse.
@(test)
test_reparse_typing_matches_cold :: proc(t: ^testing.T) {
    src, ok := read_lf("lang/odin/syntax/parser.odin")
    if !testing.expect(t, ok, "parser.odin not readable") {
        return
    }
    defer delete(src)
    head := "find_next :: proc(p: ^Parser, from: int) {\n"
    body_start := strings.index(src, head)
    if !testing.expect(t, body_start >= 0, "find_next not found") {
        return
    }
    body_start += len(head)
    body_end := body_start + strings.index(src[body_start:], "\n}\n") + 1
    body := src[body_start:body_end]

    cur, err := parse(strings.concatenate({src[:body_start], src[body_end:]}, context.temp_allocator))
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer parse_destroy(&cur)
    counts: [Reparse_Kind]int
    step :: proc(t: ^testing.T, cur: ^Parse, text: string, counts: ^[Reparse_Kind]int) -> bool {
        next, how, err := reparse(cur, text)
        if !testing.expect_value(t, err, nil) {
            return false
        }
        cur^ = next
        counts[how] += 1
        if msg := cold_mismatch(cur^, text); msg != "" {
            testing.expectf(t, false, "%v reparse differs from a cold parse: %s", how, msg)
            return false
        }
        return true
    }
    for n in 1 ..= len(body) {
        text := strings.concatenate({src[:body_start], body[:n], src[body_end:]}, context.temp_allocator)
        if !step(t, &cur, text, &counts) {
            return
        }
    }
    for n := len(body) - 1; n >= 0; n -= 1 {
        text := strings.concatenate({src[:body_start], body[:n], src[body_end:]}, context.temp_allocator)
        if !step(t, &cur, text, &counts) {
            return
        }
        free_all(context.temp_allocator)
    }
    log.infof("typing %d bytes and deleting them: %v", len(body), counts)
    testing.expect(t, counts[.Token] + counts[.Block] > counts[.Full], "most keystrokes should not parse the whole file")
}

// Random edits applied one after another; each step must equal a cold parse.
@(test)
test_reparse_random_edits_match_cold :: proc(t: ^testing.T) {
    state := rand.create(REPARSE_SEED)
    context.random_generator = rand.default_random_generator(&state)
    alphabet := "\"'`/*\\\n\t {}()[].:;,#+-=xyz019"
    paths := []string{"lang/odin/syntax/parser.odin", "lang/odin/syntax/parse_expr.odin", "lang/odin/syntax/lexer.odin"}
    counts: [Reparse_Kind]int
    for path in paths {
        src, ok := read_lf(path)
        if !testing.expectf(t, ok, "%s not readable", path) {
            return
        }
        defer delete(src)
        buf := make([dynamic]u8, 0, len(src) + 1024)
        defer delete(buf)
        append(&buf, src)
        cur, err := parse(src)
        if !testing.expect_value(t, err, nil) {
            return
        }
        defer parse_destroy(&cur)
        for round in 0 ..< REPARSE_ROUNDS {
            at := rand.int_max(len(buf) + 1)
            switch rand.int_max(4) {
            case 0:
                if at < len(buf) {
                    ordered_remove(&buf, at)
                }
            case 1, 2:
                inject_at(&buf, at, alphabet[rand.int_max(len(alphabet))])
            case 3:
                if at < len(buf) {
                    n := min(1 + rand.int_max(24), len(buf) - at)
                    chunk := slice.clone(buf[at:][:n], context.temp_allocator)
                    inject_at(&buf, rand.int_max(len(buf) + 1), ..chunk)
                }
            }
            text := string(buf[:])
            next, how, rerr := reparse(&cur, text)
            if !testing.expect_value(t, rerr, nil) {
                return
            }
            cur = next
            counts[how] += 1
            if msg := cold_mismatch(cur, text); msg != "" {
                testing.expectf(t, false, "%s round %d: %v reparse differs from a cold parse: %s", path, round, how, msg)
                return
            }
            free_all(context.temp_allocator)
        }
    }
    log.infof("random edits: %v", counts)
}

// The base chain stops at MAX_GENERATIONS: the next edit parses the whole text.
@(test)
test_reparse_generation_bound :: proc(t: ^testing.T) {
    text := "package p\nf :: proc() {\n\tx := 1\n}\n"
    cur, err := parse(text)
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer parse_destroy(&cur)
    fulls := 0
    for i in 0 ..< 2 * MAX_GENERATIONS + 8 {
        text = swap(text, "x", "xx")
        next, how, rerr := reparse(&cur, text)
        if !testing.expect_value(t, rerr, nil) {
            return
        }
        cur = next
        testing.expectf(t, cur.tree.generation <= MAX_GENERATIONS, "edit %d: generation %d", i, cur.tree.generation)
        if how == .Full {
            fulls += 1
            testing.expect_value(t, cur.tree.generation, 0)
        }
    }
    testing.expect_value(t, fulls, 2)
}

// Logs the cost of one keystroke in a large file.
@(test)
test_reparse_speed :: proc(t: ^testing.T) {
    src, ok := read_lf("editview/editor.odin")
    if !ok {
        return
    }
    defer delete(src)
    anchor := strings.index(src, "\n\treturn")
    if anchor < 0 {
        anchor = strings.index(src, "\n    return")
    }
    if !testing.expect(t, anchor >= 0, "no return statement in editor.odin") {
        return
    }
    cur, err := parse(src)
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer parse_destroy(&cur)
    typed := "x := foo(bar, 1) // and a comment\n"
    times := make([dynamic]time.Duration, 0, len(typed), context.temp_allocator)
    for n in 1 ..= len(typed) {
        text := strings.concatenate({src[:anchor + 1], typed[:n], src[anchor + 1:]}, context.temp_allocator)
        start := time.tick_now()
        next, _, rerr := reparse(&cur, text)
        elapsed := time.tick_since(start)
        if !testing.expect_value(t, rerr, nil) {
            return
        }
        cur = next
        append(&times, elapsed)
    }
    slice.sort(times[:])
    log.infof(
        "editor.odin: %d keystrokes, median %.3f ms, p95 %.3f ms",
        len(times), time.duration_milliseconds(times[len(times) / 2]), time.duration_milliseconds(times[len(times) * 95 / 100]),
    )
}

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

