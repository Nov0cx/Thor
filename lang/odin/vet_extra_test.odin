package odin

import "core:log"
import "core:path/filepath"
import "core:testing"

import lang ".."

@(test)
test_live_vet_cast :: proc(t: ^testing.T) {
    root := fixture(t, "live_vet_cast", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e    := engine_create()
    defer engine_destroy(e)

    src := `package app

Alias :: int
Dist :: distinct int

same :: proc(c: int, d: Dist, s: string, a: Alias) -> int {
	x1 := cast(int)c
	x2 := cast(Alias)c
	x3 := cast(int)5
	x4 := cast(Dist)c
	x5 := cast(Dist)d
	x6 := cast(string)s
	x7 := transmute(int)c
	x8 := int(c)
	x9 := cast(int)a
	return x1 + x2 + x3 + int(x4) + int(x5) + len(x6) + x7 + x8 + x9
}

poly :: proc(v: $T) -> T {
	return cast(T)v
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(
        t,
        &res,
        src,
        {
            {"c\n\tx2", "Unneeded cast of 'c' to identical type 'int'", 0},
            {"c\n\tx3", "Unneeded cast of 'c' to identical type 'int'", 0},
            {"d\n\tx6", "Unneeded cast of 'd' to identical type 'Dist'", 0},
            {"s\n\tx7", "Unneeded cast of 's' to identical type 'string'", 0},
            {"transmute(int)c", "Unneeded transmute of 'transmute(int)c' to identical type 'int'", 0},
            {"a\n\treturn", "Unneeded cast of 'a' to identical type 'int'", 0},
        },
    )
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_CAST)
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Warning)
    }
}

@(test)
test_live_vet_cast_off :: proc(t: ^testing.T) {
    root := fixture(
        t,
        "live_vet_cast_off",
        {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" }, diagnostics = { ["vet/cast"] = "off" } }`}},
    )
    e    := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nf :: proc(c: int) -> int {\n\treturn cast(int)c\n}\n"
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    testing.expect_value(t, len(res.report.items), 0)
}

@(test)
test_live_vet_syntax :: proc(t: ^testing.T) {
    root := fixture(
        t,
        "live_vet_syntax",
        {
            {
                ".thor/odin-analyzer.lua",
                `return { target = { os = "windows", arch = "amd64" }, diagnostics = { ["vet/semicolon"] = "warning", ["vet/tabs"] = "hint", ["vet/style"] = "warning" } }`,
            },
        },
    )
    e    := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nE :: enum {\n\tA,\n\tB\n}\n\nf :: proc() {\n\tx := 1;\n    y := 2\n\t_ = x; _ = y\n}\n"
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(
        t,
        &res,
        src,
        {
            {"\n}\n\nf", "Expected a comma, got a newline", 0},
            {";\n    y", "Found unneeded semicolon", 0},
            {"y := 2", "With '-vet-tabs', tabs must be used for indentation", 0},
        },
    )
}

