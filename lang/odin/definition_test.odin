package odin

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import lang ".."

// Runs a Definition request at `at` in `source`.
@(private = "file")
definition_offset :: proc(e: ^Engine, source: string, at: int, workspace := "", path := "buffer.odin") -> lang.Result {
    req := lang.Request {
        kind      = .Definition,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = at,
        workspace = workspace,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    return res
}

// Runs a Definition request at the first occurrence of `needle` in `source`, plus `skip` bytes.
@(private = "file")
definition_at :: proc(e: ^Engine, source, needle: string, workspace := "", path := "buffer.odin", skip := 0) -> lang.Result {
    return definition_offset(e, source, strings.index(source, needle) + skip, workspace, path)
}

@(private = "file")
free_definition :: proc(res: ^lang.Result) {
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
expect_jump :: proc(t: ^testing.T, res: ^lang.Result, file: string, want: int, loc := #caller_location) {
    testing.expect(t, res.ok, "expected a definition", loc = loc)
    testing.expectf(t, len(res.symbols) == 0, "expected a jump, got %d candidates", len(res.symbols), loc = loc)
    testing.expectf(t, strings.has_suffix(res.location.path, file), "path: got %q, want *%s", res.location.path, file, loc = loc)
    testing.expectf(t, res.location.start == want, "start: got %d, want %d", res.location.start, want, loc = loc)
}

// A fresh fixture directory under bin/test with `files` (paths relative to it) written.
@(private)
fixture :: proc(t: ^testing.T, name: string, files: [][2]string) -> string {
    root := strings.concatenate({"bin/test/", name}, context.temp_allocator)
    _ = os.remove_all(root)
    if err := os.make_directory_all(root); err != nil {
        testing.fail_now(t, "could not create the fixture directory")
    }
    for f in files {
        path := strings.concatenate({root, "/", f[0]}, context.temp_allocator)
        if err := os.make_directory_all(filepath.dir(path)); err != nil {
            testing.fail_now(t, "could not create a fixture directory")
        }
        if err := os.write_entire_file(path, transmute([]byte)f[1]); err != nil {
            testing.fail_now(t, "could not write a fixture file")
        }
    }
    return root
}

@(private)
fixture_path :: proc(root, rel: string) -> string {
    return strings.concatenate({root, "/", rel}, context.temp_allocator)
}

@(test)
test_definition_same_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

add :: proc(x: int, y: int) -> int {
	return x + y
}

main :: proc() {
	total := add(1, 2)
	_ = total
}
`
    res := definition_at(e, src, "add(1, 2)")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "add ::"))
    free_definition(&res)

    res = definition_at(e, src, "total\n")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "total :="))
    free_definition(&res)

    // A parameter use and the end of an identifier resolve too.
    res = definition_at(e, src, "x + y", skip = 1)
    expect_jump(t, &res, "buffer.odin", strings.index(src, "x: int"))
    free_definition(&res)

    // A declaration names itself.
    res = definition_at(e, src, "main ::")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "main ::"))
    free_definition(&res)
}

@(test)
test_definition_parameter_shadows_file_scope :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

value :: 100

use :: proc(value: int) -> int {
	return value * 2
}
`
    res := definition_at(e, src, "value * 2")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "value: int"))
    free_definition(&res)
}

@(test)
test_definition_use_before_short_declaration :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

limit :: 100

main :: proc() {
	_ = limit
	limit := 5
	_ = limit
}
`
    top := strings.index(src, "limit :: 100")
    decl := strings.index(src, "limit := 5")

    res := definition_at(e, src, "_ = limit", skip = len("_ = "))
    expect_jump(t, &res, "buffer.odin", top)
    free_definition(&res)

    res = definition_offset(e, src, strings.last_index(src, "_ = limit") + len("_ = "))
    expect_jump(t, &res, "buffer.odin", decl)
    free_definition(&res)

    res = definition_offset(e, src, decl)
    expect_jump(t, &res, "buffer.odin", decl)
    free_definition(&res)
}

@(test)
test_definition_typed_local_and_loop_variable_shadow :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

value :: 1
item :: 2

main :: proc(list: []int) {
	value: int = 3
	for item in list {
		_ = item
	}
	_ = value
}
`
    res := definition_at(e, src, "_ = value", skip = len("_ = "))
    expect_jump(t, &res, "buffer.odin", strings.index(src, "value: int"))
    free_definition(&res)

    res = definition_at(e, src, "_ = item", skip = len("_ = "))
    expect_jump(t, &res, "buffer.odin", strings.index(src, "item in list"))
    free_definition(&res)
}

