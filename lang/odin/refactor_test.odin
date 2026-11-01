package odin

import "core:slice"
import "core:strings"
import "core:testing"

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