@(test)
test_live_vet_syntax_default_off :: proc(t: ^testing.T) {
    root := fixture(t, "live_vet_syntax_off", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e    := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nf :: proc() {\n    x := 1;\n    _ = x\n}\n"
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    testing.expect_value(t, len(res.report.items), 0)
}

@(test)
test_live_nil_deref :: proc(t: ^testing.T) {
    root := fixture(t, "live_nil_deref", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e    := engine_create()
    defer engine_destroy(e)

    src := `package app

T :: struct { x: int }

make_t :: proc() -> ^T { return nil }

f :: proc(c: bool, q: ^T, q2: ^[4]int) -> int {
	a: ^T
	a.x = 1
	b: ^T = nil
	n := b.x
	d: ^T
	if c {
		d = make_t()
	}
	n += d.x
	e: ^T
	if c {
		e = q
	} else {
		e = nil
	}
	n += e.x
	g: ^T
	if g == nil {
		return n
	}
	n += g.x
	h: ^T
	p := &h
	p^ = q
	n += h.x
	fn: proc()
	fn()
	k: ^T
	k = nil
	for i in 0 ..< 2 {
		k = make_t()
		n += k.x
	}
	arr: ^[4]int
	n += arr[1]
	arr2: ^[4]int = q2
	n += arr2[1]
	m: ^T
	// thor:ignore nil/deref
	n += m.x
	return n + size_of(a^)
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(
        t,
        &res,
        src,
        {
            {"a.x", "Dereferencing 'a', which is always nil here", 0},
            {"b.x", "Dereferencing 'b', which is always nil here", 0},
            {"fn()", "Calling 'fn', which is always nil here", 0},
            {"arr[1]", "Dereferencing 'arr', which is always nil here", 0},
        },
    )
    for d in res.report.items {
        if d.code == CODE_NIL_DEREF {
            testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Hint)
            testing.expect(t, d.lint, "a nil dereference is a lint")
        }
    }
}

@(test)
test_live_nil_deref_narrowing :: proc(t: ^testing.T) {
    root := fixture(t, "live_nil_deref_narrowing", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e    := engine_create()
    defer engine_destroy(e)

    src := `package app

T :: struct { x: int, next: ^T }
S :: struct { cb: proc(), p: ^T, inner: struct { cb: proc() } }
U :: struct { using s: S }
V :: struct { cb: proc(v: ^V) }

make_t :: proc() -> ^T { return nil }
use :: proc(s: ^S) {}

f :: proc(c: bool, d: bool) -> int {
	n := 0
	a: ^T
	if a == nil {
		n += a.x
	}
	b: ^T
	if b != nil {
		n += b.x
	}
	g: ^T
	if g == nil {
		return n
	}
	n += g.x
	h: ^T
	if h == nil || c {
		n += 1
	} else {
		n += h.x
	}
	i: ^T
	if i != nil && i.x > 0 {
		n += 1
	}
	j: ^T
	if !(j != nil) {
		n += j.x
	}
	k: ^T
	for k != nil {
		k = k.next
	}
	n += k.x
	l: ^T
	for _ in 0 ..< 2 {
		if l == nil {
			continue
		}
		n += l.x
	}
	m: ^T
	if m == nil {
		m = make_t()
	}
	n += m.x
	o: ^T
	ok := o != nil
	if ok {
		n += o.x
	}
	q: ^T
	if q == nil && c {
		n += q.x
	}
	r: ^T
	if r != nil || d {
		n += 1
	}
	n += r.x
	return n
}

fields :: proc(c: bool) {
	s: S
	s.cb()
	t: S
	t.cb = proc() {}
	t.cb()
	u: S
	if c {
		u.cb = proc() {}
	}
	u.cb()
	v: S
	v.p.x = 1
	w: S
	w.p = make_t()
	w.p.x = 1
	x: S = {}
	if x.cb != nil {
		x.cb()
	}
	y: S
	use(&y)
	y.cb()
	z: S
	z = S{}
	z.cb()
	aa: S
	aa.inner.cb()
	ab: S
	ab.inner = {}
	ab.inner.cb()
	ac: U
	ac.cb()
	ad: S
	if ad.cb == nil {
		ad.cb()
	}
	ae: V
	ae->cb()
	ae.cb(nil)
}

multi :: proc(n: int) -> int {
	p: [^]int
	q: [^]int
	if n > 0 {
		q = raw_data([]int{1})
	}
	r: [^]int
	if r == nil {
		return 0
	}
	return p[0] + q[0] + r[0]
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(
        t,
        &res,
        src,
        {
            {"a.x", "Dereferencing 'a', which is always nil here", 0},
            {"j.x", "Dereferencing 'j', which is always nil here", 0},
            {"k.x", "Dereferencing 'k', which is always nil here", 0},
            {"q.x", "Dereferencing 'q', which is always nil here", 0},
            {"r.x", "Dereferencing 'r', which is always nil here", 0},
            {"s.cb()", "Calling 's.cb', which is always nil here", 0},
            {"v.p.x", "Dereferencing 'v.p', which is always nil here", 0},
            {"z.cb()", "Calling 'z.cb', which is always nil here", 0},
            {"aa.inner.cb()", "Calling 'aa.inner.cb', which is always nil here", 0},
            {"ab.inner.cb()", "Calling 'ab.inner.cb', which is always nil here", 0},
            {"ad.cb()", "Calling 'ad.cb', which is always nil here", 0},
            {"p[0]", "Dereferencing 'p', which is always nil here", 0},
        },
    )
}

@(test)
test_live_vet_unused_procedure :: proc(t: ^testing.T) {
    root := fixture(
        t,
        "live_vet_unused_proc",
        {
            {".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" }, diagnostics = { ["vet/unused-procedure"] = "warning" } }`},
            {"app/other.odin", "package app\n\nuse_other :: proc() {\n\tused_elsewhere()\n}\n"},
        },
    )
    e    := engine_create()
    defer engine_destroy(e)

    src := `package app

unused :: proc() {}

@(private)
unused_private :: proc() {}

used_elsewhere :: proc() {}

used_in_group_a :: proc(a: int) {}
used_in_group_b :: proc(a: f32) {}
group :: proc{used_in_group_a, used_in_group_b}

recursive :: proc(n: int) {
	if n > 0 {
		recursive(n - 1)
	}
}

@(export)
exported :: proc "c" () {}

@(require)
required :: proc() {}

@(test)
a_test :: proc() {}

@(deferred_in = cleanup)
begin :: proc() {}
cleanup :: proc() {}

main :: proc() {}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(
        t,
        &res,
        src,
        {
            {"unused ::", "'unused' declared but not used", 0},
            {"unused_private", "'unused_private' declared but not used", 0},
            {"begin ::", "'begin' declared but not used", 0},
        },
    )
}

// The on-save check passes `-vet-cast` and, once the config names it, `-vet-unused-procedures`, and
// gives their lines the ids `vet/cast` and `vet/unused-procedure`.
@(test)
test_check_vet_extra_lines :: proc(t: ^testing.T) {
    src        := "package app\n\nhelper :: proc() {}\n\nf :: proc(c: int) -> int {\n\treturn cast(int)c\n}\n"
    rel        := fixture(
        t,
        "check_vet_extra",
        {{".thor/odin-analyzer.lua", `return { diagnostics = { ["vet/unused-procedure"] = "hint" } }`}, {"app/main.odin", src}},
    )
    root, aerr := filepath.abs(rel, context.temp_allocator)
    if !testing.expect_value(t, aerr, nil) {
        return
    }
    if !odin_on_path(root) {
        log.info("odin is not on PATH; skipping the compiler check test")
        return
    }
    e := engine_create()
    defer engine_destroy(e)

    req := lang.Request{kind = .Diagnostics, path = fixture_path(root, "app/main.odin"), ext = ".odin", workspace = root}
    res := lang.Result{kind = .Diagnostics}
    resolve(e, &req, &res)
    defer free_live(&res)

    testing.expect(t, res.ok, "the check should have run")
    codes := make(map[string]lang.Diagnostic_Severity, context.temp_allocator)
    for d in res.report.items {
        codes[d.code] = d.severity
    }
    testing.expect_value(t, codes[CODE_CAST], lang.Diagnostic_Severity.Warning)
    testing.expect_value(t, codes[CODE_UNUSED_PROC], lang.Diagnostic_Severity.Hint)
    testing.expect_value(t, len(res.report.items), 3)
}

@(test)
test_live_ignored_ok :: proc(t: ^testing.T) {
    root := fixture(t, "live_ignored_ok", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e    := engine_create()
    defer engine_destroy(e)

    src := `package app

parse_ok :: proc(s: string) -> (v: int, ok: bool) { return len(s), true }
other :: proc() -> (v: int, success: bool) { return 0, true }
optional :: proc() -> (v: int, ok: bool) #optional_ok { return 0, true }
unnamed :: proc() -> (int, bool) { return 0, true }
single :: proc() -> (ok: bool) { return true }

main :: proc() {
	parse_ok("a")
	other()
	optional()
	unnamed()
	single()
	_, _ = parse_ok("b")
	v, _ := parse_ok("c")
	_ = v
	defer parse_ok("d")
	// thor:ignore api/ignored-error
	parse_ok("e")
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {{"parse_ok(\"a\")", "The 'ok' result of 'parse_ok' is ignored", 0}})
    for d in res.report.items {
        testing.expect_value(t, d.code, CODE_IGNORED_ERROR)
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Hint)
    }
}