@(test)
test_definition_initializer_clause_scope :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

ok :: true

main :: proc() {
	if v, ok := lookup(); ok {
		_ = v
	}
	_ = ok
}
`
    res := definition_at(e, src, "_ = v\n", skip = len("_ = "))
    expect_jump(t, &res, "buffer.odin", strings.index(src, "v, ok :="))
    free_definition(&res)

    res = definition_at(e, src, "_ = ok", skip = len("_ = "))
    expect_jump(t, &res, "buffer.odin", strings.index(src, "ok :: true"))
    free_definition(&res)
}

// A name declared in another file of the package; the cache reads a changed file again.
@(test)
test_definition_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    other_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n"
    root := fixture(t, "def_cross_file", {{"helper.odin", other_src}})
    defer os.remove_all(root)

    main_src := "package demo\n\nmain :: proc() {\n\t_ = helper()\n}\n"
    main_path := fixture_path(root, "main.odin")
    res := definition_at(e, main_src, "helper()", root, main_path)
    expect_jump(t, &res, "helper.odin", strings.index(other_src, "helper ::"))
    free_definition(&res)

    moved := "package demo\n\n// moved\nhelper :: proc() -> int {\n\treturn 42\n}\n"
    testing.expect_value(t, os.write_entire_file(fixture_path(root, "helper.odin"), transmute([]byte)moved), nil)
    res = definition_at(e, main_src, "helper()", root, main_path)
    expect_jump(t, &res, "helper.odin", strings.index(moved, "helper ::"))
    free_definition(&res)

    // The live buffer replaces its file on disk.
    testing.expect_value(t, os.write_entire_file(main_path, transmute([]byte)string("package demo\n\nhelper :: 1\n")), nil)
    res = definition_at(e, main_src, "helper()", root, main_path)
    expect_jump(t, &res, "helper.odin", strings.index(moved, "helper ::"))
    free_definition(&res)
}

// Two files of the package declare the name: both are candidates. Another directory never counts.
@(test)
test_definition_multiple_candidates :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    a_src := "package demo\n\nshared :: proc() -> int {\n\treturn 1\n}\n"
    b_src := "package demo\n\nshared :: proc() -> int {\n\treturn 2\n}\n"
    root := fixture(t, "def_multiple", {
        {"a.odin", a_src},
        {"b.odin", b_src},
        {"other/other.odin", "package other\n\nshared :: 3\nonly_other :: 4\n"},
    })
    defer os.remove_all(root)

    main_src := "package demo\n\nmain :: proc() {\n\t_ = shared()\n\t_ = only_other\n}\n"
    main_path := fixture_path(root, "main.odin")
    res := definition_at(e, main_src, "shared()", root, main_path)
    testing.expect(t, res.ok, "expected candidates for shared")
    testing.expectf(t, len(res.symbols) == 2, "candidate count: got %d, want 2", len(res.symbols))
    if len(res.symbols) == 2 {
        testing.expectf(t, strings.has_suffix(res.symbols[0].path, "a.odin"), "first: got %q", res.symbols[0].path)
        testing.expectf(t, strings.has_suffix(res.symbols[1].path, "b.odin"), "second: got %q", res.symbols[1].path)
        testing.expect_value(t, res.symbols[0].signature, "shared :: proc() -> int")
        testing.expect_value(t, res.symbols[0].line, 3)
        testing.expect_value(t, res.symbols[0].offset, strings.index(a_src, "shared ::"))
    }
    free_definition(&res)

    res = definition_at(e, main_src, "only_other", root, main_path)
    testing.expect(t, !res.ok, "a bare name must not reach another directory")
    free_definition(&res)
}

// A file-private declaration of another file is out of reach; a package-private one is not.
@(test)
test_definition_file_private_other_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := fixture(t, "def_private", {
        {"a.odin", "package demo\n\n@(private = \"file\")\nhidden :: 1\n@(private)\nshown :: 2\n"},
    })
    defer os.remove_all(root)

    main_src := "package demo\n\nmain :: proc() {\n\t_ = hidden\n\t_ = shown\n}\n"
    main_path := fixture_path(root, "main.odin")
    res := definition_at(e, main_src, "hidden\n", root, main_path)
    testing.expect(t, !res.ok, "a file-private name of another file must not resolve")
    free_definition(&res)

    res = definition_at(e, main_src, "shown\n", root, main_path)
    testing.expect(t, res.ok, "a package-private name must resolve in its package")
    free_definition(&res)
}

@(test)
test_definition_package_import :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    lib_src := "package lib\n\nthing :: proc() -> int {\n\treturn 7\n}\n\n@(private)\nsecret :: 1\n"
    root := fixture(t, "def_package_import", {{"lib/thing.odin", lib_src}})
    defer os.remove_all(root)

    main_src := "package app\n\nimport \"../lib\"\n\nmain :: proc() {\n\t_ = lib.thing()\n\t_ = lib.secret\n}\n"
    main_path := fixture_path(root, "app/main.odin")
    res := definition_at(e, main_src, "thing()", root, main_path)
    expect_jump(t, &res, "thing.odin", strings.index(lib_src, "thing ::"))
    free_definition(&res)

    res = definition_at(e, main_src, "secret", root, main_path)
    testing.expect(t, !res.ok, "a private name of another package must not resolve")
    free_definition(&res)
}

@(test)
test_definition_package_operand :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := fixture(t, "def_package_operand", {
        {"lib/lib.odin", "package lib\n"},
        {"lib/extra.odin", "package lib\n\nextra :: 1\n"},
    })
    defer os.remove_all(root)

    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.extra\n}\n"
    res := definition_at(e, main_src, "lib.extra", root, fixture_path(root, "main.odin"))
    expect_jump(t, &res, "lib.odin", 0)
    free_definition(&res)
}

@(test)
test_definition_package_no_entry_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := fixture(t, "def_package_no_entry", {{"lib/parts.odin", "package lib\n\nextra :: 1\n"}})
    defer os.remove_all(root)

    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.extra\n}\n"
    res := definition_at(e, main_src, "lib.extra", root, fixture_path(root, "main.odin"))
    expect_jump(t, &res, "parts.odin", 0)
    free_definition(&res)
}

@(test)
test_definition_package_fuzzy_fallback :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := fixture(t, "def_package_fuzzy", {
        {"lib/aardvark.odin", "package lib\n\naa :: 1\n"},
        {"lib/lib_windows.odin", "package lib\n\nbb :: 2\n"},
    })
    defer os.remove_all(root)

    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.bb\n}\n"
    res := definition_at(e, main_src, "lib.bb", root, fixture_path(root, "main.odin"))
    expect_jump(t, &res, "lib_windows.odin", 0)
    free_definition(&res)
}

@(test)
test_definition_on_import_line :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := fixture(t, "def_import_line", {{"lib/lib.odin", "package lib\n\nthing :: 1\n"}})
    defer os.remove_all(root)

    main_src := "package app\n\nimport lib \"lib\"\nimport \"missing\"\n\nmain :: proc() {\n\t_ = lib.thing\n}\n"
    main_path := fixture_path(root, "main.odin")
    res := definition_at(e, main_src, "\"lib\"", root, main_path, skip = 1)
    expect_jump(t, &res, "lib.odin", 0)
    free_definition(&res)

    res = definition_at(e, main_src, "lib \"lib\"", root, main_path)
    expect_jump(t, &res, "lib.odin", 0)
    free_definition(&res)

    res = definition_at(e, main_src, "\"missing\"", root, main_path, skip = 1)
    testing.expect(t, !res.ok, "an import of a missing directory must not resolve")
    free_definition(&res)
}

// `core:fmt` resolves under the Odin root.
@(test)
test_definition_stdlib :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    if odin_root(&e.root) == "" {
        testing.fail_now(t, "no Odin root: ODIN_ROOT, `odin root` and the build root all failed")
    }
    src := "package app\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(\"hi\")\n}\n"
    res := definition_at(e, src, "println")
    defer free_definition(&res)
    testing.expect(t, res.ok, "expected fmt.println to resolve into the standard library")
    testing.expectf(t, len(res.symbols) == 0, "expected one active println, got %d", len(res.symbols))
    source, ok := lang.source_read(res.location.path)
    testing.expectf(t, ok, "could not read %q", res.location.path)
    if ok && res.location.start < len(source) {
        testing.expectf(t, strings.has_prefix(source[res.location.start:], "println"), "landed on %q", source[res.location.start:][:min(20, len(source) - res.location.start)])
    }
    testing.expectf(t, strings.contains(res.location.path, "fmt"), "path: got %q", res.location.path)
}

// An ambiguous call of a procedure group offers its members.
@(test)
test_definition_overload_offers_members :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

sized_one :: proc(a: []int) -> int {
	return len(a)
}

sized_two :: proc(a: [dynamic]int) -> int {
	return len(a)
}

sizes :: proc{sized_one, sized_two}

main :: proc(xs: []int) {
	_ = sizes(nil)
}
`
    res := definition_at(e, src, "sizes(nil)")
    defer free_definition(&res)
    testing.expect(t, res.ok, "expected go-to-definition on a procedure group")
    testing.expectf(t, len(res.symbols) == 2, "expected one candidate per member: got %d", len(res.symbols))
    if len(res.symbols) == 2 {
        testing.expect_value(t, res.symbols[0].name, "sized_one")
        testing.expect_value(t, res.symbols[0].offset, strings.index(src, "sized_one ::"))
        testing.expect_value(t, res.symbols[0].path, "buffer.odin")
        testing.expect_value(t, res.symbols[1].signature, "sized_two :: proc(a: [dynamic]int) -> int")
        testing.expect_value(t, res.symbols[1].line, 7)
    }
}

