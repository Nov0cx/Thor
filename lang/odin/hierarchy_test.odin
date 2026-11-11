package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

@(private = "file")
ask :: proc(e: ^Engine, kind: lang.Request_Kind, source, needle: string, skip := 0, query := "", workspace := "", path := "buffer.odin") -> lang.Result {
    req := lang.Request{
        kind = kind,
        path = path,
        ext = ".odin",
        source = source,
        offset = strings.index(source, needle) + skip,
        workspace = workspace,
        query = query,
    }
    req.end = req.offset
    res := lang.Result{kind = kind}
    resolve(e, &req, &res)
    return res
}

@(private = "file")
free_result :: proc(res: ^lang.Result) {
    for s in res.symbols {
        delete(s.name)
        delete(s.kind)
        delete(s.signature)
        delete(s.path)
    }
    delete(res.symbols)
    delete(res.ranges)
    delete(res.lenses)
    res^ = {}
}

@(private = "file")
expect_names :: proc(t: ^testing.T, res: ^lang.Result, want: []string, loc := #caller_location) {
    testing.expectf(t, len(res.symbols) == len(want), "rows: got %d, want %d", len(res.symbols), len(want), loc = loc)
    for name in want {
        found := false
        for s in res.symbols {
            if s.name == name {
                found = true
            }
        }
        testing.expectf(t, found, "missing %q", name, loc = loc)
    }
}

CALLS_SRC :: "package demo\n\nleaf :: proc() {}\n\nmid :: proc() {\n\tleaf()\n\tleaf()\n}\n\ntop :: proc() {\n\tmid()\n\tleaf()\n\tlen(\"x\")\n}\n\nunused :: proc() {\n\t_ = leaf\n}\n"

@(test)
test_call_hierarchy_incoming :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := ask(e, .Call_Hierarchy, CALLS_SRC, "leaf ::")
    defer free_result(&res)
    testing.expect(t, res.ok)
    expect_names(t, &res, {"mid", "top"})
    for s in res.symbols {
        testing.expect_value(t, s.kind, "function")
        testing.expect(t, s.line > 0)
    }

    // From a call, and from inside the body, the answer names the same procedure.
    res2 := ask(e, .Call_Hierarchy, CALLS_SRC, "leaf()")
    defer free_result(&res2)
    expect_names(t, &res2, {"mid", "top"})

    res3 := ask(e, .Call_Hierarchy, CALLS_SRC, "\t_ = leaf", 1)
    defer free_result(&res3)
    testing.expect(t, !res3.ok || len(res3.symbols) == 0 || res3.symbols[0].name != "")
}

@(test)
test_call_hierarchy_outgoing :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := ask(e, .Call_Hierarchy, CALLS_SRC, "top ::", query = "down")
    defer free_result(&res)
    testing.expect(t, res.ok)
    // `len` is a builtin and has no declaration to show.
    expect_names(t, &res, {"mid", "leaf"})

    none := ask(e, .Call_Hierarchy, CALLS_SRC, "leaf ::", query = "down")
    defer free_result(&none)
    testing.expect(t, !none.ok)
}

@(test)
test_call_hierarchy_ignores_non_procedures :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := ask(e, .Call_Hierarchy, "package demo\n\nCount :: 3\n", "Count")
    defer free_result(&res)
    testing.expect(t, !res.ok)
}

TYPES_SRC :: "package demo\n\nBase :: struct {\n\tid: int,\n}\n\nNamed :: struct {\n\tusing base: Base,\n\tname: string,\n}\n\nPlayer :: struct {\n\tusing named: Named,\n}\n\nOther :: struct {\n\tbase: Base,\n}\n"

@(test)
test_type_hierarchy :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    up := ask(e, .Type_Hierarchy, TYPES_SRC, "Player ::")
    defer free_result(&up)
    testing.expect(t, up.ok)
    expect_names(t, &up, {"Named"})

    down := ask(e, .Type_Hierarchy, TYPES_SRC, "Base ::", query = "down")
    defer free_result(&down)
    testing.expect(t, down.ok)
    // `Other` holds a Base without `using`.
    expect_names(t, &down, {"Named"})

    mid_up := ask(e, .Type_Hierarchy, TYPES_SRC, "Named ::")
    defer free_result(&mid_up)
    expect_names(t, &mid_up, {"Base"})

    none := ask(e, .Type_Hierarchy, TYPES_SRC, "Base ::")
    defer free_result(&none)
    testing.expect(t, !none.ok)
}

