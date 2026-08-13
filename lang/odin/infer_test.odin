// Type inference for bindings the lexical walk collects: range-loop variables
// and the by-reference form the grammar wraps in a unary_expression.
package odin

import "core:strings"
import "core:testing"

import lang ".."

// A by-reference range variable is wrapped in a unary_expression, which
// range_binding used to skip entirely: no binding at all, so member completion
// and any inferred type on it answered nothing. Go-to-definition always worked
// (collect_value_decls unwraps the same shape).
@(test)
test_completion_by_reference_range_variable_members :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

walk :: proc(points: []Point) {
	for &p in points {
		p.
	}
}
`
    req := lang.Request {
        kind   = .Completion,
        path   = "buffer.odin",
        ext    = ".odin",
        source = src,
        offset = strings.index(src, "p.") + len("p."),
    }
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, has_completion(&res, "x"), "expected field x")
    testing.expect(t, has_completion(&res, "y"), "expected field y")
}

// The second variable of `for k, &v in m` still lands on the map's value type:
// unwrapping must not disturb the index accounting.
@(test)
test_completion_by_reference_map_value_members :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

walk :: proc(m: map[string]Point) {
	for k, &v in m {
		v.
	}
}
`
    req := lang.Request {
        kind   = .Completion,
        path   = "buffer.odin",
        ext    = ".odin",
        source = src,
        offset = strings.index(src, "v.") + len("v."),
    }
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, has_completion(&res, "x"), "expected field x")
    testing.expect(t, has_completion(&res, "y"), "expected field y")
}

// Hover on a range variable shows its declaring statement, by-reference or not
// — this pins the two forms to the same answer.
@(test)
test_hover_by_reference_range_variable_matches_plain :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    plain := `package demo

Point :: struct {
	x: int,
}

walk :: proc(points: []Point) {
	for p in points {
		_ = p
	}
}
`
    byref := `package demo

Point :: struct {
	x: int,
}

walk :: proc(points: []Point) {
	for &p in points {
		_ = p
	}
}
`
    a := hover_at(e, plain, strings.index(plain, "_ = p") + len("_ = "))
    defer delete(a.hover.text)
    b := hover_at(e, byref, strings.index(byref, "_ = p") + len("_ = "))
    defer delete(b.hover.text)

    testing.expect(t, a.ok && b.ok, "both forms must answer a hover")
    testing.expectf(t, strings.contains(b.hover.text, "for &p in points"), "hover text: got %q", b.hover.text)
}
