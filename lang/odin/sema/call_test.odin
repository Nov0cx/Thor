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

@(private = "file")
WHERE_SRC :: `package p

Point :: struct { x, y: f32 }
Base :: struct { id: int }
IPoint :: struct { x: int }
Derived :: struct { using base: Base, name: string }
Shape :: union { int, string }
Color :: enum { Red, Green }
Small :: enum u8 { A }
List :: struct($T: typeid) { items: []T }

cmp_y :: proc(x: $T) -> int where intrinsics.type_is_comparable(T) { return 0 }
cmp_n :: proc(x: $T) -> string where !intrinsics.type_is_comparable(T) { return "" }
ord_y :: proc(x: $T) -> int where intrinsics.type_is_ordered(T) { return 0 }
ord_n :: proc(x: $T) -> string where !intrinsics.type_is_ordered(T) { return "" }
num_y :: proc(x: $T) -> int where intrinsics.type_is_ordered_numeric(T) { return 0 }
num_n :: proc(x: $T) -> string where !intrinsics.type_is_ordered_numeric(T) { return "" }
sim_y :: proc(x: $T) -> int where intrinsics.type_is_simple_compare(T) { return 0 }
sim_n :: proc(x: $T) -> string where !intrinsics.type_is_simple_compare(T) { return "" }
key_y :: proc(x: $T) -> int where intrinsics.type_is_valid_map_key(T) { return 0 }
key_n :: proc(x: $T) -> string where !intrinsics.type_is_valid_map_key(T) { return "" }
sli_y :: proc(x: $T) -> int where intrinsics.type_is_sliceable(T) { return 0 }
sli_n :: proc(x: $T) -> string where !intrinsics.type_is_sliceable(T) { return "" }
idx_y :: proc(x: $T) -> int where intrinsics.type_is_indexable(T) { return 0 }
idx_n :: proc(x: $T) -> string where !intrinsics.type_is_indexable(T) { return "" }
big_y :: proc(x: $T) -> int where intrinsics.type_is_endian_big(T) { return 0 }
big_n :: proc(x: $T) -> string where !intrinsics.type_is_endian_big(T) { return "" }
sub_y :: proc(x: $T) -> int where intrinsics.type_is_subtype_of(T, Base) { return 0 }
sub_n :: proc(x: $T) -> string where !intrinsics.type_is_subtype_of(T, Base) { return "" }
fld_y :: proc(x: $T) -> int where intrinsics.type_has_field(T, "x") { return 0 }
fld_n :: proc(x: $T) -> string where !intrinsics.type_has_field(T, "x") { return "" }
var_y :: proc(x: $T) -> int where intrinsics.type_is_variant_of(Shape, T) { return 0 }
var_n :: proc(x: $T) -> string where !intrinsics.type_is_variant_of(Shape, T) { return "" }
spe_y :: proc(x: $T) -> int where intrinsics.type_is_specialization_of(T, List) { return 0 }
spe_n :: proc(x: $T) -> string where !intrinsics.type_is_specialization_of(T, List) { return "" }
elm_y :: proc(x: $T) -> int where intrinsics.type_elem_type(T) == f32 { return 0 }
elm_n :: proc(x: $T) -> string where intrinsics.type_elem_type(T) != f32 { return "" }
cor_y :: proc(x: $T) -> int where intrinsics.type_core_type(T) == int { return 0 }
cor_n :: proc(x: $T) -> string where intrinsics.type_core_type(T) != int { return "" }
bse_y :: proc(x: $T) -> int where intrinsics.type_bit_set_elem_type(T) == Color { return 0 }
bse_n :: proc(x: $T) -> string where intrinsics.type_bit_set_elem_type(T) != Color { return "" }
fty_y :: proc(x: $T) -> int where intrinsics.type_field_type(T, "x") == f32 { return 0 }
fty_n :: proc(x: $T) -> string where intrinsics.type_field_type(T, "x") != f32 { return "" }

cmp :: proc{cmp_y, cmp_n}
ord :: proc{ord_y, ord_n}
num :: proc{num_y, num_n}
sim :: proc{sim_y, sim_n}
key :: proc{key_y, key_n}
sli :: proc{sli_y, sli_n}
idx :: proc{idx_y, idx_n}
big :: proc{big_y, big_n}
sub :: proc{sub_y, sub_n}
fld :: proc{fld_y, fld_n}
var :: proc{var_y, var_n}
spe :: proc{spe_y, spe_n}
elm :: proc{elm_y, elm_n}
cor :: proc{cor_y, cor_n}
bse :: proc{bse_y, bse_n}
fty :: proc{fty_y, fty_n}

work :: proc(i: int, f: f32, s: []int, fs: []f32, m: map[int]int, p: Point, d: Derived, be: u32be, l: List(int), c: Color, sm: Small, cs: bit_set[Color], ds: bit_set[Small], ip: IPoint) {
    _ = cmp(i)
    _ = cmp(s)
    _ = ord(f)
    _ = ord(p)
    _ = num(c)
    _ = num("s")
    _ = sim(i)
    _ = sim(f)
    _ = key("s")
    _ = key(m)
    _ = sli(s)
    _ = sli(i)
    _ = idx(m)
    _ = idx(f)
    _ = big(be)
    _ = big(i)
    _ = sub(d)
    _ = sub(p)
    _ = fld(p)
    _ = fld(d)
    _ = var(i)
    _ = var(f)
    _ = spe(l)
    _ = spe(i)
    _ = elm(fs)
    _ = elm(s)
    _ = cor(c)
    _ = cor(sm)
    _ = bse(cs)
    _ = bse(ds)
    _ = fty(p)
    _ = fty(ip)
}
`

@(test)
test_overload_where_intrinsics :: proc(t: ^testing.T) {
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{has_live = true, live_text = WHERE_SRC}) {
        return
    }
    defer check_end(&env)
    c := &env.c
    Where_Case :: struct {
        text: string,
        want: string,
    }
    cases := []Where_Case {
        {"cmp(i)", "int"}, {"cmp(s)", "string"},
        {"ord(f)", "int"}, {"ord(p)", "string"},
        {"num(c)", "int"}, {`num("s")`, "string"},
        {"sim(i)", "int"}, {"sim(f)", "string"},
        {`key("s")`, "int"}, {"key(m)", "string"},
        {"sli(s)", "int"}, {"sli(i)", "string"},
        {"idx(m)", "int"}, {"idx(f)", "string"},
        {"big(be)", "int"}, {"big(i)", "string"},
        {"sub(d)", "int"}, {"sub(p)", "string"},
        {"fld(p)", "int"}, {"fld(d)", "string"},
        {"var(i)", "int"}, {"var(f)", "string"},
        {"spe(l)", "int"}, {"spe(i)", "string"},
        {"elm(fs)", "int"}, {"elm(s)", "string"},
        {"cor(c)", "int"}, {"cor(sm)", "string"},
        {"bse(cs)", "int"}, {"bse(ds)", "string"},
        {"fty(p)", "int"}, {"fty(ip)", "string"},
    }
    for k in cases {
        at := strings.index(WHERE_SRC, k.text)
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
    }
    testing.expect_value(t, c.err, nil)
}
