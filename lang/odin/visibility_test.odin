// Visibility attributes: `@(private)` confines a declaration to its package and
// `@(private = "file")` to its own file, so a cross-file lookup must not offer
// either past that reach. The fixture puts one of each in a sibling file and in
// another package, so a passing test means the attribute was read and applied.
package odin

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import lang ".."
import ts "../../vendor/odin-tree-sitter"

// The recorded visibility of the top-level declaration named `name`.
@(private = "file")
vis_of :: proc(e: ^Engine, source, name: string) -> (Visibility, bool) {
    parser := ts.parser_new()
    defer ts.parser_delete(parser)
    ts.parser_set_language(parser, e.language)

    tree := ts.parser_parse_string(parser, source)
    if tree == nil {
        return .Public, false
    }
    defer ts.tree_delete(tree)

    for d in collect_defs(e, ts.tree_root_node(tree), source) {
        if d.top_level && d.name == name {
            return d.visibility, true
        }
    }
    return .Public, false
}

@(test)
test_visibility_read_off_attributes :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Open :: struct {}

@(private)
Pkg :: struct {}

@(private = "package")
Named_Pkg :: 1

@(private = "file")
own :: proc() {}

@(private, require_results)
tagged :: proc() -> int {
	return 0
}

@(link_name = "private_thing")
linked :: proc() {}

