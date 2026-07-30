// Go-to-definition and hover: lexical scope in one file, then across files,
// packages and the standard library.
package odin

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

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
    // A call resolves to the proc declaration.
    loc, ok := resolve_def(e, src, "add(1, 2)")
    defer delete(loc.path)
    testing.expect(t, ok, "expected to resolve the call to add")
    if ok {
        decl := strings.index(src, "add ::")
        testing.expectf(t, loc.start == decl, "add: got start %d, want %d", loc.start, decl)
    }

    // A use of a local resolves to that local's declaration.
    loc2, ok2 := resolve_def(e, src, "total\n")
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected to resolve the local total")
    if ok2 {
        decl := strings.index(src, "total :=")
        testing.expectf(t, loc2.start == decl, "total: got start %d, want %d", loc2.start, decl)
    }
}

@(test)
test_parameter_shadows_file_scope :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A top-level `value` and a parameter `value`: a reference inside the proc
    // body must bind to the parameter, not the file-scope constant.
    src := `package demo

value :: 100

use :: proc(value: int) -> int {
	return value * 2
}
`
    loc, ok := resolve_def(e, src, "value * 2")
    defer delete(loc.path)
    testing.expect(t, ok, "expected to resolve the parameter reference")
    if ok {
        param := strings.index(src, "value: int")
        testing.expectf(t, loc.start == param, "value: got start %d, want param at %d", loc.start, param)
    }
}

@(test)
test_use_before_short_declaration :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A file-scope `limit` and a local `limit :=` in one block. A local exists
    // only from its declaration on, so the use above it still names the
    // file-scope constant and only the use below names the local.
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

    before := strings.index(src, "_ = limit") + len("_ = ")
    loc, ok := resolve_offset(e, src, before)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the use above the declaration to resolve")
    if ok {
        testing.expectf(t, loc.start == top, "above: got %d, want the file-scope limit at %d", loc.start, top)
    }

    after := strings.last_index(src, "_ = limit") + len("_ = ")
    loc2, ok2 := resolve_offset(e, src, after)
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected the use below the declaration to resolve")
    if ok2 {
        testing.expectf(t, loc2.start == decl, "below: got %d, want the local at %d", loc2.start, decl)
    }

    // The caret on the declared name resolves to that declaration itself.
    loc3, ok3 := resolve_offset(e, src, decl)
    defer delete(loc3.path)
    testing.expect(t, ok3, "expected the declaration itself to resolve")
    if ok3 {
        testing.expectf(t, loc3.start == decl, "declaration: got %d, want %d", loc3.start, decl)
    }
}

@(test)
test_typed_local_and_loop_variable_shadow :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A typed `value: int` local and a `for item in list` loop variable: this
    // grammar spells them as a var_declaration and as bare identifier children of
    // the for statement, neither of which the LOCALS query captures, so both are
    // collected directly — otherwise they would not shadow the file-scope names.
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
    loc, ok := resolve_offset(e, src, strings.index(src, "_ = value") + len("_ = "))
    defer delete(loc.path)
    testing.expect(t, ok, "expected the typed local to resolve")
    if ok {
        want := strings.index(src, "value: int")
        testing.expectf(t, loc.start == want, "value: got %d, want the local at %d", loc.start, want)
    }

    loc2, ok2 := resolve_offset(e, src, strings.index(src, "_ = item") + len("_ = "))
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected the loop variable to resolve")
    if ok2 {
        want := strings.index(src, "item in list")
        testing.expectf(t, loc2.start == want, "item: got %d, want the loop variable at %d", loc2.start, want)
    }
}

@(test)
test_initializer_clause_scope :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // An `if`'s initializer clause declares into the statement, not the block
    // around it: `v` is visible in the consequence, and the `ok` below the
    // statement is the file-scope one again.
    src := `package demo

ok :: true

main :: proc() {
	if v, ok := lookup(); ok {
		_ = v
	}
	_ = ok
}
`
    loc, ok := resolve_offset(e, src, strings.index(src, "_ = v\n") + len("_ = "))
    defer delete(loc.path)
    testing.expect(t, ok, "expected the clause binding to resolve inside the if")
    if ok {
        want := strings.index(src, "v, ok :=")
        testing.expectf(t, loc.start == want, "v: got %d, want the clause binding at %d", loc.start, want)
    }

    loc2, ok2 := resolve_offset(e, src, strings.index(src, "_ = ok") + len("_ = "))
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected the use below the if to resolve")
    if ok2 {
        want := strings.index(src, "ok :: true")
        testing.expectf(t, loc2.start == want, "ok: got %d, want the file-scope ok at %d", loc2.start, want)
    }
}

