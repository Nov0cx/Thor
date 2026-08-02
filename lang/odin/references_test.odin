// Find-usages: what an occurrence has to bind to before it is one, and the
// declaration the search leaves out.
package odin

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import lang ".."

// Runs a References request at the first occurrence of `needle` in `source`.
@(private = "file")
refs_at :: proc(e: ^Engine, source, needle: string, workspace := "", path := "buffer.odin") -> lang.Result {
    req := lang.Request {
        kind      = .References,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = strings.index(source, needle),
        workspace = workspace,
    }
    res := lang.Result{kind = .References}
    resolve(e, &req, &res)
    return res
}

// Runs a References request at an absolute byte offset, for the carets a needle
// cannot name (the member of a `value.field`, a later occurrence of a name).
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

// The offsets a reference result points at, in the order it returned them.
@(private = "file")
ref_offsets :: proc(res: ^lang.Result) -> []int {
    out := make([dynamic]int, context.temp_allocator)
    for sym in res.symbols {
        append(&out, sym.offset)
    }
    return out[:]
}

@(test)
test_references_local :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `total` is declared in `use` and, separately, in `other`. References to the
    // one in `use` must be confined to `use`'s body — its two uses, not its
    // declaration and never `other`'s same-named local.
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
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to the local total")
    testing.expectf(t, len(res.symbols) == 2, "local ref count: got %d", len(res.symbols))

    decl := strings.index(src, "total :=")
    use_end := strings.index(src, "other ::")
    for sym in res.symbols {
        testing.expectf(t, strings.has_prefix(src[sym.offset:], "total"), "ref offset %d not on the name", sym.offset)
        testing.expectf(t, sym.offset != decl, "the declaration is not one of its own uses")
        testing.expectf(t, sym.offset < use_end, "ref at %d leaked past use's body", sym.offset)
        testing.expectf(t, sym.path == "buffer.odin", "ref path: got %q", sym.path)
    }
}

@(test)
test_references_skip_use_above_declaration :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Three occurrences of `count` in the block, but the first one names the
    // file-scope constant — the local does not exist yet there. Find-usages on
    // the local lists only the use below it, which is also what keeps rename from
    // rewriting an unrelated name.
    src := `package demo

count :: 0

use :: proc() -> int {
	_ = count
	count := 1
	return count
}
`
    at := strings.index(src, "count := 1")
    res := refs_at(e, src, "count := 1")
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to the local count")
    testing.expectf(t, len(res.symbols) == 1, "local ref count: got %d, want 1", len(res.symbols))
    for sym in res.symbols {
        testing.expectf(t, sym.offset > at, "ref at %d predates the declaration at %d", sym.offset, at)
    }
}

@(test)
test_references_local_shadowed_in_inner_block :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // An inner block redeclares the name. Those two occurrences are a different
    // variable — the same lexical rules goto follows — so the outer one's usages
    // are the one below the block, nothing inside it.
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
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to the outer total")
    testing.expectf(t, len(res.symbols) == 1, "outer ref count: got %d, want 1", len(res.symbols))
    if len(res.symbols) == 1 {
        testing.expect(t, res.symbols[0].offset > strings.index(src, "}\n\treturn"), "should be the use past the block")
    }
}

@(test)
test_references_skip_member_of_a_value :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `b.total` is a field of a struct, not the local of the same name: the
    // grammar spells both as a bare identifier, and only the position tells them
    // apart. One use, and neither the field's declaration nor its access.
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
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to the local total")
    testing.expectf(t, len(res.symbols) == 1, "local ref count: got %d, want 1", len(res.symbols))
    if len(res.symbols) == 1 {
        testing.expect(t, res.symbols[0].offset == strings.index(src, "total + b.total"), "should be the bare use")
    }
}

