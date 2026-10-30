package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

// Runs a References request at `at` in `source`.
@(private = "file")
refs_offset :: proc(e: ^Engine, source: string, at: int, workspace := "", path := "buffer.odin") -> lang.Result {
    req := lang.Request {
        kind      = .References,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = at,
        workspace = workspace,
    }
    res := lang.Result{kind = .References}
    resolve(e, &req, &res)
    return res
}

// Runs a References request at the first occurrence of `needle` in `source`, plus `skip` bytes.
@(private = "file")
refs_at :: proc(e: ^Engine, source, needle: string, workspace := "", path := "buffer.odin", skip := 0) -> lang.Result {
    return refs_offset(e, source, strings.index(source, needle) + skip, workspace, path)
}

// Runs a Rename request at the first occurrence of `needle` in `source`, plus `skip` bytes.
@(private = "file")
rename_at :: proc(e: ^Engine, source, needle, new_name: string, workspace := "", path := "buffer.odin", skip := 0) -> lang.Result {
    req := lang.Request {
        kind      = .Rename,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = strings.index(source, needle) + skip,
        workspace = workspace,
        new_name  = new_name,
    }
    res := lang.Result{kind = .Rename}
    resolve(e, &req, &res)
    return res
}

@(private = "file")
free_refs :: proc(res: ^lang.Result) {
    for sym in res.symbols {
        delete(sym.name)
        delete(sym.kind)
        delete(sym.signature)
        delete(sym.path)
    }
    delete(res.symbols)
    res^ = {}
}

@(private = "file")
free_edits :: proc(res: ^lang.Result) {
    for edit in res.edits {
        delete(edit.path)
        delete(edit.old_text)
        delete(edit.new_text)
    }
    delete(res.edits)
    res^ = {}
}

// The offsets of a reference result, in order. Temp-allocated.
@(private = "file")
ref_offsets :: proc(res: ^lang.Result) -> []int {
    out := make([]int, len(res.symbols), context.temp_allocator)
    for sym, i in res.symbols {
        out[i] = sym.offset
    }
    return out
}

// The number of rows of a result whose path ends in `file`.
@(private = "file")
count_in :: proc(res: ^lang.Result, file: string) -> int {
    n := 0
    for sym in res.symbols {
        if strings.has_suffix(sym.path, file) {
            n += 1
        }
    }
    for edit in res.edits {
        if strings.has_suffix(edit.path, file) {
            n += 1
        }
    }
    return n
}

@(private = "file")
expect_offsets :: proc(t: ^testing.T, res: ^lang.Result, want: []int, loc := #caller_location) {
    got := ref_offsets(res)
    testing.expectf(t, len(got) == len(want), "refs: got %v, want %v", got, want, loc = loc)
    if len(got) != len(want) {
        return
    }
    for w, i in want {
        testing.expectf(t, got[i] == w, "ref %d: got %d, want %d", i, got[i], w, loc = loc)
    }
}

@(test)
test_references_supported :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    testing.expect(t, supports(e, ".odin", .References))
    testing.expect(t, supports(e, ".odin", .Rename))
}

// The uses of a local stay in its procedure; the declaration is not one of them.
@(test)
test_references_local :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

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
    res := refs_at(e, src, "total :=")
    defer free_refs(&res)
    testing.expect(t, res.ok, "expected references to the local total")
    first := strings.index(src, "total + total")
    expect_offsets(t, &res, {first, first + len("total + ")})
    for sym in res.symbols {
        testing.expectf(t, sym.path == "buffer.odin", "path: got %q", sym.path)
        testing.expectf(t, sym.kind == "reference", "kind: got %q", sym.kind)
        testing.expectf(t, sym.line == 5, "line: got %d", sym.line)
        testing.expectf(t, sym.signature == "return total + total", "signature: got %q", sym.signature)
    }
}

// A use above a short declaration names the file-scope constant, not the local.
@(test)
test_references_skip_use_above_declaration :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

count :: 0

