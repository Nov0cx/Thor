package odin

import "core:testing"

import lang ".."

@(test)
test_live_nil_deref_array_elements :: proc(t: ^testing.T) {
    root := fixture(t, "live_nil_deref_array", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

T :: struct { x: int }
S :: struct { arr: [3]^T }

f :: proc(q: ^T, i: int, k: [3]^T) -> int {
	n := 0
	a: [3]^T
	n += a[1].x
	b: [3]^T
	b[0] = q
	n += b[0].x
	d: [3]^T
	d[i] = q
	n += d[1].x
	h: [2]proc()
	h[0]()
	s: S
	n += s.arr[2].x
	m: [3]^T
	m[1] = q
	n += m[0].x
	r: [3]^T
	for &el in r {
		el = q
	}
	n += r[1].x
	u: [3]^T
	pu := &u
	pu[1] = q
	n += u[1].x
	v: [3]^T = k
	n += v[2].x
	w: [3]^T
	if w[2] != nil {
		n += w[2].x
	}
	z: [2]^T
	n += z[5].x
	return n
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"a[1].x", "Dereferencing 'a[1]', which is always nil here", 0},
        {"h[0]()", "Calling 'h[0]', which is always nil here", 0},
        {"s.arr[2].x", "Dereferencing 's.arr[2]', which is always nil here", 0},
        {"m[0].x", "Dereferencing 'm[0]', which is always nil here", 0},
    })
    for d in res.report.items {
        if d.code == CODE_NIL_DEREF {
            testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Hint)
        }
    }
}

@(test)
test_live_dangling_slice_flow :: proc(t: ^testing.T) {
    root := fixture(t, "live_dangling_flow", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

Holder :: struct { p: ^int, s: []u8 }
global: ^int

ident :: proc(p: ^int) -> ^int {
	return p
}
fresh :: proc(s: []u8) -> []u8 {
	return nil
}

second :: proc() -> ^int {
	x: int
	p := &x
	q := p
	return q
}
via_call :: proc() -> ^int {
	y: int
	return ident(&y)
}
via_field :: proc() -> Holder {
	buf: [4]u8
	h: Holder
	h.s = buf[:]
	return h
}
stored :: proc(out: ^Holder) {
	buf2: [4]u8
	s := buf2[1:]
	out.s = s
}
to_global :: proc() {
	z: int
	pz := &z
	global = pz
}
fine_reset :: proc() -> ^int {
	x: int
	p := &x
	p = nil
	return p
}
fine_branch :: proc(c: bool, g: ^int) -> ^int {
	x: int
	p := g
	if c {
		p = &x
	}
	return p
}
fine_deref :: proc() -> int {
	x := 1
	p := &x
	return p^
}
fine_defer :: proc(out: ^Holder) {
	x: int
	p := &x
	out.p = p
	defer out.p = nil
}
fine_static :: proc() -> []u8 {
	@(static) keep: [4]u8
	s := keep[:]
	return s
}
fine_fresh :: proc() -> []u8 {
	buf: [4]u8
	s := buf[:]
	return fresh(s)
}
fine_local_store :: proc() {
	buf: [4]u8
	h: Holder
	h.s = buf[:]
	_ = h
}
fine_param :: proc(p: ^int) -> ^int {
	q := p
	return q
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"q\n}\nvia_call", "A pointer or slice of a local is returned and dangles after the procedure returns", 0},
        {"ident(&y)\n", "A pointer or slice of a local is returned and dangles after the procedure returns", 0},
        {"h\n}\nstored", "A pointer or slice of a local is returned and dangles after the procedure returns", 0},
        {"s\n}\nto_global", "A pointer or slice of a local is stored and dangles after the procedure returns", 0},
        {"pz\n}\nfine_reset", "A pointer or slice of a local is stored and dangles after the procedure returns", 0},
    })
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_DANGLING_SLICE)
        testing.expect(t, d.lint, "a dangling slice is a lint")
    }
}
