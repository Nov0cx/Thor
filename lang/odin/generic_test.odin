package odin

import "core:strings"
import "core:testing"

import lang ".."

// `l: List(Point)` substitutes the struct's `$T`, so `l.items[0].x` reaches Point.
@(test)
test_generic_struct_field_substitutes_argument :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
}

List :: struct($T: typeid) {
	items: []T,
}

main :: proc() {
	l: List(Point)
	_ = l.items[0].x
}
`
    at := strings.index(src, "l.items[0].x") + len("l.items[0].")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected l.items[0].x to resolve through List(Point)")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

// Completion after `l.items[0].` offers the argument type's fields.
@(test)
test_generic_struct_field_completion :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

Pair :: struct($K: typeid, $V: typeid) {
	key:   K,
	value: V,
}

main :: proc() {
	p: Pair(int, Point)
	_ = p.value.
}
`
    res: lang.Result
    selector_completions(e, src, "p.value.", &res)
    defer free_symbols(&res)

    testing.expect(t, has_completion(&res, "x"), "expected Point's x through the second argument")
    testing.expect(t, has_completion(&res, "y"), "expected Point's y through the second argument")
}

// An alias that fixes the arguments (`Points :: List(Point)`) carries them.
@(test)
test_generic_alias_carries_arguments :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
}

List :: struct($T: typeid) {
	head: ^T,
}

Points :: List(Point)

main :: proc() {
	l: Points
	_ = l.head.x
}
`
    at := strings.index(src, "l.head.x") + len("l.head.")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected l.head.x to resolve through the alias")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

// A field written as another generic over the struct's own parameter
// (`next: ^Node(T)`) keeps the argument one level down.
@(test)
test_generic_field_of_generic_type :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
}

Node :: struct($T: typeid) {
	value: T,
	next:  ^Node(T),
}

main :: proc() {
	n: Node(Point)
	_ = n.next.value.x
}
`
    at := strings.index(src, "n.next.value.x") + len("n.next.value.")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected n.next.value.x to resolve")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

// A composite literal `List(Point){}` names its arguments too.
@(test)
test_generic_composite_literal :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
}

Box :: struct($T: typeid) {
	inner: T,
}

main :: proc() {
	b := Box(Point){}
	_ = b.inner.x
}
`
    at := strings.index(src, "b.inner.x") + len("b.inner.")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected b.inner.x to resolve through Box(Point){}")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

// A parameter's unbound `T` is not some other type that happens to be named T.
@(test)
test_generic_unbound_parameter_names_nothing :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

T :: struct {
	x: int,
}

Box :: struct($T: typeid) {
	inner: T,
}

main :: proc() {
	b: Box
	_ = b.inner.
}
`
    res: lang.Result
    selector_completions(e, src, "b.inner.", &res)
    defer free_symbols(&res)

    testing.expect(t, !has_completion(&res, "x"), "an unbound $T must not complete as the unrelated T")
}

// `proc(l: ^List($E)) -> E` binds E to the argument of the List passed.
@(test)
test_generic_parameter_binds_argument :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
}

List :: struct($T: typeid) {
	items: []T,
}

first :: proc(l: ^List($E)) -> E {
	return l.items[0]
}

main :: proc() {
	l: List(Point)
	_ = first(&l).x
}
`
    at := strings.index(src, "first(&l).x") + len("first(&l).")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected first(&l).x to resolve through ^List($E)")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

// `proc($T: typeid) -> List(T)` builds a List of the type the call writes.
@(test)
test_generic_result_of_explicit_type :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
}

List :: struct($T: typeid) {
	items: []T,
}

make_list :: proc($T: typeid) -> List(T) {
	return {}
}

main :: proc() {
	l := make_list(Point)
	_ = l.items[0].x
}
`
    at := strings.index(src, "l.items[0].x") + len("l.items[0].")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected l.items[0].x to resolve through -> List(T)")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

// A named argument is matched against the parameter of that name.
@(test)
test_definition_overload_named_argument :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

draw_a :: proc(count: int, label: string) {}

draw_b :: proc(count: int, scale: f32) {}

draw :: proc{draw_a, draw_b}

main :: proc() {
	draw(1, scale = 2.5)
}
`
    res := definition_at(e, src, "draw(1")
    defer free_definition(&res)

    testing.expect(t, res.ok, "expected go-to-definition on a procedure group")
    testing.expectf(t, len(res.symbols) == 0, "the named argument picks one member: got %d candidates", len(res.symbols))
    want := strings.index(src, "draw_b ::")
    testing.expectf(t, res.location.start == want, "jump target: got %d, want %d", res.location.start, want)
}

// Two members that differ only in a generic argument are told apart by it.
@(test)
test_definition_overload_generic_argument :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

List :: struct($T: typeid) {
	items: []T,
}

sum_i :: proc(l: List(int)) -> int {
	return 0
}

sum_f :: proc(l: List(f32)) -> f32 {
	return 0
}

sum :: proc{sum_i, sum_f}

main :: proc() {
	l: List(f32)
	_ = sum(l)
}
`
    res := definition_at(e, src, "sum(l)")
    defer free_definition(&res)

    testing.expect(t, res.ok, "expected go-to-definition on a procedure group")
    testing.expectf(t, len(res.symbols) == 0, "the argument picks one member: got %d candidates", len(res.symbols))
    want := strings.index(src, "sum_f ::")
    testing.expectf(t, res.location.start == want, "jump target: got %d, want %d", res.location.start, want)
}
