package odin

import "core:os"
import "core:path/filepath"
import "core:testing"

import lang ".."

// A relative and an absolute spelling of one directory resolve to the same canonical path.
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
