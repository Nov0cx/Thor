package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

// Runs a Hover request at the first occurrence of `needle` in `source`, plus `skip` bytes.
@(private = "file")
hover_at :: proc(e: ^Engine, source, needle: string, skip := 0, workspace := "", path := "buffer.odin") -> lang.Result {
    req := lang.Request {
        kind      = .Hover,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = strings.index(source, needle) + skip,
        workspace = workspace,
    }
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    return res
}

// Expects the hover text `want` over the range of `name`, found at the first `needle` plus `skip`.
@(private = "file")
expect_hover :: proc(t: ^testing.T, e: ^Engine, src, needle, want: string, skip := 0, name := "", loc := #caller_location) {
    res := hover_at(e, src, needle, skip)
    defer delete(res.hover.text)
    if !testing.expectf(t, res.ok, "%q: expected a hover", needle, loc = loc) {
        return
    }
    testing.expectf(t, res.hover.text == want, "%q: got %q, want %q", needle, res.hover.text, want, loc = loc)
    if name != "" {
        start := strings.index(src, needle) + skip
        testing.expectf(t, res.hover.start == start && res.hover.end == start + len(name),
            "%q: range got [%d, %d), want [%d, %d)", needle, res.hover.start, res.hover.end, start, start + len(name), loc = loc)
    }
}

@(private = "file")
expect_no_hover :: proc(t: ^testing.T, e: ^Engine, src, needle: string, skip := 0, loc := #caller_location) {
    res := hover_at(e, src, needle, skip)
    defer delete(res.hover.text)
    testing.expectf(t, !res.ok, "%q+%d: want no hover, got %q", needle, skip, res.hover.text, loc = loc)
}

@(private = "file")
HOVER_SRC :: `package demo

// Scales v by a factor.
// The factor may be negative.
scale :: proc(v: int, by: int) -> int {
	return v * by
}

@(private)
Point :: struct {
	x, y: int,
	label: string,
}

Shape :: union {
	Point,
	int,
}

Color :: enum {
	Red,
	Green = 5,
	Blue,
}

N :: 3
M :: N * 2
counter: int

main :: proc() {
	total := scale(N, 2) // a call
	p: Point
	_ = p.label
	c: Color = .Green
	_ = Color.Blue
	_ = total + 1
	_ = M
	counter = 1
}
`

// A local variable, a parameter and a procedure show their type or signature.
@(test)
test_hover_names :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    expect_hover(t, e, HOVER_SRC, "total + 1", "total: int", name = "total")
    expect_hover(t, e, HOVER_SRC, "by\n", "by: int", name = "by")
    expect_hover(t, e, HOVER_SRC, "v * by", "v: int", name = "v")
    expect_hover(t, e, HOVER_SRC, "scale(N", "scale :: proc(v: int, by: int) -> int\n\nScales v by a factor.\nThe factor may be negative.", name = "scale")
    expect_hover(t, e, HOVER_SRC, "counter = 1", "counter: int", name = "counter")
    expect_hover(t, e, HOVER_SRC, "p: Point", "p: Point", name = "p")
}

// A type declaration lists its fields, members or variants, with its attributes first.
@(test)
test_hover_types :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    expect_hover(t, e, HOVER_SRC, "Point :: struct", "@(private)\nPoint :: struct {\n    x, y: int,\n    label: string,\n}\n// size 32, align 8", name = "Point")
    expect_hover(t, e, HOVER_SRC, "Shape ::", "Shape :: union {\n    Point,\n    int,\n}\n// size 40, align 8", name = "Shape")
    expect_hover(t, e, HOVER_SRC, "Color ::", "Color :: enum {\n    Red,\n    Green = 5,\n    Blue,\n}\n// size 8, align 8", name = "Color")
}

// A field through a selector, and enum members implicit and qualified, name their owner.
@(test)
test_hover_members :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    expect_hover(t, e, HOVER_SRC, "p.label", "Point.label: string // offset 16, size 16", skip = 2, name = "label")
    expect_hover(t, e, HOVER_SRC, ".Green\n", "Color.Green = 5", skip = 1, name = "Green")
    expect_hover(t, e, HOVER_SRC, "Color.Blue", "Color.Blue = 6", skip = len("Color."), name = "Blue")
    expect_hover(t, e, HOVER_SRC, "\tRed,", "Color.Red = 0", skip = 1, name = "Red")
    expect_hover(t, e, HOVER_SRC, "x, y: int", "Point.x: int // offset 0, size 8", name = "x")
}

