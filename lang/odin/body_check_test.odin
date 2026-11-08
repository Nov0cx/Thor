package odin

import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_live_call_arguments :: proc(t: ^testing.T) {
    root := fixture(t, "live_call_arguments", {
        {".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`},
        {"app/q/q.odin", "package q\n\nclone :: proc(s: string, n := 1, m := 2) -> string { return s }\n"},
    })
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "q"

f :: proc(a: int, b: int) {}
g :: proc(a: int, b := 2) {}
two :: proc() -> (int, int) { return 1, 2 }
group :: proc{f, g}

Obj :: struct { call: proc(o: ^Obj, k: int) }

main :: proc() {
	f(1)
	f(1, 2, 3)
	g(1, c = 3)
	g(a = 1, a = 2)
	g(a = 1, 2)
	_ = q.clone("a", 1, 2, 3)
	o: ^Obj
	o->call(1, 2)
	f(two())
	g(b = 1, a = 2)
	group(1)
	when ODIN_OS == .Linux {
		f(1)
	}
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"f(1)", "Parameter 'b' of type 'int' is missing in procedure call", 0},
        {"f(1, 2, 3)", "Too many arguments for 'f', expected 2 arguments, got 3", 0},
        {"c = 3", "No parameter named 'c' for this procedure type", 0},
        {"a = 2", "Duplicate parameter 'a' in procedure call", 0},
        {"2)\n\t_ = q", "Non-named parameter is not allowed to follow named parameter i.e. 'field = value' in a procedure call", 0},
        {"q.clone", "Too many arguments for 'q.clone', expected 1..=3 arguments, got 4", 0},
        {"o->call", "Too many arguments for 'o->call', expected 2 arguments, got 3", 0},
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_ARITY || d.code == CODE_NAMED || d.code == CODE_NIL_DEREF, "a call error carries a call id")
    }
}

// A builtin or a conversion with the wrong number of arguments, worded as the compiler words it.
@(test)
test_live_builtin_arity :: proc(t: ^testing.T) {
    root := fixture(t, "live_builtin_arity", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "base:builtin"

Point :: struct { x: int }
List :: struct($T: typeid) { v: T }

f :: proc(s: []int, x: int) {
	_ = len()
	_ = len(s, 0)
	_ = clamp(x, 0)
	_ = min(x)
	_ = max()
	_ = int()
	_ = int(x, 1)
	_ = Point()
	_ = min(int)
	_ = max(int, 0)
	_ = min(x, 1)
	_ = clamp(x, 0, 1)
	_ = len(..s)
	_ = raw_data()
	_ = builtin.min(x)
	_ = builtin.len(s, 1)
	l: List(int)
	_ = l
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {")\n\t_ = len(s, 0)", "Too few arguments for 'len', expected 1, got 0", 0},
        {"0)\n\t_ = clamp", "Too many arguments for 'len', expected 1, got 2", 0},
        {")\n\t_ = min(x)", "Too few arguments for 'clamp', expected 3, got 2", 0},
        {"min(x)", "Too few arguments for 'min', two or more are required", 0},
        {")\n\t_ = int()", "Too few arguments for 'max', expected 1, got 0", 0},
        {"int()", "Missing argument in conversion to 'int'", 0},
        {"int(x, 1)", "Too many arguments in conversion to 'int'", 0},
        {"Point()", "Missing argument in conversion to 'Point'", 0},
        {"max(int, 0)", "If 'max' gets a type, only 1 arguments is allowed, got 2", 0},
        {")\n\t_ = builtin.min", "Too few arguments for 'raw_data', expected 1, got 0", 0},
        {"builtin.min(x)", "Too few arguments for 'min', two or more are required", 0},
        {"1)\n\tl:", "Too many arguments for 'builtin.len', expected 1, got 2", 0},
    })
}

// A constant naming a builtin types as the builtin, an intrinsic takes what the compiler takes, and
// a `where` call with arguments of a `$` type holds for some instances.
@(test)
test_live_builtin_aliases_and_intrinsics :: proc(t: ^testing.T) {
    root := fixture(t, "live_builtin_aliases", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "base:builtin"
import "base:intrinsics"

my_abs :: builtin.abs
rem16 :: proc(x: f16) -> f16 { return x }
rem32 :: proc(x: f32) -> f32 { return x }
rem :: proc{rem16, rem32}

num :: proc(x: $T) -> T where intrinsics.type_is_numeric(T) { return x }
twice :: proc(x: $T) -> T { return num(x) }

f :: proc(x: f32, h: f16, p: rawptr, n: uint, cx: complex64) {
	a: f32 = rem(my_abs(x))
	b: f32 = rem(my_abs(h))
	intrinsics.mem_zero(p, n)
	m: f32 = rem(abs(cx))
	_, _, _ = a, b, m
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"rem(my_abs(h))", "Cannot assign value 'rem(my_abs(h))' of type 'f16' to 'f32' in a variable declaration", 0},
    })
}

// A tag before each name of a parameter list, and the components of a quaternion.
@(test)
test_live_tagged_names_and_quaternions :: proc(t: ^testing.T) {
    root := fixture(t, "live_tagged_names", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "core:math"

v1 :: proc "contextless" (#any_int year, #any_int month, #any_int day: i64) -> int { return 0 }
v2 :: proc "contextless" (s: string) -> int { return 0 }
vv :: proc{v1, v2}

f :: proc(q: quaternion64, year, month, day: i64, m: int) {
	t1 := 1 - q.w*q.w
	_ = math.sqrt(t1)
	_ = vv(year, month, day)
	_ = v1(m, m, m)
	_ = v1(m, m)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"v1(m, m)", "Parameter 'day' of type 'i64' is missing in procedure call", 0},
    })
}

// A struct converts to the type of its `using` field, and a type that is not distinct is its own
// definition behind a pointer or a slice.
@(test)
test_live_subtypes_and_aliases :: proc(t: ^testing.T) {
    root := fixture(t, "live_subtypes", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

Base :: struct { x: int }
Outer :: struct { using b: Base, y: int }
Matrix :: [6]f32
D :: distinct [6]f32
take_base :: proc(b: Base) {}
take_m :: proc(m: ^Matrix) {}
take_d :: proc(m: ^D) {}
take_s :: proc(m: []Matrix) {}

f :: proc() {
	o: Outer
	take_base(o)
	a: [6]f32
	take_m(&a)
	take_d(&a)
	s: [][6]f32
	take_s(s)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"&a)\n\ts:", "Cannot assign value '&a' of type '^[6]f32' to '^D' in a procedure argument", 0},
    })
}

