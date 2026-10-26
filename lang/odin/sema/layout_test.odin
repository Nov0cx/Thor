package odinsema

import "base:runtime"

import "core:fmt"
import "core:strings"
import "core:testing"

// A type and the size and alignment `odin check` gives it; -1 when it has no layout.
@(private = "file")
Layout_Case :: struct {
    type:  string,
    size:  i64,
    align: i64,
}

// A field offset expression and the offset `odin check` gives it; -1 when it has none.
@(private = "file")
Offset_Case :: struct {
    expr: string,
    want: i64,
}

@(private = "file")
LAYOUT_DECLS :: `
Point :: struct {x, y: f32}
E3 :: enum {A, B, C}
E5 :: enum {A = 5, B, C, D, E, F, G, H}
E9 :: enum {A = 1, B = 9}
EN :: enum {A = -3, B = 4}
EB :: enum {}
E16 :: enum u16 {A}
Bf :: bit_field u16 {a: u8 | 4, b: u16 | 12}
P :: distinct ^int
S1 :: struct {a: u8, b: i32, c: u8}
S2 :: struct #packed {a: u8, b: i32, c: u8}
S3 :: struct #raw_union {a: u8, b: i64, c: [3]u16}
S4 :: struct #align(16) {a: u8}
S6 :: struct #min_field_align(4) {a: u8, b: u8}
S7 :: struct #max_field_align(2) {a: u8, b: i64}
S8 :: struct {}
S9 :: struct {a: i64, b: u8}
S10 :: struct {using p: Point, z: f32, s: string, d: u8}
S11 :: struct #raw_union {a: [5]u8, b: u32}
S12 :: struct #min_field_align(8) #max_field_align(16) {a: u8, b: i128}
S13 :: struct #align(2) {a: i64}
S14 :: struct {a: u8, b: [3]S1, c: complex64, d: u8}
S15 :: struct #max_field_align(4) {a: u8, b: i64, c: u8}
FA :: struct #field_align(4) {a: u8, b: u8}
R2 :: struct #raw_union #align(16) {a: u8}
R4 :: struct {a: S8, b: u8}
R5 :: struct {a: u8, v: #simd[4]f32}
R7 :: struct #raw_union #max_field_align(1) {a: u8, b: i64}
R9 :: struct #raw_union #min_field_align(8) {a: [3]u8}
X2 :: struct #align(2) {a: u8, b: i64, c: u8}
U1 :: union {int, f32}
U2 :: union {u8, i16}
U3 :: union #no_nil {int, f32}
U4 :: union {^int}
U5 :: union #no_nil {^int, ^f32}
U8 :: union #shared_nil {^int, ^f32}
U9 :: union #align(16) {u8}
U10 :: union {}
U11 :: union {[3]u8, u16}
U12 :: union {i128, u8}
U13 :: union {string, int}
U14 :: union {cstring}
U16 :: union {proc()}
U17 :: union {[]int}
U19 :: union {S8}
V1 :: union {typeid}
V2 :: union {P}
V3 :: union #align(2) {int, f32}
V4 :: union #align(4) {^int}
V5 :: union {V4}
W1 :: union #align(1) {i64, u8}
W2 :: union #align(4) {[9]u8, i64}
W3 :: union #align(16) {[9]u8, i64}
W4 :: union {[9]u8, i64}
W6 :: union {[17]u8, i128}
List :: struct($T: typeid) {data: [4]T, n: int}
Opt :: union($T: typeid) {T}
D1 :: distinct S1
Node :: struct {next: ^Node, v: int}
Self :: struct {a: int, s: Self}
Ping :: struct {p: Pong}
Pong :: struct {p: Ping}
`

