package odin

import "core:strings"
import "core:testing"

import lang ".."

// Runs a Package_Doc request at `at` in `source`.
@(private = "file")
package_doc_offset :: proc(e: ^Engine, source: string, at: int, workspace, path: string) -> lang.Result {
    req := lang.Request {
        kind      = .Package_Doc,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = at,
        workspace = workspace,
    }
    res := lang.Result{kind = .Package_Doc}
    resolve(e, &req, &res)
    return res
}

@(private = "file")
free_package_doc :: proc(res: ^lang.Result) {
    delete(res.doc.title)
    delete(res.doc.path)
    delete(res.doc.text)
    res^ = {}
}

@(test)
test_package_doc :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    lib_src := "package docpkg\n\n// Pings the server.\n// Returns the round-trip.\nping :: proc() -> int {\n\treturn 1\n}\n\n// A widget handle.\nWidget :: struct {\n\tid: int,\n}\n\n@(private)\nsecret :: proc() {\n}\n"
    test_src := "package docpkg\n\ntested :: proc() {\n}\n"
    root := fixture(t, "package_doc", {{"docpkg/docpkg.odin", lib_src}, {"docpkg/docpkg_test.odin", test_src}})
    main_path := fixture_path(root, "main.odin")
    main_src := "package app\n\nimport \"docpkg\"\n\nmain :: proc() {\n\t_ = docpkg.ping()\n}\n"

    // The operand, the qualified name and the import line all name docpkg.
    for needle in ([]string{"docpkg.ping", "ping()", "\"docpkg\""}) {
        res := package_doc_offset(e, main_src, strings.index(main_src, needle) + 1, root, main_path)
        testing.expectf(t, res.ok, "%s: expected the package to render docs", needle)
        testing.expectf(t, res.doc.title == "package docpkg", "%s: title: got %q", needle, res.doc.title)
        testing.expect(t, strings.contains(res.doc.text, "```odin\nping :: proc() -> int\n```"), "missing fenced proc signature")
        testing.expect(t, strings.contains(res.doc.text, "Pings the server.\nReturns the round-trip."), "doc comment should be `//`-stripped prose")
        testing.expect(t, !strings.contains(res.doc.text, "// Pings"), "the `//` markers must be stripped from the prose")
        testing.expect(t, strings.contains(res.doc.text, "Widget :: struct"), "missing public struct")
        testing.expect(t, strings.contains(res.doc.text, "A widget handle."), "missing struct doc prose")
        testing.expect(t, !strings.contains(res.doc.text, "secret"), "private proc must be omitted")
        testing.expect(t, !strings.contains(res.doc.text, "tested"), "test files must be omitted")
        testing.expect(t, strings.has_suffix(res.doc.path, "docpkg"), "path: the package directory")
        free_package_doc(&res)
    }
}

// The fallback directory is a slice of req.path, so freeing it would free the caller's path.
@(test)
test_package_doc_falls_back_to_own_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    disk_src := "package app\n\n// Adds the two.\nadd :: proc(a, b: int) -> int {\n\treturn a + b\n}\n"
    root := fixture(t, "package_doc_own", {{"main.odin", disk_src}, {"other.odin", "package app\n\n// Subtracts.\nsub :: proc(a, b: int) -> int {\n\treturn a - b\n}\n"}})
    main_path := fixture_path(root, "main.odin")
    owned_path := strings.clone(main_path)
    defer delete(owned_path)

    // The buffer replaces its file on disk.
    main_src := "package app\n\n// Adds the two.\nadd :: proc(a, b: int) -> int {\n\treturn a + b\n}\n\nlive :: 1\n"
    res := package_doc_offset(e, main_src, strings.index(main_src, "a + b"), root, owned_path)
    defer free_package_doc(&res)

    testing.expect(t, res.ok, "the file's own package should render docs")
    testing.expectf(t, res.doc.title == "package app", "title: got %q", res.doc.title)
    testing.expect(t, strings.contains(res.doc.text, "add :: proc(a, b: int) -> int"), "missing the package's own proc")
    testing.expect(t, strings.contains(res.doc.text, "Subtracts."), "missing the other file of the package")
    testing.expect(t, strings.contains(res.doc.text, "live :: 1"), "missing the declaration of the buffer")
    testing.expect_value(t, strings.count(res.doc.text, "## add"), 1)
    testing.expectf(t, owned_path == main_path, "the request path must be untouched: got %q", owned_path)
}