use :: proc() -> int {
	_ = count
	count := 1
	return count
}
`
    res := refs_at(e, src, "count := 1")
    defer free_refs(&res)
    testing.expect(t, res.ok, "expected references to the local count")
    expect_offsets(t, &res, {strings.index(src, "count\n}")})

    res2 := refs_at(e, src, "count ::")
    defer free_refs(&res2)
    expect_offsets(t, &res2, {strings.index(src, "count\n\tcount")})
}

// An inner block that declares the name again hides the outer local.
@(test)
test_references_local_shadowed_in_inner_block :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

use :: proc() -> int {
	total := 1
	{
		total := 2
		_ = total
	}
	return total
}
`
    res := refs_at(e, src, "total := 1")
    defer free_refs(&res)
    expect_offsets(t, &res, {strings.index(src, "total\n}")})
}

// `b.total` is a field, not the local of the same name.
@(test)
test_references_skip_member_of_a_value :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Box :: struct {
	total: int,
}

use :: proc(b: Box) -> int {
	total := 1
	return total + b.total
}
`
    res := refs_at(e, src, "total := 1")
    defer free_refs(&res)
    expect_offsets(t, &res, {strings.index(src, "total + b.total")})
}

// A file-scope declaration is used in the buffer and in a sibling on disk.
@(test)
test_references_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    use_src := "package demo\n\nrun :: proc() {\n\t_ = helper()\n\t_ = helper()\n}\n"
    root := fixture(t, "refs_cross_file", {{"use.odin", use_src}})
    defer os.remove_all(root)

    main_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n\nmain :: proc() {\n\t_ = helper()\n}\n"
    main_path := fixture_path(root, "main.odin")
    res := refs_at(e, main_src, "helper ::", root, main_path)
    defer free_refs(&res)
    testing.expect(t, res.ok, "expected references to helper")
    testing.expectf(t, len(res.symbols) == 3, "ref count: got %d", len(res.symbols))
    testing.expectf(t, count_in(&res, "main.odin") == 1, "refs in main.odin: got %d", count_in(&res, "main.odin"))
    testing.expectf(t, count_in(&res, "use.odin") == 2, "refs in use.odin: got %d", count_in(&res, "use.odin"))

    // From a use in the buffer the answer is the same.
    res2 := refs_at(e, main_src, "helper()", root, main_path)
    defer free_refs(&res2)
    testing.expectf(t, len(res2.symbols) == 3, "ref count from a use: got %d", len(res2.symbols))
}

// A second search reads the files of the package from the query database, not from disk.
@(test)
test_references_reuse_the_parses :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    use_src := "package demo\n\nrun :: proc() {\n\t_ = helper()\n}\n"
    root := fixture(t, "refs_reuse", {{"use.odin", use_src}})
    defer os.remove_all(root)

    main_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n"
    main_path := fixture_path(root, "main.odin")
    res := refs_at(e, main_src, "helper ::", root, main_path)
    defer free_refs(&res)
    testing.expectf(t, len(res.symbols) == 1, "ref count: got %d", len(res.symbols))
    first := db_stats(e)

    res2 := refs_at(e, main_src, "helper ::", root, main_path)
    defer free_refs(&res2)
    testing.expectf(t, len(res2.symbols) == 1, "ref count again: got %d", len(res2.symbols))
    second := db_stats(e)
    testing.expect_value(t, second.reads, first.reads)
    testing.expect_value(t, second.parses, first.parses)
    testing.expect_value(t, second.reparses, first.reparses)
}

// A sibling written after the first request counts in the next one.
@(test)
test_references_sibling_added_later :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := fixture(t, "refs_sibling_later", {{"decoy.odin", "package demo\n\nunrelated :: proc() {}\n"}})
    defer os.remove_all(root)

    main_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n\nmain :: proc() {\n\t_ = helper()\n}\n"
    main_path := fixture_path(root, "main.odin")
    res := refs_at(e, main_src, "helper ::", root, main_path)
    defer free_refs(&res)
    testing.expectf(t, len(res.symbols) == 1, "ref count before: got %d", len(res.symbols))

    use_src := "package demo\n\nrun :: proc() {\n\t_ = helper()\n\t_ = helper()\n}\n"
    if err := os.write_entire_file(fixture_path(root, "use.odin"), transmute([]byte)use_src); err != nil {
        testing.fail_now(t, "could not write the sibling")
    }
    notify(e, .Saved, fixture_path(root, "use.odin"), ".odin", "", 0)
    res2 := refs_at(e, main_src, "helper ::", root, main_path)
    defer free_refs(&res2)
    testing.expectf(t, len(res2.symbols) == 3, "ref count after: got %d", len(res2.symbols))
    testing.expectf(t, count_in(&res2, "use.odin") == 2, "refs in use.odin: got %d", count_in(&res2, "use.odin"))
}

// Two packages: `zapp` declares and uses `shared`; `alib` declares its own `shared`, uses it, and in
// a second file calls zapp's through an import.
@(private = "file")
two_packages :: proc(t: ^testing.T, name: string) -> string {
    return fixture(t, name, {
        {"zapp/helper.odin", "package app\n\nshared :: proc(n: int) -> int {\n\treturn n\n}\n\nagain :: proc() -> int {\n\treturn shared(2)\n}\n"},
        {"alib/far.odin", "package alib\n\nshared :: proc(s: string) -> string {\n\treturn s\n}\n\nnear :: proc() -> string {\n\treturn shared(\"x\")\n}\n"},
        {"alib/uses_app.odin", USES_APP_SRC},
    })
}

@(private = "file")
USES_APP_SRC :: "package alib\n\nimport app \"../zapp\"\n\nrun :: proc() -> int {\n\treturn app.shared(3)\n}\n"

// A bare name reaches its own package; a qualified use in another package counts too.
@(test)
test_references_bound_to_their_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := two_packages(t, "refs_two_packages")
    defer os.remove_all(root)

    src := "package app\n\nmain :: proc() {\n\t_ = shared(1)\n}\n"
    res := refs_at(e, src, "shared(1)", root, fixture_path(root, "zapp/main.odin"))
    defer free_refs(&res)
    testing.expect(t, res.ok, "expected references to app's shared")
    testing.expectf(t, count_in(&res, "main.odin") == 1, "refs in the buffer: got %d", count_in(&res, "main.odin"))
    testing.expectf(t, count_in(&res, "helper.odin") == 1, "refs in helper.odin: got %d", count_in(&res, "helper.odin"))
    testing.expectf(t, count_in(&res, "uses_app.odin") == 1, "refs in uses_app.odin: got %d", count_in(&res, "uses_app.odin"))
    testing.expectf(t, count_in(&res, "far.odin") == 0, "alib's shared is another declaration")
    testing.expectf(t, len(res.symbols) == 3, "ref count: got %d", len(res.symbols))
}

// The caret on `app.shared` names zapp's declaration, not alib's.
@(test)
test_references_from_a_qualified_use :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := two_packages(t, "refs_qualified_use")
    defer os.remove_all(root)

    res := refs_at(e, USES_APP_SRC, "app.shared", root, fixture_path(root, "alib/uses_app.odin"), len("app."))
    defer free_refs(&res)
    testing.expect(t, res.ok, "expected references to app's shared")
    testing.expectf(t, count_in(&res, "far.odin") == 0, "alib's shared is another declaration")
    testing.expectf(t, count_in(&res, "uses_app.odin") == 1, "refs in the buffer: got %d", count_in(&res, "uses_app.odin"))
    testing.expectf(t, count_in(&res, "helper.odin") == 1, "refs in helper.odin: got %d", count_in(&res, "helper.odin"))
    testing.expectf(t, len(res.symbols) == 2, "ref count: got %d", len(res.symbols))
}

// The uses of an import alias stay in the file that imports.
@(test)
test_references_import_alias_stays_in_its_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    other_src := "package demo\n\nimport \"core:fmt\"\n\nrun :: proc() {\n\tfmt.println(1)\n}\n"
    root := fixture(t, "refs_import_alias", {{"other.odin", other_src}})
    defer os.remove_all(root)

    src := "package demo\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(2)\n\tfmt.println(3)\n}\n"
    res := refs_at(e, src, "fmt.println", root, fixture_path(root, "main.odin"))
    defer free_refs(&res)
    testing.expect(t, res.ok, "expected the uses of the alias")
    testing.expectf(t, count_in(&res, "other.odin") == 0, "an alias use leaked into other.odin")
    first := strings.index(src, "fmt.println")
    expect_offsets(t, &res, {first, first + len("fmt.println(2)\n\t")})
}

// An enum member: `.Red`, `Color.Red` and `pkg.Color.Red` count; another type's member does not.
@(test)
test_references_enum_member :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    color_src := "package lib\n\nColor :: enum {\n\tRed,\n\tGreen,\n}\n\nShade :: enum {\n\tRed,\n}\n\nfirst :: proc() -> Color {\n\t_ = Shade.Red\n\treturn .Red\n}\n"
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.Color.Red\n\t_ = lib.Shade.Red\n}\n"
    root := fixture(t, "refs_enum_member", {{"lib/color.odin", color_src}, {"main.odin", main_src}})
    defer os.remove_all(root)

    color_path := fixture_path(root, "lib/color.odin")
    res := refs_at(e, color_src, "Red,", root, color_path)
    defer free_refs(&res)
    testing.expect(t, res.ok, "expected references to Color.Red")
    testing.expectf(t, count_in(&res, "color.odin") == 1, "refs in color.odin: got %d", count_in(&res, "color.odin"))
    testing.expectf(t, count_in(&res, "main.odin") == 1, "refs in main.odin: got %d", count_in(&res, "main.odin"))
    for sym in res.symbols {
        if strings.has_suffix(sym.path, "color.odin") {
            testing.expectf(t, sym.offset == strings.index(color_src, "return .Red") + len("return ."),"color.odin ref: got %d", sym.offset)
        } else {
            testing.expectf(t, sym.offset == strings.index(main_src, "Color.Red") + len("Color."), "main.odin ref: got %d", sym.offset)
        }
    }

    // From the qualified use.
    res2 := refs_at(e, main_src, "Color.Red", root, fixture_path(root, "main.odin"), len("Color."))
    defer free_refs(&res2)
    testing.expectf(t, len(res2.symbols) == 2, "ref count from a use: got %d", len(res2.symbols))
}

// A buffer opened as `sub/../a.odin` is told apart from its copy on disk.
@(test)
test_references_path_with_dot_dot :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package p\n\nf :: proc() {}\n\ng :: proc() {\n\tf()\n}\n"
    root := fixture(t, "refs_dot_dot", {{"a.odin", src}, {"sub/keep.txt", ""}})
    defer os.remove_all(root)

    res := refs_at(e, src, "f()", root, fixture_path(root, "sub/../a.odin"))
    defer free_refs(&res)
    testing.expectf(t, len(res.symbols) == 1, "expected the one call, got %d references", len(res.symbols))
}

// Rename edits the package's declaration and uses and the qualified use, never alib's `shared`.
@(test)
test_rename_stays_in_its_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    root := two_packages(t, "rename_two_packages")
    defer os.remove_all(root)

    src := "package app\n\nmain :: proc() {\n\t_ = shared(1)\n}\n"
    res := rename_at(e, src, "shared(1)", "combined", root, fixture_path(root, "zapp/main.odin"))
    defer free_edits(&res)
    testing.expect(t, res.ok, "expected rename edits")
    for edit in res.edits {
        testing.expectf(t, edit.old_text == "shared", "old_text: got %q", edit.old_text)
        testing.expectf(t, edit.new_text == "combined", "new_text: got %q", edit.new_text)
        testing.expectf(t, edit.end - edit.start == len("shared"), "span: %d..%d", edit.start, edit.end)
    }
    testing.expectf(t, count_in(&res, "far.odin") == 0, "alib's shared must not be renamed")
    testing.expectf(t, count_in(&res, "helper.odin") == 2, "edits in helper.odin: got %d", count_in(&res, "helper.odin"))
    testing.expectf(t, len(res.edits) == 4, "edit count: got %d", len(res.edits))
}

// A builtin, an implicit import alias and an import path have no declaration to rename.
@(test)
test_rename_refuses_an_unbound_name :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\ts := \"ab\"\n\tfmt.println(len(s), x = 1)\n}\n"
    for needle in ([?]string{"len(", "fmt.println", "fmt\"", "x = 1"}) {
        res := rename_at(e, src, needle, "other")
        testing.expectf(t, !res.ok && len(res.edits) == 0, "rename at %q: got %d edits", needle, len(res.edits))
        free_edits(&res)
    }
}

// The new name must be an identifier that is not a keyword, and not the old name.
@(test)
test_rename_refuses_a_bad_name :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nmain :: proc() {\n\tcount := 1\n\t_ = count\n}\n"
    for name in ([?]string{"", "1x", "a-b", "for", "proc", "count"}) {
        res := rename_at(e, src, "count :=", name)
        testing.expectf(t, !res.ok && len(res.edits) == 0, "rename to %q: got %d edits", name, len(res.edits))
        free_edits(&res)
    }
    res := rename_at(e, src, "count :=", "total")
    defer free_edits(&res)
    testing.expectf(t, res.ok && len(res.edits) == 2, "rename of a local: got %d edits", len(res.edits))
}

// An enum member and its implicit selector are renamed together.
@(test)
test_rename_keeps_an_enum_member :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nColor :: enum {\n\tRed,\n\tGreen,\n}\n\nc: Color = .Red\n"
    res := rename_at(e, src, "Red,", "Crimson")
    defer free_edits(&res)
    testing.expectf(t, len(res.edits) == 2, "edit count: got %d", len(res.edits))
    if len(res.edits) == 2 {
        testing.expect(t, res.edits[0].start == strings.index(src, "Red,"))
        testing.expect(t, res.edits[1].start == strings.index(src, ".Red") + 1)
    }
}

// An explicit import alias is renamed in its file: the alias and its uses.
@(test)
test_rename_import_alias :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nimport f \"core:fmt\"\n\nmain :: proc() {\n\tf.println(1)\n}\n"
    res := rename_at(e, src, "f.println", "out")
    defer free_edits(&res)
    testing.expectf(t, res.ok && len(res.edits) == 2, "edit count: got %d", len(res.edits))
    if len(res.edits) == 2 {
        testing.expect(t, res.edits[0].start == strings.index(src, "f \""))
        testing.expect(t, res.edits[1].start == strings.index(src, "f.println"))
    }
}

// A declaration in the standard library is outside the workspace.
@(test)
test_rename_refuses_a_stdlib_declaration :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    if odin_root(&e.root) == "" {
        return
    }
    src := "package app\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(\"hi\")\n}\n"
    root := fixture(t, "rename_stdlib", {})
    defer os.remove_all(root)

    res := rename_at(e, src, "println", "say", root, fixture_path(root, "main.odin"))
    defer free_edits(&res)
    testing.expectf(t, !res.ok && len(res.edits) == 0, "rename of fmt.println: got %d edits", len(res.edits))
}

// Rename edits the declarations and uses in the platform files of the package, in the build or not.
@(test)
test_rename_keeps_platform_files_in_step :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    a_src := "package demo\n\nmain :: proc() {\n\thelper()\n}\n"
    root := fixture(t, "rename_platform_files", {
        {"a.odin", a_src},
        {"x_windows.odin", "package demo\n\nhelper :: proc() {}\n"},
        {"x_linux.odin", "package demo\n\nhelper :: proc() {}\n\nagain :: proc() {\n\thelper()\n}\n"},
    })
    defer os.remove_all(root)

    res := rename_at(e, a_src, "helper()", "assist", root, fixture_path(root, "a.odin"))
    defer free_edits(&res)
    testing.expect(t, res.ok, "expected rename edits")
    testing.expectf(t, count_in(&res, "a.odin") == 1, "edits in a.odin: got %d", count_in(&res, "a.odin"))
    testing.expectf(t, count_in(&res, "x_windows.odin") == 1, "edits in x_windows.odin: got %d", count_in(&res, "x_windows.odin"))
    testing.expectf(t, count_in(&res, "x_linux.odin") == 2, "edits in x_linux.odin: got %d", count_in(&res, "x_linux.odin"))
    testing.expectf(t, len(res.edits) == 4, "edit count: got %d", len(res.edits))
}

// The uses of a builtin span the workspace; a package that declares the name binds its own.
@(test)
test_references_builtin :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    if odin_root(&e.root) == "" {
        testing.fail_now(t, "no Odin root: ODIN_ROOT, `odin root` and the build root all failed")
    }
    root := fixture(t, "refs_builtin", {
        {"app/size.odin", "package app\n\nsize :: proc(s: string) -> int {\n\treturn len(s)\n}\n"},
        {"lib/lib.odin", "package lib\n\ncount :: proc(xs: []int) -> int {\n\treturn len(xs) + len(xs)\n}\n"},
        {"own/own.odin", "package own\n\nlen :: proc(xs: []int) -> int {\n\treturn 0\n}\n"},
        {"own/own_use.odin", "package own\n\nuse :: proc(xs: []int) -> int {\n\treturn len(xs)\n}\n"},
    })
    defer os.remove_all(root)

    src := "package app\n\nmain :: proc() {\n\ts := \"ab\"\n\t_ = len(s)\n}\n"
    res := refs_at(e, src, "len(s)", root, fixture_path(root, "app/main.odin"))
    defer free_refs(&res)
    testing.expect(t, res.ok, "expected references to the builtin len")
    testing.expectf(t, count_in(&res, "main.odin") == 1, "refs in the buffer: got %d", count_in(&res, "main.odin"))
    testing.expectf(t, count_in(&res, "size.odin") == 1, "refs in size.odin: got %d", count_in(&res, "size.odin"))
    testing.expectf(t, count_in(&res, "lib.odin") == 2, "refs in lib.odin: got %d", count_in(&res, "lib.odin"))
    testing.expectf(t, count_in(&res, "own.odin") == 0 && count_in(&res, "own_use.odin") == 0, "package own binds its own len")
    testing.expectf(t, len(res.symbols) == 4, "ref count: got %d", len(res.symbols))
}

// A builtin is declared outside the workspace and has no declaration to rename.
@(test)
test_rename_refuses_a_builtin :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    if odin_root(&e.root) == "" {
        testing.fail_now(t, "no Odin root: ODIN_ROOT, `odin root` and the build root all failed")
    }
    root := fixture(t, "rename_builtin", {{"use.odin", "package app\n\nsize :: proc(s: string) -> int {\n\treturn len(s)\n}\n"}})
    defer os.remove_all(root)

    src := "package app\n\nmain :: proc() {\n\ts := \"ab\"\n\t_ = len(s)\n}\n"
    res := rename_at(e, src, "len(s)", "length", root, fixture_path(root, "main.odin"))
    defer free_edits(&res)
    testing.expectf(t, !res.ok && len(res.edits) == 0, "rename of len: got %d edits", len(res.edits))
}

// The offsets of `needle` in `src`, in order, each moved by `skip`. Temp-allocated.
@(private = "file")
all_offsets :: proc(src, needle: string, skip := 0) -> []int {
    out := make([dynamic]int, context.temp_allocator)
    from := 0
    for {
        i := strings.index(src[from:], needle)
        if i < 0 {
            break
        }
        append(&out, from + i + skip)
        from += i + len(needle)
    }
    return out[:]
}

@(private = "file")
FIELD_SRC :: `package demo