// A constant shows its declaration, and its value when the declaration does not spell it.
@(test)
test_hover_constants :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    expect_hover(t, e, HOVER_SRC, "N, 2)", "N :: 3", name = "N")
    expect_hover(t, e, HOVER_SRC, "M\n\tcounter", "M :: N * 2 // = 6", name = "M")
}

// Off a name, the hover gives the type of the expression under the caret; on trivia and statement keywords, nothing.
@(test)
test_hover_expressions :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    expect_hover(t, e, HOVER_SRC, "+ 1", "int")
    expect_hover(t, e, HOVER_SRC, ", 2) //", "int", skip = len(", 2")) // the `)` of the call
    expect_hover(t, e, HOVER_SRC, "1\n\t_ = M", "untyped int = 1")
    expect_no_hover(t, e, HOVER_SRC, "a call")
    expect_no_hover(t, e, HOVER_SRC, "+ 1", skip = 1)
    expect_no_hover(t, e, HOVER_SRC, "return")
    expect_no_hover(t, e, HOVER_SRC, "\n\nmain ::", skip = 1)
}

// An import alias shows its import; a procedure of another package shows its declaration there.
@(test)
test_hover_packages :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    lib_src := "package lib\n\n// Adds two numbers.\nadd :: proc(a, b: int) -> int {\n\treturn a + b\n}\n"
    root := fixture(t, "hover_packages", {{"lib/lib.odin", lib_src}})
    defer os.remove_all(root)
    main_src := "package app\n\nimport mylib \"lib\"\n\nmain :: proc() {\n\t_ = mylib.add(1, 2)\n}\n"
    main_path := fixture_path(root, "main.odin")

    res := hover_at(e, main_src, "mylib.add", workspace = root, path = main_path)
    testing.expect(t, res.ok, "expected a hover on the alias")
    testing.expect_value(t, res.hover.text, "import mylib \"lib\"")
    delete(res.hover.text)

    res = hover_at(e, main_src, "add(1", workspace = root, path = main_path)
    testing.expect(t, res.ok, "expected a hover on the package procedure")
    testing.expect_value(t, res.hover.text, "add :: proc(a, b: int) -> int\n\nAdds two numbers.")
    delete(res.hover.text)

    res = hover_at(e, main_src, "\"lib\"", skip = 1, workspace = root, path = main_path)
    testing.expect(t, res.ok, "expected a hover on the import path")
    testing.expect_value(t, res.hover.text, "import mylib \"lib\"")
    delete(res.hover.text)
}

// A builtin procedure, a basic type and `context` come from the universe.
@(test)
test_hover_universe :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    if odin_root(&e.root) == "" {
        testing.fail_now(t, "no Odin root: ODIN_ROOT, `odin root` and the build root all failed")
    }
    src := "package app\n\ncount :: proc(xs: []int) -> int {\n\tc := context\n\t_ = c\n\treturn len(xs)\n}\n"
    res := hover_at(e, src, "len(")
    testing.expect(t, res.ok, "expected a hover on len")
    testing.expectf(t, strings.has_prefix(res.hover.text, "len :: proc(array: Array_Type) -> int"), "len: got %q", res.hover.text)
    delete(res.hover.text)
    expect_hover(t, e, src, "int {", "int: builtin type, 8 bytes" if size_of(int) == 8 else "int: builtin type, 4 bytes", name = "int")
    expect_hover(t, e, src, "context", "context: runtime.Context")
    expect_hover(t, e, src, "c := ", "c: runtime.Context", name = "c")
}

// The workspace config turns hover off.
@(test)
test_hover_disabled :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nN :: 3\n"
    root := fixture(t, "hover_disabled", {{".thor/odin-analyzer.lua", `return { enable_hover = false }`}})
    defer os.remove_all(root)
    res := hover_at(e, src, "N ::", workspace = root, path = fixture_path(root, "main.odin"))
    defer delete(res.hover.text)
    testing.expect(t, !res.ok, "a disabled hover must answer nothing")
}

