package odin

import "core:slice"
import "core:strings"
import "core:testing"

import lang ".."

@(private = "file")
ACTION_CONFIG :: `return { target = { os = "windows", arch = "amd64" } }`

// The quick fixes for `source` with the caret at the `skip`th occurrence of `marker`.
@(private = "file")
actions_at :: proc(t: ^testing.T, e: ^Engine, root, source, marker: string, skip := 0) -> lang.Result {
    at := -1
    from := 0
    for _ in 0 ..= skip {
        i := strings.index(source[from:], marker)
        if i < 0 {
            testing.fail_now(t, "marker not found")
        }
        at = from + i
        from = at + 1
    }
    req := lang.Request {
        kind      = .Code_Actions,
        path      = fixture_path(root, "app/main.odin"),
        ext       = ".odin",
        source    = source,
        workspace = root,
        offset    = at,
        end       = at,
    }
    res: lang.Result
    code_actions(e, &req, &res)
    return res
}

@(private = "file")
free_actions :: proc(res: ^lang.Result) {
    for a in res.actions {
        for edit in a.edits {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        delete(a.edits)
        delete(a.title)
        delete(a.kind)
    }
    delete(res.actions)
}

@(private = "file")
titles :: proc(res: ^lang.Result) -> []string {
    out := make([]string, len(res.actions), context.temp_allocator)
    for a, i in res.actions {
        out[i] = a.title
    }
    return out
}

// `source` after the action titled `title`; "" when there is none.
@(private = "file")
applied :: proc(t: ^testing.T, res: ^lang.Result, source, title: string, loc := #caller_location) -> string {
    for a in res.actions {
        if a.title != title {
            continue
        }
        out := source
        #reverse for edit in a.edits {
            testing.expectf(t, out[edit.start:edit.end] == edit.old_text, "old text %q does not match", edit.old_text, loc = loc)
            out = strings.concatenate({out[:edit.start], edit.new_text, out[edit.end:]}, context.temp_allocator)
        }
        return out
    }
    testing.expectf(t, false, "no action %q in %v", title, titles(res), loc = loc)
    return ""
}

