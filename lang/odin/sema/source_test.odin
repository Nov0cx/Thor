package odinsema

import "core:testing"

@(private = "file")
SOURCE_SRC :: `package p

E :: enum { A, B }
F :: enum { X = 1, Y }
U :: union { int, string }
N :: union #no_nil { int, f32 }
S :: struct { a: int }

v_int: int
v_bool: b32
v_str: string
v_ptr: ^S
v_slice: []S
v_map: map[string]E
v_arr: [4]u8
v_enum_arr: [E]int
v_e: E
v_f: F
v_u: U
v_n: N
v_s: S
v_proc: proc(a: int) -> (S, bool)
v_set: bit_set[E; u8]
v_any: any
v_anon: struct { x: int }
`

@(test)
test_type_source :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = SOURCE_SRC}, home = ANON_FILE) {
        return
    }
    defer check_end(&env)
    c := &env.c
    Case :: struct {
        name, type, zero: string,
    }
    cases := []Case{
        {"v_int", "int", "0"},
        {"v_bool", "b32", "false"},
        {"v_str", "string", `""`},
        {"v_ptr", "^S", "nil"},
        {"v_slice", "[]S", "nil"},
        {"v_map", "map[string]E", "nil"},
        {"v_arr", "[4]u8", "{}"},
        {"v_enum_arr", "[E]int", "{}"},
        {"v_e", "E", ".A"},
        {"v_f", "F", "F(0)"},
        {"v_u", "U", "nil"},
        {"v_n", "N", "{}"},
        {"v_s", "S", "{}"},
        {"v_proc", "proc(a: int) -> (S, bool)", "nil"},
        {"v_set", "bit_set[E; u8]", "{}"},
        {"v_any", "any", "nil"},
        {"v_anon", "", "{}"},
    }
    for cs in cases {
        sym, ok := find_symbol(c, ANON_FILE, cs.name)
        if !testing.expectf(t, ok, "%s: no symbol", cs.name) {
            continue
        }
        ty       := decl_type(c, sym)
        src, has := type_source(c, ANON_FILE, ty, context.temp_allocator)
        testing.expectf(t, has == (cs.type != ""), "%s: type_source ok = %v", cs.name, has)
        testing.expectf(t, src == cs.type, "%s: type %q, want %q", cs.name, src, cs.type)
        zero, zok := zero_value(c, ANON_FILE, ty)
        testing.expectf(t, zok && zero == cs.zero, "%s: zero %q, want %q", cs.name, zero, cs.zero)
    }
    _, untyped := type_source(c, ANON_FILE, type_untyped(.Nil), context.temp_allocator)
    testing.expect(t, !untyped, "untyped nil has no source")
    s, _ := type_source(c, ANON_FILE, type_untyped(.Float), context.temp_allocator)
    testing.expect_value(t, s, "f64")
    testing.expect_value(t, c.err, nil)
}

@(private = "file")
OR_RETURN_SRC :: `package p

Error :: enum { None, Bad }
two :: proc() -> (int, Error) { return 1, .None }
one :: proc() -> int { return 1 }

fits :: proc() -> Error {
    x := two()
    return .None
}
named :: proc() -> (n: int, err: Error) {
    x := two()
    return
}
unnamed :: proc() -> (int, Error) {
    x := two()
    return 0, .None
}
nothing :: proc() {
    x := two()
}
wrong :: proc() -> bool {
    x := two()
    return true
}
single :: proc() -> Error {
    x := one()
    return .None
}
`

@(test)
test_or_return_fits :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = OR_RETURN_SRC}) {
        return
    }
    defer check_end(&env)
    c     := &env.c
    wants := []struct {
        after: string,
        call:  string,
        fits:  bool,
    }{
        {"fits ::", "two()", true},
        {"named ::", "two()", true},
        {"unnamed ::", "two()", false},
        {"nothing ::", "two()", false},
        {"wrong ::", "two()", false},
        {"single ::", "one()", false},
    }
    for w in wants {
        at := marker_offset(OR_RETURN_SRC, w.call, w.after)
        if !testing.expectf(t, at >= 0, "%s: no call", w.after) {
            continue
        }
        call: Maybe(int)
        for n in node_path(c, ANON_FILE, at) {
            if int(n.offset) == at && n.green.kind == .Call_Expr {
                testing.expectf(t, or_return_fits(c, ANON_FILE, n) == w.fits, "%s: want fits = %v", w.after, w.fits)
                call = at
                break
            }
        }
        testing.expectf(t, call != nil, "%s: no call node", w.after)
    }
    testing.expect_value(t, c.err, nil)
}