// A big struct lists its first fields only; a type and a procedure declared in a body print from the checker.
@(test)
test_hover_big_and_local :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    sb := strings.builder_make(context.temp_allocator)
    strings.write_string(&sb, "package demo\n\nBig :: struct {\n")
    want := strings.builder_make(context.temp_allocator)
    strings.write_string(&want, "Big :: struct {\n")
    for i in 0 ..< 20 {
        line := strings.concatenate({"f", i < 10 ? "0" : "1", string([]u8{'0' + u8(i % 10)}), ": int"}, context.temp_allocator)
        strings.write_string(&sb, "\t")
        strings.write_string(&sb, line)
        strings.write_string(&sb, ",\n")
        if i < 16 {
            strings.write_string(&want, "    ")
            strings.write_string(&want, line)
            strings.write_string(&want, ",\n")
        }
    }
    strings.write_string(&want, "    ...\n}\n// size 160, align 8")
    strings.write_string(&sb, "}\n\nmain :: proc() {\n\tLocal :: struct { a: int }\n\thelp :: proc(n: int) -> bool { return n > 0 }\n\tl: Local\n\t_ = help(l.a)\n}\n")
    src := strings.to_string(sb)

    expect_hover(t, e, src, "Big ::", strings.to_string(want), name = "Big")
    expect_hover(t, e, src, "Local\n", "Local :: struct {a: int}", name = "Local")
    expect_hover(t, e, src, "help(l", "help :: proc(n: int) -> bool", name = "help")
    expect_hover(t, e, src, "a)", "Local.a: int", name = "a")
}

// A field of a record declared in a body names its owner, and a `using` field keeps `using`.
@(test)
test_hover_body_fields_and_using :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Vec2 :: struct {
	x, y: f32,
}

Entity :: struct {
	using pos: Vec2,
	name: string,
}

main :: proc() {
	Body :: struct {
		using base: Vec2,
		count: int,
	}
	b: Body
	_ = b.count
	_ = b.base
	en: Entity
	_ = en.pos
}
`
    expect_hover(t, e, src, "count\n\t_ = b.base", "Body.count: int", name = "count")
    expect_hover(t, e, src, "count: int", "Body.count: int", name = "count")
    expect_hover(t, e, src, "base\n\ten", "using Body.base: Vec2", name = "base")
    expect_hover(t, e, src, "pos\n}", "using Entity.pos: Vec2 // offset 0, size 8", name = "pos")
    expect_hover(t, e, src, "Entity ::", "Entity :: struct {\n    using pos: Vec2,\n    name: string,\n}\n// size 24, align 8", name = "Entity")
}

// A `/* */` comment above a declaration is its doc.
@(test)
test_hover_block_doc :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\n/*\n\tThe answer.\n\tAlways.\n*/\nANSWER :: 42\n\nmain :: proc() {\n\t_ = ANSWER\n}\n"
    expect_hover(t, e, src, "ANSWER\n}", "ANSWER :: 42\n\nThe answer.\nAlways.", name = "ANSWER")
}

@(test)
test_hover_using_bare_name :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nBase :: struct {\n\tid: int,\n}\n\nEntity :: struct {\n\tusing base: Base,\n}\n\nmove :: proc(e: Entity) -> int {\n\tusing e\n\treturn id\n}\n"
    expect_hover(t, e, src, "id\n}", "Base.id: int // offset 0, size 8", name = "id")
}

// A type shows its size and alignment, a field its offset and size, also through a `using` field.
@(test)
test_hover_layout :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Vec :: struct {
	x, y: f32,
}

Body :: struct #packed {
	id: u8,
	using pos: Vec,
}

Flags :: bit_set[0..<12]
Id :: distinct u16
List :: struct($T: typeid) {
	items: []T,
}
Loop :: struct {
	next: Loop,
}

main :: proc() {
	b: Body
	_ = b.y
	pb := &b
	_ = pb.id
}
`
    expect_hover(t, e, src, "Body ::", "Body :: struct #packed {\n    id: u8,\n    using pos: Vec,\n}\n// size 9, align 1", name = "Body")
    expect_hover(t, e, src, "Flags ::", "Flags :: bit_set[0..<12]\n// size 2, align 2", name = "Flags")
    expect_hover(t, e, src, "Id ::", "Id :: distinct u16\n// size 2, align 2", name = "Id")
    expect_hover(t, e, src, "List ::", "List :: struct($T: typeid) {\n    items: []T,\n}", name = "List")
    expect_hover(t, e, src, "Loop ::", "Loop :: struct {\n    next: Loop,\n}", name = "Loop")
    expect_hover(t, e, src, "b.y", "Vec.y: f32 // offset 5 in Body, size 4", skip = 2, name = "y")
    expect_hover(t, e, src, "pb.id", "Body.id: u8 // offset 0, size 1", skip = 3, name = "id")
}
