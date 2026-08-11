// Member access (`value.field`): the type inference behind a struct field —
// declared types, aliases, conversions, type switches and call results.
package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_member_typed_local :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `p: Point` then `p.x`: the member resolves to the struct field, inferring
    // p's type from its declaration.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

main :: proc() {
	p: Point
	_ = p.x
}
`
    at := strings.index(src, "p.x") + 2 // caret on the member `x`
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected p.x to resolve to the field")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_composite_literal :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `p := Point{}`: the type is inferred from the composite literal.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

main :: proc() {
	p := Point{}
	_ = p.y
}
`
    at := strings.index(src, "p.y") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected p.y to resolve via the composite literal type")
    if ok {
        want := strings.index(src, "y: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_parameter :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A struct-typed parameter's field resolves.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

use :: proc(p: Point) -> int {
	return p.x
}
`
    at := strings.index(src, "p.x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the parameter's field to resolve")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_pointer :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Odin auto-derefs `.` on a pointer, so `^Point` still resolves fields.
    src := `package demo

Point :: struct {
	x: int,
}

main :: proc() {
	p: ^Point
	_ = p.x
}
`
    at := strings.index(src, "p.x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected a pointer's field to resolve")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_chain :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `l.a.x`: chained access recurses through the intermediate struct's field
    // type (Line.a is a Point, whose field x is the target).
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

Line :: struct {
	a: Point,
	b: Point,
}

main :: proc() {
	l: Line
	_ = l.a.x
}
`
    at := strings.index(src, "l.a.x") + 4 // caret on the final `x`
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the chained member to resolve")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "chained member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_hover :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

main :: proc() {
	p: Point
	_ = p.x
}
`
    at := strings.index(src, "p.x") + 2
    req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected hover on the member")
    testing.expectf(t, res.hover.text == "x: int", "member hover: got %q", res.hover.text)
}

@(test)
test_member_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The struct is declared in a sibling file; member access follows the
    // workspace index to it (the live buffer never declares Point).
    dir := "thor_lang_member_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    point := strings.concatenate({dir, "/point.odin"}, context.temp_allocator)
    point_src := "package demo\n\nPoint :: struct {\n\tx: int,\n\ty: int,\n}\n"
    _ = os.write_entire_file(point, transmute([]byte)point_src)
    defer os.remove(point)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc() {\n\tp: Point\n\t_ = p.x\n}\n"

    at := strings.index(main_src, "p.x") + 2
    loc, ok := resolve_offset(e, main_src, at, dir, main_path)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the cross-file struct's field to resolve")
    if ok {
        testing.expectf(t, strings.has_suffix(loc.path, "point.odin"), "path: got %q", loc.path)
        want := strings.index(point_src, "x: int")
        testing.expectf(t, loc.start == want, "cross-file member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_completion :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `p.` with p: Point offers the struct's fields.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

main :: proc() {
	p: Point
	_ = p.
}
`
    at := strings.index(src, "_ = p.") + len("_ = p.")
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected member completions")
    testing.expect(t, has_completion(&res, "x"), "missing field x")
    testing.expect(t, has_completion(&res, "y"), "missing field y")
    for sym in res.symbols {
        if sym.name == "x" {
            testing.expectf(t, sym.kind == "field", "x kind: got %q", sym.kind)
            testing.expectf(t, sym.signature == "x: int", "x label: got %q", sym.signature)
        }
    }
}

@(test)
test_member_type_alias :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A name that only stands for a type still carries that type's members:
    // a plain rename, a `distinct` type, and a second hop through another alias.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

Vec :: Point
Handle :: distinct Point
Pair :: Vec

main :: proc() {
	v: Vec
	h: Handle
	p: Pair
	_ = v.x
	_ = h.y
	_ = p.x
}
`
    probes := []struct {
        needle, field: string,
    }{{"v.x", "x: int"}, {"h.y", "y: int"}, {"p.x", "x: int"}}

    for probe in probes {
        at := strings.index(src, probe.needle) + 2 // caret on the member
        loc, ok := resolve_offset(e, src, at)
        defer delete(loc.path)
        testing.expectf(t, ok, "expected %s to resolve through the alias", probe.needle)
        if ok {
            want := strings.index(src, probe.field)
            testing.expectf(t, loc.start == want, "%s: got %d, want %d", probe.needle, loc.start, want)
        }
    }
}

@(test)
test_enum_selector_through_alias :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The expected type is an alias, so the enum it selects from is one hop away.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

Direction :: Axis

main :: proc() {
	d: Direction = .
	_ = d
}
`
    res: lang.Result
    selector_completions(e, src, "Direction = .", &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected enum completions through the alias")
    testing.expect(t, has_completion(&res, "Horizontal"), "missing member Horizontal")
}

@(test)
test_alias_cycle_terminates :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Two aliases naming each other resolve to nothing rather than looping.
    src := `package demo

A :: B
B :: A

main :: proc() {
	a: A
	_ = a.x
}
`
    at := strings.index(src, "a.x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, !ok, "a cycle names no declaration")
}

@(test)
test_member_alias_across_packages :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `lib.Vec` is an alias written in lib, so the name it stands for is resolved
    // from lib's side, not the importing file's.
    root := "thor_lang_alias_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    lib_path := strings.concatenate({lib, "/api.odin"}, context.temp_allocator)
    lib_src := "package lib\n\nPoint :: struct {\n\tx: int,\n}\n\nVec :: Point\n"
    _ = os.write_entire_file(lib_path, transmute([]byte)lib_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(lib_path)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\tv: lib.Vec\n\t_ = v.x\n}\n"

    at := strings.index(main_src, "v.x") + 2
    loc, ok := resolve_offset(e, main_src, at, root, main_path)
    defer delete(loc.path)

    testing.expect(t, ok, "expected lib.Vec's field to resolve through the alias")
    if ok {
        testing.expectf(t, strings.has_suffix(loc.path, "api.odin"), "path: got %q", loc.path)
        want := strings.index(lib_src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_through_conversion :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A conversion names the type of the value it yields, so that value carries
    // the named type's members however the conversion is spelled: `cast`,
    // `transmute`, the call-shaped `T(x)`, or a `x.(T)` assertion.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

Handle :: distinct Point

Shape :: union {
	Point,
}

main :: proc() {
	raw: [2]int
	h: Handle
	s: Shape
	c := cast(Point)h
	tm := transmute(Point)raw
	cv := Point(h)
	as := s.(Point)
	got, ok := s.(Point)
	_ = c.x
	_ = tm.y
	_ = cv.x
	_ = as.y
	_ = got.x
	_ = ok
}
`
    probes := []struct {
        needle, field: string,
    }{{"c.x", "x: int"}, {"tm.y", "y: int"}, {"cv.x", "x: int"}, {"as.y", "y: int"}, {"got.x", "x: int"}}

    for probe in probes {
        at := strings.index(src, probe.needle) + strings.index(probe.needle, ".") + 1
        loc, ok := resolve_offset(e, src, at)
        defer delete(loc.path)
        testing.expectf(t, ok, "expected %s to resolve through the conversion", probe.needle)
        if ok {
            want := strings.index(src, probe.field)
            testing.expectf(t, loc.start == want, "%s: got %d, want %d", probe.needle, loc.start, want)
        }
    }
}

@(test)
test_member_through_qualified_conversion :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `lib.Point(h)` is a conversion, not a call: no procedure of that name exists
    // in lib, and the qualifier sits on the member expression the call hangs under.
    root := "thor_lang_conv_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    lib_path := strings.concatenate({lib, "/api.odin"}, context.temp_allocator)
    lib_src := "package lib\n\nPoint :: struct {\n\tx: int,\n}\n\nHandle :: distinct Point\n"
    _ = os.write_entire_file(lib_path, transmute([]byte)lib_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(lib_path)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\th: lib.Handle\n\tp := lib.Point(h)\n\t_ = p.x\n}\n"

    at := strings.index(main_src, "p.x") + 2
    loc, ok := resolve_offset(e, main_src, at, root, main_path)
    defer delete(loc.path)

    testing.expect(t, ok, "expected the converted value's field to resolve")
    if ok {
        testing.expectf(t, strings.has_suffix(loc.path, "api.odin"), "path: got %q", loc.path)
        want := strings.index(lib_src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_type_switch_variant :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Each case of a type switch narrows the variable to the type it names, so the
    // same `v` carries different members from one case to the next. A case naming
    // several types, and the default case, narrow to nothing.
    src := `package demo

Circle :: struct {
	radius: int,
}

Square :: struct {
	side: int,
}

Shape :: union {
	Circle,
	Square,
}

main :: proc() {
	s: Shape
	switch v in s {
	case Circle:
		_ = v.radius
	case ^Square:
		_ = v.side
	}
}
`
    // The variable itself is a declaration, though the LOCALS query captures none.
    decl := strings.index(src, "v in s")
    loc, ok := resolve_offset(e, src, strings.index(src, "v.radius"))
    defer delete(loc.path)
    testing.expect(t, ok, "expected the switch variable to resolve to its declaration")
    if ok {
        testing.expectf(t, loc.start == decl, "v: got %d, want %d", loc.start, decl)
    }

    hits := []struct {
        needle, field: string,
    }{{"v.radius", "radius: int"}, {"v.side", "side: int"}}
    for probe in hits {
        at := strings.index(src, probe.needle) + 2
        hit, hok := resolve_offset(e, src, at)
        defer delete(hit.path)
        testing.expectf(t, hok, "expected %s to resolve through the case type", probe.needle)
        if hok {
            want := strings.index(src, probe.field)
            testing.expectf(t, hit.start == want, "%s: got %d, want %d", probe.needle, hit.start, want)
        }
    }

    // What a case narrows to shows in the member candidates it offers, which a
    // definition probe cannot tell apart: an unresolved `x.field` falls back to the
    // identifier lookup and reaches the field declaration regardless.
    heads := []struct {
        label, body: string,
    } {
        {"a case naming one type", "\tcase Circle:\n\t\t_ = v.\n\t}\n}\n"},
        {"a case naming several", "\tcase Circle, Square:\n\t\t_ = v.\n\t}\n}\n"},
        {"the default case", "\tcase:\n\t\t_ = v.\n\t}\n}\n"},
    }
    head := src[:strings.index(src, "\tcase Circle:")]
    for probe, i in heads {
        text := strings.concatenate({head, probe.body}, context.temp_allocator)
        at := strings.index(text, "v.\n") + len("v.")
        req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = text, offset = at}
        res := lang.Result{kind = .Completion}
        resolve(e, &req, &res)
        defer free_symbols(&res)

        if i == 0 {
            testing.expect(t, has_completion(&res, "radius"), "a narrowed value offers its own fields")
            testing.expectf(t, len(res.symbols) == 1, "%s offers only that type: got %d", probe.label, len(res.symbols))
            continue
        }
        // Several types leave the variable as the union, and the default case
        // narrows nothing — neither names one type to reach members through.
        testing.expectf(t, !res.ok, "%s narrows to no single type, got %d candidates", probe.label, len(res.symbols))
    }
}

@(test)
test_type_switch_qualified_variant :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A case naming a type from another package arrives as a member expression
    // rather than a qualified type, and still has to reach the right package.
    root := "thor_lang_union_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    lib_path := strings.concatenate({lib, "/api.odin"}, context.temp_allocator)
    lib_src := "package lib\n\nCircle :: struct {\n\tradius: int,\n}\n\nShape :: union {\n\tCircle,\n}\n"
    _ = os.write_entire_file(lib_path, transmute([]byte)lib_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(lib_path)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\ts: lib.Shape\n\tswitch v in s {\n\tcase lib.Circle:\n\t\t_ = v.radius\n\t}\n}\n"

    at := strings.index(main_src, "v.radius") + 2
    loc, ok := resolve_offset(e, main_src, at, root, main_path)
    defer delete(loc.path)

    testing.expect(t, ok, "expected the narrowed value's field to resolve")
    if ok {
        testing.expectf(t, strings.has_suffix(loc.path, "api.odin"), "path: got %q", loc.path)
        want := strings.index(lib_src, "radius: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_call_result :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `p := make_point()`: the binding has no written type, so it comes from the
    // callee's declared result. The nested `proc() -> int` parameter must not be
    // mistaken for that result.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

make_point :: proc(seed: proc() -> int) -> Point {
	return Point{}
}

main :: proc() {
	p := make_point(nil)
	_ = p.y
}
`
    at := strings.index(src, "p.y") + 2 // caret on the member `y`
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected p.y to resolve through the call's result type")
    if ok {
        want := strings.index(src, "y: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_call_result_pointer :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A named, pointer result (`-> (out: ^Point)`) still yields Point — `.`
    // auto-dereferences and the result's name is not part of its type.
    src := `package demo

Point :: struct {
	x: int,
}

alloc_point :: proc() -> (out: ^Point) {
	return nil
}

main :: proc() {
	p := alloc_point()
	_ = p.x
}
`
    at := strings.index(src, "p.x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected a named pointer result to resolve")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_call_result_multi_value :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `p, ok := find()` with `-> (Point, bool)`: each name takes one result slot,
    // so `p` is the Point and `ok` (slot 1, a bool) has no fields.
    src := `package demo

Point :: struct {
	x: int,
}

find :: proc() -> (Point, bool) {
	return Point{}, true
}

main :: proc() {
	p, ok := find()
	_ = p.x
	_ = ok
}
`
    at := strings.index(src, "p.x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the first result slot to resolve to Point")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_new_builtin :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `new(Point)` is a builtin with no declaration to resolve: the allocated type
    // is the result (a pointer, which `.` auto-dereferences).
    src := `package demo

Point :: struct {
	x: int,
}

main :: proc() {
	p := new(Point)
	_ = p.x
}
`
    at := strings.index(src, "p.x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected new(Point) to resolve to Point")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_aliased_binding :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `q := p` takes p's type; a self-referential binding (`z := z`) must bottom
    // out at the depth limit rather than recursing forever — its members are
    // simply unknown (goto would still fall through to the flat name scan, so the
    // observable answer is that no fields are offered for it).
    src := `package demo

Point :: struct {
	x: int,
}

main :: proc() {
	p: Point
	q := p
	_ = q.x
	z := z
	_ = z.
}
`
    at := strings.index(src, "q.x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the aliased binding to resolve")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }

    dot := strings.index(src, "_ = z.") + len("_ = z.")
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = dot}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)
    testing.expect(t, !res.ok, "a self-referential binding must not infer a type")
}

@(test)
test_member_shadowed_binding :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A package variable `p: Point` shadowed further down by a local `p :=
    // Label{}`. Type inference follows the same visibility rule as goto, so the
    // member above the local is Point's and the one below is Label's. Both
    // structs spell the field `tag`, so a member that resolves against the wrong
    // binding lands on the wrong declaration instead of quietly falling through
    // to the flat name scan.
    src := `package demo

Point :: struct {
	tag: int,
}

Label :: struct {
	tag: string,
}

p: Point

main :: proc() {
	_ = p.tag
	p := Label{}
	_ = p.tag
}
`
    point_tag := strings.index(src, "tag: int")
    label_tag := strings.index(src, "tag: string")

    loc, ok := resolve_offset(e, src, strings.index(src, "p.tag") + 2)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the package variable's member to resolve")
    if ok {
        testing.expectf(t, loc.start == point_tag, "above: got %d, want Point's tag at %d", loc.start, point_tag)
    }

    loc2, ok2 := resolve_offset(e, src, strings.last_index(src, "p.tag") + 2)
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected the shadowing local's member to resolve")
    if ok2 {
        testing.expectf(t, loc2.start == label_tag, "below: got %d, want Label's tag at %d", loc2.start, label_tag)
    }
}

