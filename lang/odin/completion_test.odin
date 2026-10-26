package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

// Runs a Completion request with the caret after the first `needle` in `source`, or at its `|`.
@(private = "file")
complete_at :: proc(e: ^Engine, source, needle: string, workspace := "", path := "buffer.odin") -> lang.Result {
    bar := strings.index_byte(needle, '|')
    search := needle
    if bar >= 0 {
        search = strings.concatenate({needle[:bar], needle[bar + 1:]}, context.temp_allocator)
    } else {
        bar = len(needle)
    }
    at := strings.index(source, search)
    assert(at >= 0, needle)
    req := lang.Request {
        kind      = .Completion,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = at + bar,
        workspace = workspace,
    }
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    return res
}

@(private = "file")
completions_free :: proc(res: ^lang.Result) {
    for item in res.completions {
        delete(item.label)
        delete(item.kind)
        delete(item.detail)
        delete(item.insert)
        delete(item.filter)
        delete(item.sort)
    }
    delete(res.completions)
}

// The candidate labelled `label`; nil when there is none.
@(private = "file")
find_item :: proc(res: ^lang.Result, label: string) -> ^lang.Completion_Item {
    for &item in res.completions {
        if item.label == label {
            return &item
        }
    }
    return nil
}

@(private = "file")
has_label :: proc(res: ^lang.Result, label: string) -> bool {
    return find_item(res, label) != nil
}

// The position of `label` in the list; -1 when it is not there.
@(private = "file")
label_index :: proc(res: ^lang.Result, label: string) -> int {
    for item, i in res.completions {
        if item.label == label {
            return i
        }
    }
    return -1
}

// Expects the candidates `want` and none of `unwanted`.
@(private = "file")
expect_labels :: proc(t: ^testing.T, res: ^lang.Result, want: []string, unwanted: []string = nil, loc := #caller_location) {
    for w in want {
        testing.expectf(t, has_label(res, w), "missing %q", w, loc = loc)
    }
    for u in unwanted {
        testing.expectf(t, !has_label(res, u), "unexpected %q", u, loc = loc)
    }
}

@(private = "file")
expect_item :: proc(t: ^testing.T, res: ^lang.Result, label, kind, detail: string, loc := #caller_location) {
    item := find_item(res, label)
    if !testing.expectf(t, item != nil, "missing %q", label, loc = loc) {
        return
    }
    testing.expectf(t, item.kind == kind, "%q kind: got %q, want %q", label, item.kind, kind, loc = loc)
    testing.expectf(t, item.detail == detail, "%q detail: got %q, want %q", label, item.detail, detail, loc = loc)
    testing.expectf(t, item.start == -1 && item.end == -1, "%q: want no range", label, loc = loc)
}

@(private = "file")
MEMBER_SRC :: `package demo

Base :: struct {
	id: int,
}

Point :: struct {
	using base: Base,
	x, y: f32,
	label: string,
}

Color :: enum {
	Red,
	Green,
	Blue,
}

Colors :: bit_set[Color]

Shape :: union {
	Point,
	Color,
}

make_point :: proc() -> ^Point {
	return nil
}

main :: proc() {
	p: Point
	pp := &p
	_ = p.x
	_ = pp.la
	_ = make_point().y
	_ = Color.Gr
	c: Color
	cs: Colors = {.Red, .}
	s: Shape = .Bl
	if c == .R {}
	d: Color = .
}
`

