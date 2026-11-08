package odin

import "core:slice"
import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_refactor_inline_variable :: proc(t: ^testing.T) {
    SRC :: `package app

g :: proc() -> int { return 1 }

f :: proc(a, b: int) -> int {
    sum := a + b
    twice := sum * 2
    once := g()
    many := g()
    _ = many + many
    moved := a
    a = 3
    _ = moved
    return twice + once
}
`
    root := fixture(t, "refactor_inline", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    sum := actions_at(t, e, root, SRC, "sum :=")
    defer free_actions(&sum)
    got := applied(t, &sum, SRC, "Inline variable 'sum'")
    testing.expect(t, strings.contains(got, "{\n    twice := (a + b) * 2\n    once"), got)

    once := actions_at(t, e, root, SRC, "once", 1)
    defer free_actions(&once)
    got = applied(t, &once, SRC, "Inline variable 'once'")
    testing.expect(t, strings.contains(got, "return twice + g()\n"), got)
    testing.expect(t, !strings.contains(got, "once :="), got)

    many := actions_at(t, e, root, SRC, "many :=")
    defer free_actions(&many)
    testing.expect(t, !slice.contains(titles(&many), "Inline variable 'many'"), "a call used twice is not inlined")

    moved := actions_at(t, e, root, SRC, "moved :=")
    defer free_actions(&moved)
    testing.expect(t, !slice.contains(titles(&moved), "Inline variable 'moved'"), "a value whose local changes before the use is not inlined")
}

@(test)
test_refactor_if_switch :: proc(t: ^testing.T) {
    SRC :: `package app

E :: enum { A, B, C }

f :: proc(e: E) -> int {
    if e == .A {
        return 1
    } else if e == .B || e == .C {
        return 2
    } else {
        return 3
    }
}

g :: proc(e: E, n: int) -> int {
    switch e {
    case .A:
        return 1
    case .B, .C:
        return 2
    case:
        return 0
    }
    switch n {
    case 0 ..< 10:
        return 3
    }
    return n
}

h :: proc(xs: []E) {
    for x in xs {
        if x == .A {
            break
        } else if x == .B {
        }
    }
}
`
    root := fixture(t, "refactor_if_switch", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    chain := actions_at(t, e, root, SRC, "return 2")
    defer free_actions(&chain)
    got := applied(t, &chain, SRC, "Convert to switch")
    want := "    switch e {\n    case .A:\n        return 1\n    case .B, .C:\n        return 2\n    case:\n        return 3\n    }\n}"
    testing.expect(t, strings.contains(got, want), got)

    sw := actions_at(t, e, root, SRC, "case .B, .C")
    defer free_actions(&sw)
    got = applied(t, &sw, SRC, "Convert to if chain")
    want = "    if e == .A {\n        return 1\n    } else if e == .B || e == .C {\n        return 2\n    } else {\n        return 0\n    }\n    switch n"
    testing.expect(t, strings.contains(got, want), got)

    ranged := actions_at(t, e, root, SRC, "return 3", 1)
    defer free_actions(&ranged)
    got = applied(t, &ranged, SRC, "Convert to if chain")
    testing.expect(t, strings.contains(got, "    if n >= 0 && n < 10 {\n        return 3\n    }\n"), got)

    loop := actions_at(t, e, root, SRC, "break")
    defer free_actions(&loop)
    testing.expect(t, !slice.contains(titles(&loop), "Convert to switch"), "a break out of the loop keeps the if chain")
}

// The Resolve_Action result of `command` with `answer`, the caret on the `skip`th `marker` and the
// selection `select` bytes long.
@(private)
resolve_at :: proc(t: ^testing.T, e: ^Engine, root, source, marker, command, answer: string, select := 0, skip := 0) -> lang.Result {
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
        kind      = .Resolve_Action,
        path      = fixture_path(root, "app/main.odin"),
        ext       = ".odin",
        source    = source,
        workspace = root,
        offset    = at,
        end       = at + select,
        command   = command,
        new_name  = answer,
    }
    res: lang.Result
    resolve_action(e, &req, &res)
    return res
}

// `source` after the edits of a Resolve_Action result on the request's own file.
@(private)
resolved :: proc(t: ^testing.T, res: ^lang.Result, source: string, loc := #caller_location) -> string {
    testing.expectf(t, res.ok, "resolve failed: %s", res.message.text, loc = loc)
    out := source
    #reverse for edit in res.edits {
        if !strings.has_suffix(edit.path, "main.odin") {
            continue
        }
        testing.expectf(t, out[edit.start:edit.end] == edit.old_text, "old text %q does not match", edit.old_text, loc = loc)
        out = strings.concatenate({out[:edit.start], edit.new_text, out[edit.end:]}, context.temp_allocator)
    }
    return out
}