@(private = "file")
AMD64_CASES := [?]Layout_Case {
    {"string", 16, 8},
    {"cstring", 8, 8},
    {"any", 16, 8},
    {"typeid", 8, 8},
    {"complex32", 4, 2},
    {"complex128", 16, 8},
    {"quaternion64", 8, 2},
    {"quaternion256", 32, 8},
    {"i128", 16, 16},
    {"u32be", 4, 4},
    {"f16", 2, 2},
    {"[dynamic]int", 40, 8},
    {"map[int]int", 32, 8},
    {"map[string]u8", 32, 8},
    {"[]u8", 16, 8},
    {"proc()", 8, 8},
    {"S1", 12, 4},
    {"S2", 6, 1},
    {"S3", 8, 8},
    {"S4", 16, 16},
    {"S6", 8, 4},
    {"S7", 10, 2},
    {"S8", 0, 1},
    {"S9", 16, 8},
    {"S10", 40, 8},
    {"S11", 8, 4},
    {"S12", 32, 16},
    {"S13", 8, 2},
    {"S14", 52, 4},
    {"S15", 16, 4},
    {"FA", 8, 4},
    {"R2", 16, 16},
    {"R4", 1, 1},
    {"R5", 32, 16},
    {"R7", 8, 1},
    {"R9", 8, 8},
    {"X2", 18, 2},
    {"U1", 16, 8},
    {"U2", 4, 2},
    {"U3", 16, 8},
    {"U4", 8, 8},
    {"U5", 16, 8},
    {"U8", 16, 8},
    {"U9", 16, 16},
    {"U10", 0, 1},
    {"U11", 6, 2},
    {"U12", 32, 16},
    {"U13", 24, 8},
    {"U14", 8, 8},
    {"U16", 8, 8},
    {"U17", 24, 8},
    {"U19", 1, 1},
    {"V1", 16, 8},
    {"V2", 8, 8},
    {"V3", 10, 2},
    {"V4", 8, 4},
    {"V5", 12, 4},
    {"W1", 9, 1},
    {"W2", 16, 4},
    {"W3", 32, 16},
    {"W4", 24, 8},
    {"W6", 32, 16},
    {"Opt(int)", 16, 8},
    {"Opt(^int)", 8, 8},
    {"bit_set[0..<8]", 1, 1},
    {"bit_set[0..=8]", 2, 2},
    {"bit_set[1..=8]", 1, 1},
    {"bit_set[0..<65]", 16, 16},
    {"bit_set['a'..='z']", 4, 4},
    {"bit_set[E3]", 1, 1},
    {"bit_set[E5]", 1, 1},
    {"bit_set[E9]", 2, 2},
    {"bit_set[EN]", 1, 1},
    {"bit_set[EB]", 1, 1},
    {"bit_set[E3; u32]", 4, 4},
    {"bit_set[-3..=4]", 1, 1},
    {"Bf", 2, 2},
    {"E16", 2, 2},
    {"matrix[2, 2]f32", 16, 4},
    {"matrix[3, 3]f32", 36, 4},
    {"matrix[4, 4]f64", 128, 8},
    {"#row_major matrix[2, 3]f32", 24, 4},
    {"#simd[4]f32", 16, 16},
    {"#simd[8]u8", 8, 8},
    {"#simd[32]f64", 256, 256},
    {"#soa[4]Point", 32, 4},
    {"#soa[]Point", 24, 8},
    {"#soa[dynamic]Point", 48, 8},
    {"#soa[3]S1", 20, 4},
    {"List(u8)", 16, 8},
    {"List", -1, -1},
    {"Opt", -1, -1},
    {"D1", 12, 4},
    {"[E3]i16", 6, 2},
    {"[E5]u8", 8, 1},
    {"[3]S1", 36, 4},
    {"[0]int", 0, 8},
    {"Node", 16, 8},
    {"Self", -1, -1},
    {"Ping", -1, -1},
}

@(private = "file")
OFFSET_CASES := [?]Offset_Case {
    {"offset_of(S1, b)", 4},
    {"offset_of(S1, c)", 8},
    {"offset_of(S2, c)", 5},
    {"offset_of(S3, c)", 0},
    {"offset_of(S6, b)", 4},
    {"offset_of(S7, b)", 2},
    {"offset_of(S10, s)", 16},
    {"offset_of(S10, d)", 32},
    {"offset_of(S10, y)", 4},
    {"offset_of(S12, b)", 16},
    {"offset_of(S14, c)", 40},
    {"offset_of(S15, c)", 12},
    {"offset_of(R5, v)", 16},
    {"offset_of(X2, c)", 16},
    {"offset_of(List(u8), n)", 8},
    {`offset_of_by_string(S1, "c")`, 8},
    {"offset_of(s1.b)", 4},
    {"offset_of(S1, missing)", -1},
    {"offset_of(Self, a)", -1},
}