// `x.` lists the fields of the operand, through `using` and a pointer.
@(test)
test_completion_members :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := complete_at(e, MEMBER_SRC, "_ = p.")
    expect_labels(t, &res, {"base", "x", "y", "label", "id"}, {"main", "Point", "int"})
    expect_item(t, &res, "x", "field", "f32")
    expect_item(t, &res, "id", "field", "int")
    testing.expect(t, label_index(&res, "x") < label_index(&res, "label"), "fields keep declaration order")
    testing.expect(t, label_index(&res, "label") < label_index(&res, "id"), "promoted fields follow the direct ones")
    completions_free(&res)

    res = complete_at(e, MEMBER_SRC, "_ = pp.la")
    expect_labels(t, &res, {"label"}, {"x", "base"})
    completions_free(&res)

    res = complete_at(e, MEMBER_SRC, "make_point().")
    expect_labels(t, &res, {"x", "y", "label"})
    completions_free(&res)

    // `p.` with nothing after it, at the end of a body.
    tail := "package demo\n\nP :: struct {\n\tx: int,\n}\n\nmain :: proc() {\n\tp: P\n\tp.\n}\n"
    res = complete_at(e, tail, "\tp.")
    expect_labels(t, &res, {"x"})
    completions_free(&res)

    // `p.` with a statement on the next line.
    next := "package demo\n\nP :: struct {\n\tx: int,\n}\n\nmain :: proc() {\n\tp: P\n\tp.\n\ty := 1\n\t_ = y\n}\n"
    res = complete_at(e, next, "\tp.")
    expect_labels(t, &res, {"x"}, {"y"})
    completions_free(&res)
}

// An enum type before the dot, and an implicit selector, list the enum members.
@(test)
test_completion_enum :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := complete_at(e, MEMBER_SRC, "Color.Gr")
    expect_labels(t, &res, {"Green"}, {"Red", "Blue"})
    expect_item(t, &res, "Green", "enum_member", "Color")
    completions_free(&res)

    res = complete_at(e, MEMBER_SRC, "d: Color = .")
    expect_labels(t, &res, {"Red", "Green", "Blue"}, {"x", "main"})
    testing.expect(t, label_index(&res, "Red") < label_index(&res, "Green"), "members keep declaration order")
    completions_free(&res)

    res = complete_at(e, MEMBER_SRC, "{.Red, .")
    expect_labels(t, &res, {"Red", "Green", "Blue"})
    completions_free(&res)

    res = complete_at(e, MEMBER_SRC, "s: Shape = .Bl")
    expect_labels(t, &res, {"Blue"}, {"Red"})
    completions_free(&res)

    res = complete_at(e, MEMBER_SRC, "c == .R")
    expect_labels(t, &res, {"Red"}, {"Green"})
    completions_free(&res)
}

// More places an implicit selector takes its enum from: an argument, a field value, a return and a case.
@(test)
test_completion_implicit_places :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Axis :: enum { Horizontal, Vertical }
Speed :: enum { Fast, Slow }

Layout :: struct {
	axis: Axis,
}

f :: proc(s: Speed, a: Axis) {}

pick :: proc() -> (int, Axis) {
	return 0, .
}

main :: proc(a: Axis) {
	f(.Fast, .)
	l := Layout{axis = .}
	switch a {
	case .:
	}
	b: Axis = .
	_ = l
}
`
    for needle in ([]string{"f(.Fast, .", "axis = .", "return 0, .", "case .", "b: Axis = ."}) {
        res := complete_at(e, src, needle)
        testing.expectf(t, has_label(&res, "Horizontal") && has_label(&res, "Vertical"), "%q: missing the Axis members", needle)
        testing.expectf(t, !has_label(&res, "Fast"), "%q: Fast belongs to another enum", needle)
        completions_free(&res)
    }
}

// A bare prefix lists locals in reach, package names, imports, keywords and builtins.
@(test)
test_completion_bare :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

import "core:fmt"
import str "core:strings"

counter :: 100

count_items :: proc() -> int {
	return 0
}

other :: proc() {
	count_other := 1
	_ = count_other
}

main :: proc(count_param: int) {
	count_local: int = 2
	_ = coun
	count_later := 3
	_ = st
	_ = cont
	_ = le
	_ = coun + count_later + count_local
}
`
    res := complete_at(e, src, "_ = coun|\n")
    expect_labels(t, &res, {"counter", "count_items", "count_local", "count_param"}, {"count_other", "count_later", "coun", "main"})
    expect_item(t, &res, "count_items", "function", "count_items :: proc() -> int")
    expect_item(t, &res, "counter", "constant", "counter :: 100")
    expect_item(t, &res, "count_local", "var", "int")
    testing.expect(t, label_index(&res, "count_local") < label_index(&res, "counter"), "locals come before package names")
    completions_free(&res)

    res = complete_at(e, src, "_ = st|\n")
    expect_labels(t, &res, {"str", "string"}, {"fmt"})
    expect_item(t, &res, "str", "namespace", "import str \"core:strings\"")
    expect_item(t, &res, "string", "keyword", "")
    completions_free(&res)

    res = complete_at(e, src, "_ = cont")
    expect_labels(t, &res, {"context", "continue"})
    completions_free(&res)

    if odin_root(&e.root) != "" {
        res = complete_at(e, src, "_ = le|\n")
        expect_labels(t, &res, {"len"})
        testing.expect(t, find_item(&res, "len") != nil && find_item(&res, "len").kind == "function", "len is a procedure")
        completions_free(&res)
    }
}

