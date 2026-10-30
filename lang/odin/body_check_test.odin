package odin

import "core:testing"

import lang ".."

@(test)
test_live_call_arguments :: proc(t: ^testing.T) {
    root := fixture(t, "live_call_arguments", {
        {".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`},
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
        testing.expect(t, d.code == CODE_ARITY || d.code == CODE_NAMED, "a call error carries a call id")
    }
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
    root := fixture(t, "live_missing_members", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
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
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"p.y", "'p' of type '^P' has no field 'y'", 0},
        {"q.p.z", "'q.p' of type 'P' has no field 'z'", 0},
        {"E.D", "Type 'E' has no field 'D'", 0},
        {"bb.hi", "'bb' of type 'B' has no field 'hi'", 0},
    })
}

@(test)
test_live_switch_cases :: proc(t: ^testing.T) {
    root := fixture(t, "live_switch_cases", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
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
    root := fixture(t, "live_static_asserts", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
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
    root := fixture(t, "live_argument_mismatches", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

I :: distinct int

take :: proc(a: int, s: string) {}
rest :: proc(xs: ..int) {}
want_i :: proc(d: I) {}

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
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_MISMATCH)
    }
}

@(test)
test_live_assign_mismatches :: proc(t: ^testing.T) {
    root := fixture(t, "live_assign_mismatches", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
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
    })
}

@(test)
test_live_return_mismatches :: proc(t: ^testing.T) {
    root := fixture(t, "live_return_mismatches", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
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
        {".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`},
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
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"g(x)", "No procedures or ambiguous call for procedure group 'g' that match with the given arguments", 0},
        {"g2(1, 2, 3)", "No procedures or ambiguous call for procedure group 'g2' that match with the given arguments", 0},
        {"g2()", "No procedures or ambiguous call for procedure group 'g2' that match with the given arguments", 0},
        {"q.grp(x)", "No procedures or ambiguous call for procedure group 'q.grp' that match with the given arguments", 0},
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_OVERLOAD, "a group error carries the overload id")
    }
}

@(test)
test_live_constant_overflow :: proc(t: ^testing.T) {
    root := fixture(t, "live_constant_overflow", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
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

@(test)
test_live_missing_returns :: proc(t: ^testing.T) {
    root := fixture(t, "live_missing_returns", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
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
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_RETURN, "a missing return carries its id")
    }
}

@(test)
test_live_or_return :: proc(t: ^testing.T) {
    root := fixture(t, "live_or_return", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
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
    root := fixture(t, "live_where_clauses", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "base:intrinsics"

num :: proc(x: $T) -> T where intrinsics.type_is_numeric(T) { return x }
two :: proc(a: $A, b: $B) where A == B, size_of(A) == 8 {}

main :: proc() {
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
    root := fixture(t, "live_assignment_counts", {{".thor/odin-analyzer.json", `{"target": {"os": "windows", "arch": "amd64"}}`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

two :: proc() -> (int, int) { return 1, 2 }
one :: proc() -> int { return 1 }

main :: proc() {
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
        {"a, b := one()", "Assignment count mismatch '2' = '1'", 0},
        {"f := two()", "Assignment count mismatch '1' = '2'", 0},
        {"m, n = one()", "Assignment count mismatch '2' = '1'", 0},
        {"m = two()", "Assignment count mismatch '1' = '2'", 0},
        {"m, n = 1, 2, 3", "Assignment count mismatch '2' = '3'", 0},
    })
    for d in res.report.items {
        testing.expect(t, d.code == CODE_COUNT, "a count error carries its id")
    }
}

@(test)
test_live_severities :: proc(t: ^testing.T) {
    root := fixture(t, "live_severities", {
        {".thor/odin-analyzer.json", `{"diagnostics": {"call/arity": "off", "call/named": "warning", "zork/none": "off", "type/mismatch": "hint"}}`},
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
        testing.expect_value(t, res.report.items[1].severity, lang.Diagnostic_Severity.Error)
    }
}
