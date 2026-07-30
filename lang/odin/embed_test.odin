// `using` embedding and container element access — the two ways a member
// resolves through something other than the struct named on the declaration.
package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_member_using_embedded :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `using base: Base` embeds Base's fields into Derived, so `d.x` resolves to
    // Base's field even though Derived never declares it.
    src := `package demo

Base :: struct {
	x: int,
}

Derived :: struct {
	using base: Base,
	y: int,
}

// Declares the same field names nearer the caret, so the flat name fallback
// would land here: a hit on the real struct proves the member path answered.
Decoy :: struct {
	x: int,
	y: int,
}

main :: proc() {
	d: Derived
	_ = d.x
	_ = d.y
}
`
    at := strings.index(src, "d.x") + 2 // caret on the embedded member
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected d.x to resolve through the embedded struct")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "embedded member start: got %d, want %d", loc.start, want)
    }

    // The outer struct's own field still wins over the embedding.
    own := strings.index(src, "d.y") + 2
    loc2, ok2 := resolve_offset(e, src, own)
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected d.y to resolve to Derived's own field")
    if ok2 {
        want := strings.index(src, "y: int")
        testing.expectf(t, loc2.start == want, "own member start: got %d, want %d", loc2.start, want)
    }
}

@(test)
test_member_using_embedded_chain :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Embedding is followed through more than one level, and a cycle between two
    // structs embedding each other must terminate rather than recurse forever.
    src := `package demo

Root :: struct {
	deep: int,
}

Middle :: struct {
	using root: Root,
}

Leaf :: struct {
	using middle: Middle,
}

Loop_A :: struct {
	using b: Loop_B,
}

Loop_B :: struct {
	using a: Loop_A,
}

Decoy :: struct {
	deep: int,
}

main :: proc() {
	l: Leaf
	_ = l.deep
	c: Loop_A
	_ = c.missing
}
`
    at := strings.index(src, "l.deep") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected l.deep to resolve two embeddings down")
    if ok {
        want := strings.index(src, "deep: int")
        testing.expectf(t, loc.start == want, "chained embed start: got %d, want %d", loc.start, want)
    }

    // The cyclic embedding is depth-capped: it answers nothing, but it returns.
    cyc := strings.index(src, "c.missing") + 2
    loc2, _ := resolve_offset(e, src, cyc)
    defer delete(loc2.path)
}

@(test)
test_member_using_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The embedded struct lives in a sibling file: the embedding is resolved the
    // same way any other type reference is (here through the workspace index).
    dir := "thor_lang_embed_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    base := strings.concatenate({dir, "/base.odin"}, context.temp_allocator)
    base_src := "package demo\n\nBase :: struct {\n\tshared_field: int,\n}\n"
    _ = os.write_entire_file(base, transmute([]byte)base_src)
    defer os.remove(base)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    // The decoy declares the same field name in the *requesting* file, so a hit in
    // base.odin proves the embedding was followed rather than the flat name scan.
    main_src := "package demo\n\nDerived :: struct {\n\tusing base: Base,\n}\n\nDecoy :: struct {\n\tshared_field: int,\n}\n\nmain :: proc() {\n\td: Derived\n\t_ = d.shared_field\n}\n"

    at := strings.index(main_src, "d.shared_field") + 2
    loc, ok := resolve_offset(e, main_src, at, dir, main_path)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the embedded cross-file struct's field to resolve")
    if ok {
        testing.expectf(t, strings.has_suffix(loc.path, "base.odin"), "path: got %q", loc.path)
        want := strings.index(base_src, "shared_field: int")
        testing.expectf(t, loc.start == want, "embedded member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_completion_using_embedded :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `d.` offers the embedded struct's fields alongside the outer one's.
    src := `package demo

Base :: struct {
	x: int,
}

Derived :: struct {
	using base: Base,
	y: int,
}

main :: proc() {
	d: Derived
	_ = d.
}
`
    at := strings.index(src, "_ = d.") + len("_ = d.")
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected member completions on the embedding struct")
    testing.expect(t, has_completion(&res, "y"), "missing the struct's own field y")
    testing.expect(t, has_completion(&res, "base"), "missing the embedded field itself")
    testing.expect(t, has_completion(&res, "x"), "missing the embedded struct's field x")
}

@(test)
test_member_container_index :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A container holds a type but is not that type: indexing one yields the
    // element, whose fields then resolve. `[N]T` and `[dynamic]T` index alike.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

Decoy :: struct {
	x: int,
	y: int,
}

main :: proc() {
	xs: []Point
	fixed: [4]Point
	grow: [dynamic]Point
	_ = xs[0].x
	_ = fixed[1].y
	_ = grow[2].x
	head := xs[0]
	_ = head.y
}
`
    Probe :: struct {
        needle: string,
        field:  string,
    }
    for probe in ([?]Probe{{"xs[0].x", "x: int"}, {"fixed[1].y", "y: int"}, {"grow[2].x", "x: int"}}) {
        at := strings.index(src, probe.needle) + len(probe.needle) - 1
        loc, ok := resolve_offset(e, src, at)
        defer delete(loc.path)
        testing.expectf(t, ok, "expected %s to resolve through the container's element", probe.needle)
        if ok {
            want := strings.index(src, probe.field)
            testing.expectf(t, loc.start == want, "%s: got %d, want %d", probe.needle, loc.start, want)
        }
    }

    // An element bound to a `:=` local carries the element type with it.
    at := strings.index(src, "head.y") + 5
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected an indexed element binding to keep its type")
    if ok {
        want := strings.index(src, "y: int")
        testing.expectf(t, loc.start == want, "element binding: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_map_value :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A map indexes to its *value* type.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

Decoy :: struct {
	y: int,
}

main :: proc() {
	table: map[string]Point
	_ = table["origin"].y
}
`
    needle := "table[\"origin\"]."
    at := strings.index(src, needle) + len(needle)
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected a map lookup to resolve to the value type's field")
    if ok {
        want := strings.index(src, "y: int")
        testing.expectf(t, loc.start == want, "map value member: got %d, want %d", loc.start, want)
    }
}