// A call of a procedure group jumps to the member its arguments pick.
@(test)
test_definition_overload_picks_by_args :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

sized_one :: proc(a: []int) -> int {
	return len(a)
}

sized_two :: proc(a: [dynamic]int) -> int {
	return len(a)
}

sized_u8 :: proc(a: u8, b: u8) -> int {
	return 0
}

sized_i64 :: proc(a: i64, b: i64) -> int {
	return 0
}

sizes :: proc{sized_one, sized_two, sized_u8, sized_i64}

main :: proc(xs: []int, ds: [dynamic]int) {
	_ = sizes(xs)
	_ = sizes(ds)
	_ = sizes(300, 1)
	_ = sizes(3, 1)
}
`
    res := definition_at(e, src, "sizes(xs)")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "sized_one ::"))
    free_definition(&res)
    res = definition_at(e, src, "sizes(ds)")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "sized_two ::"))
    free_definition(&res)
    res = definition_at(e, src, "sizes(300")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "sized_i64 ::"))
    free_definition(&res)
    res = definition_at(e, src, "sizes(3,")
    testing.expect(t, res.ok, "expected the members of an ambiguous call")
    testing.expectf(t, len(res.symbols) == 4, "ambiguous call: got %d candidates, want 4", len(res.symbols))
    free_definition(&res)
}

@(test)
test_definition_overload_without_call_offers_members :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

sized_one :: proc(a: int) -> int {
	return a
}

sized_two :: proc(a: int, b: int) -> int {
	return a + b
}

sizes :: proc{sized_one, sized_two}
`
    res := definition_at(e, src, "sizes :: proc")
    defer free_definition(&res)
    testing.expect(t, res.ok, "expected go-to-definition on the group declaration")
    testing.expectf(t, len(res.symbols) == 2, "both members: got %d", len(res.symbols))
}

