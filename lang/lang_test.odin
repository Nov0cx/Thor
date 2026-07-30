package lang

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

import ts "../vendor/odin-tree-sitter"

// Resolves the identifier at the first occurrence of `needle` in `source` and
// returns the definition byte range the engine points at. Drives odin_resolve
// directly (no threads) so the analysis is tested in isolation.
@(private = "file")
resolve_def :: proc(e: ^Odin_Engine, source, needle: string, workspace := "") -> (Location, bool) {
    at := strings.index(source, needle)
    if at < 0 {
        return {}, false
    }
    req := Request {
        kind      = .Definition,
        path      = "buffer.odin",
        ext       = ".odin",
        source    = source,
        offset    = at,
        workspace = workspace,
    }
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
    return res.location, res.ok
}

@(test)
test_definition_same_file :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

    src := `package demo

scale :: proc(v: int, by: int) -> int {
	return v * by
}

main :: proc() {
	_ = scale(2, 3)
}
`
    at := strings.index(src, "scale(2, 3)")
    req := Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Hover}
    odin_resolve(e, &req, &res)

    testing.expect(t, res.ok, "expected a hover result")
    testing.expectf(t, res.hover.text == "scale :: proc(v: int, by: int) -> int", "hover text: got %q", res.hover.text)
    defer delete(res.hover.text)
}

@(test)
test_hover_multiline_declaration :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
        req := Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
        res := Result{kind = .Hover}
        odin_resolve(e, &req, &res)
        defer delete(res.hover.text)
        testing.expect(t, res.ok, "expected a hover result for the struct")
        want := "@(private)\nPoint :: struct {\n\tx: int,\n\ty: int,\n}"
        testing.expectf(t, res.hover.text == want, "struct hover: got %q", res.hover.text)
    }

    // Hover on the proc keeps the attribute but drops the body.
    {
        at := strings.index(src, "add :: proc")
        req := Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
        res := Result{kind = .Hover}
        odin_resolve(e, &req, &res)
        defer delete(res.hover.text)
        testing.expect(t, res.ok, "expected a hover result for the proc")
        want := "@(require_results)\nadd :: proc(a: int, b: int) -> int"
        testing.expectf(t, res.hover.text == want, "proc hover: got %q", res.hover.text)
    }
}

@(test)
test_document_symbol_signature_skips_attribute :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // A symbol-list row is a compact `name :: type` line: the @() attribute is
    // dropped there, unlike the hover popup which keeps it.
    src := `package demo

@(private)
Widget :: struct {
	id: int,
}
`
    req := Request{kind = .Document_Symbols, path = "buffer.odin", ext = ".odin", source = src}
    res := Result{kind = .Document_Symbols}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected a document symbols result")
    testing.expectf(t, len(res.symbols) == 1, "symbol count: got %d", len(res.symbols))
    if len(res.symbols) == 1 {
        testing.expectf(t, res.symbols[0].signature == "Widget :: struct", "signature: got %q", res.symbols[0].signature)
    }
}

@(test)
test_definition_cross_file :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = dir,
    }
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = dir,
    }
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request {
        kind      = .Hover,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := Result{kind = .Hover}
    odin_resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected a hover result for lib.scale")
    testing.expectf(t, res.hover.text == "scale :: proc(v: int, by: int) -> int", "hover text: got %q", res.hover.text)
}

@(test)
test_definition_package_operand :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "expected to resolve the package operand lib")
    if res.ok {
        testing.expectf(t, strings.has_suffix(res.location.path, "lib.odin"), "path: got %q", res.location.path)
        testing.expectf(t, res.location.start == 0, "package start: got %d, want 0", res.location.start)
    }
}

@(test)
test_definition_package_no_entry_file :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "expected a fallback definition for a package without an entry file")
    if res.ok {
        testing.expectf(t, strings.has_suffix(res.location.path, "parts.odin"), "fallback path: got %q", res.location.path)
    }
}

@(test)
test_definition_package_fuzzy_fallback :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "expected a fuzzy fallback for a package without an entry file")
    if res.ok {
        testing.expectf(t, strings.has_suffix(res.location.path, "lib_windows.odin"), "fuzzy fallback path: got %q", res.location.path)
    }
}

@(test)
test_definition_on_import_line :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
    defer delete(res.location.path)

    testing.expect(t, res.ok, "expected the import line to resolve to the package")
    if res.ok {
        testing.expectf(t, strings.has_suffix(res.location.path, "lib.odin"), "path: got %q", res.location.path)
    }
}

@(test)
test_document_symbols :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // Top-level procs, a struct, an enum and a constant belong in the outline;
    // parameters, struct fields and locals do not. The package name is excluded.
    src := `package demo

Color :: enum {
	Red,
	Green,
}

Point :: struct {
	x: int,
	y: int,
}

MAX :: 100

add :: proc(a: int, b: int) -> int {
	sum := a + b
	return sum
}
`
    req := Request{kind = .Document_Symbols, path = "buffer.odin", ext = ".odin", source = src}
    res := Result{kind = .Document_Symbols}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected a document symbols result")

    // Exactly the four top-level declarations, in source order.
    names := make([dynamic]string, context.temp_allocator)
    for sym in res.symbols {
        append(&names, sym.name)
    }
    want := []string{"Color", "Point", "MAX", "add"}
    testing.expectf(t, len(names) == len(want), "symbol count: got %d %v, want %d", len(names), names[:], len(want))
    if len(names) == len(want) {
        for name, i in want {
            testing.expectf(t, names[i] == name, "symbol %d: got %q, want %q", i, names[i], name)
        }
    }

    // Each symbol's offset points at its declared identifier, and the signature
    // is the real Odin declaration line (name :: type), carrying its file/line.
    for sym in res.symbols {
        testing.expectf(
            t,
            strings.has_prefix(src[sym.offset:], sym.name),
            "symbol %q offset %d does not land on its name", sym.name, sym.offset,
        )
        testing.expectf(
            t,
            strings.has_prefix(sym.signature, sym.name),
            "symbol %q signature %q should start with the name", sym.name, sym.signature,
        )
        testing.expectf(t, sym.path == "buffer.odin", "symbol %q path: got %q", sym.name, sym.path)
        testing.expectf(t, sym.line > 0, "symbol %q line: got %d", sym.name, sym.line)
    }

    // The proc's signature is the real Odin type, not a "function" tag.
    for sym in res.symbols {
        if sym.name == "add" {
            testing.expectf(t, sym.signature == "add :: proc(a: int, b: int) -> int", "add signature: got %q", sym.signature)
        }
    }
}

// Frees a symbol result's owned strings (the engine clones into context.allocator).
@(private = "file")
free_symbols :: proc(res: ^Result) {
    for sym in res.symbols {
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
        delete(sym.path)
    }
    delete(res.symbols)
}

@(test)
test_workspace_symbols :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // Two packages under a workspace, each with a top-level symbol on disk, plus
    // the live buffer's own symbol. Workspace symbols must gather all three.
    root := "thor_lang_ws_syms"
    app := strings.concatenate({root, "/app"}, context.temp_allocator)
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(app)
    _ = os.make_directory(lib)

    lib_path := strings.concatenate({lib, "/thing.odin"}, context.temp_allocator)
    lib_src := "package lib\n\nthing :: proc() {}\n"
    _ = os.write_entire_file(lib_path, transmute([]byte)lib_src)
    other := strings.concatenate({app, "/util.odin"}, context.temp_allocator)
    other_src := "package app\n\nUtil :: struct {}\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)

    // Declared dirs-first so LIFO removes the files before their directories.
    defer os.remove(root)
    defer os.remove(app)
    defer os.remove(lib)
    defer os.remove(lib_path)
    defer os.remove(other)

    // The live buffer (never written) contributes `live`; its path is skipped on disk.
    main_path := strings.concatenate({app, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nlive :: proc() {}\n"

    req := Request {
        kind      = .Workspace_Symbols,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        workspace = root,
    }
    res := Result{kind = .Workspace_Symbols}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected a workspace symbols result")

    has :: proc(res: ^Result, name: string) -> bool {
        for sym in res.symbols {
            if sym.name == name {
                return true
            }
        }
        return false
    }
    testing.expect(t, has(&res, "thing"), "workspace symbols missing on-disk lib.thing")
    testing.expect(t, has(&res, "Util"), "workspace symbols missing on-disk app.Util")
    testing.expect(t, has(&res, "live"), "workspace symbols missing the live buffer's symbol")

    // Sorted by name: Util, live, thing (capitals sort before lowercase in ASCII).
    testing.expectf(t, len(res.symbols) == 3, "symbol count: got %d", len(res.symbols))
}

@(test)
test_references_local :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `total` is declared in `use` and, separately, in `other`. References to the
    // one in `use` must be confined to `use`'s body — the declaration plus its two
    // uses — never listing `other`'s same-named local.
    src := `package demo

use :: proc() -> int {
	total := 1
	return total + total
}

other :: proc() -> int {
	total := 9
	return total
}
`
    at := strings.index(src, "total :=")
    req := Request{kind = .References, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .References}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to the local total")
    testing.expectf(t, len(res.symbols) == 3, "local ref count: got %d", len(res.symbols))

    use_end := strings.index(src, "other ::")
    for sym in res.symbols {
        testing.expectf(t, strings.has_prefix(src[sym.offset:], "total"), "ref offset %d not on the name", sym.offset)
        testing.expectf(t, sym.offset < use_end, "ref at %d leaked past use's body", sym.offset)
        testing.expectf(t, sym.path == "buffer.odin", "ref path: got %q", sym.path)
    }
}