// A name whose type is the expected one comes first and is preselected.
@(test)
test_completion_expected_rank :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

value_count: int
value_name: string

main :: proc() {
	value_flag := true
	value_text := "a"
	s: string = value
	_ = value_flag
	_ = value_text
	_ = s
}
`
    res := complete_at(e, src, "s: string = value")
    defer completions_free(&res)
    expect_labels(t, &res, {"value_count", "value_name", "value_flag", "value_text"})
    if len(res.completions) < 4 {
        return
    }
    first, second := res.completions[0].label, res.completions[1].label
    testing.expectf(t, first == "value_name" && second == "value_text", "the string names rank first: got %q, %q", first, second)
    testing.expect(t, res.completions[0].preselect, "the first expected match is preselected")
    testing.expect(t, label_index(&res, "value_name") < label_index(&res, "value_count"), "a typed package value ranks above another type")
    testing.expect(t, !find_item(&res, "value_flag").preselect, "only one row is preselected")
}

// A `using` local brings its fields into scope.
@(test)
test_completion_using :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Entity :: struct {
	health: int,
	height: f32,
}

update :: proc(using ent: ^Entity) {
	_ = he
}

tick :: proc(ent: Entity) {
	using ent
	_ = hei
}
`
    res := complete_at(e, src, "_ = he")
    expect_labels(t, &res, {"health", "height"})
    expect_item(t, &res, "height", "field", "f32")
    completions_free(&res)

    res = complete_at(e, src, "_ = hei")
    expect_labels(t, &res, {"height"}, {"health"})
    completions_free(&res)
}

// A struct literal offers the fields it does not set yet.
@(test)
test_completion_comp_lit_fields :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Rect :: struct {
	width, height: int,
	wrap: bool,
}

