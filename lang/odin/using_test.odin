// `using` outside a struct: the statement and the parameter, both of which name
// a value's fields bare in the surrounding scope.
package odin

import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_using_statement_definition :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Two structs declare `n`; the `using` picks which one the bare name means.
    src := `package demo

Alpha :: struct {
	n: int,
}

Beta :: struct {
	n: string,
}

main :: proc() {
	b: Beta
	using b
	_ = n
}
`
    at := strings.index(src, "_ = n") + 4
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)

    testing.expect(t, ok, "expected the using field to resolve")
    testing.expect(t, loc.start == strings.index(src, "n: string"), "expected Beta's field, not Alpha's")
}

@(test)
test_using_statement_hover :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
}

main :: proc() {
	p: Point
	using p
	_ = x
}
`
    at := strings.index(src, "_ = x") + 4
    req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected a hover on the using field")
    testing.expectf(t, res.hover.text == "x: int", "using hover: got %q", res.hover.text)
}

@(test)
test_using_statement_before_declaration :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The fields arrive with the `using`, so a name above it is not one of them.
    src := `package demo

Point :: struct {
	width: int,
}

main :: proc() {
	p: Point
	_ = wid
	using p
}
`
    res: lang.Result
    selector_completions(e, src, "_ = wid", &res)
    defer free_symbols(&res)

    testing.expect(t, !has_completion(&res, "width"), "a field is not in scope above its using")
}

@(test)
test_using_statement_scoped_to_block :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The `using` sits in an inner block, so the name is gone below it.
    src := `package demo

Point :: struct {
	width: int,
}

main :: proc() {
	p: Point
	{
		using p
	}
	_ = wid
}
`
    res: lang.Result
    selector_completions(e, src, "_ = wid", &res)
    defer free_symbols(&res)

    testing.expect(t, !has_completion(&res, "width"), "a using does not reach past the block it sits in")
}

@(test)
test_using_binding_wins :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A local of the same name keeps its own declaration.
    src := `package demo

Point :: struct {
	x: int,
}

main :: proc() {
	p: Point
	using p
	x := 2
	_ = x
}
`
    at := strings.index(src, "_ = x") + 4
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)

    testing.expect(t, ok, "expected the local to resolve")
    testing.expect(t, loc.start == strings.index(src, "x := 2"), "expected the local, not the using field")
}

@(test)
test_using_field_chain :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The bare name carries its type, so a member access on it still resolves.
    src := `package demo

Inner :: struct {
	depth: int,
}

Outer :: struct {
	inner: Inner,
}

main :: proc() {
	o: Outer
	using o
	_ = inner.depth
}
`
    at := strings.index(src, "inner.depth") + 6
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)

    testing.expect(t, ok, "expected the chained member to resolve")
    testing.expect(t, loc.start == strings.index(src, "depth: int"), "expected Inner's depth")
}

@(test)
test_using_parameter_definition :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
}

main :: proc(using p: Point) {
	_ = x
}
`
    at := strings.index(src, "_ = x") + 4
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)

    testing.expect(t, ok, "expected the using parameter's field to resolve")
    testing.expect(t, loc.start == strings.index(src, "x: int"), "expected Point's x")
}

@(test)
test_using_completion :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	width: int,
	depth: int,
}

main :: proc() {
	p: Point
	using p
	_ = wid
}
`
    res: lang.Result
    selector_completions(e, src, "_ = wid", &res)
    defer free_symbols(&res)

    testing.expect(t, has_completion(&res, "width"), "expected the using field as a candidate")
    testing.expect(t, !has_completion(&res, "depth"), "expected the prefix to filter")
}

@(test)
test_using_member_expression_operand :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The operand of a `using` is any expression, not only a bare name.
    src := `package demo

Inner :: struct {
	depth: int,
}

Outer :: struct {
	inner: Inner,
}

main :: proc() {
	o: Outer
	using o.inner
	_ = depth
}
`
    at := strings.index(src, "_ = depth") + 4
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)

    testing.expect(t, ok, "expected the nested using to resolve")
    testing.expect(t, loc.start == strings.index(src, "depth: int"), "expected Inner's depth")
}