@(test)
test_definition_overload_single_member :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

sized_one :: proc(a: int) -> int {
	return a
}

sizes :: proc{sized_one}

main :: proc() {
	_ = sizes(1)
}
`
    res := definition_at(e, src, "sizes(1)")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "sized_one ::"))
    free_definition(&res)
}

// Members that do not resolve leave the group itself as the answer.
@(test)
test_definition_overload_falls_back_to_group :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

import "lib_that_is_not_there"

sizes :: proc{lib_that_is_not_there.sized_one, lib_that_is_not_there.sized_two}

main :: proc() {
	_ = sizes(1)
}
`
    res := definition_at(e, src, "sizes(1)")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "sizes :: proc"))
    free_definition(&res)
}

// A group of another package, reached as `pkg.group`, with members in two of its files and one
// qualified through an import of the group's file.
@(test)
test_definition_overload_package_qualified :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    one_src := "package lib\n\nsized_one :: proc(a: int) -> int {\n\treturn a\n}\n"
    three_src := "package extra\n\nsized_three :: proc(a: f32) -> int {\n\treturn 3\n}\n"
    root := fixture(t, "def_overload_pkg", {
        {"lib/one.odin", one_src},
        {"lib/two.odin", "package lib\n\nsized_two :: proc(a, b: int) -> int {\n\treturn a + b\n}\n"},
        {"lib/group.odin", "package lib\n\nimport \"../extra\"\n\nsizes :: proc{sized_one, sized_two, extra.sized_three}\n"},
        {"extra/extra.odin", three_src},
    })
    defer os.remove_all(root)

    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.sizes(missing)\n\t_ = lib.sizes(1)\n\t_ = lib.sizes(1, 2)\n\t_ = lib.sizes(1.5)\n}\n"
    main_path := fixture_path(root, "main.odin")
    picked := definition_at(e, main_src, "sizes(1)", root, main_path)
    expect_jump(t, &picked, "one.odin", strings.index(one_src, "sized_one ::"))
    free_definition(&picked)
    picked = definition_at(e, main_src, "sizes(1, 2)", root, main_path)
    expect_jump(t, &picked, "two.odin", strings.index("package lib\n\nsized_two", "sized_two"))
    free_definition(&picked)
    picked = definition_at(e, main_src, "sizes(1.5)", root, main_path)
    expect_jump(t, &picked, "extra.odin", strings.index(three_src, "sized_three ::"))
    free_definition(&picked)

    res := definition_at(e, main_src, "sizes(missing)", root, main_path)
    defer free_definition(&res)
    testing.expect(t, res.ok, "expected the members of lib.sizes")
    testing.expectf(t, len(res.symbols) == 3, "members: got %d, want 3", len(res.symbols))
    if len(res.symbols) == 3 {
        testing.expect_value(t, res.symbols[0].name, "sized_one")
        testing.expectf(t, strings.has_suffix(res.symbols[0].path, "one.odin"), "first: got %q", res.symbols[0].path)
        testing.expect_value(t, res.symbols[1].name, "sized_two")
        testing.expect_value(t, res.symbols[2].name, "sized_three")
        testing.expect_value(t, res.symbols[2].offset, strings.index(three_src, "sized_three ::"))
    }
}