@(test)
test_hover_signature :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

scale :: proc(v: int, by: int) -> int {
	return v * by
}

main :: proc() {
	_ = scale(2, 3)
}
`
    at := strings.index(src, "scale(2, 3)")
    req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)

    testing.expect(t, res.ok, "expected a hover result")
    testing.expectf(t, res.hover.text == "scale :: proc(v: int, by: int) -> int", "hover text: got %q", res.hover.text)
    defer delete(res.hover.text)
}

@(test)
test_hover_multiline_declaration :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

@(private)
Point :: struct {
	x: int,
	y: int,
}

@(require_results)
add :: proc(a: int, b: int) -> int {
	return a + b
}
`
    // Hover on the struct shows the complete multi-line declaration, keeping the
    // leading @() attribute.
    {
        at := strings.index(src, "Point :: struct")
        req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
        res := lang.Result{kind = .Hover}
        resolve(e, &req, &res)
        defer delete(res.hover.text)
        testing.expect(t, res.ok, "expected a hover result for the struct")
        want := "@(private)\nPoint :: struct {\n\tx: int,\n\ty: int,\n}"
        testing.expectf(t, res.hover.text == want, "struct hover: got %q", res.hover.text)
    }

    // Hover on the proc keeps the attribute but drops the body.
    {
        at := strings.index(src, "add :: proc")
        req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
        res := lang.Result{kind = .Hover}
        resolve(e, &req, &res)
        defer delete(res.hover.text)
        testing.expect(t, res.ok, "expected a hover result for the proc")
        want := "@(require_results)\nadd :: proc(a: int, b: int) -> int"
        testing.expectf(t, res.hover.text == want, "proc hover: got %q", res.hover.text)
    }
}

@(test)
test_document_symbol_signature_skips_attribute :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A symbol-list row is a compact `name :: type` line: the @() attribute is
    // dropped there, unlike the hover popup which keeps it.
    src := `package demo

@(private)
Widget :: struct {
	id: int,
}
`
    req := lang.Request{kind = .Document_Symbols, path = "buffer.odin", ext = ".odin", source = src}
    res := lang.Result{kind = .Document_Symbols}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected a document symbols result")
    testing.expectf(t, len(res.symbols) == 1, "symbol count: got %d", len(res.symbols))
    if len(res.symbols) == 1 {
        testing.expectf(t, res.symbols[0].signature == "Widget :: struct", "signature: got %q", res.symbols[0].signature)
    }
}

@(test)
test_definition_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Lay two files in a temp workspace under the CWD; the reference is in one,
    // the declaration in the other, so resolution must fall through to the scan.
    dir := "thor_lang_test_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    other := strings.concatenate({dir, "/helper.odin"}, context.temp_allocator)
    other_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)
    defer os.remove(other)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc() {\n\t_ = helper()\n}\n"

    at := strings.index(main_src, "helper()")
    req := lang.Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = dir,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "expected to resolve helper across files")
    if res.ok {
        testing.expectf(t, strings.has_suffix(res.location.path, "helper.odin"), "path: got %q", res.location.path)
        want := strings.index(other_src, "helper ::")
        testing.expectf(t, res.location.start == want, "cross-file start: got %d, want %d", res.location.start, want)
    }
}

