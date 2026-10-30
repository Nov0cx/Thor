package odinsema

import "core:strings"
import "core:testing"

import odinsyntax "../syntax"

@(private = "file")
CALL_SRC :: `package p

Thing :: struct { n: int }

two_ints :: proc(a: int, b: int) {}
with_default :: proc(a: int, b := 2) {}
rest :: proc(a: int, more: ..int) {}
poly :: proc(x: $T, y: T) {}
pair :: proc() -> (int, int) { return 1, 2 }
maybe :: proc() -> (int, bool) #optional_ok { return 1, true }
method :: proc(t: ^Thing, k: int) {}
group :: proc{two_ints, rest}

Obj :: struct { call: proc(t: ^Obj, k: int) }

work :: proc(o: ^Obj, cb: proc(n: int)) {
    two_ints(1)
    two_ints(1, 2, 3)
    with_default(1, c = 3)
    with_default(a = 1, a = 2)
    with_default(a = 1, 2)
    rest()
    poly(1)
    cb()
    two_ints(pair())
    two_ints(maybe(), 1)
    two_ints(1, 2)
    with_default(1)
    with_default(1, 2, 3)
    with_default(b = 3, a = 1)
    rest(1, 2, 3, 4)
    group(1)
    o->call()
    o->call(1)
}
`

// The outermost call that starts at `offset`.
@(private = "file")
call_node_at :: proc(c: ^Checker, offset: int) -> (odinsyntax.Syntax_Node, bool) {
    for n in node_path(c, ANON_FILE, offset) {
        if int(n.offset) == offset && n.green.kind == .Call_Expr {
            return n, true
        }
    }
    return {}, false
}

@(private = "file")
Call_Case :: struct {
    text:  string,
    kind:  Call_Problem_Kind,
    at:    string, // the text the problem is reported at; "" for the call
    name:  string,
    type:  string,
    least: int,
    want:  int,
    got:   int,
}

@(test)
test_call_problem :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = CALL_SRC}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    cases := []Call_Case {
        {text = "two_ints(1)\n", kind = .Missing, name = "b", type = "int"},
        {text = "two_ints(1, 2, 3)", kind = .Too_Many, least = 2, want = 2, got = 3},
        {text = "with_default(1, 2, 3)", kind = .Too_Many, least = 1, want = 2, got = 3},
        {text = "with_default(1, c = 3)", kind = .Unknown_Name, at = "c = 3", name = "c"},
        {text = "with_default(a = 1, a = 2)", kind = .Duplicate_Name, at = "a = 2", name = "a"},
        {text = "with_default(a = 1, 2)", kind = .Positional_After_Named, at = "2)"},
        {text = "rest()", kind = .Missing, name = "a", type = "int"},
        {text = "poly(1)", kind = .Missing, name = "y"},
        {text = "cb()", kind = .Missing, name = "n", type = "int"},
        {text = "two_ints(pair())", kind = .None},
        {text = "two_ints(maybe(), 1)", kind = .None},
        {text = "two_ints(1, 2)", kind = .None},
        {text = "with_default(1)\n", kind = .None},
        {text = "with_default(b = 3, a = 1)", kind = .None},
        {text = "rest(1, 2, 3, 4)", kind = .None},
        {text = "group(1)", kind = .None},
        {text = "o->call()", kind = .Missing, name = "k", type = "int"},
        {text = "o->call(1)", kind = .None},
    }
    for k in cases {
        at := strings.index(CALL_SRC, k.text)
        if !testing.expectf(t, at >= 0, "%q: not in the source", k.text) {
            continue
        }
        call, ok := call_node_at(c, at)
        if !testing.expectf(t, ok, "%q: no call node", k.text) {
            continue
        }
        got := call_problem(c, ANON_FILE, call)
        testing.expectf(t, got.kind == k.kind, "%q: kind %v, want %v", k.text, got.kind, k.kind)
        if got.kind == .None || k.kind == .None {
            continue
        }
        want_at := at
        if k.at != "" {
            want_at = at + strings.index(k.text, k.at)
        }
        testing.expectf(t, got.offset == want_at, "%q: offset %d, want %d", k.text, got.offset, want_at)
        testing.expectf(t, got.name == k.name, "%q: name %q, want %q", k.text, got.name, k.name)
        if k.type != "" {
            typ := type_string(&c.table, got.type, context.temp_allocator)
            testing.expectf(t, typ == k.type, "%q: type %q, want %q", k.text, typ, k.type)
        }
        testing.expectf(t, got.least == k.least && got.want == k.want && got.got == k.got, "%q: counts %d/%d/%d, want %d/%d/%d", k.text, got.least, got.want, got.got, k.least, k.want, k.got)
    }
    testing.expect_value(t, c.err, nil)
}