// A declaration under a false `when` comes after the active ones, and answers only when no
// active one exists.
@(test)
test_definition_inactive_when_last :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    a_src := "package demo\n\nwhen ODIN_ARCH == .wasm32 {\n\tthing :: 1\n}\n"
    root := fixture(t, "def_inactive_when", {
        {"a.odin", a_src},
        {"b.odin", "package demo\n\nthing :: 2\n"},
        {"c.odin", "package demo\n\nthing :: 3\n"},
    })
    defer os.remove_all(root)

    main_src := "package demo\n\nmain :: proc() {\n\t_ = thing\n}\n"
    res := definition_at(e, main_src, "thing\n", root, fixture_path(root, "main.odin"))
    testing.expect(t, res.ok, "expected candidates for thing")
    testing.expectf(t, len(res.symbols) == 3, "candidates: got %d, want 3", len(res.symbols))
    if len(res.symbols) == 3 {
        testing.expectf(t, strings.has_suffix(res.symbols[0].path, "b.odin"), "first: got %q", res.symbols[0].path)
        testing.expectf(t, strings.has_suffix(res.symbols[1].path, "c.odin"), "second: got %q", res.symbols[1].path)
        testing.expectf(t, strings.has_suffix(res.symbols[2].path, "a.odin"), "inactive last: got %q", res.symbols[2].path)
    }
    free_definition(&res)

    src := `package demo

when ODIN_ARCH == .wasm32 {
	limit :: 1
	only :: 1
} else {
	limit :: 2
}

main :: proc() {
	_ = limit
	_ = only
}
`
    res = definition_at(e, src, "_ = limit", skip = len("_ = "))
    expect_jump(t, &res, "buffer.odin", strings.index(src, "limit :: 2"))
    free_definition(&res)

    res = definition_at(e, src, "_ = only", skip = len("_ = "))
    expect_jump(t, &res, "buffer.odin", strings.index(src, "only :: 1"))
    free_definition(&res)
}

// `Color.Red` lands on the member; a member or field declaration names itself.
@(test)
test_definition_enum_member :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Color :: enum {
	Red,
	Green = 2,
}

Point :: struct {
	x, y: int,
}