@(test)
test_references_skip_use_above_declaration :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // Three occurrences of `count` in the block, but the first one names the
    // file-scope constant — the local does not exist yet there. Find-usages on
    // the local lists only its declaration and the use below it, which is also
    // what keeps rename from rewriting an unrelated name.
    src := `package demo

count :: 0

use :: proc() -> int {
	_ = count
	count := 1
	return count
}
`
    at := strings.index(src, "count := 1")
    req := Request{kind = .References, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .References}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to the local count")
    testing.expectf(t, len(res.symbols) == 2, "local ref count: got %d, want 2", len(res.symbols))
    for sym in res.symbols {
        testing.expectf(t, sym.offset >= at, "ref at %d predates the declaration at %d", sym.offset, at)
    }
}

@(test)
test_references_cross_file :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `helper` is declared in main.odin (the live buffer) and called from both
    // main.odin and a sibling use.odin on disk. References to a top-level symbol
    // span the whole workspace: buffer (decl + one call) and the sibling (two).
    dir := "thor_lang_refs_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    other := strings.concatenate({dir, "/use.odin"}, context.temp_allocator)
    other_src := "package demo\n\nrun :: proc() {\n\t_ = helper()\n\t_ = helper()\n}\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)
    defer os.remove(other)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n\nmain :: proc() {\n\t_ = helper()\n}\n"

    at := strings.index(main_src, "helper ::")
    req := Request {
        kind      = .References,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = dir,
    }
    res := Result{kind = .References}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected cross-file references to helper")
    testing.expectf(t, len(res.symbols) == 4, "cross-file ref count: got %d", len(res.symbols))

    in_main := 0
    in_other := 0
    for sym in res.symbols {
        if strings.has_suffix(sym.path, "main.odin") {
            in_main += 1
        }
        if strings.has_suffix(sym.path, "use.odin") {
            in_other += 1
        }
        testing.expectf(t, strings.has_prefix(src_at(sym), "helper"), "ref offset %d not on the name", sym.offset)
    }
    testing.expectf(t, in_main == 2, "helper refs in main.odin: got %d", in_main)
    testing.expectf(t, in_other == 2, "helper refs in use.odin: got %d", in_other)
}

@(test)
test_references_index_incremental :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // Phase 2: the workspace reference scan is filtered by the index's per-file
    // identifier sets. A decoy file that never mentions `helper` must contribute
    // nothing, and a sibling created *after* the first request (so after the index
    // was first built) must be picked up on the next request via the stat-walk +
    // rebuilt identifier set — proving the filter is both correct and live.
    dir := "thor_lang_refs_incr"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    decoy := strings.concatenate({dir, "/decoy.odin"}, context.temp_allocator)
    decoy_src := "package demo\n\nunrelated :: proc() {\n\t_ = 1\n}\n"
    _ = os.write_entire_file(decoy, transmute([]byte)decoy_src)
    defer os.remove(decoy)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n\nmain :: proc() {\n\t_ = helper()\n}\n"

    refs :: proc(e: ^Odin_Engine, path, src, dir: string) -> Result {
        req := Request {
            kind      = .References,
            path      = path,
            ext       = ".odin",
            source    = src,
            offset    = strings.index(src, "helper ::"),
            workspace = dir,
        }
        res := Result{kind = .References}
        odin_resolve(e, &req, &res)
        return res
    }

    // First request: only the live buffer mentions helper; the decoy is filtered out.
    res1 := refs(e, main_path, main_src, dir)
    defer free_symbols(&res1)
    testing.expectf(t, len(res1.symbols) == 2, "buffer-only ref count: got %d", len(res1.symbols))
    for sym in res1.symbols {
        testing.expectf(t, strings.has_suffix(sym.path, "main.odin"), "unexpected ref in %q", sym.path)
    }

    // Add a sibling that calls helper twice, then request again: the stat-walk sees
    // the new file, indexes its identifiers, and the filter now admits it.
    use := strings.concatenate({dir, "/use.odin"}, context.temp_allocator)
    use_src := "package demo\n\nrun :: proc() {\n\t_ = helper()\n\t_ = helper()\n}\n"
    _ = os.write_entire_file(use, transmute([]byte)use_src)
    defer os.remove(use)

    res2 := refs(e, main_path, main_src, dir)
    defer free_symbols(&res2)
    testing.expectf(t, len(res2.symbols) == 4, "ref count after sibling added: got %d", len(res2.symbols))
    in_use := 0
    for sym in res2.symbols {
        if strings.has_suffix(sym.path, "use.odin") {
            in_use += 1
        }
    }
    testing.expectf(t, in_use == 2, "helper refs in the new use.odin: got %d", in_use)
}

@(private = "file")
free_edits :: proc(res: ^Result) {
    for edit in res.edits {
        delete(edit.path)
        delete(edit.old_text)
        delete(edit.new_text)
    }
    delete(res.edits)
}

// Runs a Rename request at the first occurrence of `needle` in `source`.
@(private = "file")
rename_at :: proc(
    e: ^Odin_Engine,
    source, needle, new_name: string,
    workspace := "",
    path := "buffer.odin",
) -> Result {
    req := Request {
        kind      = .Rename,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = strings.index(source, needle),
        workspace = workspace,
        new_name  = new_name,
    }
    res := Result{kind = .Rename}
    odin_resolve(e, &req, &res)
    return res
}

@(test)
test_rename_local_scope :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // Rename inherits find-references' scoping: renaming `total` in `use` edits
    // the declaration and its two uses there, never `other`'s same-named local.
    src := `package demo

use :: proc() -> int {
	total := 1
	return total + total
}

other :: proc() -> int {
	total := 9
	return total
}
`
    res := rename_at(e, src, "total :=", "sum")
    defer free_edits(&res)

    testing.expect(t, res.ok, "expected rename edits for the local total")
    testing.expectf(t, len(res.edits) == 3, "local rename edit count: got %d", len(res.edits))

    use_end := strings.index(src, "other ::")
    for edit in res.edits {
        testing.expectf(t, src[edit.start:edit.end] == "total", "edit %d..%d not over the name", edit.start, edit.end)
        testing.expectf(t, edit.old_text == "total", "old_text: got %q", edit.old_text)
        testing.expectf(t, edit.new_text == "sum", "new_text: got %q", edit.new_text)
        testing.expectf(t, edit.start < use_end, "edit at %d leaked past use's body", edit.start)
    }

    // Applying the edits front-to-back must produce a buffer that renames only
    // `use`'s local — the shape the editor splices into a file.
    b := strings.builder_make(context.temp_allocator)
    last := 0
    for edit in res.edits {
        strings.write_string(&b, src[last:edit.start])
        strings.write_string(&b, edit.new_text)
        last = edit.end
    }
    strings.write_string(&b, src[last:])
    out := strings.to_string(b)
    testing.expect(t, strings.contains(out, "sum := 1"), "declaration not renamed")
    testing.expect(t, strings.contains(out, "return sum + sum"), "uses not renamed")
    testing.expect(t, strings.contains(out, "total := 9"), "other's local must not be renamed")
}