@(private)
free_resolved :: proc(res: ^lang.Result) {
    for edit in res.edits {
        free_edit(edit)
    }
    delete(res.edits)
    for op in res.resource_ops {
        delete(op.path)
        delete(op.new_path)
    }
    delete(res.resource_ops)
    delete(res.message.text)
}

@(test)
test_resolve_unknown_action :: proc(t: ^testing.T) {
    SRC :: "package app\n\nf :: proc() {}\n"
    root := fixture(t, "resolve_unknown", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)
    res := resolve_at(t, e, root, SRC, "f ::", "odin.nothing", "x")
    defer free_resolved(&res)
    testing.expect(t, !res.ok, "an unknown action resolves to nothing")
    testing.expect_value(t, res.message.text, "unknown action")
}

// The quick fixes for `source` with [`marker`, `marker` + `select`) selected.
@(private = "file")
selection_actions :: proc(t: ^testing.T, e: ^Engine, root, source, marker: string, select: int) -> lang.Result {
    at := strings.index(source, marker)
    if at < 0 {
        testing.fail_now(t, "marker not found")
    }
    req := lang.Request {
        kind      = .Code_Actions,
        path      = fixture_path(root, "app/main.odin"),
        ext       = ".odin",
        source    = source,
        workspace = root,
        offset    = at,
        end       = at + select,
    }
    res: lang.Result
    code_actions(e, &req, &res)
    return res
}

@(private = "file")
prompt_of :: proc(res: ^lang.Result, title: string) -> (lang.Code_Action, bool) {
    for a in res.actions {
        if a.title == title {
            return a, true
        }
    }
    return {}, false
}

