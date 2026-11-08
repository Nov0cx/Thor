package odinsema

import "core:fmt"
import "core:strings"
import "core:testing"

import odinsyntax "../syntax"

@(private = "file")
LIVE_SRC :: `package p

S :: struct { f: int }
U :: union { int, f32 }
use :: proc(args: ..any) {}
f :: proc() -> (int, bool) { return 1, true }

unused_plain :: proc() {
    a := 1
    b: int
}
unused_store_only :: proc() {
    a := 1
    a = 2
}
used_op_assign :: proc() {
    a := 1
    a += 1
}
unused_loop :: proc(xs: []int) {
    for x, i in xs {
        use(i)
    }
}
unused_none :: proc(p: int, s: U) -> (r: int) {
    switch v in s {
    case int:
    }
    @(static) st := 0
    for _ in 0 ..< 3 {}
    return
}
unused_when :: proc() {
    q := 2
    when ODIN_OS == .JS {
        use(q)
    }
}
overwrite :: proc() {
    x := f2()
    x = 3
    use(x)
}
overwrite_store :: proc() {
    x: int
    x = 1
    x = 2
    use(x)
}
both_branches :: proc(c: bool) {
    x: int
    if c {
        x = 1
    } else {
        x = 2
    }
    use(x)
}
branch_read :: proc(c: bool) {
    x := f2()
    if c {
        x = 2
    }
    use(x)
}
loop_read :: proc() {
    x := 0
    for i in 0 ..< 3 {
        use(x)
        x = i
    }
}
last_store :: proc() {
    x := 1
    use(x)
    x = 2
}
defer_read :: proc(c: bool) {
    x := 0
    defer use(x)
    x = 1
    if c {
        return
    }
    x = 2
}
or_return_defer :: proc() -> bool {
    x := 1
    defer use(x)
    y := f() or_return
    x = 2
    use(x, y)
    return true
}
named_result :: proc() -> (r: int) {
    r = 1
    return
}
named_result_twice :: proc() -> (r: int) {
    r = 1
    r = 2
    return
}
static_store :: proc() {
    @(static) n := 0
    n = 1
    use(n)
    n = 2
}
address_taken :: proc() {
    x := 1
    p := &x
    x = 2
    use(p)
}
sliced :: proc() {
    a: [4]int
    a = {1, 2, 3, 4}
    s := a[:]
    a = {}
    use(s)
}
by_ref_range :: proc() {
    a := [2]int{1, 2}
    for &e in a {
        e = 3
    }
    a = {}
    use(a)
}
when_read :: proc() {
    x := f2()
    when ODIN_OS == .JS {
        use(x)
    }
    x = 2
    use(x)
}
zero_init :: proc() {
    x := 0
    x = f2()
    use(x)
}
field_store :: proc() {
    s: S
    s = S{f = 1}
    s.f = 2
    use(s)
}
param_store :: proc(p: int) {
    p := p
    p = 3
    use(p)
}
switch_case :: proc(t: int) {
    k := f2()
    switch t {
    case k:
    }
    k = 0
    use(k)
}
dead_code_read :: proc() {
    x := f2()
    x = 1
    return
    use(x)
}
computed_init :: proc() {
    x, ok := f()
    x = 1
    use(ok)
}
when_twice :: proc() {
    when ODIN_OS == .Windows {
        w := 1
    } else {
        w := 2
    }
    use(w)
}
conversion_init :: proc(i: int) {
    a := u64(0)
    b := f32(i)
    a = 1
    b = 2
    use(a, b)
}
f2 :: proc() -> int { return 2 }
`

@(private = "file")
live_lit :: proc(c: ^Checker, src, name: string) -> (odinsyntax.Syntax_Node, bool) {
    head := fmt.tprintf("\n%s :: proc", name)
    at := strings.index(src, head)
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

// The line of `src` from `offset`, as far as its end.
@(private = "file")
live_line :: proc(src: string, offset: int) -> string {
    end := strings.index_byte(src[offset:], '\n')
    return strings.trim_space(end < 0 ? src[offset:] : src[offset:][:end])
}

@(private = "file")
Live_Case :: struct {
    name:   string,
    unused: []string, // the line from each unused name
    dead:   []string, // the line from each dead store
}

@(test)
test_liveness :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = LIVE_SRC}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    parsed := db_parse(c.snap, ANON_FILE)
    if !testing.expect(t, parsed != nil, "no parse") {
        return
    }
    m, merr := scope_map(parsed^, context.temp_allocator)
    if !testing.expect_value(t, merr, nil) {
        return
    }
    defer scope_map_destroy(m, context.temp_allocator)
    cases := []Live_Case {
        {name = "unused_plain", unused = {"a := 1", "b: int"}},
        {name = "unused_store_only", dead = {"a = 2"}},
        {name = "used_op_assign"},
        {name = "unused_loop", unused = {"x, i in xs {"}},
        {name = "unused_none"},
        {name = "unused_when", unused = {"q := 2"}},
        {name = "overwrite", dead = {"x := f2()"}},
        {name = "overwrite_store", dead = {"x = 1"}},
        {name = "both_branches"},
        {name = "branch_read"},
        {name = "loop_read"},
        {name = "last_store", dead = {"x = 2"}},
        {name = "defer_read"},
        {name = "or_return_defer"},
        {name = "named_result"},
        {name = "named_result_twice", dead = {"r = 1"}},
        {name = "static_store"},
        {name = "address_taken"},
        {name = "sliced"},
        {name = "by_ref_range"},
        {name = "when_read"},
        {name = "zero_init"},
        {name = "field_store"},
        {name = "param_store"},
        {name = "when_twice"},
        {name = "conversion_init"},
        {name = "computed_init", dead = {"x, ok := f()", "x = 1"}},
        {name = "switch_case"},
        {name = "dead_code_read"},
    }
    for k in cases {
        lit, ok := live_lit(c, LIVE_SRC, k.name)
        if !testing.expectf(t, ok, "%s: no procedure literal", k.name) {
            continue
        }
        r, err := liveness(c, ANON_FILE, m, lit, context.temp_allocator)
        if !testing.expect_value(t, err, nil) {
            continue
        }
        unused := make([dynamic]string, context.temp_allocator)
        for u in r.unused {
            append(&unused, live_line(LIVE_SRC, u.offset))
        }
        dead := make([dynamic]string, context.temp_allocator)
        for d in r.dead_stores {
            append(&dead, live_line(LIVE_SRC, d.offset))
        }
        live_expect(t, k.name, "unused", unused[:], k.unused)
        live_expect(t, k.name, "dead", dead[:], k.dead)
    }
}

@(private = "file")
live_expect :: proc(t: ^testing.T, name, what: string, got, want: []string, loc := #caller_location) {
    if !testing.expectf(t, len(got) == len(want), "%s %s: got %v, want %v", name, what, got, want, loc = loc) {
        return
    }
    for g, i in got {
        testing.expectf(t, strings.has_prefix(g, want[i]), "%s %s %d: got %q, want %q", name, what, i, g, want[i], loc = loc)
    }
}
