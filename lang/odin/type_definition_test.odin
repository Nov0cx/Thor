package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

// Runs a Type_Definition request at the first occurrence of `needle` in `source`, plus `skip` bytes.
@(private = "file")
type_definition_at :: proc(e: ^Engine, source, needle: string, workspace := "", path := "buffer.odin", skip := 0) -> lang.Result {
    req := lang.Request {
        kind      = .Type_Definition,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = strings.index(source, needle) + skip,
        workspace = workspace,
    }
    res := lang.Result{kind = .Type_Definition}
    resolve(e, &req, &res)
    return res
}

@(private = "file")
free_type_definition :: proc(res: ^lang.Result) {
    for sym in res.symbols {
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
        delete(sym.path)
    }
    delete(res.symbols)
    delete(res.location.path)
    res^ = {}
}

// Expects one jump to `want` in a file whose path ends in `file`.
@(private = "file")
expect_type_jump :: proc(t: ^testing.T, res: ^lang.Result, file: string, want: int, loc := #caller_location) {
    testing.expect(t, res.ok, "expected a type definition", loc = loc)
    testing.expectf(t, len(res.symbols) == 0, "expected a jump, got %d candidates", len(res.symbols), loc = loc)
    testing.expectf(t, strings.has_suffix(res.location.path, file), "path: got %q, want *%s", res.location.path, file, loc = loc)
    testing.expectf(t, res.location.start == want, "start: got %d, want %d", res.location.start, want, loc = loc)
}

@(private = "file")
TYPES_SRC :: `package app

Vec2 :: struct {
	x, y: f32,
}

Player :: struct {
	pos: Vec2,
}

Handle :: distinct u32

Key :: enum {
	A,
}

make_player :: proc() -> Player {
	return {}
}

current: Player

main :: proc() {
	p := Player{}
	ptr: ^Player = &p
	list: []Player
	h: Handle
	table: map[Key]Vec2
	_ = p.pos
	_ = make_player()
	_ = ptr
	_ = list
	_ = h
	_ = table
}
`

@(test)
test_type_definition_local :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    player := strings.index(TYPES_SRC, "Player ::")
    res := type_definition_at(e, TYPES_SRC, "p := ")
    expect_type_jump(t, &res, "buffer.odin", player)
    free_type_definition(&res)

    res = type_definition_at(e, TYPES_SRC, "_ = p.pos", skip = 4)
    expect_type_jump(t, &res, "buffer.odin", player)
    free_type_definition(&res)
}

// Pointers and slices are walked to their element type.
@(test)
test_type_definition_through_constructors :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    player := strings.index(TYPES_SRC, "Player ::")
    res := type_definition_at(e, TYPES_SRC, "_ = ptr", skip = 4)
    expect_type_jump(t, &res, "buffer.odin", player)
    free_type_definition(&res)

    res = type_definition_at(e, TYPES_SRC, "_ = list", skip = 4)
    expect_type_jump(t, &res, "buffer.odin", player)
    free_type_definition(&res)
}

@(test)
test_type_definition_field_and_call :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := type_definition_at(e, TYPES_SRC, "p.pos", skip = 2)
    expect_type_jump(t, &res, "buffer.odin", strings.index(TYPES_SRC, "Vec2 ::"))
    free_type_definition(&res)

    player := strings.index(TYPES_SRC, "Player ::")
    res = type_definition_at(e, TYPES_SRC, "make_player()", skip = 11)
    expect_type_jump(t, &res, "buffer.odin", player)
    free_type_definition(&res)

    res = type_definition_at(e, TYPES_SRC, "_ = make_player", skip = 4)
    expect_type_jump(t, &res, "buffer.odin", player)
    free_type_definition(&res)
}

// The declaration name of a global, and a type name, answer from the declaration.
@(test)
test_type_definition_declarations :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    player := strings.index(TYPES_SRC, "Player ::")
    res := type_definition_at(e, TYPES_SRC, "current:")
    expect_type_jump(t, &res, "buffer.odin", player)
    free_type_definition(&res)

    res = type_definition_at(e, TYPES_SRC, "Player{}")
    expect_type_jump(t, &res, "buffer.odin", player)
    free_type_definition(&res)

    res = type_definition_at(e, TYPES_SRC, "_ = h", skip = 4)
    expect_type_jump(t, &res, "buffer.odin", strings.index(TYPES_SRC, "Handle ::"))
    free_type_definition(&res)
}

// A map gives its key and its value type.
@(test)
test_type_definition_map_candidates :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := type_definition_at(e, TYPES_SRC, "_ = table", skip = 4)
    defer free_type_definition(&res)
    testing.expect(t, res.ok, "expected a type definition")
    testing.expectf(t, len(res.symbols) == 2, "expected 2 candidates, got %d", len(res.symbols))
    if len(res.symbols) != 2 {
        return
    }
    testing.expect_value(t, res.symbols[0].name, "Key")
    testing.expect_value(t, res.symbols[0].offset, strings.index(TYPES_SRC, "Key ::"))
    testing.expect_value(t, res.symbols[1].name, "Vec2")
    testing.expect_value(t, res.symbols[1].offset, strings.index(TYPES_SRC, "Vec2 ::"))
}

@(test)
test_type_definition_cross_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    lib_src := "package lib\n\nThing :: struct {\n\tn: int,\n}\n\ncreate :: proc() -> ^Thing {\n\treturn nil\n}\n"
    root := fixture(t, "typedef_package", {{"lib/thing.odin", lib_src}})
    defer os.remove_all(root)

    main_src := "package app\n\nimport \"../lib\"\n\nmain :: proc() {\n\tx := lib.create()\n\t_ = x\n}\n"
    res := type_definition_at(e, main_src, "_ = x", root, fixture_path(root, "app/main.odin"), skip = 4)
    expect_type_jump(t, &res, "thing.odin", strings.index(lib_src, "Thing ::"))
    free_type_definition(&res)
}

// A basic type answers from base:builtin.
@(test)
test_type_definition_builtin :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    if odin_root(&e.root) == "" {
        testing.fail_now(t, "no Odin root: ODIN_ROOT, `odin root` and the build root all failed")
    }
    src := "package app\n\nmain :: proc() {\n\tx: int\n\t_ = x\n}\n"
    res := type_definition_at(e, src, "_ = x", skip = 4)
    defer free_type_definition(&res)
    testing.expect(t, res.ok, "expected int to resolve")
    testing.expectf(t, len(res.symbols) == 0, "expected a jump, got %d candidates", len(res.symbols))
    testing.expectf(t, strings.has_suffix(res.location.path, "builtin.odin"), "path: got %q", res.location.path)
}

@(test)
test_type_definition_nothing :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    res := type_definition_at(e, TYPES_SRC, "\n\nmain", skip = 1)
    testing.expect(t, !res.ok, "blank space must not resolve")
    free_type_definition(&res)

    res = type_definition_at(e, TYPES_SRC, "return {}")
    testing.expect(t, !res.ok, "a keyword must not resolve")
    free_type_definition(&res)

    testing.expect(t, supports(e, ".odin", .Type_Definition))
}
