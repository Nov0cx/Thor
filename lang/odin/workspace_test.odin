// Workspace-level behaviour: collection imports, the analyzer config toggles,
// package documentation, and a cancelled request answering nothing.
package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_collection_import :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

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
    e := engine_create()
    defer engine_destroy(e)

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
        req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at, workspace = root}
        res := lang.Result{kind = .Hover}
        resolve(e, &req, &res)
        defer delete(res.hover.text)
        testing.expect(t, !res.ok, "enable_hover:false should suppress hover")
    }

    // Re-enabled (distinct file size forces the cache to re-read): hover answers.
    on_src := "{ \"enable_hover\": true, \"note\": \"on\" }"
    _ = os.write_entire_file(cfg, transmute([]byte)on_src)
    {
        req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at, workspace = root}
        res := lang.Result{kind = .Hover}
        resolve(e, &req, &res)
        defer delete(res.hover.text)
        testing.expect(t, res.ok, "enable_hover:true should restore hover")
        testing.expectf(t, res.hover.text == "scale :: proc(v: int) -> int", "hover text: got %q", res.hover.text)
    }
}

@(test)
test_package_doc :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

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
    req := lang.Request {
        kind      = .Package_Doc,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = at,
        workspace = root,
    }
    res := lang.Result{kind = .Package_Doc}
    resolve(e, &req, &res)
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
test_cancelled_request_answers_nothing :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

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
    req := lang.Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = main_src,
        offset    = strings.index(main_src, "helper()"),
        workspace = dir,
        cancel    = &cancelled,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    testing.expect(t, !res.ok, "a cancelled request must not produce a location")
    testing.expect(t, res.location.path == "", "a cancelled request must not allocate a result")

    // ...and it left the engine's index usable: the next live request still
    // resolves. (An abandoned index walk skips the prune for exactly this
    // reason — pruning against a partial `seen` set would drop live files.)
    loc2, ok2 := resolve_in_ws(e, main_path, main_src, "helper()", dir)
    defer delete(loc2.path)
    testing.expect(t, ok2, "a cancelled request must not damage the symbol index")
}