@(test)
test_type_hierarchy_across_files :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := fixture(t, "type_hierarchy_files", {{"sub.odin", "package demo\n\nChild :: struct {\n\tusing base: Base,\n}\n"}})
    defer os.remove_all(root)

    src := "package demo\n\nBase :: struct {\n\tid: int,\n}\n"
    res := ask(e, .Type_Hierarchy, src, "Base ::", query = "down", workspace = root, path = fixture_path(root, "main.odin"))
    defer free_result(&res)
    testing.expect(t, res.ok)
    expect_names(t, &res, {"Child"})
    testing.expect(t, strings.has_suffix(res.symbols[0].path, "sub.odin"))
}

IMPL_SRC :: "package demo\n\nsized_a :: proc(x: int) {}\nsized_b :: proc(x: string) {}\n\nsizes :: proc{sized_a, sized_b}\n\nShape :: union {\n\tCircle,\n\tSquare,\n\tint,\n}\n\nCircle :: struct {\n\tr: f32,\n}\n\nSquare :: struct {\n\ts: f32,\n}\n"

@(test)
test_implementations_group_members :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := ask(e, .Implementations, IMPL_SRC, "sizes ::")
    defer free_result(&res)
    testing.expect(t, res.ok)
    expect_names(t, &res, {"sized_a", "sized_b"})
}

@(test)
test_implementations_holding_groups :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := ask(e, .Implementations, IMPL_SRC, "sized_b ::")
    defer free_result(&res)
    testing.expect(t, res.ok)
    expect_names(t, &res, {"sizes"})
}

@(test)
test_implementations_union_variants :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := ask(e, .Implementations, IMPL_SRC, "Shape ::")
    defer free_result(&res)
    testing.expect(t, res.ok)
    // `int` is a basic type and has no declaration here.
    expect_names(t, &res, {"Circle", "Square"})
}

@(test)
test_implementations_embedding_types :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := ask(e, .Implementations, TYPES_SRC, "Base ::")
    defer free_result(&res)
    expect_names(t, &res, {"Named"})
}

@(test)
test_selection_range_chain :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nadd :: proc(a, b: int) -> int {\n\treturn a + b\n}\n"
    res := ask(e, .Selection_Range, src, "a + b")
    defer free_result(&res)
    testing.expect(t, res.ok)
    testing.expect(t, len(res.ranges) >= 4, "expected a token, an expression, a statement and a declaration")
    at := strings.index(src, "a + b")
    testing.expect_value(t, res.ranges[0], lang.Text_Range{at, at + 1})
    for r, i in res.ranges {
        testing.expectf(t, r.start >= 0 && r.end <= len(src) && r.start < r.end, "range %d is empty or outside the buffer", i)
        if i > 0 {
            prev := res.ranges[i - 1]
            testing.expectf(t, r.start <= prev.start && r.end >= prev.end && r != prev, "range %d does not grow", i)
        }
        if i > 0 {
            testing.expect(t, r.start != r.end)
        }
    }
    binary     := lang.Text_Range{at, at + len("a + b")}
    has_binary := false
    for r in res.ranges {
        has_binary ||= r == binary
    }
    testing.expect(t, has_binary, "the binary expression must be one of the steps")
    last := res.ranges[len(res.ranges) - 1]
    testing.expect_value(t, src[last.start:last.end], strings.trim_space(src))
}