@(private = "file")
MEMBER_SRC :: `package p

Inner :: struct { deep: int }
Point :: struct { x: int, using inner: Inner }
Flags :: bit_field u8 { lo: u8 | 4 }
Color :: enum { Red, Green }
Box :: struct($T: typeid) { item: T }
Vec :: [3]f32

work :: proc(p: Point, pp: ^Point, f: Flags, b: Box(int), v: Vec, a: any, m: map[int]int) {
    _ = p.y
    _ = pp.z
    _ = f.hi
    _ = Color.Blue
    _ = p.x
    _ = p.deep
    _ = pp.inner
    _ = f.lo
    _ = Color.Red
    _ = b.item
    _ = v.xy
    _ = a.id
    _ = m.allocator
    _ = unknown.field
}
`

@(private = "file")
Member_Case :: struct {
    text:    string,
    missing: bool,
    is_type: bool,
    owner:   string,
}

@(test)
test_member_problem :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = MEMBER_SRC}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    cases := []Member_Case {
        {"p.y", true, false, "Point"},
        {"pp.z", true, false, "^Point"},
        {"f.hi", true, false, "Flags"},
        {"Color.Blue", true, true, "Color"},
        {"p.x", false, false, ""},
        {"p.deep", false, false, ""},
        {"pp.inner", false, false, ""},
        {"f.lo", false, false, ""},
        {"Color.Red", false, false, ""},
        {"b.item", false, false, ""},
        {"v.xy", false, false, ""},
        {"a.id", false, false, ""},
        {"m.allocator", false, false, ""},
        {"unknown.field", false, false, ""},
    }
    for k in cases {
        at := strings.index(MEMBER_SRC, k.text)
        if !testing.expectf(t, at >= 0, "%q: not in the source", k.text) {
            continue
        }
        sel, ok := expr_node_at(c, ANON_FILE, at, k.text)
        if !testing.expectf(t, ok && sel.green.kind == .Selector_Expr, "%q: no selector node", k.text) {
            continue
        }
        got := member_problem(c, ANON_FILE, sel)
        testing.expectf(t, got.missing == k.missing && got.is_type == k.is_type, "%q: missing %v type %v, want %v %v", k.text, got.missing, got.is_type, k.missing, k.is_type)
        if k.missing && got.missing {
            owner := type_string(&c.table, got.owner, context.temp_allocator)
            testing.expectf(t, owner == k.owner, "%q: owner %q, want %q", k.text, owner, k.owner)
        }
    }
    testing.expect_value(t, c.err, nil)
}

@(private = "file")
SWITCH_SRC :: `package p

E :: enum { A, B, C }
U :: union { int, string, f32 }
G :: union($T: typeid) { T, bool }

work :: proc(e: E, u: U, g: G(int), x: int) {
    switch e {
    case .A, .B:
    }
    switch v in u {
    case int:
    }
    switch e {
    case .A ..= .B:
    }
    switch e {
    case .A ..< .C:
    }
    switch e {
    case .A, .B, .C:
    }
    #partial switch e {
    case .A:
    }
    switch e {
    case .A:
    case:
    }
    switch v in u {
    case nil, int, string, f32:
    }
    switch x {
    case 1:
    }
    switch v in g {
    case bool:
    }
}
`

