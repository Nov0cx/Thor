package odin

import "core:slice"
import "core:strings"
import "core:testing"

import lang ".."

@(private)
ACTION_CONFIG :: `return { target = { os = "windows", arch = "amd64" } }`

// The quick fixes for `source` with the caret at the `skip`th occurrence of `marker`.
@(private)
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

@(private)
free_actions :: proc(res: ^lang.Result) {
    for a in res.actions {
        free_action(a)
    }
    delete(res.actions)
}

@(private)
titles :: proc(res: ^lang.Result) -> []string {
    out := make([]string, len(res.actions), context.temp_allocator)
    for a, i in res.actions {
        out[i] = a.title
    }
    return out
}

// `source` after the action titled `title`; "" when there is none.
@(private)
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

@(test)
test_action_struct_fields :: proc(t: ^testing.T) {
    SRC :: `package app

E :: enum { A, B }
S :: struct { a: int, b: string, e: E, p: ^S }

f :: proc() {
    one := S{b = "x"}
    empty := S{}
    many := S{
        a = 1,
    }
    typed: S = {}
    _, _, _, _ = one, empty, many, typed
}
`
    root := fixture(t, "action_struct_fields", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    one := actions_at(t, e, root, SRC, `b = "x"`)
    defer free_actions(&one)
    got := applied(t, &one, SRC, "Add 3 missing fields")
    testing.expect(t, strings.contains(got, `one := S{b = "x", a = 0, e = .A, p = nil}`), got)

    empty := actions_at(t, e, root, SRC, "S{}")
    defer free_actions(&empty)
    got = applied(t, &empty, SRC, "Add 4 missing fields")
    testing.expect(t, strings.contains(got, `empty := S{a = 0, b = "", e = .A, p = nil}`), got)

    many := actions_at(t, e, root, SRC, "a = 1")
    defer free_actions(&many)
    got = applied(t, &many, SRC, "Add 3 missing fields")
    testing.expect(t, strings.contains(got, "many := S{\n        a = 1,\n        b = \"\",\n        e = .A,\n        p = nil,\n    }"), got)

    typed := actions_at(t, e, root, SRC, "{}", 1)
    defer free_actions(&typed)
    got = applied(t, &typed, SRC, "Add 4 missing fields")
    testing.expectf(t, strings.contains(got, `typed: S = {a = 0, b = "", e = .A, p = nil}`), "%s", got)
}

@(test)
test_action_or_return :: proc(t: ^testing.T) {
    SRC :: `package app

Error :: enum { None, Bad }
two :: proc() -> (int, Error) { return 1, .None }

f :: proc() -> Error {
    x := two()
    _ = x
    return .None
}
g :: proc() -> bool {
    y := two()
    _ = y
    return true
}
`
    root := fixture(t, "action_or_return", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    res := actions_at(t, e, root, SRC, "x := two")
    defer free_actions(&res)
    got := applied(t, &res, SRC, "Add or_return")
    testing.expect(t, strings.contains(got, "x := two() or_return\n"), got)

    wrong := actions_at(t, e, root, SRC, "y := two")
    defer free_actions(&wrong)
    testing.expect(t, !slice.contains(titles(&wrong), "Add or_return"), "no or_return when the result cannot take the error")
}

@(test)
test_action_create_decl :: proc(t: ^testing.T) {
    SRC :: `package app

import "../lib"

f :: proc(count: int, name: string, h: lib.Handle) {
    ok: bool = check(count, name, h, 2.5)
    p := Point{x = 1, label = "a"}
    total = count
    _ = ok
    _ = p
    take(missing)
}

take :: proc(s: string) {}
`
    root := fixture(t, "action_create_decl", {
        {".thor/odin-analyzer.lua", ACTION_CONFIG},
        {"lib/lib.odin", "package lib\n\nHandle :: distinct int\n"},
    })
    e := engine_create()
    defer engine_destroy(e)

    call := actions_at(t, e, root, SRC, "check(")
    defer free_actions(&call)
    got := applied(t, &call, SRC, "Create procedure 'check'")
    testing.expect(t, strings.contains(got, "\n}\n\ncheck :: proc(count: int, name: string, h: lib.Handle, p4: f64) -> bool {\n    unimplemented()\n}\n\ntake ::"), got)

    lit := actions_at(t, e, root, SRC, "Point{")
    defer free_actions(&lit)
    got = applied(t, &lit, SRC, "Create struct 'Point'")
    testing.expect(t, strings.contains(got, "\n}\n\nPoint :: struct {\n    x: int,\n    label: string,\n}\n\ntake ::"), got)

    store := actions_at(t, e, root, SRC, "total")
    defer free_actions(&store)
    got = applied(t, &store, SRC, "Declare 'total' with :=")
    testing.expect(t, strings.contains(got, "    total := count\n"), got)

    variable := actions_at(t, e, root, SRC, "missing")
    defer free_actions(&variable)
    got = applied(t, &variable, SRC, "Create variable 'missing'")
    testing.expect(t, strings.contains(got, "    missing: string\n    take(missing)\n"), got)
}

@(test)
test_action_compiler_lines :: proc(t: ^testing.T) {
    SRC :: `package app

f :: proc(n: int, s: []int) -> int {
    n += 1
    return n + len(s)
}

g :: proc() {
    x := 5
    x := 6
    _ = x
}

h :: proc(n: int) { n += 1 }
`
    root := fixture(t, "action_compiler_lines", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    at :: proc(src, marker: string, skip := 0) -> int {
        from := 0
        for _ in 0 ..< skip {
            from += strings.index(src[from:], marker) + 1
        }
        return from + strings.index(src[from:], marker)
    }
    run :: proc(e: ^Engine, root: string, offset: int, message: string) -> lang.Result {
        diags := []lang.Diagnostic_Ref{{start = offset, end = offset + 1, severity = .Error, message = message}}
        req := lang.Request {
            kind        = .Code_Actions,
            path        = fixture_path(root, "app/main.odin"),
            ext         = ".odin",
            source      = SRC,
            workspace   = root,
            offset      = offset,
            end         = offset,
            diagnostics = diags,
        }
        res: lang.Result
        code_actions(e, &req, &res)
        return res
    }

    res := run(e, root, at(SRC, "n += 1"), "Cannot assign to 'n' which is a procedure parameter")
    want, _ := strings.replace(SRC, "    n += 1\n    return", "    n := n\n    n += 1\n    return", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Copy parameter 'n' into a local variable"), want)
    free_actions(&res)

    res = run(e, root, at(SRC, "x := 6"), "Redeclaration of 'x' in this scope")
    want, _ = strings.replace(SRC, "x := 6", "x = 6", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Assign to the existing 'x' instead of declaring it again"), want)
    free_actions(&res)

    // A body on the line of its parameters gets no fix.
    res = run(e, root, at(SRC, "n += 1", 1), "Cannot assign to 'n' which is a procedure parameter")
    for a in res.actions {
        testing.expect(t, !strings.has_prefix(a.title, "Copy parameter"), "one-line body")
    }
    free_actions(&res)
}

@(test)
test_action_missing_comma :: proc(t: ^testing.T) {
    SRC :: "package app\n\nE :: enum {\n    A,\n    B // last\n}\n"
    root := fixture(t, "action_comma", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    offset := strings.index(SRC, "\n}")
    diags := []lang.Diagnostic_Ref{{start = offset, end = offset + 1, severity = .Warning, message = "Expected a comma, got a newline"}}
    req := lang.Request {
        kind        = .Code_Actions,
        path        = fixture_path(root, "app/main.odin"),
        ext         = ".odin",
        source      = SRC,
        workspace   = root,
        offset      = offset,
        end         = offset,
        diagnostics = diags,
    }
    res: lang.Result
    code_actions(e, &req, &res)
    defer free_actions(&res)
    want, _ := strings.replace(SRC, "B // last", "B, // last", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Add the missing trailing comma"), want)
}

@(test)
test_action_unneeded_semicolon :: proc(t: ^testing.T) {
    SRC :: "package app\n\nf :: proc() {\n    x := 1 ;\n    _ = x\n}\n"
    root := fixture(t, "action_semicolon", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    offset := strings.index_byte(SRC, ';')
    diags := []lang.Diagnostic_Ref{{start = offset, end = offset + 1, severity = .Warning, message = "Found unneeded semicolon"}}
    req := lang.Request {
        kind        = .Code_Actions,
        path        = fixture_path(root, "app/main.odin"),
        ext         = ".odin",
        source      = SRC,
        workspace   = root,
        offset      = offset,
        end         = offset,
        diagnostics = diags,
    }
    res: lang.Result
    code_actions(e, &req, &res)
    defer free_actions(&res)
    want, _ := strings.replace(SRC, " ;", "", 1, context.temp_allocator)
    testing.expect_value(t, applied(t, &res, SRC, "Remove the unneeded semicolon"), want)
}

// The code actions for one diagnostic of `src` at the `skip`th occurrence of `marker`.
@(private = "file")
compiler_line_actions :: proc(t: ^testing.T, e: ^Engine, root, src, marker, message: string, severity := lang.Diagnostic_Severity.Error, skip := 0) -> lang.Result {
    from := 0
    for _ in 0 ..< skip {
        from += strings.index(src[from:], marker) + 1
    }
    i := strings.index(src[from:], marker)
    if i < 0 {
        testing.fail_now(t, "marker not found")
    }
    offset := from + i
    diags := []lang.Diagnostic_Ref{{start = offset, end = offset + 1, severity = severity, message = message}}
    req := lang.Request {
        kind        = .Code_Actions,
        path        = fixture_path(root, "app/main.odin"),
        ext         = ".odin",
        source      = src,
        workspace   = root,
        offset      = offset,
        end         = offset,
        diagnostics = diags,
    }
    res: lang.Result
    code_actions(e, &req, &res)
    return res
}

// True when `res` holds an action whose title starts with `prefix`.
@(private = "file")
has_action_prefix :: proc(res: ^lang.Result, prefix: string) -> bool {
    for a in res.actions {
        if strings.has_prefix(a.title, prefix) {
            return true
        }
    }
    return false
}

// Messages as `odin check` dev-2026-11-nightly:9a69916 words them.
@(test)
test_action_immutable_loop_variable :: proc(t: ^testing.T) {
    SRC :: `package app

S :: struct { a: int }
U :: union { int, f32 }

f :: proc(m: map[int]int, s: string, sp: []int) {
    arr := [3]S{}
    for x in arr {
        x.a = 3
    }
    for x, i in arr {
        i = 2
        _ = x
    }
    for k, v in m {
        k = 1
        v = 2
    }
    for y in sp {
        p := &y
        _ = p
    }
    u: U = 1
    #partial switch w in u {
    case int:
        w = 3
    }
    for r in s {
        r = 'c'
    }
    for z in 0 ..< 3 {
        z = 1
    }
    C :: 3
    C = 4
}

g :: proc(arr: [3]int, u: U) {
    for x in arr {
        x = 1
    }
    #partial switch w in u {
    case int:
        w = 3
    }
}
`
    root := fixture(t, "action_immutable_loop", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    Want :: struct {
        marker, message, title, from, to: string,
    }
    wants := []Want {
        {"x.a = 3", "Cannot assign to 'x.a'", "Declare 'x' as '&x' to make it mutable", "for x in arr {\n        x.a", "for &x in arr {\n        x.a"},
        {"v = 2", "Cannot assign to 'v'", "Declare 'v' as '&v' to make it mutable", "for k, v in m", "for k, &v in m"},
        {"&y", "Cannot take the pointer address of 'y'", "Declare 'y' as '&y' to make it mutable", "for y in sp", "for &y in sp"},
        {"w = 3", "Cannot assign to 'w'", "Declare 'w' as '&w' to make it mutable", "switch w in u {\n    case int:\n        w = 3\n    }\n    for r", "switch &w in u {\n    case int:\n        w = 3\n    }\n    for r"},
    }
    for w in wants {
        res := compiler_line_actions(t, e, root, SRC, w.marker, w.message)
        want, _ := strings.replace(SRC, w.from, w.to, 1, context.temp_allocator)
        testing.expect_value(t, applied(t, &res, SRC, w.title), want)
        free_actions(&res)
    }

    // An index, a map key, a rune, an interval value, a constant, a parameter array and a parameter subject.
    Miss :: struct {
        marker, message: string,
        skip:            int,
    }
    misses := []Miss {
        {"i = 2", "Cannot assign to 'i'", 0},
        {"k = 1", "Cannot assign to 'k'", 0},
        {"r = 'c'", "Cannot assign to 'r'", 0},
        {"z = 1", "Cannot assign to 'z'", 0},
        {"C = 4", "Cannot assign to 'C'", 0},
        {"x = 1", "Cannot assign to 'x'", 0},
        {"w = 3", "Cannot assign to 'w'", 1},
        {"x.a = 3", "Cannot assign to 'x.a' because it is a field", 0},
    }
    for m in misses {
        res := compiler_line_actions(t, e, root, SRC, m.marker, m.message, skip = m.skip)
        testing.expectf(t, !has_action_prefix(&res, "Declare '"), "%s: %v", m.marker, titles(&res))
        free_actions(&res)
    }
}