@(test)
test_selection_range_from_selection :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src  := "package demo\n\nmain :: proc() {\n\tx := (1 + 2) * 3\n}\n"
    from := strings.index(src, "1 + 2")
    req  := lang.Request{kind = .Selection_Range, path = "buffer.odin", ext = ".odin", source = src, offset = from, end = from + len("1 + 2")}
    res  := lang.Result{kind = .Selection_Range}
    resolve(e, &req, &res)
    defer free_result(&res)
    testing.expect(t, res.ok)
    for r in res.ranges {
        testing.expect(t, r.start <= from && r.end >= from + len("1 + 2"), "a step must hold the selection")
    }
    paren     := strings.index(src, "(1 + 2)")
    has_paren := false
    for r in res.ranges {
        has_paren ||= r == lang.Text_Range{paren, paren + len("(1 + 2)")}
    }
    testing.expect(t, has_paren, "the parenthesized expression must be a step")
}

LENS_SRC :: "package demo\n\nhelper :: proc() -> int {\n\treturn 1\n}\n\nMode :: enum {\n\tA,\n}\n\nunused :: proc() {}\n\nmain :: proc() {\n\t_ = helper()\n\t_ = helper()\n\tm: Mode\n\t_ = m\n}\n"

@(test)
test_code_lens_counts :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := ask(e, .Code_Lens, LENS_SRC, "package")
    defer free_result(&res)
    testing.expect(t, res.ok)
    lens_src := LENS_SRC
    counts   := map[string]int{}
    defer delete(counts)
    for l in res.lenses {
        counts[lens_src[l.start:l.end]] = l.count
    }
    testing.expect_value(t, len(res.lenses), 4)
    testing.expect_value(t, counts["helper"], 2)
    testing.expect_value(t, counts["Mode"], 1)
    testing.expect_value(t, counts["unused"], 0)
    testing.expect_value(t, counts["main"], 0)
    for l, i in res.lenses {
        if i > 0 {
            testing.expect(t, l.start > res.lenses[i - 1].start, "lenses must ascend")
        }
    }
}

@(test)
test_code_lens_counts_other_files :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := fixture(t, "code_lens_files", {{"use.odin", "package demo\n\nrun :: proc() {\n\t_ = helper()\n}\n"}})
    defer os.remove_all(root)

    src := "package demo\n\nhelper :: proc() -> int {\n\treturn 1\n}\n"
    res := ask(e, .Code_Lens, src, "package", workspace = root, path = fixture_path(root, "main.odin"))
    defer free_result(&res)
    testing.expect_value(t, len(res.lenses), 1)
    testing.expect_value(t, res.lenses[0].count, 1)
}

@(test)
test_engine_supports_new_kinds :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    for kind in ([]lang.Request_Kind{.Call_Hierarchy, .Type_Hierarchy, .Implementations, .Selection_Range, .Code_Lens}) {
        testing.expectf(t, supports(e, ".odin", kind), "%v must be answered", kind)
    }
}

@(test)
test_code_lens_count_cache_reuse_and_invalidate :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := fixture(t, "code_lens_cache", {{"use.odin", "package demo\n\nrun :: proc() {\n\t_ = helper()\n}\n"}})
    defer os.remove_all(root)
    use_path := fixture_path(root, "use.odin")

    src       := "package demo\n\nhelper :: proc() -> int {\n\treturn 1\n}\n"
    main_path := fixture_path(root, "main.odin")
    for _ in 0 ..< 3 {
        res := ask(e, .Code_Lens, src, "package", workspace = root, path = main_path)
        testing.expect_value(t, len(res.lenses), 1)
        if len(res.lenses) == 1 {
            testing.expect_value(t, res.lenses[0].count, 1)
        }
        free_result(&res)
    }
    testing.expect_value(t, e.counts.builds, 1)

    // A sibling edit must show in the next count.
    edited := "package demo\n\nrun :: proc() {\n\t_ = helper()\n\t_ = helper()\n\t_ = helper()\n}\n"
    if err := os.write_entire_file(use_path, transmute([]byte)edited); err != nil {
        testing.fail_now(t, "could not rewrite the sibling")
    }
    notify(e, .Saved, use_path, ".odin", "", 0)
    res := ask(e, .Code_Lens, src, "package", workspace = root, path = main_path)
    defer free_result(&res)
    testing.expect_value(t, len(res.lenses), 1)
    if len(res.lenses) == 1 {
        testing.expect_value(t, res.lenses[0].count, 3)
    }
    testing.expect_value(t, e.counts.builds, 2)
}