// Conversions the compiler allows: a distinct rawptr to rawptr, an enum to `#any_int`, `!` of a
// distinct bool, `len` in arithmetic to another integer, a `#subtype` field, a record parameter
// default, `builtin.new` and an intrinsic the listing leaves out.
@(test)
test_live_compiler_conversions :: proc(t: ^testing.T) {
    root := fixture(t, "live_compiler_conversions", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "base:builtin"
import "base:intrinsics"

HANDLE :: distinct rawptr
BOOL :: distinct b32
E :: enum u32 { A, B }
Raw :: struct { n: int }
Wrap :: struct($T: typeid, $D: int = 2) {
	#subtype impl: ^Raw,
}
W :: Wrap(int)

take_raw :: proc(r: ^Raw) {}
take_any :: proc(#any_int x: int) {}
take_bool :: proc(b: bool) {}
take_uint :: proc(u: uint) {}
take_w :: proc(w: ^Wrap(int, 2)) {}

f :: proc(h: HANDLE, b: BOOL, s: []int, w: W) {
	p: rawptr = h
	take_any(E.B)
	take_bool(!b)
	take_uint(len(s) + 1)
	take_raw(w)
	ww := w
	take_w(&ww)
	q := builtin.new(int)
	_ = q
	_ = intrinsics.Fast_Math_Flags{}
	_ = p
	take_uint(s[0])
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"s[0])", "Cannot assign value 's[0]' of type 'int' to 'uint' in a procedure argument", 0},
    })
}

// An undeclared name leaves the body errors out.
@(test)
test_live_body_after_names :: proc(t: ^testing.T) {
    root := fixture(t, "live_body_after_names", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nf :: proc(a: int) {}\n\nmain :: proc() {\n\tf()\n\t_ = zork\n}\n"
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {{"zork", "Undeclared name: zork", 0}})
}

@(test)
test_live_missing_members :: proc(t: ^testing.T) {
    root := fixture(t, "live_missing_members", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

P :: struct { x: int }
Q :: struct { p: P }
E :: enum { A, B }
B :: bit_field u8 { lo: u8 | 4 }

main :: proc() {
	p: ^P
	_ = p.y
	q: Q
	_ = q.p.z
	_ = E.D
	bb: B
	_ = bb.hi
	_ = q.p.x + p.x
	_ = E.A
	a: any
	_ = a.data
	_ = a.id
	_ = a.size
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"p.y", "'p' of type '^P' has no field 'y'", 0},
        {"q.p.z", "'q.p' of type 'P' has no field 'z'", 0},
        {"E.D", "Type 'E' has no field 'D'", 0},
        {"bb.hi", "'bb' of type 'B' has no field 'hi'", 0},
        {"a.size", "'a' of type 'any' has no field 'size'", 0},
    })
}

@(test)
test_live_switch_cases :: proc(t: ^testing.T) {
    root := fixture(t, "live_switch_cases", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

E :: enum { A, B, C }
U :: union { int, string, f32 }

main :: proc() {
	e: E
	u: U
	switch e {
	case .A, .B:
	}
	outer: switch v in u {
	case int:
	}
	#partial switch e {
	case .A:
	}
	switch e {
	case .A ..= .C:
	}
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"switch e", "Unhandled switch case: C", 0},
        {"switch v", "Unhandled switch cases: string, f32", 0},
    })
}

@(test)
test_live_static_asserts :: proc(t: ^testing.T) {
    root := fixture(t, "live_static_asserts", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

N :: 3
#assert(N == 4)
#assert(N > 4, "N is too small")
#assert(N == 3)

main :: proc() {
	#assert(size_of(int) == 4)
	#assert(size_of(int) == 8)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"#assert(N == 4)", "Compile time assertion: N == 4", 0},
        {"#assert(N > 4", `Compile time assertion: N > 4 ("N is too small")`, 0},
        {"#assert(size_of(int) == 4)", "Compile time assertion: size_of(int) == 4", 0},
    })
}

@(test)
test_live_argument_mismatches :: proc(t: ^testing.T) {
    root := fixture(t, "live_argument_mismatches", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

I :: distinct int

take :: proc(a: int, s: string) {}
rest :: proc(xs: ..int) {}
want_i :: proc(d: I) {}
store :: proc(dst: ^$T, val: T) {}

main :: proc() {
	s: string
	i: int
	take(s, "a")
	take(1, 2)
	take(1, nil)
	rest(1, s)
	want_i(i)
	want_i(3)
	take(1, s)
	when ODIN_OS == .Linux {
		take(s, s)
	}
	_ = max(i, "zq")
	_ = clamp(i, true, 3)
	_ = max(i, true)
	_ = min(true, i)
	u: uint
	store(&u, "zq")
	store(&u, 3)
	_ = min(1, 2)
	_ = max(i, 2)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"s, \"a\"", "Cannot assign value 's' of type 'string' to 'int' in a procedure argument", 0},
        {"2)", "Cannot convert '2' to 'string' from 'untyped integer', got 2", 0},
        {"nil)", "Cannot convert untyped value 'nil' to 'string' from 'untyped nil'", 0},
        {"s)\n\twant_i", "Cannot assign value 's' of type 'string' to 'int' in a procedure argument", 0},
        {"i)\n\twant_i(3)", "Cannot assign value 'i' of type 'int' to 'I' in a procedure argument", 0},
        {"\"zq\"", "Cannot convert '\"zq\"' to 'int' from 'untyped string', got \"zq\"", 0},
        {"clamp(i, true", "Expected an ordered numeric or string type to 'clamp', got 'untyped bool'", 0},
        {"true)", "Expected an ordered numeric type to 'max', got 'untyped bool'", 0},
        {"min(true", "Expected an ordered numeric type to 'min', got 'untyped bool'", 0},
        {"\"zq\")\n\tstore(&u, 3)", "Cannot convert '\"zq\"' to 'uint' from 'untyped string', got \"zq\"", 0},
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_MISMATCH)
    }
}

@(test)
test_live_assign_mismatches :: proc(t: ^testing.T) {
    root := fixture(t, "live_assign_mismatches", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

I :: distinct int
E :: enum { A, B }

g: int = "top"

main :: proc() {
	s: string
	i: int
	d: I
	i = s
	i = "a"
	d = i
	x: int = s
	e: f32 = i
	k: E = 1
	r: string = 'a'
	ok: u8 = 300
	v: [3]f32 = 0
	d = 3
	i += "zq"
	i <<= "zq"
	i <<= 2
	b := true
	b &&= 1
	s += "ok"
	e += 1
	_, _, _, _, _, _ = x, e, k, r, ok, v
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"\"top\"", "Cannot convert '\"top\"' to 'int' from 'untyped string', got \"top\"", 0},
        {"s\n\ti = \"a\"", "Cannot assign value 's' of type 'string' to 'int' in assignment", 0},
        {"\"a\"", "Cannot convert '\"a\"' to 'int' from 'untyped string', got \"a\"", 0},
        {"i\n\tx: int", "Cannot assign value 'i' of type 'int' to 'I' in assignment", 0},
        {"s\n\te: f32", "Cannot assign value 's' of type 'string' to 'int' in a variable declaration", 0},
        {"i\n\tk: E", "Cannot assign value 'i' of type 'int' to 'f32' in a variable declaration", 0},
        {"1\n\tr:", "Cannot convert untyped value '1' to 'E' from 'untyped integer'", 0},
        {"'a'", "Cannot convert ''a'' to 'string' from 'untyped rune', got 97", 0},
        {"300", "Cannot convert numeric value '300' from '300' to 'u8' from 'untyped integer'", 0},
        {"\"zq\"", "Cannot convert '\"zq\"' to 'int' from 'untyped string', got \"zq\"", 0},
        {"\"zq\"", "Cannot convert untyped value '\"zq\"' to 'untyped integer' from 'untyped string'", 1},
        {"1\n\ts +=", "Cannot convert '1' to 'bool' from 'untyped integer', got 1", 0},
    })
}