@(test)
test_member_range_variable :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `for p in xs` binds p to the element type; over a map the *second* variable
    // is the value. A loop variable is scoped to its own loop, so the two `p`
    // declarations here are separate bindings.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

Other :: struct {
	z: int,
}

Decoy :: struct {
	x: int,
	z: int,
}

main :: proc() {
	xs: []Point
	table: map[string]Other
	for p in xs {
		_ = p.x
	}
	for key, p in table {
		_ = p.z
	}
}
`
    at := strings.index(src, "p.x") + 2
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the range variable to take the element type")
    if ok {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc.start == want, "range member: got %d, want %d", loc.start, want)
    }

    at2 := strings.index(src, "p.z") + 2
    loc2, ok2 := resolve_offset(e, src, at2)
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected the map range's second variable to take the value type")
    if ok2 {
        want := strings.index(src, "z: int")
        testing.expectf(t, loc2.start == want, "map range member: got %d, want %d", loc2.start, want)
    }
}

@(test)
test_completion_container_is_not_its_element :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `xs.` must not offer Point's fields — a slice is not the struct it holds.
    // (Indexing it does; see test_member_container_index.)
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

main :: proc() {
	xs: []Point
	_ = xs.
}
`
    at := strings.index(src, "_ = xs.") + len("_ = xs.")
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, !has_completion(&res, "x"), "a container must not offer its element's fields")
    testing.expect(t, !has_completion(&res, "y"), "a container must not offer its element's fields")
}

@(test)
test_member_call_result_container :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A procedure returning a container: the result type is read out of the
    // signature text, container and all, so indexing the call resolves.
    src := `package demo

Point :: struct {
	x: int,
	y: int,
}

points :: proc() -> []Point {
	return nil
}

Decoy :: struct {
	x: int,
	y: int,
}

main :: proc() {
	all := points()
	_ = all[0].y
	for p in all {
		_ = p.x
	}
}
`
    needle := "all[0]."
    at := strings.index(src, needle) + len(needle)
    loc, ok := resolve_offset(e, src, at)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the call's slice result to index to Point")
    if ok {
        want := strings.index(src, "y: int")
        testing.expectf(t, loc.start == want, "call container member: got %d, want %d", loc.start, want)
    }

    at2 := strings.index(src, "p.x") + 2
    loc2, ok2 := resolve_offset(e, src, at2)
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected ranging over the call's result to bind the element")
    if ok2 {
        want := strings.index(src, "x: int")
        testing.expectf(t, loc2.start == want, "range over call result: got %d, want %d", loc2.start, want)
    }
}

@(test)
test_member_result_qualified_by_callee :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The callee returns `pt.Point`, a package the *calling* file never imports.
    // The result type carries the callee's file, so the qualifier resolves against
    // that file's imports instead of the caller's.
    root := "thor_lang_origin_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    point_path := strings.concatenate({lib, "/point.odin"}, context.temp_allocator)
    point_src := "package lib\n\nPoint :: struct {\n\tx: int,\n\ty: int,\n}\n"
    _ = os.write_entire_file(point_path, transmute([]byte)point_src)

    api_path := strings.concatenate({root, "/api.odin"}, context.temp_allocator)
    api_src := "package demo\n\nimport pt \"lib\"\n\nmake_point :: proc() -> pt.Point {\n\treturn pt.Point{}\n}\n"
    _ = os.write_entire_file(api_path, transmute([]byte)api_src)

    defer {
        os.remove(point_path)
        os.remove(api_path)
        os.remove(lib)
        os.remove(root)
    }

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nDecoy :: struct {\n\ty: int,\n}\n\nmain :: proc() {\n\tp := make_point()\n\t_ = p.y\n}\n"

    at := strings.index(main_src, "p.y") + 2
    loc, ok := resolve_offset(e, main_src, at, root, main_path)
    defer delete(loc.path)
    testing.expect(t, ok, "expected a callee-qualified result type to resolve")
    if ok {
        testing.expectf(t, strings.has_suffix(loc.path, "point.odin"), "path: got %q", loc.path)
        want := strings.index(point_src, "y: int")
        testing.expectf(t, loc.start == want, "qualified result member: got %d, want %d", loc.start, want)
    }
}