@(test)
test_definition_multiple_candidates :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Two packages in the workspace both declare a top-level `shared`. The flat
    // cross-file scan ignores package boundaries, so it can't disambiguate them;
    // both must come back as candidates rather than the first winning silently.
    dir := "thor_lang_test_multi_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    a_dir := strings.concatenate({dir, "/a"}, context.temp_allocator)
    _ = os.make_directory(a_dir)
    defer os.remove(a_dir)
    b_dir := strings.concatenate({dir, "/b"}, context.temp_allocator)
    _ = os.make_directory(b_dir)
    defer os.remove(b_dir)

    a_path := strings.concatenate({a_dir, "/a.odin"}, context.temp_allocator)
    a_src := "package a\n\nshared :: proc() -> int {\n\treturn 1\n}\n"
    _ = os.write_entire_file(a_path, transmute([]byte)a_src)
    defer os.remove(a_path)
    b_path := strings.concatenate({b_dir, "/b.odin"}, context.temp_allocator)
    b_src := "package b\n\nshared :: proc() -> int {\n\treturn 2\n}\n"
    _ = os.write_entire_file(b_path, transmute([]byte)b_src)
    defer os.remove(b_path)

    // The reference lives in a file that does NOT declare `shared`, so the
    // same-file lexical pass misses and the workspace scan runs.
    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc() {\n\t_ = shared()\n}\n"

    at := strings.index(main_src, "shared()")
    req := lang.Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = dir,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    defer {
        for sym in res.symbols {
            delete(sym.name)
            delete(sym.kind)
            delete(sym.signature)
            delete(sym.path)
        }
        delete(res.symbols)
        delete(res.location.path)
    }

    testing.expect(t, res.ok, "expected to resolve shared across files")
    testing.expectf(t, len(res.symbols) == 2, "candidate count: got %d, want 2", len(res.symbols))
    if len(res.symbols) == 2 {
        got_a := strings.has_suffix(res.symbols[0].path, "a.odin") || strings.has_suffix(res.symbols[1].path, "a.odin")
        got_b := strings.has_suffix(res.symbols[0].path, "b.odin") || strings.has_suffix(res.symbols[1].path, "b.odin")
        testing.expect(t, got_a, "expected a candidate in a.odin")
        testing.expect(t, got_b, "expected a candidate in b.odin")
        testing.expectf(t, res.symbols[0].signature == "shared :: proc() -> int", "signature: got %q", res.symbols[0].signature)
    }
}

@(test)
test_definition_package_import :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Two packages under a workspace: app/main.odin imports the sibling `lib`
    // package by relative path and calls lib.thing. Resolution must follow the
    // import to lib/thing.odin, not flat-scan the whole tree.
    root := "thor_lang_pkg_ws"
    app := strings.concatenate({root, "/app"}, context.temp_allocator)
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(app)
    _ = os.make_directory(lib)

    lib_path := strings.concatenate({lib, "/thing.odin"}, context.temp_allocator)
    lib_src := "package lib\n\nthing :: proc() -> int {\n\treturn 7\n}\n"
    _ = os.write_entire_file(lib_path, transmute([]byte)lib_src)

    defer os.remove(root)
    defer os.remove(app)
    defer os.remove(lib)
    defer os.remove(lib_path)

    // main.odin lives only in the buffer (never written); the scan reads lib/.
    main_path := strings.concatenate({app, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"../lib\"\n\nmain :: proc() {\n\t_ = lib.thing()\n}\n"

    at := strings.index(main_src, "thing()")
    req := lang.Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "expected to resolve lib.thing across packages")
    if res.ok {
        testing.expectf(t, strings.has_suffix(res.location.path, "thing.odin"), "path: got %q", res.location.path)
        want := strings.index(lib_src, "thing ::")
        testing.expectf(t, res.location.start == want, "package start: got %d, want %d", res.location.start, want)
    }
}

@(test)
test_hover_package_member :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := "thor_lang_pkg_hover_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    lib_path := strings.concatenate({lib, "/api.odin"}, context.temp_allocator)
    lib_src := "package lib\n\nscale :: proc(v: int, by: int) -> int {\n\treturn v * by\n}\n"
    _ = os.write_entire_file(lib_path, transmute([]byte)lib_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(lib_path)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.scale(2, 3)\n}\n"

    at := strings.index(main_src, "scale(2, 3)")
    req := lang.Request {
        kind      = .Hover,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected a hover result for lib.scale")
    testing.expectf(t, res.hover.text == "scale :: proc(v: int, by: int) -> int", "hover text: got %q", res.hover.text)
}