@(test)
test_live_return_mismatches :: proc(t: ^testing.T) {
    root := fixture(t, "live_return_mismatches", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

E :: enum { A, B }

one :: proc() -> int { return "x" }
two :: proc() -> (int, string) {
	s: string
	return s, 1
}
fine :: proc() -> (E, bool) { return .A, true }
named :: proc() -> (n: int) {
	inner := proc() -> string { return "ok" }
	_ = inner
	return
}
pair :: proc() -> (int, string) { return two() }
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"\"x\"", "Cannot convert '\"x\"' to 'int' from 'untyped string', got \"x\"", 0},
        {"s, 1", "Cannot assign value 's' of type 'string' to 'int' in return statement", 0},
        {"1\n}", "Cannot convert '1' to 'string' from 'untyped integer', got 1", 0},
    })
}

@(test)
test_live_group_no_match :: proc(t: ^testing.T) {
    root := fixture(t, "live_group_no_match", {
        {".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`},
        {"app/q/q.odin", "package q\n\nfa :: proc(a: i32) {}\nfb :: proc(a: string) {}\ngrp :: proc{fa, fb}\n"},
    })
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "q"

fi :: proc(a: int) {}
fs :: proc(a: string) {}
g :: proc{fi, fs}
f2 :: proc(a: int, b: int) {}
g2 :: proc{fi, f2}
pi :: proc(a: $T) {}
gp :: proc{fs, pi}
va :: proc(a: any) {}
ga :: proc{fs, va}
t1 :: proc(x: [dynamic]$E, ys: ..E) {}
t2 :: proc(x: []int, ys: ..int) {}
tt :: proc{t1, t2}
p1 :: proc(x: $T/[]$E, ys: ..E) {}
p2 :: proc(x: string, ys: ..int) {}
pp :: proc{p1, p2}
v1 :: proc(x: int, ys: ..$E) {}
v2 :: proc(x: string, ys: ..int) {}
vv :: proc{v1, v2}

main :: proc() {
	x: f32
	g(x)
	g2(1, 2, 3)
	g2()
	q.grp(x)
	g(1)
	g("a")
	g2(1, b = 2)
	gp(x)
	ga(x)
	g(true)
	str: string
	delete(str, 0)
	arr: [dynamic]int
	append(&arr, "x")
	append(&arr, 1, 2)
	delete(arr)
	append(&arr)
	tt(arr)
	tt(arr, 1)
	pp(str)
	vv(1)
	inject_at(&arr, 0)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"g(x)", "No procedures or ambiguous call for procedure group 'g' that match with the given arguments", 0},
        {"g2(1, 2, 3)", "No procedures or ambiguous call for procedure group 'g2' that match with the given arguments", 0},
        {"g2()", "No procedures or ambiguous call for procedure group 'g2' that match with the given arguments", 0},
        {"q.grp(x)", "No procedures or ambiguous call for procedure group 'q.grp' that match with the given arguments", 0},
        {"g(true)", "No procedures or ambiguous call for procedure group 'g' that match with the given arguments", 0},
        {"delete(str, 0)", "No procedures or ambiguous call for procedure group 'delete' that match with the given arguments", 0},
        {"append(&arr, \"x\")", "No procedures or ambiguous call for procedure group 'append' that match with the given arguments", 0},
        {"vv(1)", "No procedures or ambiguous call for procedure group 'vv' that match with the given arguments", 0},
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_OVERLOAD, "a group error carries the overload id")
    }
}

@(test)
test_live_constant_overflow :: proc(t: ^testing.T) {
    root := fixture(t, "live_constant_overflow", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

N :: 300
I :: distinct i8
X :: u8(N)
Z : u8 : 999

f :: proc(a: u8) {}
r :: proc() -> i16 { return 40000 }

main :: proc() {
	a: u8 = 200 + 100
	b: u8 = N
	c: u8 = 'Ā'
	d: u64 = -1
	k: I = -129
	f(256)
	g := i8(-129)
	h: u8 = 255
	i: u64 = 0x7fff_ffff_ffff_ffff
	j: u32 = 'a'
	_, _, _, _, _, _, _, _, _, _ = a, b, c, d, k, g, h, i, j, Z
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"N)", "Cannot cast 'N' as 'u8' from 'untyped integer'", 0},
        {"999", "Cannot convert numeric value '999' from '999' to 'u8' from 'untyped integer'", 0},
        {"40000", "Cannot convert numeric value '40000' from '40000' to 'i16' from 'untyped integer'", 0},
        {"200 + 100", "Cannot convert numeric value '300' from '200 + 100' to 'u8' from 'untyped integer'", 0},
        {"N\n", "Cannot convert numeric value '300' from 'N' to 'u8' from 'untyped integer'", 0},
        {"'Ā'", "Cannot convert numeric value '256' from ''Ā'' to 'u8' from 'untyped rune'", 0},
        {"-1", "Cannot convert numeric value '-1' from '-1' to 'u64' from 'untyped integer'", 0},
        {"-129", "Cannot convert numeric value '-129' from '-129' to 'I' from 'untyped integer'", 0},
        {"256", "Cannot convert numeric value '256' from '256' to 'u8' from 'untyped integer'", 0},
        {"-129)", "Cannot cast '-129' as 'i8' from 'untyped integer'", 0},
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_OVERFLOW, "an overflow carries the overflow id")
    }
}

// A constant conversion the compiler refuses: a string into a type that is no string, a number or
// bool into a string, a number into a bool.
@(test)
test_live_cast_refused :: proc(t: ^testing.T) {
    root := fixture(t, "live_cast_refused", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

E :: enum u8 { A }

main :: proc() {
	_ = u8("zq")
	_ = E("x")
	_ = string(true)
	_ = string(65)
	_ = bool(1)
	_ = int(true)
	_ = cstring("ok")
	_ = f32(1)
	str: string
	cs: cstring
	n: int
	_ = i8(str)
	_ = rawptr(cs)
	_ = uintptr(cs)
	_ = string(n)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"\"zq\"", "Cannot cast '\"zq\"' as 'u8' from 'untyped string'", 0},
        {"\"x\"", "Cannot cast '\"x\"' as 'E' from 'untyped string'", 0},
        {"true)\n\t_ = string(65)", "Cannot cast 'true' as 'string' from 'untyped bool'", 0},
        {"65", "Cannot cast '65' as 'string' from 'untyped integer'", 0},
        {"1)\n\t_ = int", "Cannot cast '1' as 'bool' from 'untyped integer'", 0},
        {"str)", "Cannot cast 'str' as 'i8' from 'string'", 0},
        {"cs)\n\t_ = string", "Cannot cast 'cs' as 'uintptr' from 'cstring'", 0},
        {"n)", "Cannot cast 'n' as 'string' from 'int'", 0},
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_MISMATCH)
    }
}