main :: proc() {
	c := Color.Green
	_ = c
	_ = Color.Blue
}
`
    res := definition_at(e, src, "Color.Green", skip = len("Color."))
    expect_jump(t, &res, "buffer.odin", strings.index(src, "Green = 2"))
    free_definition(&res)

    res = definition_at(e, src, "Color.Green")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "Color ::"))
    free_definition(&res)

    res = definition_at(e, src, "Green = 2")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "Green = 2"))
    free_definition(&res)

    res = definition_at(e, src, "y: int")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "y: int"))
    free_definition(&res)

    res = definition_at(e, src, "Color.Blue", skip = len("Color."))
    testing.expect(t, !res.ok, "an unknown member must not resolve")
    free_definition(&res)
}

// An enum of another file of the package.
@(test)
test_definition_enum_member_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    color_src := "package demo\n\nColor :: enum {\n\tRed,\n\tGreen,\n}\n"
    root := fixture(t, "def_enum_cross_file", {{"color.odin", color_src}})
    defer os.remove_all(root)

    main_src := "package demo\n\nmain :: proc() {\n\t_ = Color.Red\n}\n"
    res := definition_at(e, main_src, "Red", root, fixture_path(root, "main.odin"))
    expect_jump(t, &res, "color.odin", strings.index(color_src, "Red"))
    free_definition(&res)
}

// `pkg.Color.Red` lands on the member in the imported package.
@(test)
test_definition_package_enum_member :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    color_src := "package lib\n\nColor :: enum {\n\tRed,\n\tGreen,\n}\n"
    root := fixture(t, "def_package_enum_member", {{"lib/color.odin", color_src}})
    defer os.remove_all(root)

    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.Color.Green\n\tlib := 1\n\t_ = lib.Color.Red\n}\n"
    main_path := fixture_path(root, "main.odin")
    res := definition_at(e, main_src, "Green\n", root, main_path)
    expect_jump(t, &res, "color.odin", strings.index(color_src, "Green"))
    free_definition(&res)

    res = definition_at(e, main_src, "Color.Green", root, main_path)
    expect_jump(t, &res, "color.odin", strings.index(color_src, "Color ::"))
    free_definition(&res)

    // A local that shadows the import is a value, whose type is not known yet.
    res = definition_at(e, main_src, "Red\n", root, main_path)
    testing.expect(t, !res.ok, "a selector on a local must not reach the package")
    free_definition(&res)
}

// The source of the file at `path` from `offset` on; "" when it cannot be read. Temp-allocated.
@(private = "file")
text_from :: proc(path: string, offset: int) -> string {
    source, ok := lang.source_read(path)
    if !ok || offset < 0 || offset > len(source) {
        return ""
    }
    return source[offset:]
}

// A bare builtin jumps into base:builtin.
@(test)
test_definition_builtin_bare :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    if odin_root(&e.root) == "" {
        testing.fail_now(t, "no Odin root: ODIN_ROOT, `odin root` and the build root all failed")
    }
    src := "package app\n\ncount :: proc(xs: []int) -> int {\n\treturn len(xs)\n}\n"
    res := definition_at(e, src, "len(")
    defer free_definition(&res)
    testing.expect(t, res.ok, "expected the builtin len to resolve")
    testing.expectf(t, len(res.symbols) == 0, "expected a jump, got %d candidates", len(res.symbols))
    testing.expectf(t, strings.has_suffix(res.location.path, "builtin.odin"), "path: got %q", res.location.path)
    testing.expect(t, strings.has_prefix(text_from(res.location.path, res.location.start), "len"), "expected the jump to land on the declaration")
}

// A builtin type resolves into base:builtin; a package of the workspace that does not bind it is not read.
@(test)
test_definition_builtin_type :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    if odin_root(&e.root) == "" {
        testing.fail_now(t, "no Odin root: ODIN_ROOT, `odin root` and the build root all failed")
    }
    root := fixture(t, "def_builtin_type", {
        {"vt/vtable.odin", "package vt\n\nTransport :: struct {\n\twrite: proc(data: rawptr) -> bool,\n\tread:  proc(data: rawptr) -> int,\n}\n"},
    })
    defer os.remove_all(root)

    src := "package app\n\nmain :: proc() {\n\tx: int\n\t_ = x\n}\n"
    res := definition_at(e, src, "int", root, fixture_path(root, "app/main.odin"))
    defer free_definition(&res)
    testing.expect(t, res.ok, "expected the builtin int to resolve")
    testing.expectf(t, len(res.symbols) == 0, "expected a jump, got %d candidates", len(res.symbols))
    testing.expectf(t, strings.has_suffix(res.location.path, "builtin.odin"), "path: got %q", res.location.path)
}

// A builtin procedure group offers its members from base:runtime; a call of it jumps to the member
// its arguments pick.
@(test)
test_definition_builtin_group :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    if odin_root(&e.root) == "" {
        testing.fail_now(t, "no Odin root: ODIN_ROOT, `odin root` and the build root all failed")
    }
    src := "package app\n\nadd :: proc(xs: ^[dynamic]int) {\n\tappend(xs, 1)\n\t_ = append\n}\n"
    call := definition_at(e, src, "append(")
    testing.expect(t, call.ok, "expected the call of append to resolve")
    testing.expectf(t, len(call.symbols) == 0, "expected a jump, got %d candidates", len(call.symbols))
    testing.expectf(t, strings.has_suffix(call.location.path, "core_builtin.odin"), "path: got %q", call.location.path)
    testing.expect(t, strings.has_prefix(text_from(call.location.path, call.location.start), "append_elem ::"), "expected the jump to land on append_elem")
    free_definition(&call)

    res := definition_at(e, src, "append\n")
    defer free_definition(&res)
    testing.expect(t, res.ok, "expected the builtin append to resolve")
    found := false
    for sym in res.symbols {
        if sym.name != "append_elem" {
            continue
        }
        found = true
        testing.expectf(t, strings.has_suffix(sym.path, "core_builtin.odin"), "path: got %q", sym.path)
        testing.expect(t, sym.line > 0, "expected a line for the member")
        testing.expect(t, strings.has_prefix(text_from(sym.path, sym.offset), "append_elem"), "expected the member offset to land on its declaration")
    }
    testing.expectf(t, found, "expected append_elem among %d candidates", len(res.symbols))
}

// A name the package declares hides the builtin of that name, in the buffer or in another file.
@(test)
test_definition_builtin_shadowed :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nlen :: proc(xs: []int) -> int {\n\treturn 0\n}\n\nuse :: proc(xs: []int) -> int {\n\treturn len(xs)\n}\n"
    res := definition_at(e, src, "len(xs)\n}")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "len ::"))
    free_definition(&res)

    other_src := "package app\n\nmake :: proc() -> int {\n\treturn 1\n}\n"
    root := fixture(t, "def_builtin_shadowed", {{"other.odin", other_src}})
    defer os.remove_all(root)
    main_src := "package app\n\nmain :: proc() {\n\t_ = make()\n}\n"
    res = definition_at(e, main_src, "make()", root, fixture_path(root, "main.odin"))
    expect_jump(t, &res, "other.odin", strings.index(other_src, "make ::"))
    free_definition(&res)
}

// A name of base:runtime with no `builtin` attribute needs an import.
@(test)
test_definition_runtime_needs_import :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    if odin_root(&e.root) == "" {
        testing.fail_now(t, "no Odin root: ODIN_ROOT, `odin root` and the build root all failed")
    }
    src := "package app\n\nmain :: proc() {\n\tx: Raw_Dynamic_Array\n\t_ = x\n}\n"
    res := definition_at(e, src, "Raw_Dynamic_Array")
    defer free_definition(&res)
    testing.expectf(t, !res.ok, "expected no definition, got %q", res.location.path)

    qualified := "package app\n\nimport \"base:runtime\"\n\nmain :: proc() {\n\tx: runtime.Raw_Dynamic_Array\n\t_ = x\n}\n"
    res2 := definition_at(e, qualified, "Raw_Dynamic_Array")
    defer free_definition(&res2)
    testing.expect(t, res2.ok, "expected runtime.Raw_Dynamic_Array to resolve")
}

// The offset of `needle` at or after the first `after` in `src`; -1 when not found.
@(private)
offset_after :: proc(src, needle, after: string) -> int {
    base := strings.index(src, after)
    if base < 0 {
        return -1
    }
    i := strings.index(src[base:], needle)
    return i < 0 ? -1 : base + i
}

// A name a definition is asked for, and the declaration it lands on.
@(private = "file")
Typed_Case :: struct {
    at:         string,
    after:      string,
    decl:       string,
    decl_after: string,
}

@(private = "file")
TYPED_SRC :: `package demo

