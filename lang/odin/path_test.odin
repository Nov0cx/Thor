// index_package_dir's third fallback tier: a workspace and a buffer opened
// through two different on-disk spellings of the same directory still scope a
// bare-name lookup to the right package once path_real resolves both.
package odin

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import lang ".."

// Deterministic, environment-independent coverage of path_real itself: a
// relative and an absolute spelling of the same directory must resolve to the
// identical canonical path. Doesn't depend on 8.3 short names being enabled or
// symlink privileges, unlike the mismatch test below.
@(test)
test_path_real_agrees_on_relative_and_absolute :: proc(t: ^testing.T) {
    rel := "thor_lang_path_real_relabs_ws"
    _ = os.make_directory(rel)
    defer os.remove(rel)

    abs, abs_err := filepath.abs(rel, context.temp_allocator)
    testing.expect(t, abs_err == nil, "could not absolutize the test directory")

    from_rel, rel_ok := path_real(rel, context.temp_allocator)
    from_abs, abs_ok := path_real(abs, context.temp_allocator)

    testing.expect(t, rel_ok, "path_real should resolve the relative spelling")
    testing.expect(t, abs_ok, "path_real should resolve the absolute spelling")
    testing.expectf(
        t,
        lang.path_equal(from_rel, from_abs),
        "expected the same canonical path, got %q and %q",
        from_rel,
        from_abs,
    )
}

@(test)
test_definition_resolves_spelling_mismatch :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Long enough that Windows generates a distinct 8.3 alias for it.
    rel := "thor_lang_path_real_mismatch_ws"
    root, main_path := package_ws(t, rel)
    defer package_ws_clean(rel, root)

    mismatched_root, ok := mismatched_workspace_spelling(root)
    if !ok {
        return // platform can't produce a mismatch here; nothing to prove
    }
    defer cleanup_mismatched_workspace_spelling(mismatched_root)

    // main_path is still spelled from `root` — the live buffer was opened with
    // the original spelling, only the workspace root differs.
    src := "package app\n\nmain :: proc() {\n\t_ = shared(1)\n}\n"
    req := lang.Request {
        kind      = .Definition,
        path      = main_path,
        ext       = ".odin",
        source    = src,
        offset    = strings.index(src, "shared(1)"),
        workspace = mismatched_root,
    }
    res := lang.Result{kind = .Definition}
    resolve(e, &req, &res)
    defer free_definition(&res)

    testing.expect(t, res.ok, "expected `shared` to resolve despite the spelling mismatch")
    // Both packages declare it; only the package-scoped tier-3 match keeps this
    // a direct jump instead of the two-candidate picker the flat scan gives.
    testing.expectf(t, len(res.symbols) == 0, "expected a direct jump, got %d candidates", len(res.symbols))
    testing.expectf(
        t,
        strings.has_suffix(res.location.path, "helper.odin"),
        "should still land in the requesting package, got %q",
        res.location.path,
    )
}

// A spelling of `root` that path_real must resolve back to it, but that a
// literal or filepath.abs comparison would not: the 8.3 short-name alias on
// Windows, a symlink on POSIX. Reports false when the platform can't produce
// one here (short names off on this volume, or symlink creation refused).
@(private = "file")
mismatched_workspace_spelling :: proc(root: string) -> (string, bool) {
    when ODIN_OS == .Windows {
        short, ok := path_short_form(root, context.allocator)
        if !ok || short == root {
            delete(short)
            log.info("8.3 short names are disabled on this volume; skipping")
            return "", false
        }
        return short, true
    } else {
        link := strings.concatenate({root, "_link"})
        if err := os.symlink(root, link); err != nil {
            log.infof("could not create a symlink (%v); skipping", err)
            delete(link)
            return "", false
        }
        return link, true
    }
}

@(private = "file")
cleanup_mismatched_workspace_spelling :: proc(mismatched_root: string) {
    when ODIN_OS == .Windows {
        delete(mismatched_root)
    } else {
        os.remove(mismatched_root)
        delete(mismatched_root)
    }
}

// A buffer opened under another spelling of its own path is still told apart
// from its on-disk copy in the index, so its usages are not listed twice.
@(test)
test_references_skip_buffer_under_another_spelling :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    rel := "thor_lang_path_skip_ws"
    _ = os.make_directory(rel)
    defer os.remove(rel)
    root, abs_err := filepath.abs(rel, context.temp_allocator)
    testing.expect(t, abs_err == nil, "could not absolutize the test workspace")
    sub := strings.concatenate({root, "/sub"}, context.temp_allocator)
    _ = os.make_directory(sub)
    defer os.remove(sub)

    src := "package p\n\nf :: proc() {}\n\ng :: proc() {\n\tf()\n}\n"
    file := strings.concatenate({root, "/a.odin"}, context.temp_allocator)
    _ = os.write_entire_file(file, transmute([]byte)src)
    defer os.remove(file)

    req := lang.Request {
        kind      = .References,
        path      = strings.concatenate({root, "/sub/../a.odin"}, context.temp_allocator),
        ext       = ".odin",
        source    = src,
        offset    = strings.index(src, "f()"),
        workspace = root,
    }
    res := lang.Result{kind = .References}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expectf(t, len(res.symbols) == 1, "expected the one call, got %d references", len(res.symbols))
}
