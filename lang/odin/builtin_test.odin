// The implicit scope: bare names the toolchain declares (`len`, `append`,
// `make`), which no file and no package in the workspace does. These read the
// standard library beside the compiler that built the test, the way every other
// stdlib test here does.
package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

// Text of the file a location points at, from the offset it names, so a test can
// assert the jump landed on the declaring identifier.
@(private = "file")
text_at :: proc(loc: lang.Location) -> string {
    // Through source_read: offsets are in the collapsed-CRLF space, and the
    // toolchain's own sources are CRLF in a Windows checkout.
    source, ok := source_read(loc.path)
    if !ok {
        return ""
    }
    return source[clamp(loc.start, 0, len(source)):]
}

// Go-to-definition on a bare builtin jumps into base:builtin.
@(test)
test_definition_builtin_bare :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

count :: proc(xs: []int) -> int {
	return len(xs)
}
`
    loc, ok := resolve_def(e, src, "len(")
    defer delete(loc.path)

    testing.expect(t, ok, "expected the builtin len to resolve")
    if ok {
        testing.expectf(t, strings.has_suffix(loc.path, "builtin.odin"), "path: got %q", loc.path)
        testing.expect(t, strings.has_prefix(text_at(loc), "len"), "expected the jump to land on the declaration")
    }
}

// Hover on a bare builtin shows the toolchain's own declaration.
@(test)
test_hover_builtin_bare :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nmain :: proc() {\n\tpanic(\"no\")\n}\n"
    req := lang.Request {
        kind   = .Hover,
        path   = "app/main.odin",
        ext    = ".odin",
        source = src,
        offset = strings.index(src, "panic"),
    }
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected the builtin panic to resolve")
    if res.ok {
        // The `@builtin` attribute leads the declaration and is kept, like any
        // other attribute a hover shows.
        testing.expectf(t, strings.contains(res.hover.text, "panic :: proc("), "hover text: got %q", res.hover.text)
    }
}

// A builtin procedure group reaches through to its members, like any other group.
@(test)
test_definition_builtin_group :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

add :: proc(xs: ^[dynamic]int) {
	append(xs, 1)
}
`
    res := definition_at(e, src, "append(")
    defer free_definition(&res)

    testing.expect(t, res.ok, "expected the builtin append to resolve")
    found := false
    for sym in res.symbols {
        if sym.name != "append_elem" {
            continue
        }
        found = true
        // The members come out of the cache rather than a walk of base:runtime,
        // so the jump target it recorded is what a picker row would use.
        testing.expectf(t, strings.has_suffix(sym.path, "core_builtin.odin"), "path: got %q", sym.path)
        testing.expect(t, sym.line > 0, "expected a line for the member")
        testing.expect(
            t,
            strings.has_prefix(text_at(lang.Location{path = sym.path, start = sym.offset}), "append_elem"),
            "expected the member offset to land on its declaration",
        )
    }
    testing.expectf(t, found, "expected append_elem among %d candidates", len(res.symbols))
}

// A name the file declares itself shadows the builtin of the same name.
@(test)
test_definition_builtin_shadowed :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

len :: proc(xs: []int) -> int {
	return 0
}

use :: proc(xs: []int) -> int {
	return len(xs)
}
`
    loc, ok := resolve_def(e, src, "len(xs)\n}")
    defer delete(loc.path)

    testing.expect(t, ok, "expected the local len to resolve")
    if ok {
        testing.expectf(t, loc.path == "buffer.odin", "expected the file's own len, got %q", loc.path)
    }
}

// base:runtime is an ordinary package apart from what it marks `@(builtin)`: a
// name it exports without the marker needs an import and is not reachable bare.
@(test)
test_definition_runtime_needs_import :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nmain :: proc() {\n\tx: Raw_Dynamic_Array\n}\n"
    loc, ok := resolve_def(e, src, "Raw_Dynamic_Array")
    defer delete(loc.path)

    testing.expectf(t, !ok, "expected no definition, got %q", loc.path)
}

// Signature help signs a builtin call, the group once per member.
@(test)
test_signature_help_builtin :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

count :: proc(xs: []int) -> int {
	return len(xs)
}
`
    sig, ok := sig_help(e, src, strings.index(src, "len(") + len("len("))
    defer sig_free(sig)

    testing.expect(t, ok, "expected a signature for the builtin len")
    if ok {
        label, _ := sig_active(sig)
        testing.expectf(t, strings.has_prefix(label, "len :: proc("), "label: got %q", label)
    }
}

// Completion offers the implicit scope, and only the part of base:runtime that
// is in it.
@(test)
test_completion_builtin :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nmain :: proc() {\n\tappe\n}\n"
    req := lang.Request {
        kind   = .Completion,
        path   = "app/main.odin",
        ext    = ".odin",
        source = src,
        offset = strings.index(src, "appe") + len("appe"),
    }
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, has_completion(&res, "append"), "expected the builtin append")
    testing.expect(t, has_completion(&res, "append_elem"), "expected the builtin append_elem")
}

// A base:runtime export without the `@(builtin)` marker is not offered bare.
@(test)
test_completion_builtin_skips_unmarked :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\nmain :: proc() {\n\tRaw_\n}\n"
    req := lang.Request {
        kind   = .Completion,
        path   = "app/main.odin",
        ext    = ".odin",
        source = src,
        offset = strings.index(src, "Raw_") + len("Raw_"),
    }
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, !has_completion(&res, "Raw_Dynamic_Array"), "Raw_Dynamic_Array needs an import")
}