@(test)
test_rename_cross_file :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // A top-level symbol is renamed across the workspace: the live buffer's
    // declaration plus its call, and both calls in the sibling on disk.
    dir := "thor_lang_rename_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    other := strings.concatenate({dir, "/use.odin"}, context.temp_allocator)
    other_src := "package demo\n\nrun :: proc() {\n\t_ = helper()\n\t_ = helper()\n}\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)
    defer os.remove(other)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n\nmain :: proc() {\n\t_ = helper()\n}\n"

    res := rename_at(e, main_src, "helper ::", "assist", workspace = dir, path = main_path)
    defer free_edits(&res)

    testing.expect(t, res.ok, "expected cross-file rename edits")
    testing.expectf(t, len(res.edits) == 4, "cross-file rename edit count: got %d", len(res.edits))

    in_main, in_other := 0, 0
    for edit in res.edits {
        testing.expectf(t, edit.old_text == "helper", "old_text: got %q", edit.old_text)
        testing.expectf(t, edit.end - edit.start == len("helper"), "edit span: got %d", edit.end - edit.start)
        if strings.has_suffix(edit.path, "main.odin") {
            in_main += 1
            testing.expectf(t, main_src[edit.start:edit.end] == "helper", "buffer edit %d off the name", edit.start)
        }
        if strings.has_suffix(edit.path, "use.odin") {
            in_other += 1
            testing.expectf(t, other_src[edit.start:edit.end] == "helper", "sibling edit %d off the name", edit.start)
        }
    }
    testing.expectf(t, in_main == 2, "edits in main.odin: got %d", in_main)
    testing.expectf(t, in_other == 2, "edits in use.odin: got %d", in_other)

    // No file was touched: the engine only reports edits, the editor applies them.
    on_disk, rerr := os.read_entire_file(other, context.temp_allocator)
    testing.expect(t, rerr == nil, "sibling should still be readable")
    testing.expect(t, string(on_disk) == other_src, "the engine must not write files itself")
}

@(test)
test_rename_rejects_bad_names :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    src := "package demo\n\nuse :: proc() -> int {\n\ttotal := 1\n\treturn total\n}\n"

    for bad in ([?]string{"", "  ", "2fast", "has space", "with-dash", "proc", "int", "total"}) {
        res := rename_at(e, src, "total :=", bad)
        defer free_edits(&res)
        testing.expectf(t, !res.ok && len(res.edits) == 0, "%q should not be a rename target", bad)
    }

    // A leading underscore is a legal identifier and must be accepted.
    ok_res := rename_at(e, src, "total :=", "_total")
    defer free_edits(&ok_res)
    testing.expect(t, ok_res.ok, "_total should be a legal rename target")
}

// Reads the name-bearing slice at a reference symbol's offset from its file, so a
// test can assert the jump lands on the identifier. Buffer files (never written)
// won't read back; those are covered by the same-file assertions instead.
@(private = "file")
src_at :: proc(sym: Symbol) -> string {
    data, err := os.read_entire_file(sym.path, context.temp_allocator)
    if err != nil {
        return "helper" // buffer-only file; skip the on-disk check
    }
    s := clamp(sym.offset, 0, len(data))
    return string(data[s:])
}

// Runs a Signature_Help request at `at` and returns the resolved signature.
@(private = "file")
sig_help :: proc(e: ^Odin_Engine, source: string, at: int, workspace := "", path := "buffer.odin") -> (Signature_Info, bool) {
    req := Request {
        kind      = .Signature_Help,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = at,
        workspace = workspace,
    }
    res := Result{kind = .Signature_Help}
    odin_resolve(e, &req, &res)
    return res.signature, res.ok
}

@(test)
test_signature_help_same_file :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    src := `package demo

add :: proc(a: int, b: int) -> int {
	return a + b
}

main :: proc() {
	_ = add(1, 2)
}
`
    call := strings.index(src, "add(1, 2)")

    // Caret on the first argument: signature resolved, first parameter active.
    sig1, ok1 := sig_help(e, src, call + len("add("))
    defer delete(sig1.label)
    testing.expect(t, ok1, "expected signature help on the first argument")
    testing.expectf(t, sig1.label == "add :: proc(a: int, b: int) -> int", "label: got %q", sig1.label)
    testing.expectf(t, sig1.label[sig1.active_start:sig1.active_end] == "a: int", "active param 0: got %q", sig1.label[sig1.active_start:sig1.active_end])

    // Caret on the second argument: same signature, second parameter active.
    sig2, ok2 := sig_help(e, src, strings.index(src, ", 2)") + 2)
    defer delete(sig2.label)
    testing.expect(t, ok2, "expected signature help on the second argument")
    testing.expectf(t, sig2.label[sig2.active_start:sig2.active_end] == "b: int", "active param 1: got %q", sig2.label[sig2.active_start:sig2.active_end])
}

@(test)
test_signature_help_cross_file :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // The procedure is declared in a sibling file; signature help follows the
    // cross-file scan, like go-to-definition.
    dir := "thor_lang_sig_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    other := strings.concatenate({dir, "/api.odin"}, context.temp_allocator)
    other_src := "package demo\n\nscale :: proc(v: int, by: int) -> int {\n\treturn v * by\n}\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)
    defer os.remove(other)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc() {\n\t_ = scale(2, 3)\n}\n"

    // Caret on the second argument -> second parameter active.
    at := strings.index(main_src, ", 3)") + 2
    sig, ok := sig_help(e, main_src, at, dir, main_path)
    defer delete(sig.label)
    testing.expect(t, ok, "expected cross-file signature help")
    testing.expectf(t, sig.label == "scale :: proc(v: int, by: int) -> int", "label: got %q", sig.label)
    testing.expectf(t, sig.label[sig.active_start:sig.active_end] == "by: int", "active param: got %q", sig.label[sig.active_start:sig.active_end])
}

@(test)
test_signature_help_package :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `pkg.fn(...)`: signature help follows the import into the package's dir.
    root := "thor_lang_sig_pkg_ws"
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

    at := strings.index(main_src, "scale(2, 3)") + len("scale(")
    sig, ok := sig_help(e, main_src, at, root, main_path)
    defer delete(sig.label)
    testing.expect(t, ok, "expected package-qualified signature help")
    testing.expectf(t, sig.label == "scale :: proc(v: int, by: int) -> int", "label: got %q", sig.label)
    testing.expectf(t, sig.label[sig.active_start:sig.active_end] == "v: int", "active param: got %q", sig.label[sig.active_start:sig.active_end])
}

@(test)
test_definition_stdlib :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `core:fmt` resolves against the compiler's own standard library with no
    // environment set up (the baked-in ODIN_ROOT). Hovering fmt.println must
    // find its declaration in the stdlib sources.
    src := "package app\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(\"hi\")\n}\n"

    at := strings.index(src, "println")
    req := Request {
        kind      = .Hover,
        path      = "app/main.odin",
        ext       = ".odin",
        source    = src,
        offset    = at,
        workspace = "app",
    }
    res := Result{kind = .Hover}
    odin_resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected fmt.println to resolve into the stdlib")
    if res.ok {
        testing.expectf(t, strings.has_prefix(res.hover.text, "println ::"), "hover text: got %q", res.hover.text)
    }
}

// True when the completion result offers a candidate named `name`.
@(private = "file")
has_completion :: proc(res: ^Result, name: string) -> bool {
    for sym in res.symbols {
        if sym.name == name {
            return true
        }
    }
    return false
}

@(test)
test_completion_same_file :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // A temp dir kept empty on disk (main.odin is never written), so the sibling
    // scan finds nothing and candidates come only from the buffer and keywords.
    dir := "thor_lang_complete_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)
    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)

    src := `package demo

counter :: 100

count_items :: proc() -> int {
	return 0
}

main :: proc() {
	total := 0
	_ = coun
}
`
    at := strings.index(src, "coun\n") + len("coun")
    req := Request{kind = .Completion, path = main_path, ext = ".odin", source = src, offset = at, workspace = dir}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected completion candidates")
    testing.expect(t, has_completion(&res, "counter"), "missing top-level counter")
    testing.expect(t, has_completion(&res, "count_items"), "missing top-level count_items")
    // Names that don't share the typed prefix are filtered out.
    testing.expect(t, !has_completion(&res, "total"), "total does not share the prefix")
    testing.expect(t, !has_completion(&res, "main"), "main does not share the prefix")

    // A top-level candidate carries its declaration line and kind; the caret's own
    // partial word is never offered back as a candidate.
    for sym in res.symbols {
        if sym.name == "count_items" {
            testing.expectf(t, sym.signature == "count_items :: proc() -> int", "count_items label: got %q", sym.signature)
            testing.expectf(t, sym.kind == "function", "count_items kind: got %q", sym.kind)
        }
    }
    testing.expect(t, !has_completion(&res, "coun"), "the typed prefix is not a candidate")
}