@(test)
test_member_call_result_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The procedure and the struct it returns both live in a sibling file: the
    // callee is found through the workspace index, then its result type is.
    dir := "thor_lang_result_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    lib := strings.concatenate({dir, "/point.odin"}, context.temp_allocator)
    lib_src := "package demo\n\nPoint :: struct {\n\tx: int,\n\ty: int,\n}\n\nmake_point :: proc() -> Point {\n\treturn Point{}\n}\n"
    _ = os.write_entire_file(lib, transmute([]byte)lib_src)
    defer os.remove(lib)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc() {\n\tp := make_point()\n\t_ = p.y\n}\n"

    at := strings.index(main_src, "p.y") + 2
    loc, ok := resolve_offset(e, main_src, at, dir, main_path)
    defer delete(loc.path)
    testing.expect(t, ok, "expected a cross-file call result's field to resolve")
    if ok {
        testing.expectf(t, strings.has_suffix(loc.path, "point.odin"), "path: got %q", loc.path)
        want := strings.index(lib_src, "y: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_completion_call_result_member :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `p.` on a call-result binding offers the result struct's fields.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

make_point :: proc() -> Point {
	return Point{}
}

main :: proc() {
	p := make_point()
	_ = p.
}
`
    at := strings.index(src, "_ = p.") + len("_ = p.")
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected member completions on a call result")
    testing.expect(t, has_completion(&res, "x"), "missing field x")
    testing.expect(t, has_completion(&res, "y"), "missing field y")
}

@(test)
test_completion_expression_member :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The operand of a `.` is whatever expression ends at it, not just the word
    // before it: a field chain, an element and a call result all offer the struct
    // they read as, while a re-slice stays a container and offers nothing. Each
    // selector gets a buffer of its own, one dangling dot in it — the shape a live
    // edit has, and the one the filler-identifier repair is written for.
    head := `package demo

Point :: struct {
	x: int,
	y: int,
}

Line :: struct {
	from: Point,
	to:   Point,
}

make_point :: proc() -> Point {
	return Point{}
}

main :: proc() {
	l: Line
	pts: []Point
	_ = `

    typed :: proc(e: ^Engine, head, selector: string, res: ^lang.Result) {
        src := strings.concatenate({head, selector, "\n}\n"}, context.temp_allocator)
        selector_completions(e, src, selector, res)
    }

    for needle in ([]string{"l.from.", "pts[0].", "make_point()."}) {
        res: lang.Result
        typed(e, head, needle, &res)
        defer free_symbols(&res)
        testing.expectf(t, res.ok, "expected member completions on %q", needle)
        testing.expectf(t, has_completion(&res, "x"), "%q: missing field x", needle)
        testing.expectf(t, has_completion(&res, "y"), "%q: missing field y", needle)
    }

    sliced: lang.Result
    typed(e, head, "pts[1:].", &sliced)
    defer free_symbols(&sliced)
    testing.expect(t, !has_completion(&sliced, "x"), "a slice is still a container, not a Point")
}

@(test)
test_member_proc_value_result :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A proc-typed value names no declaration to look up, so its own signature is
    // what the call's result is read from: a struct's callback field, that field
    // bound to a local, and a plain proc-typed variable all resolve alike.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

Decoy :: struct {
	x: int,
	y: int,
}

Handlers :: struct {
	make_point: proc(a: int) -> Point,
}

global: proc() -> Point

main :: proc() {
	h: Handlers
	_ = h.make_point(1).x
	bound := h.make_point
	_ = bound(2).y
	_ = global().x
	made := global()
	_ = made.y
}
`
    Probe :: struct {
        needle: string,
        field:  string,
    }
    probes := [?]Probe {
        {"h.make_point(1).x", "x: int"},
        {"bound(2).y", "y: int"},
        {"global().x", "x: int"},
        {"made.y", "y: int"},
    }
    for probe in probes {
        at := strings.index(src, probe.needle) + len(probe.needle) - 1
        loc, ok := resolve_offset(e, src, at)
        defer delete(loc.path)
        testing.expectf(t, ok, "expected %s to resolve through the proc type's result", probe.needle)
        if ok {
            want := strings.index(src, probe.field)
            testing.expectf(t, loc.start == want, "%s: got %d, want %d", probe.needle, loc.start, want)
        }
    }
}

@(test)
test_completion_proc_value_result :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The same operand answers member completion, while the uncalled proc value
    // is not the type it returns.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

Handlers :: struct {
	make_point: proc(a: int) -> Point,
}

main :: proc() {
	h: Handlers
	_ = h.make_point(1).
}
`
    res: lang.Result
    selector_completions(e, src, "h.make_point(1).", &res)
    defer free_symbols(&res)
    testing.expect(t, has_completion(&res, "x"), "missing the result struct's field x")
    testing.expect(t, has_completion(&res, "y"), "missing the result struct's field y")

    uncalled := `package demo

Point :: struct {
	x: int,
	y: int,
}

Handlers :: struct {
	make_point: proc(a: int) -> Point,
}

main :: proc() {
	h: Handlers
	cb := h.make_point
	_ = cb.
}
`
    other: lang.Result
    selector_completions(e, uncalled, "cb.", &other)
    defer free_symbols(&other)
    testing.expect(t, !has_completion(&other, "x"), "a proc value is not the struct it returns")
}

@(test)
test_member_or_else :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `p := m[k] or_else Point{}` then `p.x`: or_else is type-transparent, so
    // the member resolves through the left operand's type (the map's element).
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

main :: proc() {
	m: map[string]Point
	k := "a"
	p := m[k] or_else Point{}
	_ = p.x
}
`
    at := strings.index(src, "p.x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected p.x to resolve through the or_else's left operand")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_polymorphic_result :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `identity :: proc(v: $T) -> T`: the bare-$T shorthand. At the call site
    // the result is simply whatever the bound argument itself infers to, so
    // `identity(p).x` reaches Point's own field.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

identity :: proc(v: $T) -> T {
	return v
}

main :: proc() {
	p := Point{}
	_ = identity(p).x
}
`
    at := strings.index(src, "identity(p).x") + len("identity(p).")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected identity(p).x to resolve through the bound $T")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_poly_param_shape_bare_shorthand :: proc(t: ^testing.T) {
    // `v: $T`: the shorthand, wrapped in nothing.
    name, shape, ok := poly_param_shape("v: $T")
    testing.expect(t, ok, "expected the bare $T shorthand to be found")
    if ok {
        testing.expectf(t, name == "T", "name: got %q, want T", name)
        testing.expectf(t, shape.depth == 0, "depth: got %d, want 0", shape.depth)
        testing.expectf(t, shape.pointers == 0, "pointers: got %d, want 0", shape.pointers)
    }
}

@(test)
test_poly_param_shape_container :: proc(t: ^testing.T) {
    // `xs: []$T`: $T sits inside a container — now read, not rejected.
    name, shape, ok := poly_param_shape("xs: []$T")
    testing.expect(t, ok, "expected $T inside a container to be found")
    if ok {
        testing.expectf(t, name == "T", "name: got %q, want T", name)
        testing.expectf(t, shape.depth == 1, "depth: got %d, want 1", shape.depth)
        if shape.depth == 1 {
            testing.expectf(
                t,
                shape.containers[0].kind == .Array,
                "kind: got %v, want Array",
                shape.containers[0].kind,
            )
        }
    }
}

@(test)
test_poly_param_shape_pointer :: proc(t: ^testing.T) {
    // `l: ^$T`: a pointer wraps $T — counted, not rejected.
    name, shape, ok := poly_param_shape("l: ^$T")
    testing.expect(t, ok, "expected $T behind a pointer to be found")
    if ok {
        testing.expectf(t, name == "T", "name: got %q, want T", name)
        testing.expectf(t, shape.pointers == 1, "pointers: got %d, want 1", shape.pointers)
        testing.expectf(t, shape.depth == 0, "depth: got %d, want 0", shape.depth)
    }
}

@(test)
test_peel_poly_shape_composed_pointer_and_container :: proc(t: ^testing.T) {
    // `^[]$T`: a pointer wraps a container, which wraps $T.
    shape, leaf, ok := peel_poly_shape("^[]$T")
    testing.expect(t, ok, "expected ^[]$T to peel cleanly")
    if ok {
        testing.expectf(t, shape.pointers == 1, "pointers: got %d, want 1", shape.pointers)
        testing.expectf(t, shape.depth == 1, "depth: got %d, want 1", shape.depth)
        testing.expectf(t, leaf == "$T", "leaf: got %q, want $T", leaf)
    }
}

@(test)
test_peel_poly_shape_map :: proc(t: ^testing.T) {
    shape, leaf, ok := peel_poly_shape("map[string]$T")
    testing.expect(t, ok, "expected map[string]$T to peel cleanly")
    if ok {
        testing.expectf(t, shape.depth == 1, "depth: got %d, want 1", shape.depth)
        if shape.depth == 1 {
            testing.expectf(t, shape.containers[0].kind == .Map, "kind: got %v, want Map", shape.containers[0].kind)
            testing.expectf(t, shape.containers[0].key == "string", "key: got %q, want string", shape.containers[0].key)
        }
        testing.expectf(t, leaf == "$T", "leaf: got %q, want $T", leaf)
    }
}

@(test)
test_peel_poly_shape_bit_set :: proc(t: ^testing.T) {
    shape, leaf, ok := peel_poly_shape("bit_set[$T]")
    testing.expect(t, ok, "expected bit_set[$T] to peel cleanly")
    if ok {
        testing.expectf(t, shape.depth == 1, "depth: got %d, want 1", shape.depth)
        if shape.depth == 1 {
            testing.expectf(
                t,
                shape.containers[0].kind == .Bit_Set,
                "kind: got %v, want Bit_Set",
                shape.containers[0].kind,
            )
        }
        testing.expectf(t, leaf == "$T", "leaf: got %q, want $T", leaf)
    }
}

@(test)
test_peel_poly_shape_where_clause_tail_dropped :: proc(t: ^testing.T) {
    // A trailing `where` clause is not part of the type — the same tail
    // result_type_ref's own default case already drops for the general path.
    shape, leaf, ok := peel_poly_shape("T where T == int")
    testing.expect(t, ok, "expected the where clause tail to be dropped")
    if ok {
        testing.expectf(t, leaf == "T", "leaf: got %q, want T", leaf)
        testing.expectf(t, shape.depth == 0, "depth: got %d, want 0", shape.depth)
    }
}

@(test)
test_explicit_poly_name_typeid_form :: proc(t: ^testing.T) {
    // `$T: typeid`: the explicit binding form.
    name, ok := explicit_poly_name("$T: typeid")
    testing.expect(t, ok, "expected the explicit typeid form to be found")
    if ok {
        testing.expectf(t, name == "T", "got %q, want T", name)
    }
}

@(test)
test_explicit_poly_name_specialization_form :: proc(t: ^testing.T) {
    // `$T: typeid/int`: typeid with a specialization — the constraint text
    // past the slash is tolerated, not parsed further.
    name, ok := explicit_poly_name("$T: typeid/int")
    testing.expect(t, ok, "expected the typeid/Constraint form to be found")
    if ok {
        testing.expectf(t, name == "T", "got %q, want T", name)
    }
}

@(test)
test_explicit_poly_name_rejects_value_parameter :: proc(t: ^testing.T) {
    // `$N: int` is a compile-time *value* parameter (array-size shorthand),
    // not a type parameter — must not be read as one just because its name
    // starts with `$`.
    _, ok := explicit_poly_name("$N: int")
    testing.expect(t, !ok, "a $Name: int value parameter must not match")
}

@(test)
test_polymorphic_params_explicit_form_bound_by_later_usage :: proc(t: ^testing.T) {
    // `proc($T: typeid, v: T) -> T`: T supplies no shape at its own
    // parameter — it is bound by the later `v: T` parameter instead, the same
    // way Odin itself infers `$T: typeid` when a caller passes no type
    // argument explicitly.
    bindings := polymorphic_params("proc($T: typeid, v: T) -> T")
    testing.expectf(t, len(bindings) == 1, "expected one binding, got %d", len(bindings))
    if len(bindings) == 1 {
        testing.expectf(t, bindings[0].name == "T", "name: got %q, want T", bindings[0].name)
        testing.expectf(t, bindings[0].index == 1, "index: got %d, want 1", bindings[0].index)
    }
}

@(test)
test_polymorphic_params_multiple_names :: proc(t: ^testing.T) {
    // `proc(a: $T, b: $U) -> (T, U)`: two independently bound names.
    bindings := polymorphic_params("proc(a: $T, b: $U) -> (T, U)")
    testing.expectf(t, len(bindings) == 2, "expected two bindings, got %d", len(bindings))
    if len(bindings) == 2 {
        testing.expectf(t, bindings[0].name == "T", "binding 0 name: got %q, want T", bindings[0].name)
        testing.expectf(t, bindings[0].index == 0, "binding 0 index: got %d, want 0", bindings[0].index)
        testing.expectf(t, bindings[1].name == "U", "binding 1 name: got %q, want U", bindings[1].name)
        testing.expectf(t, bindings[1].index == 1, "binding 1 index: got %d, want 1", bindings[1].index)
    }
}

@(test)
test_result_poly_use_unwraps_container_parameter :: proc(t: ^testing.T) {
    // `proc(xs: []$T) -> T`: the result is bare, the parameter is not — no
    // container is left to wrap back onto the result.
    sig := "proc(xs: []$T) -> T"
    bindings := polymorphic_params(sig)
    shape, binding, ok := result_poly_use(sig, bindings, 0)
    testing.expect(t, ok, "expected the result to resolve to T's binding")
    if ok {
        testing.expectf(t, binding.name == "T", "name: got %q, want T", binding.name)
        testing.expectf(t, shape.depth == 0, "result shape depth: got %d, want 0", shape.depth)
    }
}

@(test)
test_result_poly_use_wraps_container_result :: proc(t: ^testing.T) {
    // `proc(v: $T) -> []T`: the parameter is bare, the result wraps it in a
    // container the parameter didn't have.
    sig := "proc(v: $T) -> []T"
    bindings := polymorphic_params(sig)
    shape, binding, ok := result_poly_use(sig, bindings, 0)
    testing.expect(t, ok, "expected the result to resolve to T's binding")
    if ok {
        testing.expectf(t, binding.name == "T", "name: got %q, want T", binding.name)
        testing.expectf(t, shape.depth == 1, "result shape depth: got %d, want 1", shape.depth)
        if shape.depth == 1 {
            testing.expectf(t, shape.containers[0].kind == .Array, "kind: got %v, want Array", shape.containers[0].kind)
        }
    }
}

@(test)
test_result_poly_use_rejects_unrelated_tuple :: proc(t: ^testing.T) {
    // A genuinely non-polymorphic result must still be rejected —
    // result_poly_use only ever matches a known binding's name, and there are
    // none here.
    _, _, ok := result_poly_use("proc() -> (a, b: int)", nil, 0)
    testing.expect(t, !ok, "an unrelated tuple result must not match with no bindings")
}

@(test)
test_member_polymorphic_result_through_container :: proc(t: ^testing.T) {
    // `first :: proc(xs: []$T) -> T`: $T sits inside the parameter's
    // container — the result is the argument's element type.
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

first :: proc(xs: []$T) -> T {
	return xs[0]
}

main :: proc() {
	pts: []Point
	_ = first(pts).x
}
`
    at := strings.index(src, "first(pts).x") + len("first(pts).")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected first(pts).x to resolve through []$T")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_polymorphic_result_wraps_container :: proc(t: ^testing.T) {
    // `singleton :: proc(v: $T) -> []T`: the result wraps the argument's own
    // type in a container the parameter didn't have.
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

singleton :: proc(v: $T) -> []T {
	return []T{v}
}

main :: proc() {
	p := Point{}
	xs := singleton(p)
	_ = xs[0].x
}
`
    at := strings.index(src, "xs[0].x") + len("xs[0].")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected xs[0].x to resolve through singleton's []T result")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_polymorphic_result_through_pointer :: proc(t: ^testing.T) {
    // `deref :: proc(l: ^$T) -> T`: a pointer wraps $T on the parameter side —
    // transparent, same as everywhere else a pointer appears in this engine.
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

deref :: proc(l: ^$T) -> T {
	return l^
}

main :: proc() {
	p := Point{}
	_ = deref(&p).x
}
`
    at := strings.index(src, "deref(&p).x") + len("deref(&p).")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected deref(&p).x to resolve through ^$T")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_polymorphic_result_multiple_names :: proc(t: ^testing.T) {
    // `pair :: proc(a: $T, b: $U) -> (T, U)`: two names composed into a tuple
    // result, each slot resolving through its own argument.
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

Vec :: struct {
	dx: int,
	dy: int,
}

pair :: proc(a: $T, b: $U) -> (T, U) {
	return a, b
}

main :: proc() {
	p := Point{}
	v := Vec{}
	first, second := pair(p, v)
	_ = first.x
	_ = second.dx
}
`
    at1 := strings.index(src, "first.x") + len("first.")
    loc1, ok1 := resolve_offset(e, src, at1)
    defer delete(loc1.path)
    testing.expect(t, ok1, "expected first.x to resolve through slot 0's T")
    if ok1 {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc1.start == want, "slot 0 member start: got %d, want %d", loc1.start, want)
    }

    at2 := strings.index(src, "second.dx") + len("second.")
    loc2, ok2 := resolve_offset(e, src, at2)
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected second.dx to resolve through slot 1's U")
    if ok2 {
        want := strings.index(src, "dx: int")
        testing.expectf(t, loc2.start == want, "slot 1 member start: got %d, want %d", loc2.start, want)
    }
}

@(test)
test_member_polymorphic_result_explicit_form :: proc(t: ^testing.T) {
    // `identity2 :: proc($T: typeid, v: T) -> T`: the explicit binding form.
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

identity2 :: proc($T: typeid, v: T) -> T {
	return v
}

main :: proc() {
	p := Point{}
	_ = identity2(p).x
}
`
    at := strings.index(src, "identity2(p).x") + len("identity2(p).")
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected identity2(p).x to resolve through the explicit $T: typeid form")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "member start: got %d, want %d", loc.start, want)
    }
}
