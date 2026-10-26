package odinsema

import "core:strings"
import "core:testing"

@(private = "file")
OVERLOAD_SRC :: `package p

Shape :: union { int, string }
Color :: enum { Red, Green }
Dir :: enum { Up, Down }

take_int :: proc(x: int) -> int { return x }
take_f32 :: proc(x: f32) -> f32 { return x }
take_any :: proc(x: any) -> string { return "" }
take_u8 :: proc(x: u8) -> u8 { return x }
take_i64 :: proc(x: i64) -> i64 { return x }
take_shape :: proc(x: Shape) -> Shape { return x }
take_poly :: proc(x: $T) -> bool { return true }
by_color :: proc(c: Color) -> int { return 0 }
by_dir :: proc(d: Dir) -> string { return "" }
w_int :: proc(x: $T) -> int where intrinsics.type_is_integer(T) { return 0 }
w_str :: proc(x: $T) -> string where T == string { return "" }
w_big :: proc($N: int) -> int where N > 2 { return N }
w_small :: proc($N: int) -> string where N <= 2 { return "" }

exact :: proc{take_any, take_f32, take_int}
untyped :: proc{take_f32, take_int}
small :: proc{take_u8, take_any}
over :: proc{take_u8, take_i64}
poly :: proc{take_poly, take_int}
conv :: proc{take_any, take_shape}
pick :: proc{by_color, by_dir}
wsel :: proc{w_int, w_str}
wn :: proc{w_big, w_small}

work :: proc(i: int, f: f32) {
    _ = exact(i)
    _ = exact(f)
    _ = exact("s")
    _ = untyped(1)
    _ = untyped(1.5)
    _ = small(3)
    _ = small(300)
    _ = small(2.0)
    _ = small(2.5)
    _ = over(300)
    _ = over(3)
    _ = poly(i)
    _ = poly("s")
    _ = conv(i)
    _ = pick(.Down)
    _ = pick(.Red)
    _ = wsel(i)
    _ = wsel("s")
    _ = wn(5)
    _ = wn(1)
}
`

// The type of the call at `text` of OVERLOAD_SRC, and the type call_group_member picks for it.
@(private = "file")
Overload_Case :: struct {
    text:   string,
    want:   string,
    member: string, // the parameter list of the member picked; "" for none
}

@(test)
test_overload_resolution :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = OVERLOAD_SRC}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    cases := []Overload_Case {
        {"exact(i)", "int", "proc(x: int) -> int"},
        {"exact(f)", "f32", "proc(x: f32) -> f32"},
        {`exact("s")`, "string", "proc(x: any) -> string"},
        {"untyped(1)", "int", "proc(x: int) -> int"},
        {"untyped(1.5)", "f32", "proc(x: f32) -> f32"},
        {"small(3)", "u8", "proc(x: u8) -> u8"},
        {"small(300)", "string", "proc(x: any) -> string"},
        {"small(2.0)", "u8", "proc(x: u8) -> u8"},
        {"small(2.5)", "string", "proc(x: any) -> string"},
        {"over(300)", "i64", "proc(x: i64) -> i64"},
        {"over(3)", "u8", ""},
        {"poly(i)", "int", "proc(x: int) -> int"},
        {`poly("s")`, "bool", "proc(x: $T) -> bool"},
        {"conv(i)", "Shape", "proc(x: Shape) -> Shape"},
        {"pick(.Down)", "string", "proc(d: Dir) -> string"},
        {"pick(.Red)", "int", "proc(c: Color) -> int"},
        {"wsel(i)", "int", "proc(x: $T) -> int"},
        {`wsel("s")`, "string", "proc(x: $T) -> string"},
        {"wn(5)", "int", "proc($N: int) -> int"},
        {"wn(1)", "string", "proc($N: int) -> string"},
    }
    for k in cases {
        at := strings.index(OVERLOAD_SRC, k.text)
        if !testing.expectf(t, at >= 0, "%q: not in the source", k.text) {
            continue
        }
        n, ok := expr_node_at(c, ANON_FILE, at, k.text)
        if !testing.expectf(t, ok, "%q: no call node", k.text) {
            continue
        }
        op := expr_type(c, ANON_FILE, n)
        got := op.mode == .Invalid ? "<invalid>" : type_string(&c.table, op.type, context.temp_allocator)
        testing.expectf(t, got == k.want, "%q: got %q, want %q", k.text, got, k.want)
        member := call_group_member(c, ANON_FILE, n)
        picked := member == INVALID_TYPE ? "" : type_string(&c.table, member, context.temp_allocator)
        testing.expectf(t, picked == k.member, "%q: picked %q, want %q", k.text, picked, k.member)
    }
    testing.expect_value(t, c.err, nil)
}