@(test)
test_switch_missing :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = SWITCH_SRC}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    wants := [][]string{{"C"}, {"string", "f32"}, {"C"}, {"C"}, {}, {}, {}, {}, {}, {"int"}}
    src := SWITCH_SRC
    found := 0
    from := 0
    for {
        i := strings.index(src[from:], "switch ")
        if i < 0 {
            break
        }
        at := from + i
        from = at + 1
        sw, ok := switch_node_at(c, at)
        if !testing.expectf(t, ok, "switch %d: no statement", found) || found >= len(wants) {
            found += 1
            continue
        }
        got := switch_missing(c, ANON_FILE, sw, context.temp_allocator)
        want := wants[found]
        testing.expectf(t, len(got) == len(want), "switch %d: got %v, want %v", found, got, want)
        for g, k in got {
            if k < len(want) {
                testing.expectf(t, g == want[k], "switch %d: got %v, want %v", found, got, want)
            }
        }
        found += 1
    }
    testing.expect_value(t, found, len(wants))
    testing.expect_value(t, c.err, nil)
}

// The switch statement whose `switch` keyword is at `offset`.
@(private = "file")
switch_node_at :: proc(c: ^Checker, offset: int) -> (odinsyntax.Syntax_Node, bool) {
    path := node_path(c, ANON_FILE, offset)
    for k := len(path) - 1; k >= 0; k -= 1 {
        if path[k].green.kind == .Switch_Stmt || path[k].green.kind == .Type_Switch_Stmt {
            return path[k], true
        }
    }
    return {}, false
}

@(private = "file")
ASSERT_SRC :: `package p

N :: 3

#assert(N == 4)
#assert(N > 4, "too small")
#assert(N == 3)
#assert(size_of(i32) == 4)

work :: proc($T: typeid) {
    #assert(size_of(T) == 4)
    #assert(size_of(u8) == 2)
}
`

@(test)
test_static_assert_fails :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = ASSERT_SRC}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    Assert_Case :: struct {
        text:    string,
        fails:   bool,
        message: string,
    }
    cases := []Assert_Case {
        {"#assert(N == 4)", true, ""},
        {`#assert(N > 4, "too small")`, true, `"too small"`},
        {"#assert(N == 3)", false, ""},
        {"#assert(size_of(i32) == 4)", false, ""},
        {"#assert(size_of(T) == 4)", false, ""},
        {"#assert(size_of(u8) == 2)", true, ""},
    }
    for k in cases {
        at := strings.index(ASSERT_SRC, k.text)
        if !testing.expectf(t, at >= 0, "%q: not in the source", k.text) {
            continue
        }
        call, ok := call_node_at(c, at)
        if !testing.expectf(t, ok, "%q: no call node", k.text) {
            continue
        }
        _, message, has_message, fails := static_assert_fails(c, ANON_FILE, call)
        testing.expectf(t, fails == k.fails, "%q: fails %v, want %v", k.text, fails, k.fails)
        got := has_message ? odinsyntax.node_text(message) : ""
        testing.expectf(t, got == k.message, "%q: message %q, want %q", k.text, got, k.message)
    }
    testing.expect_value(t, c.err, nil)
}

@(private = "file")
MISMATCH_SRC :: `package p

I :: distinct int
E :: enum { A, B }
U :: union { int, string }
Base :: struct { n: int }
Derived :: struct { using base: Base }
Box :: struct($T: typeid) { item: T }

take :: proc(a: int, s: string) {}
rest :: proc(xs: ..int) {}
loose :: proc(a: any, #any_int b: int) {}
poly :: proc(x: $T, y: T) {}
two :: proc() -> (int, string) { s: string; return s, 1 }
one :: proc() -> int { return "x" }
fine :: proc() -> (I, E) { return 1, .A }
base_of :: proc(b: ^Base) {}

work :: proc() {
    s: string
    i: int
    d: I
    u8v: u8
    f: f32
    take(s, "a")
    take(1, 2)
    take(s = "a", a = s)
    rest(1, s)
    loose(s, u8v)
    poly(1, 2)
    i = s
    i = "a"
    d = i
    d = 3
    x: int = s
    y: [3]f32 = 0
    z: [3]f32 = f
    w: b8 = true
    c: u8 = 300
    e: E = .B
    un: U = s
    p: ^Derived
    base_of(p)
    q: rawptr = p
    m: [^]Derived = p
    bx: Box(int)
    bx.item = s
    v: string = nil
    _ = s
}
`

