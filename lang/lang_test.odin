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