main :: proc() {
	a := Rect{width = 1, w}
	b: Rect = {h}
	_ = a
	_ = b
}
`
    res := complete_at(e, src, "width = 1, w")
    expect_labels(t, &res, {"wrap"}, {"width"})
    if item := find_item(&res, "wrap"); item != nil {
        testing.expect_value(t, item.insert, "wrap = ")
        testing.expect_value(t, item.kind, "field")
    }
    completions_free(&res)

    res = complete_at(e, src, "{h")
    expect_labels(t, &res, {"height"})
    completions_free(&res)
}

// Nothing in a comment, a string or a number.
@(test)
test_completion_inside_literals :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nvalue :: 1\n\nmain :: proc() {\n\t// val\n\t/* val */\n\ts := \"val\n\tn := 1.\n\tm := 12\n}\n"
    for needle in ([]string{"// val", "/* val", "\"val", "1.", "12"}) {
        res := complete_at(e, src, needle)
        testing.expectf(t, !res.ok && len(res.completions) == 0, "%q: want no candidates, got %d", needle, len(res.completions))
        completions_free(&res)
    }
}

// `pkg.` lists the public declarations of the imported package; a bare prefix lists sibling files.
@(test)
test_completion_packages :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    lib_src := "package lib\n\nscale :: proc(v: int, by: int) -> int {\n\treturn v * by\n}\n\nshift :: 3\n\n@(private)\nscale_hidden :: 1\n"
    sib_src := "package app\n\nsib_value :: 7\n\n@(private = \"file\")\nsib_hidden :: 8\n"
    far_src := "package other\n\nsib_far :: 1\n"
    root := fixture(t, "completion_packages", {{"lib/lib.odin", lib_src}, {"app/sibling.odin", sib_src}, {"other/far.odin", far_src}})
    defer os.remove_all(root)
    main_src := "package app\n\nimport \"../lib\"\n\nmain :: proc() {\n\t_ = lib.sc\n\t_ = lib.\n\t_ = sib\n}\n"
    main_path := fixture_path(root, "app/main.odin")

    res := complete_at(e, main_src, "lib.sc", workspace = root, path = main_path)
    expect_labels(t, &res, {"scale"}, {"shift", "scale_hidden"})
    expect_item(t, &res, "scale", "function", "scale :: proc(v: int, by: int) -> int")
    completions_free(&res)

    res = complete_at(e, main_src, "_ = lib.", workspace = root, path = main_path)
    expect_labels(t, &res, {"scale", "shift"}, {"scale_hidden", "main"})
    completions_free(&res)

    res = complete_at(e, main_src, "_ = sib", workspace = root, path = main_path)
    expect_labels(t, &res, {"sib_value"}, {"sib_hidden", "sib_far"})
    completions_free(&res)
}

// The workspace config turns completion off.
@(test)
test_completion_disabled :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nvalue :: 3\n\nmain :: proc() {\n\t_ = val\n}\n"
    root := fixture(t, "completion_disabled", {{".thor/odin-analyzer.json", `{"enable_completion": false}`}})
    defer os.remove_all(root)
    res := complete_at(e, src, "_ = val", workspace = root, path = fixture_path(root, "main.odin"))
    defer completions_free(&res)
    testing.expect(t, !res.ok && len(res.completions) == 0, "a disabled completion must answer nothing")
}

// `x.(` lists the variants of the union the operand is.
@(test)
test_completion_union_variants :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nPoint :: struct {\n\tx: int,\n}\n\nShape :: union {\n\tPoint,\n\tint,\n\t^Point,\n}\n\nmain :: proc() {\n\ts: Shape\n\t_ = s.(\n}\n"
    res := complete_at(e, src, "s.(")
    expect_labels(t, &res, {"Point", "int", "^Point"}, {"x", "main"})
    expect_item(t, &res, "Point", "type", "Shape")
    testing.expect(t, label_index(&res, "Point") < label_index(&res, "int"), "variants keep declaration order")
    completions_free(&res)

    typed := "package demo\n\nPoint :: struct {\n\tx: int,\n}\n\nShape :: union {\n\tPoint,\n\tint,\n}\n\nmain :: proc() {\n\ts: Shape\n\tp := s.(Po\n\ty := 1\n}\n"
    res = complete_at(e, typed, "s.(Po")
    expect_labels(t, &res, {"Point"}, {"int"})
    completions_free(&res)
}

// `x->` lists only the procedure members.
@(test)
test_completion_arrow :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nObj :: struct {\n\tadd:   proc(self: ^Obj, n: int) -> int,\n\tclear: proc(self: ^Obj),\n\tcount: int,\n}\n\nmain :: proc() {\n\to: ^Obj\n\to->\n}\n"
    res := complete_at(e, src, "o->")
    defer completions_free(&res)
    expect_labels(t, &res, {"add", "clear"}, {"count", "main"})
}
