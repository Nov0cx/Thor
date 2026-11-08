package odinsema

import "core:testing"

@(private = "file")
USING_SRC :: `package p

Vec :: struct { x, y: f32 }
Base :: struct { id: int, name: string }
Entity :: struct { using base: Base, pos: Vec }
Color :: enum { Red, Green }

by_param :: proc(using e: ^Entity) {
    a := pos
    b := id
}

by_local :: proc() {
    using v: Vec
    c := x
}

by_stmt :: proc(e: Entity) {
    d0 := id
    using e
    d := name
    {
        name := 1
        d2 := name
    }
    using Color
    col := Green
}

shadow_outer :: proc(v: Vec) {
    x := 1
    {
        using v
        s := x
    }
    t := x
}
`

// A bare name, the text it follows, the type it should have ("" when no `using` gives it) and
// the text the declaration it names follows.
@(private = "file")
Using_Case :: struct {
    name:       string,
    after:      string,
    want:       string,
    decl_after: string,
}

@(test)
test_using_lookup :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = USING_SRC}) {
        return
    }
    defer check_end(&env)
    cases := []Using_Case {
        {"pos", "a := ", "Vec", "Entity ::"},
        {"id", "b := ", "int", "Base ::"},
        {"x", "c := ", "f32", "Vec ::"},
        {"id", "d0 := ", "", ""},
        {"name", "d := ", "string", "Base ::"},
        {"name", "d2 := ", "", ""},
        {"Green", "col := ", "Color", "Color ::"},
        {"x", "s := ", "f32", "Vec ::"},
        {"x", "t := ", "", ""},
    }
    for k in cases {
        at := marker_offset(USING_SRC, k.name, k.after)
        if !testing.expectf(t, at >= 0, "%s after %q: not in the source", k.name, k.after) {
            continue
        }
        op, ok := using_lookup(&env.c, ANON_FILE, k.name, at)
        sym, has_sym := using_symbol(&env.c, ANON_FILE, at)
        if k.want == "" {
            testing.expectf(t, !ok, "%s after %q: want no using hit", k.name, k.after)
            testing.expectf(t, !has_sym, "%s after %q: want no using symbol", k.name, k.after)
            continue
        }
        if !testing.expectf(t, ok, "%s after %q: want a using hit", k.name, k.after) {
            continue
        }
        got := type_string(&env.c.table, op.type, context.temp_allocator)
        testing.expectf(t, got == k.want, "%s after %q: got %q, want %q", k.name, k.after, got, k.want)
        if !testing.expectf(t, has_sym, "%s after %q: want a symbol", k.name, k.after) {
            continue
        }
        _, start, _, rok := symbol_range(&env.c, sym)
        want := marker_offset(USING_SRC, k.name, k.decl_after)
        testing.expectf(t, rok && start == want, "%s after %q: declaration at %d, want %d", k.name, k.after, start, want)
    }
    testing.expect_value(t, env.c.err, nil)
}

@(test)
test_using_ident_type :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = USING_SRC}) {
        return
    }
    defer check_end(&env)
    at := marker_offset(USING_SRC, "id", "b := ")
    n, ok := expr_node_at(&env.c, ANON_FILE, at, "id")
    if !testing.expect(t, ok, "no expression node") {
        return
    }
    op := expr_type(&env.c, ANON_FILE, n)
    testing.expect_value(t, type_string(&env.c.table, op.type, context.temp_allocator), "int")
    testing.expect(t, op.has_symbol, "a using field has a symbol")
}