@(test)
test_action_switch_cases :: proc(t: ^testing.T) {
    SRC :: `package app

E :: enum { A, B, C }

f :: proc(e: E, u: union { int, string }) {
    switch e {
    case .A:
    }
    switch v in u {
    case int:
        _ = v
    }
    switch e {}
}
`
    root := fixture(t, "action_switch", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    res := actions_at(t, e, root, SRC, "case .A")
    defer free_actions(&res)
    filled, _ := strings.replace(SRC, "    case .A:\n    }\n", "    case .A:\n    case .B:\n    case .C:\n    }\n", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Add 2 missing cases"), filled)
    partial, _ := strings.replace(SRC, "switch e {\n", "#partial switch e {\n", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Add #partial"), partial)

    union_res := actions_at(t, e, root, SRC, "_ = v")
    defer free_actions(&union_res)
    got := applied(t, &union_res, SRC, "Add missing case: string")
    testing.expect(t, strings.contains(got, "    case int:\n        _ = v\n    case string:\n    }\n"), got)

    inline_res := actions_at(t, e, root, SRC, "switch e {}")
    defer free_actions(&inline_res)
    got = applied(t, &inline_res, SRC, "Add 3 missing cases")
    testing.expect(t, strings.contains(got, "    switch e {\n    case .A:\n    case .B:\n    case .C:\n    }\n}"), got)
}

@(test)
test_action_unused_imports :: proc(t: ^testing.T) {
    SRC :: `package app

import "core:fmt"
import "core:strings"
import "core:mem"

f :: proc() {
    fmt.println()
}
`
    root := fixture(t, "action_imports", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    res := actions_at(t, e, root, SRC, "core:strings")
    defer free_actions(&res)
    one, _ := strings.replace(SRC, "import \"core:strings\"\n", "", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Remove unused import 'strings'"), one)
    both, _ := strings.replace(one, "import \"core:mem\"\n", "", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Remove 2 unused imports"), both)

    // Away from the imports only the bulk fix is offered.
    away := actions_at(t, e, root, SRC, "fmt.println")
    defer free_actions(&away)
    testing.expect(t, !slice.contains(titles(&away), "Remove unused import 'strings'"))
    testing.expect_value(t, applied(t, &away, SRC, "Remove 2 unused imports"), both)
}

@(test)
test_action_add_import :: proc(t: ^testing.T) {
    SRC :: `package app

f :: proc() {
    fmt.println("x")
}
`
    root := fixture(t, "action_add_import", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    res := actions_at(t, e, root, SRC, "mt.println")
    defer free_actions(&res)
    want, _ := strings.replace(SRC, "package app\n", "package app\n\nimport \"core:fmt\"\n", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Import \"core:fmt\""), want)

    WITH :: `package app

import "core:strings"

f :: proc() {
    _ = strings.clone
    fmt.println("x")
}
`
    with := actions_at(t, e, root, WITH, "fmt.println")
    defer free_actions(&with)
    want, _ = strings.replace(WITH, "import \"core:strings\"\n", "import \"core:strings\"\nimport \"core:fmt\"\n", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &with, WITH, "Import \"core:fmt\""), want)

    // A selector on a value is not a package qualifier.
    value := actions_at(t, e, root, WITH, "strings.clone")
    defer free_actions(&value)
    for title in titles(&value) {
        testing.expect(t, !strings.has_prefix(title, "Import"), title)
    }
}

@(test)
test_action_unused_variable :: proc(t: ^testing.T) {
    SRC :: `package app

g :: proc() -> (int, bool) { return 1, true }

f :: proc(xs: []int) {
    x := g()
    a, b := g()
    _ = b
    p, q := g()
    y: int
    for k in xs {}
}
`
    root := fixture(t, "action_unused_var", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    cases := [?]struct {
        marker, title, from, to: string,
    } {
        {"x := g()", "Assign the value of 'x' to '_'", "x := g()", "_ = g()"},
        {"a, b", "Rename 'a' to '_'", "a, b := g()", "_, b := g()"},
        {"p, q", "Rename 'p' to '_'", "p, q := g()", "_, q := g()"},
        {"y: int", "Remove 'y'", "    y: int\n", ""},
        {"for k", "Rename 'k' to '_'", "for k in", "for _ in"},
    }
    for c in cases {
        res := actions_at(t, e, root, SRC, c.marker)
        want, _ := strings.replace(SRC, c.from, c.to, 1, context.temp_allocator)
        testing.expect_value(t, applied(t, &res, SRC, c.title), want)
        free_actions(&res)
    }

    // The last name of a declaration whose other names are `_` makes it an assignment.
    BLANK :: `package app

g :: proc() -> (int, bool) { return 1, true }

f :: proc() {
    _, q := g()
}
`
    res := actions_at(t, e, root, BLANK, "q :=")
    defer free_actions(&res)
    want, _ := strings.replace(BLANK, "_, q := g()", "_, _ = g()", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, BLANK, "Assign the value of 'q' to '_'"), want)
}

@(test)
test_action_ignore :: proc(t: ^testing.T) {
    SRC :: `package app

f :: proc() {
    x := 1
    {
        x := 2
        _ = x
    }
    {
        // thor:ignore flow/dead-store
        x := 3
        _ = x
    }
    _ = x
}
`
    root := fixture(t, "action_ignore", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    res := actions_at(t, e, root, SRC, "x := 2")
    defer free_actions(&res)
    line, _ := strings.replace(SRC, "        x := 2\n", "        // thor:ignore vet/shadowing\n        x := 2\n", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Ignore vet/shadowing on this line"), line)
    file, _ := strings.replace(SRC, "package app\n", "package app\n// thor:ignore-file vet/shadowing\n", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Ignore vet/shadowing in this file"), file)

    // An ignore comment above the line takes the id.
    more := actions_at(t, e, root, SRC, "x := 3")
    defer free_actions(&more)
    added, _ := strings.replace(SRC, "// thor:ignore flow/dead-store", "// thor:ignore flow/dead-store vet/shadowing", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &more, SRC, "Ignore vet/shadowing on this line"), added)
}

@(test)
test_action_syntax_error :: proc(t: ^testing.T) {
    SRC :: `package app

f :: proc() {
    x := )
}
`
    root := fixture(t, "action_syntax", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    res := actions_at(t, e, root, SRC, "x :=")
    defer free_actions(&res)
    testing.expect_value(t, len(res.actions), 2)
    want, _ := strings.replace(SRC, "    x := )", "    // thor:ignore syntax/error\n    x := )", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Ignore syntax/error on this line"), want)
}