Base :: struct {
	id: int,
}

Entity :: struct {
	using base: Base,
	next:       ^Entity,
}

Other :: struct {
	id: int,
}

main :: proc() {
	e: Entity
	_ = e.id
	pe := &e
	_ = pe.next.id
	_ = e.base.id
	b := Base{id = 1}
	_ = b
	o: Other
	_ = o.id
	_ = Other{id = 2}
}
`

// A field is used through a value, a pointer, `using`, a chain and a composite literal; a field
// of the same name in another type is not.
@(test)
test_references_typed_field :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    want := []int {
        strings.index(FIELD_SRC, "e.id") + 2,
        strings.index(FIELD_SRC, "pe.next.id") + len("pe.next."),
        strings.index(FIELD_SRC, "e.base.id") + len("e.base."),
        strings.index(FIELD_SRC, "Base{id") + len("Base{"),
    }
    res := refs_at(e, FIELD_SRC, "id: int")
    expect_offsets(t, &res, want)
    free_refs(&res)

    // From a use: the same set.
    res = refs_at(e, FIELD_SRC, "pe.next.id", skip = len("pe.next."))
    expect_offsets(t, &res, want)
    free_refs(&res)

    // The other type's field.
    res = refs_at(e, FIELD_SRC, "o.id", skip = 2)
    expect_offsets(t, &res, {strings.index(FIELD_SRC, "o.id") + 2, strings.index(FIELD_SRC, "Other{id") + len("Other{")})
    free_refs(&res)
}

// An enum member from its declaration: every implicit selector whose expected type is the enum.
@(test)
test_references_typed_implicit_selectors :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Color :: enum {
	Red,
	Green,
}

Shade :: enum {
	Red,
}

Colors :: bit_set[Color]

paint :: proc(c: Color) {}

pick :: proc() -> Color {
	return .Red
}

main :: proc() {
	c: Color = .Red
	c = .Red
	if c == .Red {}
	paint(.Red)
	switch c {
	case .Red:
	}
	_ = Colors{.Red}
	s: Shade = .Red
	_ = s
	_ = Color.Red
}
`
    want := make([dynamic]int, context.temp_allocator)
    for off in all_offsets(src, ".Red", 1) {
        if off != strings.index(src, "Shade = .Red") + len("Shade = .") {
            append(&want, off)
        }
    }
    res := refs_at(e, src, "Red,")
    expect_offsets(t, &res, want[:])
    free_refs(&res)
}

