package lang

import "core:os"
import "core:strings"
import "core:testing"

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