@(test)
test_completion_keyword :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `str` matches no declaration but does prefix the builtin `string`, tagged
    // "keyword" so the editor colors it like one.
    src := "package demo\n\nmain :: proc() {\n\tx: str\n\t_ = x\n}\n"
    at := strings.index(src, "str\n") + len("str")
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected a keyword completion")
    testing.expect(t, has_completion(&res, "string"), "missing builtin string")
    for sym in res.symbols {
        if sym.name == "string" {
            testing.expectf(t, sym.kind == "keyword", "string kind: got %q", sym.kind)
        }
    }
}

@(test)
test_completion_skips_later_local :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // At the caret only `count_all` is in reach: `counted` is declared below it
    // (naming it there would not compile) and `counter` belongs to another
    // procedure's block.
    src := `package demo

count_all :: proc() -> int {
	return 0
}

other :: proc() {
	counter := 1
	_ = counter
}

main :: proc() {
	_ = coun
	counted := 2
	_ = counted
}
`
    at := strings.index(src, "coun\n") + len("coun")
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected completion candidates")
    testing.expect(t, has_completion(&res, "count_all"), "missing top-level count_all")
    testing.expect(t, !has_completion(&res, "counted"), "counted is not declared yet at the caret")
    testing.expect(t, !has_completion(&res, "counter"), "counter belongs to another block")
}

@(test)
test_completion_package_name :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // Typing the start of an imported package's name offers the package itself
    // (the operand you then qualify with `.`), tagged "namespace".
    src := "package app\n\nimport \"../widgets\"\nimport \"core:fmt\"\n\nmain :: proc() {\n\t_ = wi\n}\n"
    at := strings.index(src, "wi\n") + len("wi")
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected the imported package as a candidate")
    testing.expect(t, has_completion(&res, "widgets"), "missing imported package widgets")
    testing.expect(t, !has_completion(&res, "fmt"), "fmt does not share the prefix")
    for sym in res.symbols {
        if sym.name == "widgets" {
            testing.expectf(t, sym.kind == "namespace", "widgets kind: got %q", sym.kind)
        }
    }
}

@(test)
test_completion_package_member :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `lib.sc<caret>`: completion follows the import into the package's dir and
    // lists that package's top-level declarations matching the prefix.
    root := "thor_lang_complete_pkg_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    lib_path := strings.concatenate({lib, "/api.odin"}, context.temp_allocator)
    lib_src := "package lib\n\nscale :: proc(v: int, by: int) -> int {\n\treturn v * by\n}\n\nshift :: 3\n\nother :: 9\n"
    _ = os.write_entire_file(lib_path, transmute([]byte)lib_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(lib_path)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.sc\n}\n"

    at := strings.index(main_src, "lib.sc") + len("lib.sc")
    req := Request{kind = .Completion, path = main_path, ext = ".odin", source = main_src, offset = at, workspace = root}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected package-member completions")
    testing.expect(t, has_completion(&res, "scale"), "missing lib.scale")
    // Only the `sc` prefix matches: shift and other are excluded.
    testing.expect(t, !has_completion(&res, "shift"), "shift does not share the prefix")
    testing.expect(t, !has_completion(&res, "other"), "other does not share the prefix")
}

@(test)
test_completion_siblings_from_index :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // Sibling-file completion is served from the symbol index, which holds the
    // *whole* workspace while an Odin package is one flat directory — so the
    // per-directory filter is what keeps another package's declarations out. The
    // workspace is made absolute because the index keys the paths os.read_dir
    // produced; a relative spelling would miss and quietly fall back to the disk
    // scan, testing the old path instead of the new one.
    rel := "thor_lang_complete_idx_ws"
    _ = os.make_directory(rel)
    root, abs_err := filepath.abs(rel, context.temp_allocator)
    testing.expect(t, abs_err == nil, "could not absolutize the test workspace")

    app := strings.concatenate({root, "/app"}, context.temp_allocator)
    other := strings.concatenate({root, "/other"}, context.temp_allocator)
    _ = os.make_directory(app)
    _ = os.make_directory(other)

    sibling := strings.concatenate({app, "/sibling.odin"}, context.temp_allocator)
    sibling_src := "package app\n\nsib_value :: 7\n"
    _ = os.write_entire_file(sibling, transmute([]byte)sibling_src)

    // Same workspace, different package: indexed, but must never be offered here.
    far := strings.concatenate({other, "/far.odin"}, context.temp_allocator)
    far_src := "package other\n\nsib_far :: 1\n"
    _ = os.write_entire_file(far, transmute([]byte)far_src)

    defer os.remove(rel)
    defer os.remove(app)
    defer os.remove(other)
    defer os.remove(sibling)
    defer os.remove(far)

    main_path := strings.concatenate({app, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nmain :: proc() {\n\t_ = sib\n}\n"
    at := strings.index(main_src, "sib\n") + len("sib")

    complete_sib :: proc(e: ^Odin_Engine, path, src, root: string, at: int) -> Result {
        req := Request{kind = .Completion, path = path, ext = ".odin", source = src, offset = at, workspace = root}
        res := Result{kind = .Completion}
        odin_resolve(e, &req, &res)
        return res
    }

    res1 := complete_sib(e, main_path, main_src, root, at)
    defer free_symbols(&res1)
    testing.expect(t, res1.ok, "expected sibling completions")
    testing.expect(t, has_completion(&res1, "sib_value"), "missing the sibling package file's sib_value")
    testing.expect(t, !has_completion(&res1, "sib_far"), "another package's sib_far must not be offered")

    // The index is resident across requests, so an edited sibling must be
    // re-parsed (its size moved) rather than answered from the first parse.
    edited_src := "package app\n\nsib_value :: 7\n\nsib_extra :: 9\n"
    _ = os.write_entire_file(sibling, transmute([]byte)edited_src)

    res2 := complete_sib(e, main_path, main_src, root, at)
    defer free_symbols(&res2)
    testing.expect(t, has_completion(&res2, "sib_extra"), "an edited sibling's new decl should be offered")
    testing.expect(t, has_completion(&res2, "sib_value"), "sib_value should survive the reindex")
}

// Like resolve_def but with a caller-chosen file path, so a cross-file test can
// place the live buffer somewhere the symbol index will (correctly) exclude.
@(private = "file")
resolve_in_ws :: proc(e: ^Odin_Engine, path, source, needle, workspace: string) -> (Location, bool) {
    at := strings.index(source, needle)
    if at < 0 {
        return {}, false
    }
    req := Request{kind = .Definition, path = path, ext = ".odin", source = source, offset = at, workspace = workspace}
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
    return res.location, res.ok
}

@(test)
test_index_reflects_file_change :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // A workspace whose only on-disk file declares `helper`. The first cross-file
    // goto builds the index; a later goto (same engine) must reflect an edit to
    // that file rather than serving the decls it parsed the first time.
    dir := "thor_lang_index_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    helper := strings.concatenate({dir, "/helper.odin"}, context.temp_allocator)
    v1_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 1\n}\n"
    _ = os.write_entire_file(helper, transmute([]byte)v1_src)
    defer os.remove(helper)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc() {\n\t_ = helper()\n}\n"

    // First query: builds the index and resolves across files.
    loc, ok := resolve_in_ws(e, main_path, main_src, "helper()", dir)
    defer delete(loc.path)
    testing.expect(t, ok, "expected to resolve helper on the first query")

    // Rewrite the file so `helper` becomes `renamed`; the size changes, so the
    // stat-based validation re-parses it on the next query.
    v2_src := "package demo\n\nrenamed :: proc() -> int {\n\treturn 1\n}\n"
    _ = os.write_entire_file(helper, transmute([]byte)v2_src)

    // The old name is gone from the index...
    stale_loc, still := resolve_in_ws(e, main_path, main_src, "helper()", dir)
    defer delete(stale_loc.path)
    testing.expect(t, !still, "helper should no longer resolve after the file changed")

    // ...and the new name resolves into the same file, proving the re-parse.
    new_src := "package demo\n\nmain :: proc() {\n\t_ = renamed()\n}\n"
    loc2, ok2 := resolve_in_ws(e, main_path, new_src, "renamed()", dir)
    defer delete(loc2.path)
    testing.expect(t, ok2, "expected to resolve renamed after the file changed")
    if ok2 {
        testing.expect(t, strings.has_suffix(loc2.path, "helper.odin"), "renamed should resolve into helper.odin")
    }
}