// A parameter: its uses in the body and its named arguments in other files of the package and in importing packages.
@(test)
test_references_typed_param :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    lib_src := "package lib\n\ngrow :: proc(size: int, step := 1) -> int {\n\treturn size + step\n}\n\nuse :: proc() {\n\t_ = grow(size = 2)\n}\n"
    other_src := "package lib\n\nagain :: proc() {\n\t_ = grow(size = 3, step = 2)\n\tsize := 1\n\t_ = size\n}\n"
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.grow(size = 4)\n}\n"
    root := fixture(t, "refs_typed_param", {{"lib/lib.odin", lib_src}, {"lib/other.odin", other_src}, {"main.odin", main_src}})
    defer os.remove_all(root)
    lib_path := fixture_path(root, "lib/lib.odin")

    res := refs_at(e, lib_src, "size:", root, lib_path)
    testing.expectf(t, count_in(&res, "lib.odin") == 2, "refs in lib.odin: got %d", count_in(&res, "lib.odin"))
    testing.expectf(t, count_in(&res, "other.odin") == 1, "refs in other.odin: got %d", count_in(&res, "other.odin"))
    testing.expectf(t, count_in(&res, "main.odin") == 1, "refs in main.odin: got %d", count_in(&res, "main.odin"))
    free_refs(&res)

    // From a named argument in the importing package.
    res = refs_at(e, main_src, "size = 4", root, fixture_path(root, "main.odin"))
    testing.expectf(t, len(res.symbols) == 4, "refs from a named argument: got %d", len(res.symbols))
    free_refs(&res)

    // Rename from a named argument renames the declaration too.
    res = rename_at(e, other_src, "size = 3", "count", root, fixture_path(root, "lib/other.odin"))
    testing.expectf(t, len(res.edits) == 5, "rename edits: got %d", len(res.edits))
    testing.expectf(t, count_in(&res, "other.odin") == 1, "edits in other.odin: got %d", count_in(&res, "other.odin"))
    free_edits(&res)
}