@(test)
test_live_missing_returns :: proc(t: ^testing.T) {
    root := fixture(t, "live_missing_returns", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "core:os"

w1 :: proc() -> int {
	when ODIN_OS == .Windows {
		return 1
	}
}
w2 :: proc() -> int {
	when ODIN_OS == .Windows {
		return 1
	} else {
		return 2
	}
}
p1 :: proc() -> int { panic("x") }
p2 :: proc() -> int { os.exit(1) }
p3 :: proc() -> int { unreachable() }
f1 :: proc(a: int) -> int {
	for {
		if a > 0 { break }
	}
}
f2 :: proc(a: int) -> int {
	outer: for {
		for { break outer }
	}
}
f3 :: proc(a: int) -> int {
	for {
		for { break }
	}
}
s1 :: proc(a: int) -> int {
	switch a {
	case 1: return 1
	case: return 2
	}
}
s2 :: proc(a: int) -> int {
	switch a {
	case 1: fallthrough
	case: return 2
	}
}
s3 :: proc(a: int) -> int {
	switch a {
	case 1: return 1
	}
}
s4 :: proc(a: int) -> int {
	switch a {
	case 1:
		if a > 0 { break }
		return 1
	case: return 2
	}
}
E :: enum {A, B}
s5 :: proc(e: E) -> int {
	switch e {
	case .A: return 1
	case .B: return 2
	}
}
b1 :: proc() -> int {
	{
		return 1
	}
}
l1 :: proc() -> int {
	inner := proc() -> int {
	}
	return inner()
}
r1 :: proc() -> int {
	for i in 0..<3 { return i }
}
d1 :: proc() -> int {
	return 1
	;
}
i1 :: proc(a: int) -> int {
	if a > 0 { return 1 } else if a < 0 { return 2 } else { return 3 }
}
t1 :: proc() -> int {
	intrinsics_trap()
}
intrinsics_trap :: proc() -> ! { for {} }
fs :: proc(a: int) -> int {
	for a > 0 {}
}
x1 :: proc() -> int {
	defer {}
	return 1
}
lb :: proc() -> int {
	blk: {
		return 1
	}
}
lb2 :: proc(a: int) -> int {
	blk: {
		if a > 0 { break blk }
		return 1
	}
}
g1 :: proc(d: ^[dynamic]int) -> bool {
	resize(d, 0)
}
g2 :: proc() {}
n1 :: proc() -> int {
	return helper()

	helper :: proc() -> int { return 1 }
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"}\nf2 ::", "Missing return statement at the end of the procedure 'f1'", 0},
        {"}\nf3 ::", "Missing return statement at the end of the procedure 'f2'", 0},
        {"}\ns4 ::", "Missing return statement at the end of the procedure 's3'", 0},
        {"}\nE ::", "Missing return statement at the end of the procedure 's4'", 0},
        {"}\nb1 ::", "Missing return statement at the end of the procedure 's5'", 0},
        {"}\n\treturn inner()", "Missing return statement at the end of the procedure", 0},
        {"}\nd1 ::", "Missing return statement at the end of the procedure 'r1'", 0},
        {"}\nx1 ::", "Missing return statement at the end of the procedure 'fs'", 0},
        {"}\ng2 ::", "Missing return statement at the end of the procedure 'g1'", 0},
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_RETURN, "a missing return carries its id")
    }
}

@(test)
test_live_or_return :: proc(t: ^testing.T) {
    root := fixture(t, "live_or_return", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

Err :: enum { None, Bad }
Other :: enum { None, X }

ok :: proc() -> (int, bool) { return 1, true }
er :: proc() -> (int, Err) { return 1, .None }
one :: proc() -> int { return 1 }

a :: proc() {
	_ = ok() or_return
}
b :: proc() -> int {
	_ = ok() or_return
	return 1
}
c :: proc() -> (n: int, e: Other) {
	_ = er() or_return
	return
}
d :: proc() -> (int, Err) {
	_ = er() or_return
	return 1, .None
}
e :: proc() -> bool {
	_ = one() or_return
	return true
}
f :: proc() -> (n: int, ok2: bool) {
	_ = ok() or_return
	return
}
g :: proc() -> (int, bool) {
	_ = ok() or_return
	return 1, true
}
h :: proc() -> Err {
	_ = er() or_return
	return .None
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"ok() or_return", "'or_return' requires the current procedure to have at least one return value", 0},
        {"ok() or_return", "Cannot assign end value of type 'bool' to 'int' in 'or_return'", 1},
        {"er() or_return", "Cannot assign end value of type 'Err' to 'Other' in 'or_return'", 0},
        {"er() or_return", "'or_return' within a procedure with more than 1 return value requires that the return values are named, allowing for early return", 1},
        {"one() or_return", "'or_return' expects an \"optional ok\" like value, or an n-valued expression where the last value is either a boolean or can be compared against 'nil', got int", 0},
        {"ok() or_return", "'or_return' within a procedure with more than 1 return value requires that the return values are named, allowing for early return", 3},
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_OR_RETURN, "an or_return error carries its id")
    }
}

@(test)
test_live_where_clauses :: proc(t: ^testing.T) {
    root := fixture(t, "live_where_clauses", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "base:intrinsics"

num :: proc(x: $T) -> T where intrinsics.type_is_numeric(T) { return x }
two :: proc(a: $A, b: $B) where A == B, size_of(A) == 8 {}
feature :: proc($test: $T) -> bool where intrinsics.type_is_string(T) { return true }
IS_FLOAT :: intrinsics.type_is_float
sd :: proc(a: $T) -> T where IS_FLOAT(T) { return a }
vd :: proc(a: $T/[$N]$E) -> E { return a[0] }
dot :: proc{sd, vd}

main :: proc() {
	_ = feature("avx2")
	_ = feature(1)
	v: [2]f32
	dx: f32 = dot(v)
	_ = dx
	_ = sd(v)
	_ = num("s")
	_ = num(1)
	two(1, 2)
	x: i32
	two(x, x)
	two(x, "a")
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"feature(1)", "'where' clause evaluated to false: intrinsics.type_is_string(T)", 0},
        {"sd(v)", "'where' clause evaluated to false: IS_FLOAT(T)", 0},
        {"num(\"s\")", "'where' clause evaluated to false: intrinsics.type_is_numeric(T)", 0},
        {"two(x, x)", "'where' clause evaluated to false: size_of(A) == 8", 0},
        {"two(x, \"a\")", "'where' clause evaluated to false: A == B", 0},
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_WHERE, "a where error carries its id")
    }
}