// Resolves the definition at an absolute byte offset (member-access tests need
// the caret on the member of a `value.field`, not the first textual match).
@(private = "file")
resolve_offset :: proc(e: ^Odin_Engine, source: string, at: int, workspace := "", path := "buffer.odin") -> (Location, bool) {
    req := Request{kind = .Definition, path = path, ext = ".odin", source = source, offset = at, workspace = workspace}
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
    return res.location, res.ok
}

@(test)
test_member_typed_local :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Hover}
    odin_resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected hover on the member")
    testing.expectf(t, res.hover.text == "x: int", "member hover: got %q", res.hover.text)
}

@(test)
test_member_cross_file :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
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
test_enum_selector_completion :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `a: Axis = .` offers the enum's members as implicit selectors (the `.` is
    // already typed, so the candidates are the bare member names).
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

main :: proc() {
	a: Axis = .
	_ = a
}
`
    at := strings.index(src, "= .") + len("= .")
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected enum selector completions")
    testing.expect(t, has_completion(&res, "Horizontal"), "missing member Horizontal")
    testing.expect(t, has_completion(&res, "Vertical"), "missing member Vertical")
    for sym in res.symbols {
        if sym.name == "Horizontal" {
            testing.expectf(t, sym.kind == "enum_member", "Horizontal kind: got %q", sym.kind)
        }
    }
}

@(test)
test_enum_selector_assignment :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `a = .Ho` (reassignment of a typed var, with a prefix) filters the enum's
    // members: only Horizontal shares the `Ho` prefix.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

main :: proc() {
	a: Axis
	a = .Ho
	_ = a
}
`
    at := strings.index(src, "= .Ho") + len("= .Ho")
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected filtered enum selector completions")
    testing.expect(t, has_completion(&res, "Horizontal"), "missing member Horizontal")
    testing.expect(t, !has_completion(&res, "Vertical"), "Vertical does not share the Ho prefix")
}

// Runs a completion request just past `needle` and returns the result, for the
// implicit-selector contexts (the caret sits right after the `.`).
@(private = "file")
selector_completions :: proc(e: ^Odin_Engine, src, needle: string, res: ^Result) {
    at := strings.index(src, needle) + len(needle)
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res^ = Result{kind = .Completion}
    odin_resolve(e, &req, res)
}

@(test)
test_enum_selector_call_argument :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `f(1, .)` offers the members of the *second* parameter's enum — the argument
    // index comes from the commas before the caret.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

Mode :: enum {
	Fast,
	Slow,
}

f :: proc(m: Mode, a: Axis) {}

main :: proc() {
	f(.Fast, .)
}
`
    res: Result
    selector_completions(e, src, "f(.Fast, .", &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected enum selector completions for the argument")
    testing.expect(t, has_completion(&res, "Horizontal"), "missing member Horizontal")
    testing.expect(t, !has_completion(&res, "Fast"), "Fast belongs to the first parameter's enum")
}

@(test)
test_enum_selector_grouped_and_variadic_params :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // A grouped parameter (`a, b: Axis`) writes its type once, on the last name of
    // the group; a variadic tail (`..Axis`) answers for every argument past it.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

g :: proc(a, b: Axis) {}
h :: proc(n: int, rest: ..Axis) {}

main :: proc() {
	g(., .Vertical)
	h(1, .Horizontal, .)
}
`
    grouped: Result
    selector_completions(e, src, "g(.", &grouped)
    defer free_symbols(&grouped)
    testing.expect(t, grouped.ok, "expected completions for a grouped parameter")
    testing.expect(t, has_completion(&grouped, "Horizontal"), "grouped: missing member Horizontal")

    variadic: Result
    selector_completions(e, src, ".Horizontal, .", &variadic)
    defer free_symbols(&variadic)
    testing.expect(t, variadic.ok, "expected completions past a variadic parameter")
    testing.expect(t, has_completion(&variadic, "Vertical"), "variadic: missing member Vertical")
}

@(test)
test_enum_selector_composite_literal_field :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `Config{axis = .}` resolves the literal's struct, then that field's type.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

Config :: struct {
	axis: Axis,
	size: int,
}

main :: proc() {
	c := Config{axis = .}
	_ = c
}
`
    res: Result
    selector_completions(e, src, "axis = .", &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected enum selector completions for the literal field")
    testing.expect(t, has_completion(&res, "Horizontal"), "missing member Horizontal")
}

@(test)
test_enum_selector_return :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // A bare `.` derails the parse outright here — the repaired re-parse is what
    // finds the return statement, and with it the procedure's result type. The
    // second procedure takes slot 1 of a named result list.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

one :: proc() -> Axis {
	return .
}

two :: proc() -> (n: int, a: Axis) {
	return 0, .
}
`
    single: Result
    selector_completions(e, src, "return .", &single)
    defer free_symbols(&single)
    testing.expect(t, single.ok, "expected completions for a lone result")
    testing.expect(t, has_completion(&single, "Vertical"), "single: missing member Vertical")

    tuple: Result
    selector_completions(e, src, "return 0, .", &tuple)
    defer free_symbols(&tuple)
    testing.expect(t, tuple.ok, "expected completions for the second result slot")
    testing.expect(t, has_completion(&tuple, "Vertical"), "tuple: missing member Vertical")
}

@(test)
test_enum_selector_comparison_and_switch :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // `a == .` takes the type of the other operand; `case .` takes the type of the
    // value the switch is over. One buffer each: the repair puts a single selector
    // back together, and a second broken one swallows whatever follows it.
    comparison := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

main :: proc() {
	a: Axis
	if a == . {
	}
}
`
    cmp: Result
    selector_completions(e, comparison, "a == .", &cmp)
    defer free_symbols(&cmp)
    testing.expect(t, cmp.ok, "expected completions on the other side of a comparison")
    testing.expect(t, has_completion(&cmp, "Horizontal"), "comparison: missing member Horizontal")

    switched := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

main :: proc() {
	a: Axis
	switch a {
	case .:
	}
}
`
    sw: Result
    selector_completions(e, switched, "case .", &sw)
    defer free_symbols(&sw)
    testing.expect(t, sw.ok, "expected completions for a switch case")
    testing.expect(t, has_completion(&sw, "Vertical"), "switch: missing member Vertical")
}