@(private = "file")
counter := 0
`

    cases := []struct {
        name: string,
        want: Visibility,
        why:  string,
    } {
        {"Open", .Public, "no attribute is public"},
        {"Pkg", .Package, "a bare @(private) is package-private"},
        {"Named_Pkg", .Package, "@(private = \"package\") spells the same thing"},
        {"own", .File, "@(private = \"file\") is file-private"},
        {"tagged", .Package, "a second attribute beside private changes nothing"},
        {"linked", .Public, "`private` inside an unrelated value is not the attribute"},
        {"counter", .File, "a package variable carries its attribute too"},
    }
    for c in cases {
        got, found := vis_of(e, src, c.name)
        testing.expectf(t, found, "%s was not collected as a top-level declaration", c.name)
        testing.expectf(t, got == c.want, "%s: %s — got %v, want %v", c.name, c.why, got, c.want)
    }
}

// The shared workspace: package `app` in `zapp` (a public, a package-private and
// a file-private declaration, plus a second file with a file-private name of its
// own) and package `alib` in `alib`. Returns the root and the paths the tests
// drive requests from; `main.odin` is a live buffer that is never written, so the
// index sees only its siblings.
@(private = "file")
vis_ws :: proc(t: ^testing.T, rel: string) -> (root, main_path, helper_path: string) {
    _ = os.make_directory(rel)
    // Absolute, so the index's directory filter matches: it keys the paths
    // os.read_dir produced (see test_completion_siblings_from_index).
    abs, abs_err := filepath.abs(rel, context.temp_allocator)
    testing.expect(t, abs_err == nil, "could not absolutize the test workspace")
    root = abs

    app := strings.concatenate({root, "/zapp"}, context.temp_allocator)
    lib := strings.concatenate({root, "/alib"}, context.temp_allocator)
    _ = os.make_directory(app)
    _ = os.make_directory(lib)

    helper_path = strings.concatenate({app, "/helper.odin"}, context.temp_allocator)
    _ = os.write_entire_file(
        helper_path,
        transmute([]byte) string(
            "package app\n\nopen_helper :: proc() -> int {\n\treturn 1\n}\n\n" +
            "@(private)\npkg_helper :: proc() -> int {\n\treturn 2\n}\n\n" +
            "@(private = \"file\")\nown_helper :: proc() -> int {\n\treturn 3\n}\n",
        ),
    )

    // A second file of the same package with a file-private name spelled exactly
    // like helper.odin's: two different procedures, so nothing that reaches for
    // one may answer with, or rename, the other.
    twin := strings.concatenate({app, "/twin.odin"}, context.temp_allocator)
    _ = os.write_entire_file(
        twin,
        transmute([]byte) string(
            "package app\n\n@(private = \"file\")\nown_helper :: proc() -> int {\n\treturn 9\n}\n\n" +
            "twin_use :: proc() -> int {\n\treturn own_helper()\n}\n",
        ),
    )

    far := strings.concatenate({lib, "/far.odin"}, context.temp_allocator)
    _ = os.write_entire_file(
        far,
        transmute([]byte) string(
            "package alib\n\nfar_open :: proc() -> int {\n\treturn 1\n}\n\n" +
            "@(private)\nfar_priv :: proc() -> int {\n\treturn 2\n}\n",
        ),
    )

    main_path = strings.concatenate({app, "/main.odin"}, context.temp_allocator)
    return root, main_path, helper_path
}

@(private = "file")
vis_ws_clean :: proc(rel, root: string) {
    app := strings.concatenate({root, "/zapp"}, context.temp_allocator)
    lib := strings.concatenate({root, "/alib"}, context.temp_allocator)
    os.remove(strings.concatenate({app, "/helper.odin"}, context.temp_allocator))
    os.remove(strings.concatenate({app, "/twin.odin"}, context.temp_allocator))
    os.remove(strings.concatenate({lib, "/far.odin"}, context.temp_allocator))
    os.remove(app)
    os.remove(lib)
    os.remove(rel)
}

@(test)
test_definition_reaches_package_private_sibling :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_vis_pkg_ws"
    root, main_path, _ := vis_ws(t, rel)
    defer vis_ws_clean(rel, root)

    // `@(private)` hides a declaration from other packages, not from its own.
    src := "package app\n\nmain :: proc() {\n\t_ = pkg_helper()\n}\n"
    res := definition_at(e, src, "pkg_helper()", root, main_path)
    defer free_definition(&res)

    testing.expect(t, res.ok, "a package-private sibling is in reach of its own package")
    testing.expectf(
        t,
        strings.has_suffix(res.location.path, "helper.odin"),
        "should land in the declaring sibling, got %q",
        res.location.path,
    )
}

@(test)
test_definition_skips_file_private_sibling :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_vis_file_ws"
    root, main_path, _ := vis_ws(t, rel)
    defer vis_ws_clean(rel, root)

    // Two siblings declare `own_helper`, both `@(private = "file")`. Neither is
    // nameable here, so the honest answer is no definition rather than a jump
    // into whichever file sorted first.
    src := "package app\n\nmain :: proc() {\n\t_ = own_helper()\n}\n"
    res := definition_at(e, src, "own_helper()", root, main_path)
    defer free_definition(&res)

    testing.expectf(t, !res.ok, "a file-private sibling must not resolve, got %q", res.location.path)
    testing.expectf(t, len(res.symbols) == 0, "expected no candidates, got %d", len(res.symbols))
}

@(test)
test_definition_skips_other_package_private :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_vis_far_ws"
    root, main_path, _ := vis_ws(t, rel)
    defer vis_ws_clean(rel, root)

    // The workspace-wide widening still answers for a public name it cannot
    // reach any other way (see test_definition_widens_past_package) …
    open_src := "package app\n\nmain :: proc() {\n\t_ = far_open()\n}\n"
    open_res := definition_at(e, open_src, "far_open()", root, main_path)
    defer free_definition(&open_res)
    testing.expect(t, open_res.ok, "the workspace fallback should still find a public name")

    // … but not for one the declaring package keeps to itself.
    priv_src := "package app\n\nmain :: proc() {\n\t_ = far_priv()\n}\n"
    priv_res := definition_at(e, priv_src, "far_priv()", root, main_path)
    defer free_definition(&priv_res)
    testing.expectf(
        t,
        !priv_res.ok,
        "another package's @(private) must not widen into reach, got %q",
        priv_res.location.path,
    )
}

@(test)
test_hover_skips_other_package_private :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_vis_hover_ws"
    root, main_path, _ := vis_ws(t, rel)
    defer vis_ws_clean(rel, root)

    src := "package app\n\nmain :: proc() {\n\t_ = far_priv()\n}\n"
    req := lang.Request {
        kind      = .Hover,
        path      = main_path,
        ext       = ".odin",
        source    = src,
        offset    = strings.index(src, "far_priv()"),
        workspace = root,
    }
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expectf(t, !res.ok, "hover follows the same reach, got %q", res.hover.text)
}

@(private = "file")
vis_complete :: proc(e: ^Engine, path, src, root: string, at: int) -> lang.Result {
    req := lang.Request{kind = .Completion, path = path, ext = ".odin", source = src, offset = at, workspace = root}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    return res
}

@(test)
test_completion_sibling_visibility :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_vis_complete_ws"
    root, main_path, _ := vis_ws(t, rel)
    defer vis_ws_clean(rel, root)

    // `open_helper` and `own_helper` share the `o` prefix, so one request
    // separates "offered" from "filtered" without a second variable.
    o_src := "package app\n\nmain :: proc() {\n\t_ = o\n}\n"
    o_res := vis_complete(e, main_path, o_src, root, strings.index(o_src, "= o") + len("= o"))
    defer free_symbols(&o_res)
    testing.expect(t, has_completion(&o_res, "open_helper"), "a public sibling is offered")
    testing.expect(t, !has_completion(&o_res, "own_helper"), "a file-private sibling must not be offered")

    p_src := "package app\n\nmain :: proc() {\n\t_ = p\n}\n"
    p_res := vis_complete(e, main_path, p_src, root, strings.index(p_src, "= p") + len("= p"))
    defer free_symbols(&p_res)
    testing.expect(t, has_completion(&p_res, "pkg_helper"), "a package-private sibling is offered in its own package")
}

@(test)
test_completion_package_member_visibility :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_vis_member_ws"
    root, main_path, _ := vis_ws(t, rel)
    defer vis_ws_clean(rel, root)

    // `alib.far<caret>`: both names share the prefix, so only visibility can
    // separate them.
    src := "package app\n\nimport \"../alib\"\n\nmain :: proc() {\n\t_ = alib.far\n}\n"
    res := vis_complete(e, main_path, src, root, strings.index(src, "alib.far") + len("alib.far"))
    defer free_symbols(&res)

    testing.expect(t, has_completion(&res, "far_open"), "missing the imported package's public procedure")
    testing.expect(t, !has_completion(&res, "far_priv"), "another package's @(private) must not be offered")
}

@(test)
test_signature_skips_other_package_private :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_vis_sig_ws"
    root, main_path, _ := vis_ws(t, rel)
    defer vis_ws_clean(rel, root)

    src := "package app\n\nmain :: proc() {\n\t_ = far_priv()\n}\n"
    sig, ok := sig_help(e, src, strings.index(src, "far_priv(") + len("far_priv("), root, main_path)
    defer sig_free(sig)

    testing.expect(t, !ok, "signature help must not sign a procedure this file cannot call")
}

@(test)
test_rename_file_private_stays_in_its_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_vis_rename_ws"
    root, _, helper_path := vis_ws(t, rel)
    defer vis_ws_clean(rel, root)

    // The request comes from helper.odin, whose `own_helper` is file-private.
    // twin.odin declares and calls a name spelled the same, and a rename that
    // reached it would break code that never referred to this procedure.
    src := "package app\n\nopen_helper :: proc() -> int {\n\treturn 1\n}\n\n" +
           "@(private)\npkg_helper :: proc() -> int {\n\treturn 2\n}\n\n" +
           "@(private = \"file\")\nown_helper :: proc() -> int {\n\treturn 3\n}\n"
    res := rename_at(e, src, "own_helper", "renamed", root, helper_path)
    defer free_edits(&res)

    testing.expect(t, res.ok, "expected the declaration itself to be renamed")
    for edit in res.edits {
        testing.expectf(
            t,
            !strings.has_suffix(edit.path, "twin.odin"),
            "a file-private rename reached another file: %q",
            edit.path,
        )
    }
}