@(test)
test_references_field_bound_to_its_struct :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Two structs declare an `x`. Find-usages on Point's lists the accesses whose
    // operand is a Point — a parameter and a composite literal's field — and not
    // Rect's field, its declaration, or the `x` that is a local of its own.
    src := `package demo

Point :: struct {
	x: int,
}

Rect :: struct {
	x: int,
}

use :: proc(p: Point, r: Rect) -> int {
	x := 7
	q := Point{x = 2}
	return p.x + r.x + q.x + x
}
`
    at := strings.index(src, "x: int") // Point's field, the first one
    res := refs_offset(e, src, at)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to Point's x")
    want := []int {
        strings.index(src, "Point{x = 2}") + len("Point{"),
        strings.index(src, "p.x") + len("p."),
        strings.index(src, "q.x") + len("q."),
    }
    got := ref_offsets(&res)
    testing.expectf(t, len(got) == len(want), "field ref count: got %d %v, want %d %v", len(got), got, len(want), want)
    if len(got) == len(want) {
        for offset, i in want {
            testing.expectf(t, got[i] == offset, "ref %d: got %d, want %d", i, got[i], offset)
        }
    }
}

@(test)
test_references_field_from_a_use :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The caret on the member of `p.x` resolves the same field as the caret on
    // its declaration does, so both searches answer with the same set.
    src := `package demo

Point :: struct {
	x: int,
}

Rect :: struct {
	x: int,
}

use :: proc(p: Point, r: Rect) -> int {
	return p.x + r.x
}
`
    res := refs_offset(e, src, strings.index(src, "p.x") + len("p."))
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to Point's x")
    testing.expectf(t, len(res.symbols) == 1, "field ref count: got %d, want 1", len(res.symbols))
    if len(res.symbols) == 1 {
        testing.expectf(
            t,
            res.symbols[0].offset == strings.index(src, "p.x") + len("p."),
            "ref offset: got %d",
            res.symbols[0].offset,
        )
    }
}

@(test)
test_references_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `helper` is declared in main.odin (the live buffer) and called from both
    // main.odin and a sibling use.odin on disk. References to a top-level symbol
    // span its whole package: the buffer's one call and the sibling's two.
    dir := "thor_lang_refs_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    other := strings.concatenate({dir, "/use.odin"}, context.temp_allocator)
    other_src := "package demo\n\nrun :: proc() {\n\t_ = helper()\n\t_ = helper()\n}\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)
    defer os.remove(other)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n\nmain :: proc() {\n\t_ = helper()\n}\n"

    res := refs_at(e, main_src, "helper ::", dir, main_path)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected cross-file references to helper")
    testing.expectf(t, len(res.symbols) == 3, "cross-file ref count: got %d", len(res.symbols))

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
    testing.expectf(t, in_main == 1, "helper refs in main.odin: got %d", in_main)
    testing.expectf(t, in_other == 2, "helper refs in use.odin: got %d", in_other)
}

@(test)
test_references_index_incremental :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The workspace reference scan is filtered by the index's per-file identifier
    // sets. A decoy file that never mentions `helper` must contribute nothing, and
    // a sibling created *after* the first request (so after the index was first
    // built) must be picked up on the next request via the stat-walk + rebuilt
    // identifier set — proving the filter is both correct and live.
    dir := "thor_lang_refs_incr"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    decoy := strings.concatenate({dir, "/decoy.odin"}, context.temp_allocator)
    decoy_src := "package demo\n\nunrelated :: proc() {\n\t_ = 1\n}\n"
    _ = os.write_entire_file(decoy, transmute([]byte)decoy_src)
    defer os.remove(decoy)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nhelper :: proc() -> int {\n\treturn 42\n}\n\nmain :: proc() {\n\t_ = helper()\n}\n"

    // First request: only the live buffer mentions helper; the decoy is filtered out.
    res1 := refs_at(e, main_src, "helper ::", dir, main_path)
    defer free_symbols(&res1)
    testing.expectf(t, len(res1.symbols) == 1, "buffer-only ref count: got %d", len(res1.symbols))
    for sym in res1.symbols {
        testing.expectf(t, strings.has_suffix(sym.path, "main.odin"), "unexpected ref in %q", sym.path)
    }

    // Add a sibling that calls helper twice, then request again: the stat-walk sees
    // the new file, indexes its identifiers, and the filter now admits it.
    use := strings.concatenate({dir, "/use.odin"}, context.temp_allocator)
    use_src := "package demo\n\nrun :: proc() {\n\t_ = helper()\n\t_ = helper()\n}\n"
    _ = os.write_entire_file(use, transmute([]byte)use_src)
    defer os.remove(use)

    res2 := refs_at(e, main_src, "helper ::", dir, main_path)
    defer free_symbols(&res2)
    testing.expectf(t, len(res2.symbols) == 3, "ref count after sibling added: got %d", len(res2.symbols))
    in_use := 0
    for sym in res2.symbols {
        if strings.has_suffix(sym.path, "use.odin") {
            in_use += 1
        }
    }
    testing.expectf(t, in_use == 2, "helper refs in the new use.odin: got %d", in_use)
}