@(test)
test_definition_package_operand :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Caret on the package operand `lib` (not the member): go-to-def jumps into
    // the package, targeting the file named like the package (lib/lib.odin).
    root := "thor_lang_pkg_op_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    named := strings.concatenate({lib, "/lib.odin"}, context.temp_allocator)
    named_src := "package lib\n"
    _ = os.write_entire_file(named, transmute([]byte)named_src)
    other := strings.concatenate({lib, "/extra.odin"}, context.temp_allocator)
    other_src := "package lib\n\nextra :: 1\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(named)
    defer os.remove(other)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.extra\n}\n"

    // The `lib` operand precedes the `.` — index the reference, not the import.
    at := strings.index(main_src, "lib.extra")
    req := lang.Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "expected to resolve the package operand lib")
    if res.ok {
        testing.expectf(t, strings.has_suffix(res.location.path, "lib.odin"), "path: got %q", res.location.path)
        testing.expectf(t, res.location.start == 0, "package start: got %d, want 0", res.location.start)
    }
}

@(test)
test_definition_package_no_entry_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A package with no file named like it: the package operand falls back to the
    // package's first .odin file, so navigation still lands inside the package.
    root := "thor_lang_pkg_noentry_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    other := strings.concatenate({lib, "/parts.odin"}, context.temp_allocator)
    other_src := "package lib\n\nextra :: 1\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(other)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.extra\n}\n"

    at := strings.index(main_src, "lib.extra")
    req := lang.Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "expected a fallback definition for a package without an entry file")
    if res.ok {
        testing.expectf(t, strings.has_suffix(res.location.path, "parts.odin"), "fallback path: got %q", res.location.path)
    }
}

@(test)
test_definition_package_fuzzy_fallback :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A package `lib` with no `lib.odin`: the fallback picks the file whose name
    // is fuzzily closest to the package name (`lib_windows.odin`, sharing the
    // `lib` prefix) over the lexicographically-first `aardvark.odin`.
    root := "thor_lang_pkg_fuzzy_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    a := strings.concatenate({lib, "/aardvark.odin"}, context.temp_allocator)
    a_src := "package lib\n\naa :: 1\n"
    _ = os.write_entire_file(a, transmute([]byte)a_src)
    b := strings.concatenate({lib, "/lib_windows.odin"}, context.temp_allocator)
    b_src := "package lib\n\nbb :: 2\n"
    _ = os.write_entire_file(b, transmute([]byte)b_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(a)
    defer os.remove(b)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.bb\n}\n"

    at := strings.index(main_src, "lib.bb")
    req := lang.Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "expected a fuzzy fallback for a package without an entry file")
    if res.ok {
        testing.expectf(t, strings.has_suffix(res.location.path, "lib_windows.odin"), "fuzzy fallback path: got %q", res.location.path)
    }
}

@(test)
test_definition_on_import_line :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Alt+Enter with the caret on the import declaration itself (the aliased
    // path string) opens the package, targeting its entry file (lib/lib.odin).
    root := "thor_lang_import_line_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    named := strings.concatenate({lib, "/lib.odin"}, context.temp_allocator)
    named_src := "package lib\n\nthing :: 1\n"
    _ = os.write_entire_file(named, transmute([]byte)named_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(named)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport lib \"lib\"\n\nmain :: proc() {\n\t_ = lib.thing\n}\n"

    // Caret on the quoted path, which is not an identifier.
    at := strings.index(main_src, "\"lib\"") + 1
    req := lang.Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "expected the import line to resolve to the package")
    if res.ok {
        testing.expectf(t, strings.has_suffix(res.location.path, "lib.odin"), "path: got %q", res.location.path)
    }
}

@(test)
test_definition_stdlib :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `core:fmt` resolves against the compiler's own standard library with no
    // environment set up (the baked-in ODIN_ROOT). Hovering fmt.println must
    // find its declaration in the stdlib sources.
    src := "package app\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(\"hi\")\n}\n"

    at := strings.index(src, "println")
    req := lang.Request {
        kind      = .Hover,
        path      = "app/main.odin",
        ext       = ".odin",
        source    = src,
        offset    = at,
        workspace = "app",
    }
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected fmt.println to resolve into the stdlib")
    if res.ok {
        testing.expectf(t, strings.has_prefix(res.hover.text, "println ::"), "hover text: got %q", res.hover.text)
    }
}