// The outermost node of `kind` that starts at `offset`.
@(private = "file")
node_kind_at :: proc(c: ^Checker, offset: int, kind: odinsyntax.Syntax_Kind) -> (odinsyntax.Syntax_Node, bool) {
    for n in node_path(c, ANON_FILE, offset) {
        if int(n.offset) == offset && n.green.kind == kind {
            return n, true
        }
    }
    return {}, false
}

@(test)
test_type_mismatches :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = MISMATCH_SRC}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    Mismatch_Case :: struct {
        text:  string,
        kind:  odinsyntax.Syntax_Kind,
        wants: []string, // "value -> type" per problem
    }
    cases := []Mismatch_Case {
        {"take(s, \"a\")", .Call_Expr, {"s -> int"}},
        {"take(1, 2)", .Call_Expr, {"2 -> string"}},
        {"take(s = \"a\", a = s)", .Call_Expr, {"s -> int"}},
        {"rest(1, s)", .Call_Expr, {"s -> int"}},
        {"loose(s, u8v)", .Call_Expr, {}},
        {"poly(1, 2)", .Call_Expr, {}},
        {"base_of(p)", .Call_Expr, {}},
        {"return s, 1", .Return_Stmt, {"s -> int", "1 -> string"}},
        {"return \"x\"", .Return_Stmt, {"\"x\" -> int"}},
        {"return 1, .A", .Return_Stmt, {}},
        {"i = s", .Assign_Stmt, {"s -> int"}},
        {"i = \"a\"", .Assign_Stmt, {"\"a\" -> int"}},
        {"d = i", .Assign_Stmt, {"i -> I"}},
        {"d = 3", .Assign_Stmt, {}},
        {"x: int = s", .Value_Decl, {"s -> int"}},
        {"y: [3]f32 = 0", .Value_Decl, {}},
        {"z: [3]f32 = f", .Value_Decl, {}},
        {"w: b8 = true", .Value_Decl, {}},
        {"c: u8 = 300", .Value_Decl, {}},
        {"e: E = .B", .Value_Decl, {}},
        {"un: U = s", .Value_Decl, {}},
        {"q: rawptr = p", .Value_Decl, {}},
        {"m: [^]Derived = p", .Value_Decl, {}},
        {"bx.item = s", .Assign_Stmt, {"s -> int"}},
        {"v: string = nil", .Value_Decl, {"nil -> string"}},
        {"_ = s", .Assign_Stmt, {}},
    }
    for k in cases {
        at := strings.index(MISMATCH_SRC, k.text)
        if !testing.expectf(t, at >= 0, "%q: not in the source", k.text) {
            continue
        }
        n, ok := node_kind_at(c, at, k.kind)
        if !testing.expectf(t, ok, "%q: no %v node", k.text, k.kind) {
            continue
        }
        problems: []Type_Problem
        #partial switch k.kind {
        case .Call_Expr:   problems = argument_mismatches(c, ANON_FILE, n, context.temp_allocator)
        case .Return_Stmt: problems = return_mismatches(c, ANON_FILE, n, context.temp_allocator)
        case:              problems = assign_mismatches(c, ANON_FILE, n, context.temp_allocator)
        }
        got := make([dynamic]string, context.temp_allocator)
        for p in problems {
            append(&got, strings.concatenate({odinsyntax.node_text(p.value), " -> ", type_string(&c.table, p.to, context.temp_allocator)}, context.temp_allocator))
        }
        testing.expectf(t, len(got) == len(k.wants), "%q: got %v, want %v", k.text, got[:], k.wants)
        for g, i in got {
            if i < len(k.wants) {
                testing.expectf(t, g == k.wants[i], "%q: got %q, want %q", k.text, g, k.wants[i])
            }
        }
    }
    testing.expect_value(t, c.err, nil)
}