@(test)
test_refactor_extract_variable :: proc(t: ^testing.T) {
    SRC :: `package app

f :: proc(a, b: int, ok: bool) -> int {
    x := a * b + 1
    value := 2
    if ok && a + b > 0 {
        return x
    }
    return x + value
}
`
    root := fixture(t, "refactor_extract_variable", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    offer := selection_actions(t, e, root, SRC, "a * b", len("a * b"))
    defer free_actions(&offer)
    action, found := prompt_of(&offer, "Extract variable")
    testing.expect(t, found, "extract variable is offered")
    testing.expect_value(t, action.prompt, "Variable name")
    testing.expect_value(t, action.prompt_default, "value2")
    testing.expect_value(t, len(action.edits), 0)

    res := resolve_at(t, e, root, SRC, "a * b", ACTION_EXTRACT_VARIABLE, "product", select = len("a * b"))
    defer free_resolved(&res)
    got := resolved(t, &res, SRC)
    testing.expect(t, strings.contains(got, "    product := a * b\n    x := product + 1\n"), got)

    rhs := selection_actions(t, e, root, SRC, "a + b > 0", len("a + b > 0"))
    defer free_actions(&rhs)
    _, offered := prompt_of(&rhs, "Extract variable")
    testing.expect(t, !offered, "the right side of && is not evaluated every time")

    taken := resolve_at(t, e, root, SRC, "a * b", ACTION_EXTRACT_VARIABLE, "value", select = len("a * b"))
    defer free_resolved(&taken)
    testing.expect(t, !taken.ok, "a name in reach is refused")
}

@(test)
test_refactor_extract_procedure :: proc(t: ^testing.T) {
    SRC :: `package app

f :: proc(xs: []int) -> int {
    total := 0
    count := 0
    for x in xs {
        total += x
    }
    scale := 2
    doubled := total * scale
    return doubled + count
}

g :: proc(xs: []int) {
    for x in xs {
        if x > 0 {
            return
        }
    }
}
`
    root := fixture(t, "refactor_extract_procedure", {{".thor/odin-analyzer.lua", ACTION_CONFIG}})
    e := engine_create()
    defer engine_destroy(e)

    BODY :: "for x in xs {\n        total += x\n    }\n    scale := 2\n    doubled := total * scale"
    offer := selection_actions(t, e, root, SRC, BODY, len(BODY))
    defer free_actions(&offer)
    _, found := prompt_of(&offer, "Extract procedure")
    testing.expect(t, found, "extract procedure is offered")

    res := resolve_at(t, e, root, SRC, BODY, ACTION_EXTRACT_PROCEDURE, "sum_scaled", select = len(BODY))
    defer free_resolved(&res)
    got := resolved(t, &res, SRC)
    testing.expect(t, strings.contains(got, "    count := 0\n    doubled := sum_scaled(xs, &total)\n    return doubled + count\n"), got)
    testing.expect(t, strings.contains(got, "sum_scaled :: proc(xs: []int, total: ^int) -> int {\n    for x in xs {\n        total^ += x\n    }\n    scale := 2\n    doubled := total^ * scale\n    return doubled\n}\n\ng ::"), got)

    RET :: "for x in xs {\n        if x > 0 {\n            return\n        }\n    }"
    ret := selection_actions(t, e, root, SRC, RET, len(RET))
    defer free_actions(&ret)
    _, offered := prompt_of(&ret, "Extract procedure")
    testing.expect(t, !offered, "a return in the selection is refused")
}

// `source` after the edits of a Resolve_Action result on the file whose path ends in `suffix`.
@(private = "file")
resolved_in :: proc(t: ^testing.T, res: ^lang.Result, source, suffix: string, loc := #caller_location) -> string {
    out := source
    #reverse for edit in res.edits {
        if !strings.has_suffix(edit.path, suffix) {
            continue
        }
        testing.expectf(t, out[edit.start:edit.end] == edit.old_text, "old text %q does not match", edit.old_text, loc = loc)
        out = strings.concatenate({out[:edit.start], edit.new_text, out[edit.end:]}, context.temp_allocator)
    }
    return out
}

