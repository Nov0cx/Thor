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
    text: string,
    kind: Call_Problem_Kind,
    at:   string, // the text the problem is reported at; "" for the call
    name: string,
    type: string,
    want: int,
    got:  int,
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
        {text = "two_ints(1, 2, 3)", kind = .Too_Many, want = 2, got = 3},
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
        testing.expectf(t, got.want == k.want && got.got == k.got, "%q: want/got %d/%d, want %d/%d", k.text, got.want, got.got, k.want, k.got)
    }
    testing.expect_value(t, c.err, nil)
}