@(test)
test_collection_import :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // A user-defined collection in the analyzer config: `import "shared:foo"`
    // resolves through the collection's path (relative to the workspace) into foo's dir.
    root := "thor_lang_coll_ws"
    libs := strings.concatenate({root, "/libs"}, context.temp_allocator)
    foo := strings.concatenate({libs, "/foo"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(libs)
    _ = os.make_directory(foo)

    foo_path := strings.concatenate({foo, "/foo.odin"}, context.temp_allocator)
    foo_src := "package foo\n\nbar :: proc() -> int {\n\treturn 1\n}\n"
    _ = os.write_entire_file(foo_path, transmute([]byte)foo_src)

    cfg_dir := strings.concatenate({root, "/.thor"}, context.temp_allocator)
    _ = os.make_directory(cfg_dir)
    cfg := strings.concatenate({cfg_dir, "/odin-analyzer.json"}, context.temp_allocator)
    cfg_src := "{\n\t\"collections\": [\n\t\t{ \"name\": \"shared\", \"path\": \"libs\" }\n\t]\n}\n"
    _ = os.write_entire_file(cfg, transmute([]byte)cfg_src)

    defer os.remove(root)
    defer os.remove(cfg_dir)
    defer os.remove(libs)
    defer os.remove(foo)
    defer os.remove(foo_path)
    defer os.remove(cfg)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"shared:foo\"\n\nmain :: proc() {\n\t_ = foo.bar()\n}\n"

    at := strings.index(main_src, "bar()")
    loc, ok := resolve_offset(e, main_src, at, root, main_path)
    defer delete(loc.path)
    testing.expect(t, ok, "expected the collection import to resolve foo.bar")
    if ok {
        testing.expectf(t, strings.has_suffix(loc.path, "foo.odin"), "path: got %q", loc.path)
        want := strings.index(foo_src, "bar ::")
        testing.expectf(t, loc.start == want, "collection member start: got %d, want %d", loc.start, want)
    }
}

@(test)
test_config_feature_toggle :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // The analyzer config's feature toggles are honored: enable_hover:false
    // suppresses hover, and a later edit re-enabling it is picked up (the config
    // cache is stat-invalidated, like the symbol index).
    root := "thor_lang_cfg_ws"
    cfg_dir := strings.concatenate({root, "/.thor"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(cfg_dir)
    cfg := strings.concatenate({cfg_dir, "/odin-analyzer.json"}, context.temp_allocator)
    defer os.remove(root)
    defer os.remove(cfg_dir)
    defer os.remove(cfg)

    src := "package demo\n\nscale :: proc(v: int) -> int {\n\treturn v\n}\n\nmain :: proc() {\n\t_ = scale(2)\n}\n"
    at := strings.index(src, "scale(2)")

    // Disabled: hover answers nothing.
    off_src := "{ \"enable_hover\": false }"
    _ = os.write_entire_file(cfg, transmute([]byte)off_src)
    {
        req := Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at, workspace = root}
        res := Result{kind = .Hover}
        odin_resolve(e, &req, &res)
        defer delete(res.hover.text)
        testing.expect(t, !res.ok, "enable_hover:false should suppress hover")
    }

    // Re-enabled (distinct file size forces the cache to re-read): hover answers.
    on_src := "{ \"enable_hover\": true, \"note\": \"on\" }"
    _ = os.write_entire_file(cfg, transmute([]byte)on_src)
    {
        req := Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at, workspace = root}
        res := Result{kind = .Hover}
        odin_resolve(e, &req, &res)
        defer delete(res.hover.text)
        testing.expect(t, res.ok, "enable_hover:true should restore hover")
        testing.expectf(t, res.hover.text == "scale :: proc(v: int) -> int", "hover text: got %q", res.hover.text)
    }
}

@(test)
test_package_doc :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // A `docpkg` package with a documented public proc, a public type, and a
    // @(private) proc. F3 on the `docpkg.pinged` operand renders the package: the
    // page must carry the public symbols with their doc comments and omit the
    // private one.
    root := "thor_lang_doc_ws"
    lib := strings.concatenate({root, "/docpkg"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    lib_path := strings.concatenate({lib, "/docpkg.odin"}, context.temp_allocator)
    lib_src := "package docpkg\n\n// Pings the server.\n// Returns the round-trip.\nping :: proc() -> int {\n\treturn 1\n}\n\n// A widget handle.\nWidget :: struct {\n\tid: int,\n}\n\n@(private)\nsecret :: proc() {\n}\n"
    _ = os.write_entire_file(lib_path, transmute([]byte)lib_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(lib_path)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"docpkg\"\n\nmain :: proc() {\n\t_ = docpkg.ping()\n}\n"

    at := strings.index(main_src, "docpkg.ping") // caret on the package operand
    req := Request {
        kind      = .Package_Doc,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := Result{kind = .Package_Doc}
    odin_resolve(e, &req, &res)
    defer delete(res.doc.title)
    defer delete(res.doc.path)
    defer delete(res.doc.text)

    testing.expect(t, res.ok, "expected the package to render docs")
    testing.expectf(t, res.doc.title == "package docpkg", "title: got %q", res.doc.title)
    // OLS-style Markdown: fenced Odin signatures + cleaned doc-comment prose.
    testing.expect(t, strings.contains(res.doc.text, "```odin\nping :: proc() -> int\n```"), "missing fenced proc signature")
    testing.expect(t, strings.contains(res.doc.text, "Pings the server.\nReturns the round-trip."), "doc comment should be `//`-stripped prose")
    testing.expect(t, !strings.contains(res.doc.text, "// Pings"), "the `//` markers must be stripped from the prose")
    testing.expect(t, strings.contains(res.doc.text, "Widget :: struct"), "missing public struct")
    testing.expect(t, strings.contains(res.doc.text, "A widget handle."), "missing struct doc prose")
    testing.expect(t, !strings.contains(res.doc.text, "secret"), "private proc must be omitted")
}

@(test)
test_member_call_result :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = dot}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)
    testing.expect(t, !res.ok, "a self-referential binding must not infer a type")
}

@(test)
test_member_shadowed_binding :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected member completions on a call result")
    testing.expect(t, has_completion(&res, "x"), "missing field x")
    testing.expect(t, has_completion(&res, "y"), "missing field y")
}

// A Backend that parks inside `resolve` until the test releases it, so a cancel
// can be observed landing mid-flight. Counters are touched from both the worker
// and the test thread, hence the atomics.
@(private = "file")
Probe :: struct {
    started:   int,
    release:   bool,
    cancelled: int, // resolve calls that saw the cancellation flag
    resolved:  int, // resolve calls that ran to completion
}

@(private = "file")
probe_handles :: proc(data: rawptr, ext: string) -> bool {
    return ext == ".probe"
}

@(private = "file")
probe_resolve :: proc(data: rawptr, req: ^Request, res: ^Result) {
    p := cast(^Probe) data
    sync.atomic_add(&p.started, 1)
    for !sync.atomic_load(&p.release) {
        time.sleep(time.Millisecond)
    }
    if request_cancelled(req) {
        sync.atomic_add(&p.cancelled, 1)
        return
    }
    sync.atomic_add(&p.resolved, 1)
    res.ok = true
}

@(private = "file")
probe_backend :: proc(p: ^Probe) -> Backend {
    return Backend{data = p, name = "probe", handles = probe_handles, resolve = probe_resolve}
}

// Spins (bounded, so a wedged worker fails the test instead of hanging it) until
// an atomic counter reaches `want`.
@(private = "file")
wait_for :: proc(counter: ^int, want: int) -> bool {
    for _ in 0 ..< 2000 {
        if sync.atomic_load(counter) >= want {
            return true
        }
        time.sleep(time.Millisecond)
    }
    return false
}

@(private = "file")
count_results :: proc(user: rawptr, res: ^Result) {
    n := cast(^int) user
    n^ += 1
}

// Drains every in-flight job, counting the results that reached the handler.
@(private = "file")
drain_manager :: proc(m: ^Manager) -> int {
    delivered := 0
    for manager_busy(m) {
        manager_dispatch(m, &delivered, count_results)
        time.sleep(time.Millisecond)
    }
    manager_dispatch(m, &delivered, count_results)
    return delivered
}

@(test)
test_cancel_drops_result :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    id := manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, id != 0, "expected the probe backend to claim .probe")
    testing.expect(t, wait_for(&p.started, 1), "worker never started")

    // Cancel while the worker is parked, then let it run on to its check.
    testing.expect(t, manager_cancel(&m, id), "expected the in-flight id to be cancellable")
    sync.atomic_store(&p.release, true)

    delivered := drain_manager(&m)
    testing.expect(t, sync.atomic_load(&p.cancelled) == 1, "the backend did not observe the cancellation")
    testing.expect(t, sync.atomic_load(&p.resolved) == 0, "a cancelled request should not produce a result")
    testing.expectf(t, delivered == 0, "a cancelled result must not reach the handler (got %d)", delivered)

    // The job is reaped, so its id is no longer cancellable.
    testing.expect(t, !manager_cancel(&m, id), "a reaped id should not be cancellable")
}

@(test)
test_request_latest_supersedes :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    // The first request parks in the backend; the second supersedes it.
    first := manager_request(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, wait_for(&p.started, 1), "first worker never started")
    second := manager_request_latest(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, first != second, "expected a fresh id for the replacement")
    sync.atomic_store(&p.release, true)

    delivered := drain_manager(&m)
    testing.expect(t, sync.atomic_load(&p.cancelled) == 1, "the superseded request should have been cancelled")
    testing.expect(t, sync.atomic_load(&p.resolved) == 1, "the replacement request should have resolved")
    testing.expectf(t, delivered == 1, "only the latest result should reach the handler (got %d)", delivered)
}