@(test)
test_live_assignment_counts :: proc(t: ^testing.T) {
    root := fixture(t, "live_assignment_counts", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

two :: proc() -> (int, int) { return 1, 2 }
one :: proc() -> int { return 1 }
K :: enum { A, B }

main :: proc() {
	k: K
	k = .A, 0
	arr: [2]int
	arr = {}, 0
	g, h, j := two(), 3
	_, _, _ = g, h, j
	ps: ^string
	str: string
	str = ps[1:], 0
	mm: map[int]int
	o1, o2 := mm[1], 0
	_, _ = o1, o2
	o1 = mm[1], 0
	for r, off in ps {
		o2 = off, 0
		_ = r
	}
	a, b := one()
	f := two()
	m, n: int
	m, n = one()
	m = two()
	p, q := two()
	m, n = 1, 2, 3
	mp: map[int]int
	s, t := mp[1]
	u := mp[1]
	v, w := 1, "x"
	_, _, _, _, _, _, _, _, _, _ = a, b, f, p, q, s, t, u, v, w
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"k = .A", "Assignment count mismatch '1' = '2'", 0},
        {"arr = {}", "Assignment count mismatch '1' = '2'", 0},
        {"str = ps", "Assignment count mismatch '1' = '2'", 0},
        {"o1 = mm", "Assignment count mismatch '1' = '2'", 0},
        {"o2 = off", "Assignment count mismatch '1' = '2'", 0},
        {"a, b := one()", "Assignment count mismatch '2' = '1'", 0},
        {"f := two()", "Assignment count mismatch '1' = '2'", 0},
        {"m, n = one()", "Assignment count mismatch '2' = '1'", 0},
        {"m = two()", "Assignment count mismatch '1' = '2'", 0},
        {"m, n = 1, 2, 3", "Assignment count mismatch '2' = '3'", 0},
    })
    for d in res.report.items {
        testing.expect(t, d.lint || d.code == CODE_COUNT, "a count error carries its id")
    }
}

@(test)
test_live_severities :: proc(t: ^testing.T) {
    root := fixture(t, "live_severities", {
        {".thor/odin-analyzer.lua", `return { diagnostics = { ["call/arity"] = "off", ["call/named"] = "warning", ["zork/none"] = "off", ["type/mismatch"] = "hint" } }`},
    })
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nf :: proc(a: int, b: int) {}\n\nmain :: proc() {\n\tf(1)\n\tf(1, c = 2)\n\tx: int = \"s\"\n\t_ = x\n}\n"
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"c = 2", "No parameter named 'c' for this procedure type", 0},
        {"\"s\"", "Cannot convert '\"s\"' to 'int' from 'untyped string', got \"s\"", 0},
    })
    if testing.expect_value(t, len(res.report.items), 2) {
        testing.expect_value(t, res.report.items[0].severity, lang.Diagnostic_Severity.Warning)
        testing.expect_value(t, res.report.items[1].severity, lang.Diagnostic_Severity.Hint)
    }
}

// A `$K` bound by the result of a procedure literal, and a `where` on a private constant of the callee's package.
@(test)
test_live_where_through_bindings :: proc(t: ^testing.T) {
    root := fixture(t, "live_where_bindings", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "core:math/linalg"
import "core:slice"

Vector2 :: [2]f32

cross2 :: proc "c" (a, b: Vector2) -> f32 {
	return linalg.cross(a, b)
}

cross3 :: proc "c" (a, b: [3]f32) -> f32 {
	return linalg.cross(a, b)
}

f :: proc() {
	Pair :: struct { key: u64, idx: u16 }
	rebuild :: proc(all: []Pair) {
		s := make([dynamic]Pair, 0, len(all))
		defer delete(s)
		slice.sort_by_key(s[:], proc(p: Pair) -> u64 { return p.key })
	}
	rebuild(nil)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"linalg.cross(a, b)", "Cannot assign value 'linalg.cross(a, b)' of type '[3]f32' to 'f32' in return statement", 1},
    })
}

// Builtin calls in a ternary, `append` with a spread, `$N` of a fixed-capacity array, a type from an intrinsic and an `#soa` group.
@(test)
test_live_builtin_corners :: proc(t: ^testing.T) {
    root := fixture(t, "live_builtin_corners", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "base:intrinsics"
import "base:runtime"
import "core:slice"

H :: struct { idx, gen: u32 }

Foot_S :: struct { len: int }
Foot_D :: struct { len, cap: int }
foot_s :: proc(a: ^$T/#soa[]$E) -> ^Foot_S { return nil }
foot_d :: proc(a: ^$T/#soa[dynamic]$E) -> ^Foot_D { return nil }
foot :: proc{foot_s, foot_d}

P :: struct { x: int }

grow :: proc(a: ^$T/#soa[dynamic]$E) -> int {
	return foot(a).cap
}

grow_p :: proc(a: ^#soa[dynamic]P) -> int {
	return foot(a).cap
}

add :: proc(array: ^$T/[dynamic]$E/u8, args: ..string, loc := #caller_location) -> (n: int, err: runtime.Allocator_Error) {
	for arg in args {
		k: int
		k, err = append(array, ..transmute([]E)(arg), loc=loc)
		n += k
	}
	return
}

fixed :: proc(array: ^$T/[dynamic; $N]$E, length: int) -> int {
	return min(N, length)
}

Map :: struct($N: uint, $Handle: typeid) where N < uint(max(intrinsics.type_field_type(Handle, "idx"))) {
	n: [N]Handle,
}

f :: proc(c: bool, s: string) {
	buf: [dynamic]u8
	k: int
	err: runtime.Allocator_Error
	k, err = append(&buf, ..transmute([]u8)(s), loc=#caller_location)
	top := max(intrinsics.type_field_type(H, "idx"))
	x := c ? max(int, 0) : 1
	_, _, _ = k, top, x
	stops: []H
	slice.stable_sort_by(stops, proc(a, b: H) -> bool {
		key := a.idx == 0 ? max(u32, 0) : a.idx
		return key < b.idx
	})
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"max(int, 0)", "If 'max' gets a type, only 1 arguments is allowed, got 2", 0},
        {"max(u32, 0)", "If 'max' gets a type, only 1 arguments is allowed, got 2", 0},
    })
}

// An intrinsic takes no string or bool constant for a number, and takes anything else its signature does not name.
@(test)
test_live_intrinsic_arguments :: proc(t: ^testing.T) {
    root := fixture(t, "live_intrinsic_arguments", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "base:intrinsics"
import "core:sync"

Futex :: distinct u32

f :: proc(n: u16) {
	tail: uint
	space: Futex
	sync.atomic_store(&tail, "zq")
	sync.atomic_add_explicit(&space, "zq", .Release)
	sync.atomic_store(&tail, 1)
	sync.atomic_add_explicit(&space, 1, .Release)
	p := intrinsics.alloca(n, true)
	q := intrinsics.alloca(n, 8)
	_, _ = p, q
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {`"zq"`, `Cannot convert '"zq"' to 'uint' from 'untyped string', got "zq"`, 0},
        {`"zq"`, `Cannot convert '"zq"' to 'Futex' from 'untyped string', got "zq"`, 1},
        {"true", "Cannot convert 'true' to 'int' from 'untyped bool', got true", 0},
    })
}

@(test)
test_live_unreachable :: proc(t: ^testing.T) {
    root := fixture(t, "live_unreachable", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "core:os"

g :: proc() {}

r1 :: proc() {
	return
	g()
}
r2 :: proc() {
	for {
		break
		g()
	}
}
r3 :: proc() {
	panic("x")
	g()
}
r4 :: proc() {
	os.exit(1)
	g()
}
r5 :: proc() {
	for {}
	g()
	g()
}
r6 :: proc(x: int) -> int {
	if x > 0 { return 1 } else { return 2 }
	// thor:ignore flow/unreachable
	g()
	return 0
}
d1 :: proc() {
	defer g()
	os.exit(1)
}
ok1 :: proc() {
	when ODIN_OS == .Windows {
		return
	}
	g()
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"return\n\tg()", "Statements after this 'return' are never executed", 0},
        {"break\n", "Statements after this 'break' are never executed", 0},
        {"panic(", "Statements after a diverging procedure call are never executed", 0},
        {"os.exit(1)\n\tg()", "Statements after a diverging procedure call are never executed", 0},
        {"g()\n\tg()\n}", "Unreachable code", 0},
        {"defer g()", "Unreachable defer statement due to diverging procedure call at the end of the current scope", 0},
    })
    for d in res.report.items {
        dead := d.message == "Unreachable code"
        testing.expect(t, d.code == (CODE_UNREACHABLE_DEFER if strings.has_prefix(d.message, "Unreachable defer") else CODE_UNREACHABLE), "an unreachable item carries its id")
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Warning if dead else lang.Diagnostic_Severity.Error)
        testing.expect_value(t, d.lint, dead)
    }
}