@(test)
test_refactor_change_signature :: proc(t: ^testing.T) {
    SRC :: `package app

scale :: proc(v: int, by: int = 2, name: string) -> int {
    return v * by + len(name)
}

user :: proc() {
    _ = scale(1, 3, "a")
    _ = scale(4, name = "b")
}
`
    OTHER :: "package app\n\nother :: proc() {\n    _ = scale(5, 6, \"c\")\n}\n"
    CLI :: "package cli\n\nimport app \"../app\"\n\nrun :: proc() {\n    _ = app.scale(7, 8, \"d\")\n}\n"
    root := fixture(t, "refactor_change_signature", {
        {".thor/odin-analyzer.lua", ACTION_CONFIG},
        {"app/main.odin", SRC},
        {"app/other.odin", OTHER},
        {"cli/cli.odin", CLI},
    })
    e := engine_create()
    defer engine_destroy(e)

    offer := actions_at(t, e, root, SRC, "scale ::")
    defer free_actions(&offer)
    action, found := prompt_of(&offer, "Change signature")
    testing.expect(t, found, "change signature is offered")
    testing.expect_value(t, action.prompt_default, "v: int, by: int = 2, name: string")

    res := resolve_at(t, e, root, SRC, "scale ::", ACTION_CHANGE_SIGNATURE, "name: string, v: int, by: int = 2, verbose: bool")
    defer free_resolved(&res)
    got := resolved(t, &res, SRC)
    testing.expect(t, strings.contains(got, "scale :: proc(name: string, v: int, by: int = 2, verbose: bool) -> int {"), got)
    testing.expect(t, strings.contains(got, `_ = scale("a", 1, 3, false)`), got)
    testing.expect(t, strings.contains(got, `_ = scale(name = "b", v = 4, verbose = false)`), got)
    testing.expect_value(t, resolved_in(t, &res, OTHER, "other.odin"), "package app\n\nother :: proc() {\n    _ = scale(\"c\", 5, 6, false)\n}\n")
    testing.expect_value(t, resolved_in(t, &res, CLI, "cli.odin"), "package cli\n\nimport app \"../app\"\n\nrun :: proc() {\n    _ = app.scale(\"d\", 7, 8, false)\n}\n")

    drop := resolve_at(t, e, root, SRC, "scale ::", ACTION_CHANGE_SIGNATURE, "v: int, name: string, by: int = 2")
    defer free_resolved(&drop)
    got = resolved(t, &drop, SRC)
    testing.expect(t, strings.contains(got, `_ = scale(1, "a", 3)`), got)
    testing.expect(t, strings.contains(got, `_ = scale(4, name = "b")`), got)

    used := resolve_at(t, e, root, SRC, "scale ::", ACTION_CHANGE_SIGNATURE, "v: int, name: string")
    defer free_resolved(&used)
    testing.expect_value(t, used.message.text, "'by' is used in the body")

    bad := resolve_at(t, e, root, SRC, "scale ::", ACTION_CHANGE_SIGNATURE, "v: int,, ")
    defer free_resolved(&bad)
    testing.expect_value(t, bad.message.text, "not a parameter list")
}

@(test)
test_refactor_change_signature_refusals :: proc(t: ^testing.T) {
    SRC :: `package app

pair :: proc() -> (int, int) { return 1, 2 }

add :: proc(a, b: int) -> int {
    return a + b
}

spread :: proc() {
    _ = add(pair())
}

callback := add
`
    root := fixture(t, "refactor_change_signature_refusals", {{".thor/odin-analyzer.lua", ACTION_CONFIG}, {"app/main.odin", SRC}})
    e := engine_create()
    defer engine_destroy(e)

    res := resolve_at(t, e, root, SRC, "add ::", ACTION_CHANGE_SIGNATURE, "b, a: int")
    defer free_resolved(&res)
    testing.expect(t, !res.ok, "a refused change gives no edits")
    testing.expect(t, strings.contains(res.message.text, "passes several values") || strings.contains(res.message.text, "used as a value"), res.message.text)
}

// The text a Resolve_Action result inserts into the file it creates at the path ending in `suffix`.
@(private = "file")
created_text :: proc(t: ^testing.T, res: ^lang.Result, suffix: string, loc := #caller_location) -> string {
    created := false
    for op in res.resource_ops {
        created ||= op.kind == .Create && strings.has_suffix(op.path, suffix)
    }
    testing.expectf(t, created, "no file ending in %s is created", suffix, loc = loc)
    return resolved_in(t, res, "", suffix, loc)
}