// A field of an imported type: its uses in the package and in importing packages, renamed together.
@(test)
test_references_typed_field_cross_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    lib_src := "package lib\n\nVec :: struct {\n\tlen: f32,\n}\n\norigin :: proc() -> ^Vec {\n\treturn nil\n}\n"
    more_src := "package lib\n\nscale :: proc(v: Vec) -> f32 {\n\treturn v.len\n}\n"
    main_src := "package app\n\nimport \"../lib\"\n\nWrap :: struct {\n\tv: lib.Vec,\n}\n\nmain :: proc() {\n\tw: Wrap\n\t_ = w.v.len\n\t_ = lib.origin().len\n\t_ = lib.Vec{len = 1}\n\ts := \"x\"\n\t_ = len(s)\n}\n"
    root := fixture(t, "refs_typed_field_package", {{"lib/lib.odin", lib_src}, {"lib/more.odin", more_src}, {"app/main.odin", main_src}})
    defer os.remove_all(root)
    main_path := fixture_path(root, "app/main.odin")

    res := refs_at(e, main_src, "len\n", root, main_path)
    testing.expectf(t, count_in(&res, "more.odin") == 1, "refs in more.odin: got %d", count_in(&res, "more.odin"))
    testing.expectf(t, count_in(&res, "main.odin") == 3, "refs in main.odin: got %d", count_in(&res, "main.odin"))
    testing.expectf(t, count_in(&res, "lib.odin") == 0, "refs in lib.odin: got %d", count_in(&res, "lib.odin"))
    free_refs(&res)

    res = rename_at(e, main_src, "len = 1", "length", root, main_path)
    testing.expectf(t, len(res.edits) == 5, "rename edits: got %d", len(res.edits))
    testing.expectf(t, count_in(&res, "lib.odin") == 1, "edits in lib.odin: got %d", count_in(&res, "lib.odin"))
    for edit in res.edits {
        testing.expect_value(t, edit.old_text, "len")
        testing.expect_value(t, edit.new_text, "length")
    }
    free_edits(&res)
}