@(test)
test_references_field_across_files :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The struct is declared in one file, used in two others. The scan infers each
    // operand's type in the file it is written in, so the sibling's `p.x` counts
    // and its `r.x` — the same field name on another struct — does not. The live
    // buffer is never written, so its type lookup crosses files for real.
    dir := "thor_lang_refs_field_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    types := strings.concatenate({dir, "/types.odin"}, context.temp_allocator)
    _ = os.write_entire_file(
        types,
        transmute([]byte) string("package demo\n\nPoint :: struct {\n\tx: int,\n}\n\nRect :: struct {\n\tx: int,\n}\n"),
    )
    defer os.remove(types)

    use := strings.concatenate({dir, "/use.odin"}, context.temp_allocator)
    use_src := "package demo\n\nuse :: proc(p: Point, r: Rect) -> int {\n\treturn p.x + r.x\n}\n"
    _ = os.write_entire_file(use, transmute([]byte)use_src)
    defer os.remove(use)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc(p: Point) -> int {\n\treturn p.x\n}\n"

    res := refs_offset(e, main_src, strings.index(main_src, "p.x") + len("p."), dir, main_path)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to Point's x")
    testing.expectf(t, len(res.symbols) == 2, "field ref count: got %d", len(res.symbols))
    for sym in res.symbols {
        testing.expectf(t, !strings.has_suffix(sym.path, "types.odin"), "the declaration is not a use")
        if strings.has_suffix(sym.path, "use.odin") {
            testing.expectf(
                t,
                sym.offset == strings.index(use_src, "p.x") + len("p."),
                "should be the Point access, not Rect's: got %d",
                sym.offset,
            )
        }
    }
}

// A two-package workspace for the scoping tests: `zapp` (package app, where the
// request comes from) declares and uses `shared`; `alib` declares a rival
// `shared`, uses its own, and — in a second file — imports app and calls *its*
// `shared` behind a qualifier. Returns the workspace root and the live buffer's
// path; the buffer is never written, so the index sees only the siblings.
@(private = "file")
refs_ws :: proc(t: ^testing.T, rel: string) -> (root, main_path: string) {
    _ = os.make_directory(rel)
    // Absolute: the index keys the paths os.read_dir produced, and a relative
    // spelling would miss the directory filter the package scoping runs on.
    abs, abs_err := filepath.abs(rel, context.temp_allocator)
    testing.expect(t, abs_err == nil, "could not absolutize the test workspace")
    root = abs

    app := strings.concatenate({root, "/zapp"}, context.temp_allocator)
    lib := strings.concatenate({root, "/alib"}, context.temp_allocator)
    _ = os.make_directory(app)
    _ = os.make_directory(lib)

    _ = os.write_entire_file(
        strings.concatenate({app, "/helper.odin"}, context.temp_allocator),
        transmute([]byte) string("package app\n\nshared :: proc(n: int) -> int {\n\treturn n\n}\n\nagain :: proc() -> int {\n\treturn shared(2)\n}\n"),
    )
    _ = os.write_entire_file(
        strings.concatenate({lib, "/far.odin"}, context.temp_allocator),
        transmute([]byte) string("package alib\n\nshared :: proc(s: string) -> string {\n\treturn s\n}\n\nnear :: proc() -> string {\n\treturn shared(\"x\")\n}\n"),
    )
    _ = os.write_entire_file(
        strings.concatenate({lib, "/uses_app.odin"}, context.temp_allocator),
        transmute([]byte) string("package alib\n\nimport app \"../zapp\"\n\nrun :: proc() -> int {\n\treturn app.shared(3)\n}\n"),
    )

    main_path = strings.concatenate({app, "/main.odin"}, context.temp_allocator)
    return root, main_path
}