@(test)
test_cancel_kind_leaves_others :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    hover := manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "")
    defn := manager_request(&m, .Definition, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, wait_for(&p.started, 2), "both workers never started")

    // Cancelling by kind must not touch a request of a different kind.
    testing.expectf(t, manager_cancel_kind(&m, .Hover) == 1, "expected exactly one Hover cancelled")
    testing.expect(t, hover != defn, "expected distinct ids")
    sync.atomic_store(&p.release, true)

    delivered := drain_manager(&m)
    testing.expect(t, sync.atomic_load(&p.cancelled) == 1, "only the Hover should have been cancelled")
    testing.expect(t, sync.atomic_load(&p.resolved) == 1, "the Definition should have resolved")
    testing.expectf(t, delivered == 1, "only the Definition result should be delivered (got %d)", delivered)
}

@(test)
test_pool_caps_concurrency :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    n := manager_worker_count(&m)
    testing.expectf(t, n >= WORKERS_MIN && n <= WORKERS_MAX, "pool size %d out of bounds", n)

    // More requests than there are workers: the surplus waits in the queue
    // instead of spawning a thread each.
    total := n + 3
    for _ in 0 ..< total {
        testing.expect(t, manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "") != 0, "dispatch failed")
    }
    testing.expect(t, wait_for(&p.started, n), "the pool never filled")
    time.sleep(20 * time.Millisecond) // long enough for a stray worker to have started
    testing.expectf(t, sync.atomic_load(&p.started) == n, "%d jobs ran at once, the pool caps at %d", sync.atomic_load(&p.started), n)

    // Releasing the parked jobs frees the workers, which then drain the queue.
    sync.atomic_store(&p.release, true)
    delivered := drain_manager(&m)
    testing.expectf(t, sync.atomic_load(&p.started) == total, "expected all %d jobs to run eventually", total)
    testing.expectf(t, delivered == total, "expected %d results (got %d)", total, delivered)
}

@(test)
test_queued_job_cancelled_before_it_starts :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))

    n := manager_worker_count(&m)
    for _ in 0 ..< n {
        manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "")
    }
    testing.expect(t, wait_for(&p.started, n), "the pool never filled")

    // This one has no worker yet, so cancelling it must keep it out of the
    // backend entirely rather than have `resolve` poll and return.
    queued := manager_request(&m, .Hover, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, manager_cancel(&m, queued), "a queued job should be cancellable")

    sync.atomic_store(&p.release, true)
    delivered := drain_manager(&m)
    testing.expectf(t, sync.atomic_load(&p.started) == n, "the cancelled job should never have reached the backend")
    testing.expectf(t, sync.atomic_load(&p.cancelled) == 0, "the backend should not have observed the cancellation itself")
    testing.expectf(t, delivered == n, "expected %d results (got %d)", n, delivered)
}

@(test)
test_debounce_collapses_burst :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))
    sync.atomic_store(&p.release, true) // nothing to park for here

    // A burst of keystrokes: each queues a request, none dispatches yet.
    first := manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    last: u64
    for _ in 0 ..< 4 {
        last = manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    }
    testing.expect(t, first != last, "each keystroke should reserve a fresh id")
    testing.expect(t, manager_debounce_pending(&m, .Completion), "the last request should still be queued")
    testing.expect(t, !manager_busy(&m), "a debounced request must not dispatch before its delay")
    testing.expect(t, sync.atomic_load(&p.started) == 0, "no worker should have run during the burst")

    testing.expectf(t, manager_flush_debounced(&m, force = true) == 1, "the burst should flush as one request")
    testing.expect(t, !manager_debounce_pending(&m, .Completion), "the slot should be empty after a flush")

    delivered := drain_manager(&m)
    testing.expectf(t, sync.atomic_load(&p.started) == 1, "expected exactly one worker for the whole burst")
    testing.expectf(t, delivered == 1, "expected one result from the burst (got %d)", delivered)
}

@(test)
test_debounce_delay_elapses :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))
    sync.atomic_store(&p.release, true)

    manager_request_debounced(&m, .Signature_Help, "a.probe", ".probe", "", 0, 0, "", delay = time.Millisecond)
    // Not yet due: the unforced flush leaves it queued.
    testing.expectf(t, manager_flush_debounced(&m) == 0, "flushed before the delay elapsed")

    for _ in 0 ..< 2000 {
        if manager_flush_debounced(&m) == 1 {
            break
        }
        time.sleep(time.Millisecond)
    }
    testing.expect(t, !manager_debounce_pending(&m, .Signature_Help), "the delay elapsed but nothing dispatched")

    delivered := drain_manager(&m)
    testing.expectf(t, delivered == 1, "expected the debounced request's result (got %d)", delivered)
}

@(test)
test_debounce_cancelled_never_dispatches :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))
    sync.atomic_store(&p.release, true)

    // Cancelling by kind drops the queued request...
    manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    testing.expectf(t, manager_cancel_kind(&m, .Completion) == 1, "expected the queued request to be cancelled")
    testing.expectf(t, manager_flush_debounced(&m, force = true) == 0, "a cancelled request must not dispatch")

    // ...as does cancelling it by its reserved id.
    id := manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, manager_cancel(&m, id), "a queued request should be cancellable by id")
    testing.expectf(t, manager_flush_debounced(&m, force = true) == 0, "a cancelled request must not dispatch")

    // An explicit request supersedes a queued one of the same kind: only the
    // explicit one runs, so the debounced answer can't land on top of it.
    queued := manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    now := manager_request_latest(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    testing.expect(t, queued != now, "expected a fresh id for the explicit request")
    testing.expectf(t, manager_flush_debounced(&m, force = true) == 0, "the queued request should have been dropped")

    delivered := drain_manager(&m)
    testing.expectf(t, sync.atomic_load(&p.started) == 1, "only the explicit request should have run")
    testing.expectf(t, delivered == 1, "expected only the explicit request's result (got %d)", delivered)
}

@(test)
test_debounce_slots_are_per_kind :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    p := Probe{}
    manager_register(&m, probe_backend(&p))
    sync.atomic_store(&p.release, true)

    manager_request_debounced(&m, .Completion, "a.probe", ".probe", "", 0, 0, "")
    manager_request_debounced(&m, .Signature_Help, "a.probe", ".probe", "", 0, 0, "")
    testing.expectf(t, manager_cancel_kind(&m, .Completion) == 1, "expected one queued Completion cancelled")
    testing.expect(t, manager_debounce_pending(&m, .Signature_Help), "another kind's slot must be untouched")

    testing.expectf(t, manager_flush_debounced(&m, force = true) == 1, "only Signature_Help should dispatch")
    delivered := drain_manager(&m)
    testing.expectf(t, delivered == 1, "expected only the Signature_Help result (got %d)", delivered)
}

@(test)
test_cancelled_request_answers_nothing :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // A workspace whose index a first, live request builds.
    dir := "thor_lang_cancel_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    helper := strings.concatenate({dir, "/helper.odin"}, context.temp_allocator)
    helper_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 1\n}\n"
    _ = os.write_entire_file(helper, transmute([]byte)helper_src)
    defer os.remove(helper)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc() {\n\t_ = helper()\n}\n"

    loc, ok := resolve_in_ws(e, main_path, main_src, "helper()", dir)
    defer delete(loc.path)
    testing.expect(t, ok, "expected to resolve helper before cancelling anything")

    // The same request, already cancelled, answers nothing at all.
    cancelled := true
    req := Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = strings.index(main_src, "helper()"),
        workspace = dir,
        cancel    = &cancelled,
    }
    res := Result{kind = .Definition}
    odin_resolve(e, &req, &res)
    testing.expect(t, !res.ok, "a cancelled request must not produce a location")
    testing.expect(t, res.location.path == "", "a cancelled request must not allocate a result")

    // ...and it left the engine's index usable: the next live request still
    // resolves. (An abandoned index walk skips the prune for exactly this
    // reason — pruning against a partial `seen` set would drop live files.)
    loc2, ok2 := resolve_in_ws(e, main_path, main_src, "helper()", dir)
    defer delete(loc2.path)
    testing.expect(t, ok2, "a cancelled request must not damage the symbol index")
}

@(test)
test_member_using_embedded :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected member completions on the embedding struct")
    testing.expect(t, has_completion(&res, "y"), "missing the struct's own field y")
    testing.expect(t, has_completion(&res, "base"), "missing the embedded field itself")
    testing.expect(t, has_completion(&res, "x"), "missing the embedded struct's field x")
}