// The checker's value of each `size_of`/`align_of`/`offset_of` against the numbers of `odin check`.
@(private = "file")
expect_layouts :: proc(t: ^testing.T, target: Target, cases: []Layout_Case, offsets: []Offset_Case, loc := #caller_location) {
    sb := strings.builder_make(context.temp_allocator)
    strings.write_string(&sb, "package p\n")
    strings.write_string(&sb, LAYOUT_DECLS)
    strings.write_string(&sb, "s1: S1\n")
    for k, i in cases {
        fmt.sbprintf(&sb, "Z%d :: size_of(%s)\nA%d :: align_of(%s)\n", i, k.type, i, k.type)
    }
    for k, i in offsets {
        fmt.sbprintf(&sb, "O%d :: %s\n", i, k.expr)
    }
    env: Check_Env
    if !check_begin(t, &env, Snapshot_Input{target = target, has_live = true, live_text = strings.to_string(sb)}) {
        return
    }
    defer check_end(&env)
    value_of :: proc(t: ^testing.T, c: ^Checker, name: string, loc: runtime.Source_Code_Location) -> i64 {
        sym, ok := find_symbol(c, ANON_FILE, name)
        if !testing.expectf(t, ok, "%s: not declared", name, loc = loc) {
            return -2
        }
        v, is_int := item_operand(c, sym).value.(i64)
        return is_int ? v : -1
    }
    for k, i in cases {
        size := value_of(t, &env.c, fmt.tprintf("Z%d", i), loc)
        align := value_of(t, &env.c, fmt.tprintf("A%d", i), loc)
        testing.expectf(t, size == k.size && align == k.align, "%s: got %d/%d, want %d/%d", k.type, size, align, k.size, k.align, loc = loc)
    }
    for k, i in offsets {
        got := value_of(t, &env.c, fmt.tprintf("O%d", i), loc)
        testing.expectf(t, got == k.want, "%s: got %d, want %d", k.expr, got, k.want, loc = loc)
    }
}

@(test)
test_layout_amd64 :: proc(t: ^testing.T) {
    expect_layouts(t, Target{os = .Windows, arch = .amd64}, AMD64_CASES[:], OFFSET_CASES[:])
}

@(test)
test_layout_32_bit :: proc(t: ^testing.T) {
    i386 := [?]Layout_Case {
        {"any", 16, 8},
        {"i64", 8, 8},
        {"i128", 16, 16},
        {"string", 8, 4},
        {"[dynamic]u8", 20, 4},
        {"map[int]int", 16, 4},
        {"#soa[]Point", 12, 4},
        {"#soa[dynamic]Point", 24, 4},
        {"union {string}", 12, 4},
        {"#simd[32]f64", 256, 256},
    }
    expect_layouts(t, Target{os = .Windows, arch = .i386}, i386[:], nil)
    wasm := [?]Layout_Case {
        {"string", 16, 8},
        {"cstring", 4, 4},
        {"[]u8", 16, 8},
        {"[dynamic]u8", 32, 8},
        {"map[int]int", 16, 4},
        {"i128", 16, 8},
        {"#soa[]Point", 16, 8},
        {"union {i128, u8}", 24, 8},
        {"union {[17]u8, i128}", 32, 8},
        {"bit_set[0..<128]", 16, 16},
    }
    expect_layouts(t, Target{os = .JS, arch = .wasm64p32}, wasm[:], nil)
    arm32 := [?]Layout_Case {
        {"i128", 16, 8},
        {"#simd[4]f32", 16, 8},
        {"union {i128, u8}", 24, 8},
    }
    expect_layouts(t, Target{os = .Linux, arch = .arm32}, arm32[:], nil)
}