@(test)
test_refactor_move_declaration :: proc(t: ^testing.T) {
    SRC :: `package app

import "core:fmt"

// Says hello.
helper :: proc(n: int) {
    fmt.println(n)
}

user :: proc() {
    helper(1)
}
`
    root := fixture(t, "refactor_move_declaration", {{".thor/odin-analyzer.lua", ACTION_CONFIG}, {"app/main.odin", SRC}})
    e := engine_create()
    defer engine_destroy(e)

    offer := actions_at(t, e, root, SRC, "helper ::")
    defer free_actions(&offer)
    action, found := prompt_of(&offer, "Move declaration")
    testing.expect(t, found, "move declaration is offered")
    testing.expect_value(t, action.prompt_default, "helper.odin")

    res := resolve_at(t, e, root, SRC, "helper ::", ACTION_MOVE_DECLARATION, "helper.odin")
    defer free_resolved(&res)
    testing.expect_value(t, resolved(t, &res, SRC), "package app\n\nuser :: proc() {\n    helper(1)\n}\n")
    testing.expect_value(t, created_text(t, &res, "helper.odin"), "package app\n\nimport \"core:fmt\"\n\n// Says hello.\nhelper :: proc(n: int) {\n    fmt.println(n)\n}\n")
}

@(test)
test_refactor_move_declaration_cross_package :: proc(t: ^testing.T) {
    SRC :: `package app

clamp_int :: proc(v: int) -> int {
    return max(v, 0)
}

user :: proc() -> int {
    return clamp_int(-1)
}
`
    CLI :: "package cli\n\nimport \"../app\"\n\nrun :: proc() -> int {\n    return app.clamp_int(2)\n}\n"
    UTIL :: "package util\n\nzero :: proc() -> int {\n    return 0\n}\n"
    root := fixture(t, "refactor_move_declaration_cross", {
        {".thor/odin-analyzer.lua", ACTION_CONFIG},
        {"app/main.odin", SRC},
        {"cli/cli.odin", CLI},
        {"util/util.odin", UTIL},
    })
    e := engine_create()
    defer engine_destroy(e)

    res := resolve_at(t, e, root, SRC, "clamp_int ::", ACTION_MOVE_DECLARATION, "../util/math.odin")
    defer free_resolved(&res)
    testing.expect_value(t, resolved(t, &res, SRC), "package app\n\nimport \"../util\"\n\nuser :: proc() -> int {\n    return util.clamp_int(-1)\n}\n")
    testing.expect_value(t, resolved_in(t, &res, CLI, "cli.odin"), "package cli\n\nimport \"../app\"\nimport \"../util\"\n\nrun :: proc() -> int {\n    return util.clamp_int(2)\n}\n")
    testing.expect_value(t, created_text(t, &res, "math.odin"), "package util\n\nclamp_int :: proc(v: int) -> int {\n    return max(v, 0)\n}\n")
}

@(test)
test_refactor_move_declaration_refusals :: proc(t: ^testing.T) {
    SRC :: `package app

LIMIT :: 10

capped :: proc(v: int) -> int {
    return min(v, LIMIT)
}

twice :: proc(v: int) -> int {
    return v * 2
}

user :: proc() -> int {
    return twice(capped(3))
}
`
    UTIL :: "package util\n\nimport \"../app\"\n\nuse :: proc() -> int {\n    return app.LIMIT\n}\n"
    root := fixture(t, "refactor_move_declaration_refusals", {
        {".thor/odin-analyzer.lua", ACTION_CONFIG},
        {"app/main.odin", SRC},
        {"util/util.odin", UTIL},
    })
    e := engine_create()
    defer engine_destroy(e)

    dep := resolve_at(t, e, root, SRC, "capped ::", ACTION_MOVE_DECLARATION, "../util/capped.odin")
    defer free_resolved(&dep)
    testing.expect_value(t, dep.message.text, "'capped' uses 'LIMIT' of its package; move it too")

    cycle := resolve_at(t, e, root, SRC, "twice ::", ACTION_MOVE_DECLARATION, "../util/twice.odin")
    defer free_resolved(&cycle)
    testing.expect(t, strings.contains(cycle.message.text, "cycle"), cycle.message.text)

    missing := resolve_at(t, e, root, SRC, "twice ::", ACTION_MOVE_DECLARATION, "../nowhere/twice.odin")
    defer free_resolved(&missing)
    testing.expect(t, strings.contains(missing.message.text, "does not exist"), missing.message.text)
}
