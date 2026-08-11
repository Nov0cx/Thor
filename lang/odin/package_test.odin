// Package-scoped resolution: a bare name binds in its own package before the
// workspace is consulted at all. Every test here shares one workspace whose
// decoy package sorts *before* the requesting one, so the old flat first-hit
// would answer with the decoy and a passing test means the scoping ran.
package odin

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import lang ".."

// The shared fixture: `zapp` (package app, where the request comes from) and
// `alib`, both declaring `shared` and `Cfg`. `alib` also declares a name `zapp`
// has nothing of, for the widening case. Returns the workspace root and the live
// buffer's path; the buffer itself is never written, so the index sees only the
// sibling.
// Shared with path_test.odin's spelling-mismatch regression test.
@(private)
package_ws :: proc(t: ^testing.T, rel: string) -> (root, main_path: string) {
    _ = os.make_directory(rel)
    // Absolute, for the reason test_completion_siblings_from_index gives: the
    // index keys the paths os.read_dir produced, and a relative spelling would
    // miss the directory filter and widen straight back to the flat scan.
    abs, abs_err := filepath.abs(rel, context.temp_allocator)
    testing.expect(t, abs_err == nil, "could not absolutize the test workspace")
    root = abs

    app := strings.concatenate({root, "/zapp"}, context.temp_allocator)
    lib := strings.concatenate({root, "/alib"}, context.temp_allocator)
    _ = os.make_directory(app)
    _ = os.make_directory(lib)

    helper := strings.concatenate({app, "/helper.odin"}, context.temp_allocator)
    _ = os.write_entire_file(
        helper,
        transmute([]byte) string(
            "package app\n\nshared :: proc(n: int) -> int {\n\treturn n\n}\n\nCfg :: struct {\n\tvalue: int,\n}\n",
        ),
    )

    far := strings.concatenate({lib, "/far.odin"}, context.temp_allocator)
    _ = os.write_entire_file(
        far,
        transmute([]byte) string(
            "package alib\n\nshared :: proc(s: string) -> string {\n\treturn s\n}\n\nCfg :: struct {\n\tvalue: string,\n}\n\nonly_far :: proc() -> int {\n\treturn 2\n}\n",
        ),
    )

    main_path = strings.concatenate({app, "/main.odin"}, context.temp_allocator)
    return root, main_path
}

// Removes the fixture. Deepest first: the directories only go once they are empty.
@(private)
package_ws_clean :: proc(rel, root: string) {
    app := strings.concatenate({root, "/zapp"}, context.temp_allocator)
    lib := strings.concatenate({root, "/alib"}, context.temp_allocator)
    os.remove(strings.concatenate({app, "/helper.odin"}, context.temp_allocator))
    os.remove(strings.concatenate({lib, "/far.odin"}, context.temp_allocator))
    os.remove(app)
    os.remove(lib)
    os.remove(rel)
}

@(test)
test_definition_prefers_own_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_pkg_def_ws"
    root, main_path := package_ws(t, rel)
    defer package_ws_clean(rel, root)

    src := "package app\n\nmain :: proc() {\n\t_ = shared(1)\n}\n"
    res := definition_at(e, src, "shared(1)", root, main_path)
    defer free_definition(&res)

    testing.expect(t, res.ok, "expected `shared` to resolve")
    // Both packages declare it, but only one is in scope for a bare name, so this
    // is an unambiguous jump rather than the two-candidate picker the flat scan
    // used to raise.
    testing.expectf(t, len(res.symbols) == 0, "expected a direct jump, got %d candidates", len(res.symbols))
    testing.expectf(
        t,
        strings.has_suffix(res.location.path, "helper.odin"),
        "should land in the requesting package, got %q",
        res.location.path,
    )
}

@(test)
test_definition_widens_past_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_pkg_widen_ws"
    root, main_path := package_ws(t, rel)
    defer package_ws_clean(rel, root)

    // `only_far` is declared in the other package alone, so no bare use of it is
    // legal Odin. The widened scan answers anyway: with no correct definition to
    // shadow, pointing at the one symbol of that name is more use than reporting
    // nothing, and it keeps the reach the engine has for what it cannot model.
    src := "package app\n\nmain :: proc() {\n\t_ = only_far()\n}\n"
    res := definition_at(e, src, "only_far()", root, main_path)
    defer free_definition(&res)

    testing.expect(t, res.ok, "the workspace fallback should still answer")
    testing.expectf(
        t,
        strings.has_suffix(res.location.path, "far.odin"),
        "expected the other package's declaration, got %q",
        res.location.path,
    )
}

@(test)
test_hover_prefers_own_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_pkg_hover_ws"
    root, main_path := package_ws(t, rel)
    defer package_ws_clean(rel, root)

    src := "package app\n\nmain :: proc() {\n\t_ = shared(1)\n}\n"
    req := lang.Request {
        kind      = .Hover,
        path      = main_path,
        ext       = ".odin",
        source    = src,
        offset    = strings.index(src, "shared(1)"),
        workspace = root,
    }
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)

    testing.expect(t, res.ok, "expected hover to resolve `shared`")
    // The decoy sorts first on disk, so the pre-scoping first-hit showed
    // `shared :: proc(s: string) -> string` here.
    testing.expectf(t, res.hover.text == "shared :: proc(n: int) -> int", "hover text: got %q", res.hover.text)
}

@(test)
test_signature_prefers_own_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_pkg_sig_ws"
    root, main_path := package_ws(t, rel)
    defer package_ws_clean(rel, root)

    src := "package app\n\nmain :: proc() {\n\t_ = shared(1)\n}\n"
    sig, ok := sig_help(e, src, strings.index(src, "shared(1)") + len("shared("), root, main_path)
    defer sig_free(sig)

    testing.expect(t, ok, "expected signature help for `shared`")
    testing.expect(t, sig_has(sig, "shared :: proc(n: int) -> int"), "should sign the requesting package's procedure")
}

@(test)
test_member_type_prefers_own_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_pkg_type_ws"
    root, main_path := package_ws(t, rel)
    defer package_ws_clean(rel, root)

    // The type locator behind member access takes the same route. Both packages
    // declare a `Cfg` with a `value` field, so the field resolves either way and
    // only the file it lands in says which struct was read — a decoy without the
    // field would have let the flat name scan answer and prove nothing.
    src := "package app\n\nmain :: proc() {\n\tc: Cfg\n\t_ = c.value\n}\n"
    loc, ok := resolve_offset(e, src, strings.index(src, ".value") + 1, root, main_path)
    defer delete(loc.path)

    testing.expect(t, ok, "expected `c.value` to resolve to the field")
    testing.expectf(
        t,
        strings.has_suffix(loc.path, "helper.odin"),
        "should read the requesting package's struct, got %q",
        loc.path,
    )
}
