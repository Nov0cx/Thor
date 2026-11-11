package odinsema

import "core:fmt"
import "core:strings"
import "core:testing"

import odinsyntax "../syntax"

@(private = "file")
CFG_SRC :: `package p

die :: proc() -> ! { for {} }
maybe :: proc() -> (int, bool) { return 1, true }
a :: proc() {}
unknown_callee: proc()

after_return :: proc() {
    a()
    return
    a1()
    a2()
}
after_die :: proc() {
    die()
    b1()
}
after_loop :: proc() {
    for {
        a()
    }
    c1()
}
loop_break :: proc(x: int) {
    for {
        if x > 0 { break }
    }
    d1()
}
in_loop :: proc(x: int) {
    for i in 0..<x {
        if i > 1 {
            continue
            e1()
        }
        break
        e2()
    }
}
after_if_else :: proc(x: int) -> int {
    if x > 0 {
        return 1
    } else {
        return 2
    }
    f1()
    f2()
}
after_switch :: proc(x: int) -> int {
    switch x {
    case 1: return 1
    case: return 2
    }
    g1()
}
switch_no_default :: proc(x: int) -> int {
    switch x {
    case 1: return 1
    }
    return 0
}
switch_break :: proc(x: int) {
    for {
        switch x {
        case: break
        }
        h1()
    }
}
labelled :: proc() {
    outer: for {
        for {
            break outer
        }
        i1()
    }
    i2()
}
or_ret :: proc() -> (n: int, ok: bool) {
    n = maybe() or_return
    j1()
    return
}
whens :: proc() {
    when false {
        return
    }
    k1()
}
when_return :: proc() {
    when true {
        return
    }
    k2()
}
loop_return :: proc() -> int {
    for {
        a()
    }
    return 1
}
loop_die :: proc() {
    for {
        a()
    }
    die()
}
loop_two :: proc() -> int {
    for {
        a()
    }
    a()
    return 1
}
unknown :: proc() {
    unknown_callee()
    l1()
}
nested :: proc() {
    return
    inner := proc() {
        m1()
    }
}
consts :: proc() {
    return
    K :: 1
}
defers :: proc() {
    defer a()
    die()
}
defers_not_last :: proc() {
    defer a()
    die()
    n1()
}
`

// Gives the text of the statement at each offset, cut at its first newline.
@(private = "file")
offset_texts :: proc(src: string, offsets: []int) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    for o in offsets {
        end := strings.index_byte(src[o:], '\n')
        append(&out, end < 0 ? src[o:] : src[o:][:end])
    }
    return out[:]
}

// The procedure literal of `name :: proc`.
@(private = "file")
proc_lit_named :: proc(c: ^Checker, src, name: string) -> (odinsyntax.Syntax_Node, bool) {
    head := fmt.tprintf("\n%s :: proc", name)
    at   := strings.index(src, head)
    if at < 0 {
        return {}, false
    }
    offset := at + len(head) - len("proc")
    for n in node_path(c, ANON_FILE, offset) {
        if int(n.offset) == offset && n.green.kind == .Proc_Lit {
            return n, true
        }
    }
    return {}, false
}

@(private = "file")
Unreachable_Case :: struct {
    name:   string,
    never:  []string, // the terminators `odin check` reports
    dead:   []string, // the first statement of each run only the graph finds
    defer_: []string,
}

@(test)
test_cfg_unreachable :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = CFG_SRC}) {
        return
    }
    defer check_end(&env)
    c     := &env.c
    cases := []Unreachable_Case{
        {name = "after_return", never = {"return"}},
        {name = "after_die", never = {"die()"}},
        {name = "after_loop", dead = {"c1()"}},
        {name = "loop_break"},
        {name = "in_loop", never = {"break", "continue"}},
        {name = "after_if_else", dead = {"f1()"}},
        {name = "after_switch", dead = {"g1()"}},
        {name = "switch_no_default"},
        {name = "switch_break"},
        {name = "labelled", dead = {"i1()"}},
        {name = "or_ret"},
        {name = "whens"},
        {name = "when_return"},
        {name = "loop_return"},
        {name = "loop_die"},
        {name = "loop_two", dead = {"a()"}},
        {name = "unknown"},
        {name = "nested", never = {"return"}},
        {name = "consts"},
        {name = "defers", defer_ = {"defer a()"}},
        {name = "defers_not_last", never = {"die()"}},
    }
    for k in cases {
        lit, ok := proc_lit_named(c, CFG_SRC, k.name)
        if !testing.expectf(t, ok, "%s: no procedure literal", k.name) {
            continue
        }
        r, err := unreachable_code(c, ANON_FILE, lit, context.temp_allocator)
        if !testing.expect_value(t, err, nil) {
            continue
        }
        never := make([dynamic]int, context.temp_allocator)
        for n in r.never_executed {
            append(&never, n.offset)
        }
        expect_texts(t, k.name, "never", offset_texts(CFG_SRC, never[:]), k.never)
        expect_texts(t, k.name, "dead", offset_texts(CFG_SRC, r.dead[:]), k.dead)
        expect_texts(t, k.name, "defer", offset_texts(CFG_SRC, r.defers[:]), k.defer_)
    }
}

@(private = "file")
expect_texts :: proc(t: ^testing.T, name, what: string, got, want: []string, loc := #caller_location) {
    if !testing.expectf(t, len(got) == len(want), "%s %s: got %v, want %v", name, what, got, want, loc = loc) {
        return
    }
    for g, i in got {
        testing.expectf(t, strings.has_prefix(g, want[i]), "%s %s %d: got %q, want %q", name, what, i, g, want[i], loc = loc)
    }
}

@(private = "file")
DEFER_SRC :: `package p

a :: proc() {}
b :: proc() {}
c :: proc() {}

run :: proc(x: int) {
    defer a()
    defer b()
    if x > 0 {
        return
    }
    for {
        defer c()
        if x > 1 { break }
    }
}
`

// Every exit edge runs the defers of the scopes it leaves, last first.
@(test)
test_cfg_defer_runs :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = DEFER_SRC}) {
        return
    }
    defer check_end(&env)
    c       := &env.c
    lit, ok := proc_lit_named(c, DEFER_SRC, "run")
    if !testing.expect(t, ok, "no procedure literal") {
        return
    }
    g, err := cfg_build(c, ANON_FILE, lit, context.temp_allocator)
    if !testing.expect_value(t, err, nil) || !testing.expect(t, g != nil, "no graph") {
        return
    }
    defer cfg_destroy(g, context.temp_allocator)
    runs := make([dynamic]string, context.temp_allocator)
    for blk in g.blocks {
        sb := strings.builder_make(context.temp_allocator)
        for s in blk.steps {
            if s.kind == .Defer_Run {
                if strings.builder_len(sb) > 0 {
                    strings.write_string(&sb, " ")
                }
                strings.write_string(&sb, odinsyntax.node_text(s.node))
            }
        }
        if strings.builder_len(sb) > 0 {
            append(&runs, strings.to_string(sb))
        }
    }
    // The return, the break out of the loop, each loop iteration's end, the end of the body.
    want := []string{"b() a()", "c()", "c()", "b() a()"}
    testing.expectf(t, len(runs) == len(want), "got %v, want %v", runs[:], want)
    for r in want {
        found := false
        for g in runs {
            found ||= g == r
        }
        testing.expectf(t, found, "no block runs %q: %v", r, runs[:])
    }
    reach := cfg_reachable(g, context.temp_allocator)
    testing.expect(t, reach[g.exit], "the exit is reachable")
}
