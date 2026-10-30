package odin

import "core:testing"

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
    })
}
