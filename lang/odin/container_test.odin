// The members a container has itself: fixed-array swizzles, `#soa` per-field
// arrays, and the variants a union offers a type assertion.
package odin

import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_swizzle_hover_component :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

main :: proc() {
	v: [4]f32
	_ = v.x
}
`
    at := strings.index(src, "v.x") + 2
    req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected a hover on the swizzle")
    testing.expectf(t, res.hover.text == "x: f32", "swizzle hover: got %q", res.hover.text)
}

@(test)
test_swizzle_hover_group :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

main :: proc() {
	v: [4]f32
	_ = v.rgb
}
`
    at := strings.index(src, "v.rgb") + 2
    req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected a hover on the grouped swizzle")
    testing.expectf(t, res.hover.text == "rgb: [3]f32", "swizzle hover: got %q", res.hover.text)
}

@(test)
test_swizzle_outside_array :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `z` is the third component, which a two-element array does not have.
    src := `package demo

main :: proc() {
	v: [2]f32
	_ = v.z
}
`
    at := strings.index(src, "v.z") + 2
    req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, !res.ok, "a component past the array's length is no member")
}

@(test)
test_swizzle_slice_has_no_members :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

main :: proc() {
	v: []f32
	_ = v.x
}
`
    at := strings.index(src, "v.x") + 2
    req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, !res.ok, "a slice swizzles nothing")
}

@(test)
test_swizzle_completion :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

main :: proc() {
	v: [3]f32
	_ = v.
}
`
    res: lang.Result
    selector_completions(e, src, "v.", &res)
    defer free_symbols(&res)

    testing.expect(t, has_completion(&res, "x"), "expected the x component")
    testing.expect(t, has_completion(&res, "b"), "expected the b component")
    testing.expect(t, !has_completion(&res, "w"), "a three-element array has no fourth component")
}

@(test)
test_soa_member_definition :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: f32,
	y: f32,
}

main :: proc() {
	s: #soa[]Point
	_ = s.y
}
`
    at := strings.index(src, "s.y") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)

    testing.expect(t, ok, "expected the #soa member to resolve")
    testing.expectf(t, src[loc.start:loc.end] == "y", "soa member: got %q", src[loc.start:loc.end])
    testing.expect(t, loc.start == strings.index(src, "y: f32"), "expected the element struct's own field")
}

@(test)
test_soa_member_hover_wraps_field :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // An `#soa` array holds one array per field, so the field reads as a slice
    // of its declared type rather than as the type itself.
    src := `package demo

Point :: struct {
	x: f32,
}

main :: proc() {
	s: #soa[]Point
	_ = s.x
}
`
    at := strings.index(src, "s.x") + 2
    req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected a hover on the #soa member")
    testing.expectf(t, res.hover.text == "x: []f32", "soa hover: got %q", res.hover.text)
}

@(test)
test_soa_fixed_hover :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `#soa[8]Point` writes its tag beside the type, not inside the brackets.
    src := `package demo

Point :: struct {
	x: f32,
}

main :: proc() {
	s: #soa[8]Point
	_ = s.x
}
`
    at := strings.index(src, "s.x") + 2
    req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected a hover on the fixed #soa member")
    testing.expectf(t, res.hover.text == "x: [8]f32", "soa hover: got %q", res.hover.text)
}

@(test)
test_soa_completion :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: f32,
	y: f32,
}

main :: proc() {
	s: #soa[]Point
	_ = s.
}
`
    res: lang.Result
    selector_completions(e, src, "s.", &res)
    defer free_symbols(&res)

    testing.expect(t, has_completion(&res, "x"), "expected the element's x field")
    testing.expect(t, has_completion(&res, "y"), "expected the element's y field")
}

@(test)
test_soa_element_member_chain :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Indexing an `#soa` array yields the element struct, whose fields resolve
    // the ordinary way.
    src := `package demo

Point :: struct {
	x: f32,
}

main :: proc() {
	s: #soa[]Point
	_ = s[0].x
}
`
    at := strings.index(src, "s[0].x") + 5
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)

    testing.expect(t, ok, "expected the element's field to resolve")
    testing.expect(t, loc.start == strings.index(src, "x: f32"), "expected Point's x")
}

@(test)
test_container_nesting_past_four :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Six container levels — more than the four this engine used to model.
    src := `package demo

Point :: struct {
	x: int,
}

main :: proc() {
	xs: [][][][][][]Point
	_ = xs[0][0][0][0][0][0].x
}
`
    at := strings.index(src, "].x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)

    testing.expect(t, ok, "expected six nested containers to unwrap")
    testing.expect(t, loc.start == strings.index(src, "x: int"), "expected Point's x")
}

@(test)
test_container_nesting_past_eight :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Ten container levels — more than the eight this engine used to model.
    src := `package demo

Point :: struct {
	x: int,
}

main :: proc() {
	xs: [][][][][][][][][][]Point
	_ = xs[0][0][0][0][0][0][0][0][0][0].x
}
`
    at := strings.index(src, "].x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)

    testing.expect(t, ok, "expected ten nested containers to unwrap")
    testing.expect(t, loc.start == strings.index(src, "x: int"), "expected Point's x")
}

@(test)
test_wrap_container_depth_limit :: proc(t: ^testing.T) {
    tr := Type_Ref{name = "Point"}
    for i in 0 ..< CONTAINER_DEPTH_LIMIT {
        wrapped, ok := wrap_container(tr, Container_Layer{kind = .Array})
        testing.expectf(t, ok, "expected layer %d to wrap", i)
        tr = wrapped
    }
    testing.expectf(t, tr.depth == CONTAINER_DEPTH_LIMIT, "depth: got %d, want %d", tr.depth, CONTAINER_DEPTH_LIMIT)

    _, ok := wrap_container(tr, Container_Layer{kind = .Array})
    testing.expect(t, !ok, "expected the layer past the limit to fail")
}

@(test)
test_union_variant_completion :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
}

Value :: union {
	int,
	Point,
}

main :: proc() {
	v: Value
	_ = v.(
}
`
    res: lang.Result
    selector_completions(e, src, "v.(", &res)
    defer free_symbols(&res)

    testing.expect(t, has_completion(&res, "Point"), "expected the Point variant")
    testing.expect(t, has_completion(&res, "int"), "expected the int variant")
}

@(test)
test_union_variant_completion_prefix :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Alpha :: struct {
	a: int,
}

Beta :: struct {
	b: int,
}

Value :: union {
	Alpha,
	Beta,
}

main :: proc() {
	v: Value
	_ = v.(Be
}
`
    res: lang.Result
    selector_completions(e, src, "v.(Be", &res)
    defer free_symbols(&res)

    testing.expect(t, has_completion(&res, "Beta"), "expected the prefixed variant")
    testing.expect(t, !has_completion(&res, "Alpha"), "expected the prefix to filter")
}

@(test)
test_union_member_offers_nothing :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // An un-narrowed union has no members; only the assertion above reaches one.
    src := `package demo

Value :: union {
	int,
}

main :: proc() {
	v: Value
	_ = v.
}
`
    res: lang.Result
    selector_completions(e, src, "v.", &res)
    defer free_symbols(&res)

    testing.expect(t, len(res.symbols) == 0, "a union offers no members on a plain dot")
}