@(private = "file")
refs_ws_clean :: proc(rel, root: string) {
    app := strings.concatenate({root, "/zapp"}, context.temp_allocator)
    lib := strings.concatenate({root, "/alib"}, context.temp_allocator)
    os.remove(strings.concatenate({app, "/helper.odin"}, context.temp_allocator))
    os.remove(strings.concatenate({lib, "/far.odin"}, context.temp_allocator))
    os.remove(strings.concatenate({lib, "/uses_app.odin"}, context.temp_allocator))
    os.remove(app)
    os.remove(lib)
    os.remove(rel)
}

@(test)
test_references_bound_to_their_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_refs_pkg_ws"
    root, main_path := refs_ws(t, rel)
    defer refs_ws_clean(rel, root)

    // Both packages declare `shared`, and both use their own. A bare name reaches
    // only its own package, so the other's declaration and use are a different
    // symbol; the qualified `app.shared` in that package *is* this one.
    src := "package app\n\nmain :: proc() {\n\t_ = shared(1)\n}\n"
    res := refs_at(e, src, "shared(1)", root, main_path)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to app's shared")
    in_buffer, in_helper, in_qualified := 0, 0, 0
    for sym in res.symbols {
        switch {
        case strings.has_suffix(sym.path, "main.odin"):
            in_buffer += 1
        case strings.has_suffix(sym.path, "helper.odin"):
            in_helper += 1
        case strings.has_suffix(sym.path, "uses_app.odin"):
            in_qualified += 1
        case:
            testing.expectf(t, false, "reference in an unrelated package: %q", sym.path)
        }
    }
    testing.expectf(t, in_buffer == 1, "refs in the buffer: got %d", in_buffer)
    testing.expectf(t, in_helper == 1, "refs in the sibling (the declaration excluded): got %d", in_helper)
    testing.expectf(t, in_qualified == 1, "qualified refs in the importing package: got %d", in_qualified)
    testing.expectf(t, len(res.symbols) == 3, "package ref count: got %d", len(res.symbols))
}

@(test)
test_references_from_a_qualified_use :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_refs_qual_ws"
    root, main_path := refs_ws(t, rel)
    defer refs_ws_clean(rel, root)

    // The caret on the member of `app.shared` names the same symbol as a bare use
    // inside app does, so the search answers with app's package plus the qualified
    // use — never alib's own `shared`, whose file this request is made from.
    lib_path := strings.concatenate({root, "/alib/uses_app.odin"}, context.temp_allocator)
    src := "package alib\n\nimport app \"../zapp\"\n\nrun :: proc() -> int {\n\treturn app.shared(3)\n}\n"
    res := refs_offset(e, src, strings.index(src, "app.shared") + len("app."), root, lib_path)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected references to app's shared")
    for sym in res.symbols {
        testing.expectf(t, !strings.has_suffix(sym.path, "far.odin"), "alib's own shared is a different symbol")
    }
    // The buffer's qualified use, plus the use in app's own helper.odin. main.odin
    // was never written to disk, and the declaration is not a use of itself.
    testing.expectf(t, len(res.symbols) == 2, "qualified ref count: got %d", len(res.symbols))
}

@(test)
test_rename_stays_in_its_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_refs_rename_ws"
    root, main_path := refs_ws(t, rel)
    defer refs_ws_clean(rel, root)

    // Rename runs the same scan, so it edits app's declaration, app's uses and the
    // qualified use in the importing package — and leaves alib's same-named
    // procedure alone, which is the edit that used to be wrong.
    src := "package app\n\nmain :: proc() {\n\t_ = shared(1)\n}\n"
    res := rename_at(e, src, "shared(1)", "combined", workspace = root, path = main_path)
    defer free_edits(&res)

    testing.expect(t, res.ok, "expected rename edits for app's shared")
    declared := 0
    for edit in res.edits {
        testing.expectf(t, edit.old_text == "shared", "old_text: got %q", edit.old_text)
        testing.expectf(t, !strings.has_suffix(edit.path, "far.odin"), "alib's shared must not be renamed")
        if strings.has_suffix(edit.path, "helper.odin") {
            declared += 1
        }
    }
    // helper.odin holds both the declaration — which rename must rewrite, unlike
    // find-usages — and one call.
    testing.expectf(t, declared == 2, "edits in the declaring file: got %d", declared)
    testing.expectf(t, len(res.edits) == 4, "rename edit count: got %d", len(res.edits))
}