Color :: enum {
	Red,
	Green,
	Blue,
}

Colors :: bit_set[Color]

Point :: struct {
	x, y: int,
	c:    Color,
}

Base :: struct {
	id:   int,
	name: string,
}

Entity :: struct {
	using base: Base,
	pos:        Point,
	next:       ^Entity,
}

paint :: proc(color: Color, at: Point = {}) {}

pick :: proc() -> Color {
	return .Blue
}

main :: proc() {
	e: Entity
	_ = e.pos
	_ = e.id
	_ = e.pos.x
	pe := &e
	_ = pe.name
	_ = pe.next.pos.y
	c: Color = .Green
	c = .Red
	if c == .Blue {}
	paint(.Green)
	paint(color = .Red, at = {x = 1})
	switch c {
	case .Blue:
	}
	flags := Colors{.Green, .Blue}
	_ = flags
	q := Point{x = 1, c = .Red}
	_ = q
	ok := .Red in flags
	_ = ok
}
`

// A selector on a value, an implicit selector, a field name and a named argument land on their declarations.
@(test)
test_definition_typed_names :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    cases := [?]Typed_Case {
        {"pos", "_ = e.", "pos:", "Entity ::"},
        {"id", "_ = e.", "id:", "Base ::"},
        {"x", "_ = e.pos.", "x, y", "Point ::"},
        {"name", "_ = pe.", "name:", "Base ::"},
        {"y", "_ = pe.next.pos.", "y: int", "Point ::"},
        {"pos", "_ = pe.next.", "pos:", "Entity ::"},
        {"Green", "c: Color = .", "Green", "Color ::"},
        {"Red", "c = .", "Red", "Color ::"},
        {"Blue", "if c == .", "Blue", "Color ::"},
        {"Green", "paint(.", "Green", "Color ::"},
        {"color", "paint(color", "color:", "paint ::"},
        {"at", "paint(color = .Red, ", "at:", "paint ::"},
        {"x", "at = {", "x, y", "Point ::"},
        {"Blue", "case .", "Blue", "Color ::"},
        {"Blue", "return .", "Blue", "Color ::"},
        {"Green", "Colors{.", "Green", "Color ::"},
        {"Blue", "Colors{.Green, .", "Blue", "Color ::"},
        {"x", "q := Point{", "x, y", "Point ::"},
        {"c", "q := Point{x = 1, ", "c:", "Point ::"},
        {"Red", "Point{x = 1, c = .", "Red", "Color ::"},
        {"Red", "ok := .", "Red", "Color ::"},
    }
    for k in cases {
        at := offset_after(TYPED_SRC, k.at, k.after)
        want := offset_after(TYPED_SRC, k.decl, k.decl_after)
        if !testing.expectf(t, at >= 0 && want >= 0, "%q after %q: not in the source", k.at, k.after) {
            continue
        }
        res := definition_offset(e, TYPED_SRC, at)
        testing.expectf(t, res.ok && len(res.symbols) == 0 && res.location.start == want,
            "%q after %q: got ok=%v start=%d, want %d", k.at, k.after, res.ok, res.location.start, want)
        free_definition(&res)
    }
}

// A field of a type declared in another file, and of a type of an imported package.
@(test)
test_definition_typed_cross_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    shape_src := "package app\n\nShape :: struct {\n\twidth: int,\n\tkind:  lib.Kind,\n}\n\nimport \"lib\"\n"
    lib_src := "package lib\n\nKind :: enum {\n\tSquare,\n\tRound,\n}\n\nVec :: struct {\n\tlen: f32,\n}\n\norigin :: proc() -> Vec {\n\treturn {}\n}\n"
    root := fixture(t, "def_typed_cross_package", {{"shape.odin", shape_src}, {"lib/lib.odin", lib_src}})
    defer os.remove_all(root)

    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\ts: Shape\n\t_ = s.width\n\ts.kind = .Round\n\tv := lib.origin()\n\t_ = v.len\n\t_ = lib.Vec{len = 1}\n}\n"
    main_path := fixture_path(root, "main.odin")

    res := definition_at(e, main_src, "width\n", root, main_path)
    expect_jump(t, &res, "shape.odin", strings.index(shape_src, "width"))
    free_definition(&res)

    res = definition_at(e, main_src, "Round", root, main_path)
    expect_jump(t, &res, "lib.odin", strings.index(lib_src, "Round"))
    free_definition(&res)

    res = definition_at(e, main_src, "len\n", root, main_path)
    expect_jump(t, &res, "lib.odin", strings.index(lib_src, "len:"))
    free_definition(&res)

    res = definition_at(e, main_src, "len = 1", root, main_path)
    expect_jump(t, &res, "lib.odin", strings.index(lib_src, "len:"))
    free_definition(&res)
}

// A record declared in a procedure body.
@(test)
test_definition_typed_local_record :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nmain :: proc() {\n\tPair :: struct {\n\t\tleft, right: int,\n\t}\n\tp := Pair{right = 2}\n\t_ = p.left\n}\n"
    res := definition_at(e, src, "left\n")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "left,"))
    free_definition(&res)

    res = definition_at(e, src, "right = 2")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "right:"))
    free_definition(&res)
}

// A bare name a `using` brings in jumps to its field, also over a package name it shadows.
@(test)
test_definition_using_bare_name :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nBase :: struct {\n\tid: int,\n}\n\nEntity :: struct {\n\tusing base: Base,\n\tpos: int,\n}\n\nmove :: proc(using e: ^Entity) -> int {\n\treturn id + pos\n}\n\nid :: proc() {}\n"
    res := definition_at(e, src, "id + pos")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "id: int"))
    free_definition(&res)

    res = definition_at(e, src, "pos\n}")
    expect_jump(t, &res, "buffer.odin", strings.index(src, "pos: int"))
    free_definition(&res)
}
