// Completion candidates: file scope, keywords, package members and siblings
// offered out of the symbol index.
package odin

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_completion_same_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

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
    req := lang.Request{kind = .Completion, path = main_path, ext = ".odin", source = src, offset = at, workspace = dir}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
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
    e := engine_create()
    defer engine_destroy(e)

    // `str` matches no declaration but does prefix the builtin `string`, tagged
    // "keyword" so the editor colors it like one.
    src := "package demo\n\nmain :: proc() {\n\tx: str\n\t_ = x\n}\n"
    at := strings.index(src, "str\n") + len("str")
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
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
    e := engine_create()
    defer engine_destroy(e)

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
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected completion candidates")
    testing.expect(t, has_completion(&res, "count_all"), "missing top-level count_all")
    testing.expect(t, !has_completion(&res, "counted"), "counted is not declared yet at the caret")
    testing.expect(t, !has_completion(&res, "counter"), "counter belongs to another block")
}

@(test)
test_completion_package_name :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Typing the start of an imported package's name offers the package itself
    // (the operand you then qualify with `.`), tagged "namespace".
    src := "package app\n\nimport \"../widgets\"\nimport \"core:fmt\"\n\nmain :: proc() {\n\t_ = wi\n}\n"
    at := strings.index(src, "wi\n") + len("wi")
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
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
    e := engine_create()
    defer engine_destroy(e)

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
    req := lang.Request{kind = .Completion, path = main_path, ext = ".odin", source = main_src, offset = at, workspace = root}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected package-member completions")
    testing.expect(t, has_completion(&res, "scale"), "missing lib.scale")
    // Only the `sc` prefix matches: shift and other are excluded.
    testing.expect(t, !has_completion(&res, "shift"), "shift does not share the prefix")
    testing.expect(t, !has_completion(&res, "other"), "other does not share the prefix")
}

@(test)
test_completion_siblings_from_index :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

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

    complete_sib :: proc(e: ^Engine, path, src, root: string, at: int) -> lang.Result {
        req := lang.Request{kind = .Completion, path = path, ext = ".odin", source = src, offset = at, workspace = root}
        res := lang.Result{kind = .Completion}
        resolve(e, &req, &res)
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