@(test)
test_member_container_index :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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
    req := Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := Result{kind = .Completion}
    odin_resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, !has_completion(&res, "x"), "a container must not offer its element's fields")
    testing.expect(t, !has_completion(&res, "y"), "a container must not offer its element's fields")
}

@(test)
test_member_call_result_container :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

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
    e := odin_engine_create()
    defer odin_destroy(e)

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

@(test)
test_source_edit_spans :: proc(t: ^testing.T) {
    expect_edit :: proc(t: ^testing.T, label: string, e: ts.Input_Edit, start, old_end, new_end: u32) {
        testing.expectf(
            t,
            e.start_byte == start && e.old_end_byte == old_end && e.new_end_byte == new_end,
            "%s: got %d..%d -> %d, want %d..%d -> %d",
            label,
            e.start_byte,
            e.old_end_byte,
            e.new_end_byte,
            start,
            old_end,
            new_end,
        )
    }

    // An insertion is a zero-width span in the old text, a deletion in the new.
    expect_edit(t, "insert", source_edit("abcdef", "abcXYZdef"), 3, 3, 6)
    expect_edit(t, "delete", source_edit("abcXYZdef", "abcdef"), 3, 6, 3)
    expect_edit(t, "replace", source_edit("abcXYZdef", "abcQdef"), 3, 6, 4)
    expect_edit(t, "append", source_edit("abc", "abcdef"), 3, 3, 6)
    expect_edit(t, "prepend", source_edit("def", "abcdef"), 0, 0, 3)
    // Nothing in common: the span is the whole buffer.
    expect_edit(t, "swap", source_edit("abc", "xyz"), 0, 3, 3)
    // Editing one byte of a multi-byte rune widens the span to the whole rune,
    // so neither end lands mid-rune.
    expect_edit(t, "utf8", source_edit("aéb", "aèb"), 1, 3, 3)
}

@(test)
test_incremental_reparse_tracks_edits :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // Every request after the first re-parses off this path's resident tree, so
    // a mis-described edit span would misplace the declaration.
    expect_add :: proc(t: ^testing.T, e: ^Odin_Engine, src, label: string) {
        loc, ok := resolve_offset(e, src, strings.index(src, "add(1, 2)"))
        defer delete(loc.path)
        testing.expectf(t, ok, "%s: expected to resolve the call to add", label)
        if ok {
            want := strings.index(src, "add ::")
            testing.expectf(t, loc.start == want, "%s: got start %d, want %d", label, loc.start, want)
        }
    }

    header := "package demo\n\n"
    body := "add :: proc(x: int, y: int) -> int {\n\treturn x + y\n}\n\nmain :: proc() {\n\ttotal := add(1, 2)\n\t_ = total\n}\n"
    first := strings.concatenate({header, body}, context.temp_allocator)

    // Cold: a full parse that seeds the cache.
    expect_add(t, e, first, "cold parse")

    // An insertion above shifts every later offset; removing it shifts them back.
    inserted := strings.concatenate({header, "MAX :: 64\n\n", body}, context.temp_allocator)
    expect_add(t, e, inserted, "insert above")
    expect_add(t, e, first, "delete above")

    // A replacement inside the body leaves the declaration where it is.
    swapped, _ := strings.replace(first, "return x + y", "return y + x", 1, context.temp_allocator)
    expect_add(t, e, swapped, "replace in body")

    // Renaming the target itself edits both the declaration and the call.
    renamed, _ := strings.replace_all(first, "add", "sum", context.temp_allocator)
    loc, ok := resolve_offset(e, renamed, strings.index(renamed, "sum(1, 2)"))
    defer delete(loc.path)
    testing.expect(t, ok, "expected the renamed symbol to resolve")
    if ok {
        want := strings.index(renamed, "sum ::")
        testing.expectf(t, loc.start == want, "rename: got start %d, want %d", loc.start, want)
    }
}

@(test)
test_tree_cache_is_per_path :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // Two buffers resident at once: alternating between them must not diff one
    // against the other's source.
    a := "package demo\n\nalpha :: proc() -> int {\n\treturn 1\n}\n\nuse_a :: proc() {\n\t_ = alpha()\n}\n"
    b := "package demo\n\nbeta :: proc() -> int {\n\treturn 2\n}\n\nuse_b :: proc() {\n\t_ = beta()\n}\n"

    for round in 0 ..< 3 {
        la, oka := resolve_offset(e, a, strings.index(a, "alpha()"), "", "a.odin")
        defer delete(la.path)
        testing.expectf(t, oka, "round %d: expected alpha to resolve", round)
        if oka {
            want := strings.index(a, "alpha ::")
            testing.expectf(t, la.start == want, "round %d alpha: got %d, want %d", round, la.start, want)
        }

        lb, okb := resolve_offset(e, b, strings.index(b, "beta()"), "", "b.odin")
        defer delete(lb.path)
        testing.expectf(t, okb, "round %d: expected beta to resolve", round)
        if okb {
            want := strings.index(b, "beta ::")
            testing.expectf(t, lb.start == want, "round %d beta: got %d, want %d", round, lb.start, want)
        }
    }
}

@(test)
test_tree_cache_evicts_and_reparses :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    // More buffers than slots: the least recently used is retired, and its next
    // request parses cold rather than off a freed tree.
    src := "package demo\n\ntarget :: proc() -> int {\n\treturn 1\n}\n\nuse :: proc() {\n\t_ = target()\n}\n"
    at := strings.index(src, "target()")
    want := strings.index(src, "target ::")

    for i in 0 ..< TREE_CACHE_SLOTS + 2 {
        path := fmt.tprintf("file%d.odin", i)
        loc, ok := resolve_offset(e, src, at, "", path)
        defer delete(loc.path)
        testing.expectf(t, ok, "%s: expected target to resolve", path)
        if ok {
            testing.expectf(t, loc.start == want, "%s: got %d, want %d", path, loc.start, want)
        }
    }

    loc, ok := resolve_offset(e, src, at, "", "file0.odin")
    defer delete(loc.path)
    testing.expect(t, ok, "expected the evicted buffer to re-parse and resolve")
    testing.expectf(t, loc.start == want, "evicted: got %d, want %d", loc.start, want)
}

@(test)
test_incremental_tree_matches_cold_parse :: proc(t: ^testing.T) {
    e := odin_engine_create()
    defer odin_destroy(e)

    parser := ts.parser_new()
    defer ts.parser_delete(parser)
    ts.parser_set_language(parser, e.language)

    // Walk one buffer through a series of edits and, after each, compare the
    // incrementally re-parsed tree against a parse of the same text from
    // scratch. A mis-described edit span shows up here as a divergent tree even
    // when a lookup happens to land on the right offset anyway.
    steps := []string {
        `package demo

add :: proc(x: int) -> int {
	return x
}
`,
        `package demo

add :: proc(x: int) -> int {
	return x + 1
}
`,
        `package demo

MAX :: 64

add :: proc(x: int) -> int {
	return x + 1
}
`,
        `package demo

MAX :: 64

add :: proc(x, y: int) -> int {
	return x + y
}
`,
        `package demo

MAX :: 64

sum :: proc(x, y: int) -> int {
	return x + y
}
`,
        `package demo

sum :: proc(x, y: int) -> int {
	return x + y
}
`,
        `package demo

Point :: struct {
	x: int,
}
`,
        // A multi-byte rune edited one byte in: the span must cover the whole rune.
        `package demo

Point :: struct {
	x: int,
	label: string, // naïve
}
`,
        `package demo

Point :: struct {
	x: int,
	label: string, // naive
}
`,
    }

    for src, i in steps {
        incremental := tree_for_source(e, parser, "buffer.odin", src)
        defer ts.tree_delete(incremental)
        cold := ts.parser_parse_string(parser, src)
        defer ts.tree_delete(cold)

        got := ts.node_string(ts.tree_root_node(incremental))
        defer libc.free(rawptr(got))
        want := ts.node_string(ts.tree_root_node(cold))
        defer libc.free(rawptr(want))

        testing.expectf(
            t,
            string(got) == string(want),
            "step %d: incremental tree diverged\n got: %s\nwant: %s",
            i,
            got,
            want,
        )
    }
}