@(test)
test_live_liveness :: proc(t: ^testing.T) {
    root := fixture(t, "live_liveness", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

g :: proc() -> int { return 1 }
h :: proc(args: ..any) {}

u1 :: proc() {
	a := 1
	for x in 0 ..< 3 {}
}
s1 :: proc() {
	b := g()
	b = 2
	h(b)
	// thor:ignore flow/dead-store
	c := g()
	c = 3
	h(c)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"a := 1", "'a' declared but not used", 0},
        {"x in 0", "'x' declared but not used", 0},
        {"b := g()", "Value assigned to 'b' is never used", 0},
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_UNUSED_VAR || d.code == CODE_DEAD_STORE, "a liveness item carries its id")
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Warning)
        testing.expect_value(t, d.lint, d.code == CODE_DEAD_STORE)
    }
}

@(test)
test_live_unnamed_param_and_extra_values :: proc(t: ^testing.T) {
    root := fixture(t, "live_unnamed_param", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "base:intrinsics"

f :: proc(p: proc(rune) -> bool) -> bool {
	return p()
}
g :: proc(v: #simd[4]u32) -> u32 {
	x: u32
	x = intrinsics.simd_reduce_or(v), 0
	return x
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"p()", "Parameter '_' of type 'rune' is missing in procedure call", 0},
        {"x = intrinsics", "Assignment count mismatch '1' = '2'", 0},
    })
}

@(test)
test_live_fmt_verbs :: proc(t: ^testing.T) {
    root := fixture(t, "live_fmt_verbs", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "core:fmt"

E :: enum { A, B }
P :: struct { x: int }

printf :: proc(fmt: string, args: ..any) {}
logf :: proc(level: int, fmt_str: string, args: ..any) {}
not_format :: proc(msg: string, args: ..any) {}

main :: proc() {
	n := 3
	s := "s"
	f := 1.5
	p := P{}
	e := E.A
	xs := []any{1, 2}
	printf("%d %s %f %v %d %s", n, s, f, p, e, e)
	printf("%s", n)
	printf("%t %d", n, f)
	printf("%d %d", n)
	printf("%d", n, s, f)
	printf("%*d", s, n)
	printf("struct {x}", n)
	printf("tab\t%s", n)
	printf("%[3]d", n)
	printf(` + "`raw %s`" + `, n)
	printf("%d", ..xs)
	printf("{} {:x}", n, n)
	printf("cat %d " + "{y}", s)
	logf(1, "%s", n)
	not_format("%s", n)
	fmt.printf("%d\n", s)
	fmt.printfln("%v", p)
	// thor:ignore api/fmt-verbs
	printf("%s", n)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"%s\", n)", "Verb 's' does not take an argument of type 'int'", 0},
        {"%t %d", "Verb 't' does not take an argument of type 'int'", 0},
        {"%d\", n, f)", "Verb 'd' does not take an argument of type 'f64'", 0},
        {"%d\", n)", "No argument for verb 'd' in the format string", 0},
        {"s, f)", "2 arguments more than the format string uses", 0},
        {"%*d", "Width argument of type 'string' is not a number", 0},
        {"{x}", "No '}' for '{' in the format string; write '{{' for a literal '{'", 0},
        {"n)\n\tprintf(\"tab", "1 argument more than the format string uses", 0},
        {"%s\", n)\n\tprintf(\"%[3]", "Verb 's' does not take an argument of type 'int'", 0},
        {"%[3]d", "Argument index in the format string is out of range", 0},
        {"n)\n\tprintf(`raw", "1 argument more than the format string uses", 0},
        {"%s`", "Verb 's' does not take an argument of type 'int'", 0},
        {"%d \" + ", "Verb 'd' does not take an argument of type 'string'", 0},
        {"{y}", "No '}' for '{' in the format string; write '{{' for a literal '{'", 0},
        {"%s\", n)\n\tnot_format", "Verb 's' does not take an argument of type 'int'", 0},
        {"%d\\n", "Verb 'd' does not take an argument of type 'string'", 0},
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_FMT_VERBS)
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Hint)
        testing.expect(t, d.lint, "a format problem is a lint")
    }
}

@(test)
test_live_fmt_verbs_user_formatter :: proc(t: ^testing.T) {
    root := fixture(t, "live_fmt_user", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "core:fmt"

Id :: distinct int
Plain :: int

main :: proc() {
	_ = fmt.register_user_formatter(type_info_of(Id), nil)
	i: Id
	fmt.printf("%s", i)
	n: Plain
	fmt.printf("%s", n)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"%s\", n)", "Verb 's' does not take an argument of type 'int'", 0},
    })
}