// A field of a record declared in a procedure body: its selector and field-name uses.
@(test)
test_references_typed_local_record :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nmain :: proc() {\n\tPair :: struct {\n\t\tleft, right: int,\n\t}\n\tp := Pair{left = 1}\n\t_ = p.left\n\tleft := 2\n\t_ = left\n}\n"
    res := refs_at(e, src, "left,")
    expect_offsets(t, &res, {strings.index(src, "left = 1"), strings.index(src, "p.left") + 2})
    free_refs(&res)
}

// A bare name a `using` brings in is a use of its field.
@(test)
test_references_using_bare_name :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := "package demo\n\nBase :: struct {\n\tid: int,\n}\n\nEntity :: struct {\n\tusing base: Base,\n}\n\nmove :: proc(using e: ^Entity, b: Base) -> int {\n\tid += 1\n\t_ = b.id\n\treturn id\n}\n\nid :: proc() {}\n"
    uses := []int{strings.index(src, "id += 1"), strings.index(src, "b.id") + 2, strings.index(src, "return id") + 7}
    res := refs_at(e, src, "id: int")
    expect_offsets(t, &res, uses)
    free_refs(&res)

    res = refs_at(e, src, "id += 1")
    expect_offsets(t, &res, uses)
    free_refs(&res)

    renamed := rename_at(e, src, "return id", "key", skip = 7)
    testing.expectf(t, renamed.ok && len(renamed.edits) == 4, "rename: got %d edits, want 4", len(renamed.edits))
    free_edits(&renamed)
}