@(test)
test_live_const_arith_and_no_value :: proc(t: ^testing.T) {
    root := fixture(t, "live_const_arith", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

nothing :: proc() {}
one :: proc() -> int { return 1 }
stop :: proc() -> ! { for {} }

small: i8 : 100
byte: u8 : 200

main :: proc() {
	a := small + 100
	b := small + 20
	c := byte * 2
	d := byte - 201
	e := small + 100 + 1
	f := nothing()
	g: int = nothing()
	h := one()
	var: int
	var = nothing()
	i := 1 + 2
	_, _, _, _, _, _, _, _, _ = a, b, c, d, e, f, g, h, i
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"small + 100\n\tb", "Numeric value '200' from 'small + 100' cannot be represented by 'i8'", 0},
        {"byte * 2", "Numeric value '400' from 'byte * 2' cannot be represented by 'u8'", 0},
        {"byte - 201", "Numeric value '-1' from 'byte - 201' cannot be represented by 'u8'", 0},
        {"small + 100 + 1", "Numeric value '200' from 'small + 100' cannot be represented by 'i8'", 0},
        {"nothing()\n\tg","'nothing()' call does not return a value and cannot be used as a value", 0},
        {"nothing()\n\th","'nothing()' call does not return a value and cannot be used as a value", 0},
        {"nothing()\n\ti","'nothing()' call does not return a value and cannot be used as a value", 0},
    })
}

@(test)
test_live_ignored_error :: proc(t: ^testing.T) {
    root := fixture(t, "live_ignored_error", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "base:runtime"
import "core:os"
import "core:strings"

Parse_Error :: enum { None, Bad }
Error :: union { Parse_Error, runtime.Allocator_Error }

parse :: proc() -> (int, Parse_Error) { return 0, .None }
load :: proc() -> Error { return nil }
alloc :: proc() -> runtime.Allocator_Error { return nil }
@(require_results)
must :: proc() -> Parse_Error { return .None }
plain :: proc() -> int { return 1 }

main :: proc() {
	parse()
	(load())
	alloc()
	plain()
	defer load()
	defer {
		load()
	}
	_ = load()
	n, _ := parse()
	_ = n
	x: [dynamic]int
	append(&x, 1)
	delete(x)
	os.close(os.stdout)
	b := strings.builder_make()
	strings.write_rune(&b, 'x')
	strings.builder_destroy(&b)
	// thor:ignore api/ignored-error
	load()
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"parse()\n", "Error result of type 'Parse_Error' is ignored", 0},
        {"load())", "Error result of type 'Error' is ignored", 0},
        {"os.close", "Error result of type 'os.Error' is ignored", 0},
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_IGNORED_ERROR)
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Hint)
        testing.expect(t, d.lint, "an ignored error is a lint")
    }
}

@(test)
test_live_deprecated :: proc(t: ^testing.T) {
    root := fixture(t, "live_deprecated", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

@(deprecated = "use fresh")
old :: proc() {}
@(deprecated)
bare :: proc() {}
fresh :: proc() {}

main :: proc() {
	old()
	bare()
	fresh()
	// thor:ignore api/deprecated
	old()
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"old()\n\tbare", "'old' is deprecated: use fresh", 0},
        {"bare()\n\tfresh", "'bare' is deprecated", 0},
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_DEPRECATED)
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Hint)
    }
}

@(test)
test_live_logic :: proc(t: ^testing.T) {
    root := fixture(t, "live_logic", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

P :: struct { x, y: int }

main :: proc(p: ^P, n: int) {
	n := n
	n = n
	p.x = p.y
	p.x = p.x
	n += n
	if true {
		n = 1
	}
	if n > 0 {
		n = 2
	} else {
		n  = 2
	}
	if n > 0 {
		n = 2
	} else {
		n = 3
	}
	// thor:ignore logic/const-condition
	if false {
		n = 4
	}
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"n = n", "A place is assigned to itself", 0},
        {"p.x = p.x", "A place is assigned to itself", 0},
        {"true {", "The condition is always true", 0},
        {"{\n\t\tn  = 2", "Both branches of the if statement are the same", 0},
    })
}

@(test)
test_live_naming :: proc(t: ^testing.T) {
    root := fixture(t, "live_naming", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" }, naming = { constant = "any", enum_member = "snake_case" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

Good_Type :: struct {
	good_field: int,
	badField:   int,
}

badType :: struct {}

Color :: enum { red, Green }

oddConstant :: 1

main :: proc(good_param: int, badParam: int) {
	_ = good_param
	_ = badParam
	good_var := 1
	badVar := 2
	_, _ = good_var, badVar
	// thor:ignore style/naming
	ignoredVar := 3
	_ = ignoredVar
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"badField", "'badField' should be snake_case", 0},
        {"badType", "'badType' should be Ada_Case", 0},
        {"Green", "'Green' should be snake_case", 0},
        {"badParam: int", "'badParam' should be snake_case", 0},
        {"badVar :=", "'badVar' should be snake_case", 0},
    })
}

@(test)
test_live_range_copy :: proc(t: ^testing.T) {
    root := fixture(t, "live_range_copy", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

Big :: struct { data: [80]int, n: int }
Small :: struct { a, b: int }

main :: proc(bigs: []Big, smalls: []Small, arr: [4]Big) {
	total := 0
	for b in bigs {
		total += b.n
	}
	for s in smalls {
		total += s.a
	}
	for &b in bigs {
		b.n = 1
	}
	for b in bigs {
		p := &b
		_ = p
	}
	for b in bigs {
		b.n = 2
	}
	for b in arr {
		total += b.data[1]
	}
	for _, i in bigs {
		total += i
	}
	// thor:ignore perf/range-copy
	for b in bigs {
		total += b.n
	}
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"b in bigs {\n\t\ttotal += b.n\n\t}\n\tfor s", "'b' copies 648 bytes on every iteration; 'for &b' avoids the copy", 0},
        {"b in arr", "'b' copies 648 bytes on every iteration; 'for &b' avoids the copy", 0},
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_RANGE_COPY)
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Hint)
    }
}

@(test)
test_live_dangling_slice :: proc(t: ^testing.T) {
    root := fixture(t, "live_dangling_slice", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

Holder :: struct { buf: [8]u8, n: int }
global: ^int

by_addr :: proc() -> ^int {
	one: int
	return &one
}
by_slice :: proc() -> []u8 {
	arr: [4]u8
	return arr[:]
}
by_field :: proc() -> ^int {
	h: Holder
	return &h.n
}
by_result :: proc() -> (r: []u8) {
	two: [2]u8
	r = two[1:]
	return
}
to_global :: proc() {
	three: int
	global = &three
}
to_param :: proc(out: ^^int) {
	four: int
	out^ = &four
}
fine :: proc(p: ^Holder, s: []u8, d: [dynamic]u8) -> (^int, []u8, []u8, ^int) {
	local := p
	return &p.n, s[:], d[:], &local.n
}
fine_static :: proc() -> []u8 {
	@(static) keep: [4]u8
	return keep[:]
}
fine_ref :: proc(items: []int) -> ^int {
	for &item in items {
		return &item
	}
	return nil
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"&one", "Address of local 'one' is returned and dangles after the procedure returns", 0},
        {"arr[:]", "Address of local 'arr' is returned and dangles after the procedure returns", 0},
        {"&h.n", "Address of local 'h' is returned and dangles after the procedure returns", 0},
        {"two[1:]", "Address of local 'two' is stored and dangles after the procedure returns", 0},
        {"&three", "Address of local 'three' is stored and dangles after the procedure returns", 0},
        {"&four", "Address of local 'four' is stored and dangles after the procedure returns", 0},
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_DANGLING_SLICE)
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Hint)
        testing.expect(t, d.lint, "a dangling slice is a lint")
    }
}

@(test)
test_live_temp_escape :: proc(t: ^testing.T) {
    root := fixture(t, "live_temp_escape", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "core:fmt"
import "core:strings"

keep: string

returned :: proc(name: string) -> string {
	return fmt.tprintf("hi %s", name)
}
named :: proc(s: string) -> (r: string) {
	r = strings.clone(s, context.temp_allocator)
	return
}
to_global :: proc(s: string) {
	dup := strings.clone(s, context.temp_allocator)
	keep = dup
}
to_param :: proc(out: ^string, name: string) {
	out^ = fmt.tprintf("hi %s", name)
}
copied :: proc(s: string) {
	a := strings.clone(s, context.temp_allocator)
	b := a
	keep = b
}
fine :: proc(s: string) -> string {
	return strings.clone(s)
}
fine_local :: proc(s: string) -> int {
	tmp := strings.clone(s, context.temp_allocator)
	return len(tmp)
}
temp_name :: proc(s: string) -> string {
	return strings.clone(s, context.temp_allocator)
}
Holder :: struct { name: string, id: int }
holder: Holder
later :: proc(s: string) {
	x: string
	x = strings.clone(s, context.temp_allocator)
	keep = x
}
reset :: proc(s: string) {
	x := strings.clone(s, context.temp_allocator)
	_ = len(x)
	x = strings.clone(s)
	keep = x
}
branchy :: proc(s: string, c: bool) {
	x := strings.clone(s)
	if c {
		x = strings.clone(s, context.temp_allocator)
	}
	keep = x
}
trimmed :: proc(s: string) {
	t := strings.clone(s, context.temp_allocator)
	keep = strings.trim_space(t)
}
cloned :: proc(s: string) {
	t := strings.clone(s, context.temp_allocator)
	keep = strings.clone(t)
}
field_store :: proc(s: string) {
	h: Holder
	h.name = strings.clone(s, context.temp_allocator)
	holder = h
}
field_read :: proc(s: string) {
	h: Holder
	h.name = strings.clone(s, context.temp_allocator)
	keep = h.name
}
field_other :: proc(s: string) {
	h: Holder
	h.name = strings.clone(s, context.temp_allocator)
	holder.id = h.id
}
field_reset :: proc(s: string) {
	h: Holder
	h.name = strings.clone(s, context.temp_allocator)
	h.name = "x"
	holder = h
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"dup\n}", "Value from the temp allocator is stored and is freed by the next free_all(context.temp_allocator)", 0},
        {"fmt.tprintf(\"hi %s\", name)\n}\ncopied","Value from the temp allocator is stored and is freed by the next free_all(context.temp_allocator)", 0},
        {"b\n}\nfine ::", "Value from the temp allocator is stored and is freed by the next free_all(context.temp_allocator)", 0},
        {"x\n}\nreset", "Value from the temp allocator is stored and is freed by the next free_all(context.temp_allocator)", 0},
        {"strings.trim_space(t)", "Value from the temp allocator is stored and is freed by the next free_all(context.temp_allocator)", 0},
        {"h\n}\nfield_read", "Value from the temp allocator is stored and is freed by the next free_all(context.temp_allocator)", 0},
        {"h.name\n}\nfield_other", "Value from the temp allocator is stored and is freed by the next free_all(context.temp_allocator)", 0},
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_TEMP_ESCAPE)
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Hint)
        testing.expect(t, d.lint, "a temp escape is a lint")
    }
}

@(test)
test_live_defer_in_loop :: proc(t: ^testing.T) {
    root := fixture(t, "live_defer_in_loop", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

outer_free :: proc(buf: []int) {
	for _ in 0 ..< 3 {
		defer delete(buf)
	}
}
nested_if :: proc(ok: bool, buf: []int) {
	for ok {
		if ok {
			defer delete(buf)
		}
	}
}
fine_inner :: proc() {
	for _ in 0 ..< 3 {
		buf := make([]int, 4)
		defer delete(buf)
	}
}
fine_loop_var :: proc(items: [][]int) {
	for item in items {
		defer delete(item)
	}
}
fine_outside :: proc(buf: []int) {
	defer delete(buf)
	for _ in 0 ..< 3 {
	}
}
fine_proc_lit :: proc(buf: []int) {
	for _ in 0 ..< 3 {
		f := proc(b: []int) {
			defer delete(b)
		}
		f(buf)
	}
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"defer delete(buf)", "A defer in a loop body releases a variable declared outside the loop on every iteration", 0},
        {"defer delete(buf)", "A defer in a loop body releases a variable declared outside the loop on every iteration", 1},
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_DEFER_IN_LOOP)
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Hint)
        testing.expect(t, d.lint, "a defer in a loop is a lint")
    }
}

@(test)
test_live_ownership :: proc(t: ^testing.T) {
    root := fixture(t, "live_ownership", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" }, diagnostics = { ["mem/leak"] = "hint", ["mem/double-free"] = "hint", ["mem/use-after-free"] = "hint" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

Holder :: struct {
	items: []int,
}

consume :: proc(items: []int) {}

leak_plain :: proc() {
	leaked := new(int)
	leaked^ = 1
}
leak_branch :: proc(ok: bool) {
	partial := make([]int, 4)
	if ok {
		delete(partial)
	}
}
double_free :: proc() {
	twice := make([]int, 4)
	delete(twice)
	delete(twice)
}
use_after_free :: proc() {
	gone := make([]int, 4)
	delete(gone)
	gone[0] = 1
}
fine_defer :: proc() {
	kept := make([]int, 4)
	defer delete(kept)
	kept[0] = 1
}
fine_return :: proc() -> []int {
	out := make([]int, 4)
	return out
}
fine_store :: proc(h: ^Holder) {
	stored := make([]int, 4)
	h.items = stored
}
fine_call :: proc() {
	passed := make([]int, 4)
	consume(passed)
}
fine_temp :: proc() {
	scratch := make([]int, 4, context.temp_allocator)
	scratch[0] = 1
}
fine_both_branches :: proc(ok: bool) {
	either := make([]int, 4)
	if ok {
		delete(either)
	} else {
		delete(either)
		either = nil
	}
}
fine_reassign :: proc() {
	again := make([]int, 4)
	delete(again)
	again = make([]int, 4)
	delete(again)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"leaked := new(int)", "'leaked' is allocated and a path neither frees nor hands it on", 0},
        {"partial := make", "'partial' is allocated and a path neither frees nor hands it on", 0},
        {"twice)\n}", "'twice' is freed twice on every path to here", 0},
        {"gone[0]", "'gone' is used after it is freed", 0},
    })
    for d in res.report.items {
        if d.code == CODE_LEAK || d.code == CODE_DOUBLE_FREE || d.code == CODE_USE_AFTER_FREE {
            testing.expect(t, d.lint && d.severity == .Hint, "an ownership finding is a hint lint")
        }
    }
}
