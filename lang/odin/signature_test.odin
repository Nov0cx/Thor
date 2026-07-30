// Signature help: the resolved callee's signature line and its active parameter.
package odin

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_signature_help_same_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

add :: proc(a: int, b: int) -> int {
	return a + b
}

main :: proc() {
	_ = add(1, 2)
}
`
    call := strings.index(src, "add(1, 2)")

    // Caret on the first argument: signature resolved, first parameter active.
    sig1, ok1 := sig_help(e, src, call + len("add("))
    defer delete(sig1.label)
    testing.expect(t, ok1, "expected signature help on the first argument")
    testing.expectf(t, sig1.label == "add :: proc(a: int, b: int) -> int", "label: got %q", sig1.label)
    testing.expectf(t, sig1.label[sig1.active_start:sig1.active_end] == "a: int", "active param 0: got %q", sig1.label[sig1.active_start:sig1.active_end])

    // Caret on the second argument: same signature, second parameter active.
    sig2, ok2 := sig_help(e, src, strings.index(src, ", 2)") + 2)
    defer delete(sig2.label)
    testing.expect(t, ok2, "expected signature help on the second argument")
    testing.expectf(t, sig2.label[sig2.active_start:sig2.active_end] == "b: int", "active param 1: got %q", sig2.label[sig2.active_start:sig2.active_end])
}

@(test)
test_signature_help_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The procedure is declared in a sibling file; signature help follows the
    // cross-file scan, like go-to-definition.
    dir := "thor_lang_sig_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    other := strings.concatenate({dir, "/api.odin"}, context.temp_allocator)
    other_src := "package demo\n\nscale :: proc(v: int, by: int) -> int {\n\treturn v * by\n}\n"
    _ = os.write_entire_file(other, transmute([]byte)other_src)
    defer os.remove(other)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc() {\n\t_ = scale(2, 3)\n}\n"

    // Caret on the second argument -> second parameter active.
    at := strings.index(main_src, ", 3)") + 2
    sig, ok := sig_help(e, main_src, at, dir, main_path)
    defer delete(sig.label)
    testing.expect(t, ok, "expected cross-file signature help")
    testing.expectf(t, sig.label == "scale :: proc(v: int, by: int) -> int", "label: got %q", sig.label)
    testing.expectf(t, sig.label[sig.active_start:sig.active_end] == "by: int", "active param: got %q", sig.label[sig.active_start:sig.active_end])
}

@(test)
test_signature_help_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `pkg.fn(...)`: signature help follows the import into the package's dir.
    root := "thor_lang_sig_pkg_ws"
    lib := strings.concatenate({root, "/lib"}, context.temp_allocator)
    _ = os.make_directory(root)
    _ = os.make_directory(lib)

    lib_path := strings.concatenate({lib, "/api.odin"}, context.temp_allocator)
    lib_src := "package lib\n\nscale :: proc(v: int, by: int) -> int {\n\treturn v * by\n}\n"
    _ = os.write_entire_file(lib_path, transmute([]byte)lib_src)

    defer os.remove(root)
    defer os.remove(lib)
    defer os.remove(lib_path)

    main_path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    main_src := "package app\n\nimport \"lib\"\n\nmain :: proc() {\n\t_ = lib.scale(2, 3)\n}\n"

    at := strings.index(main_src, "scale(2, 3)") + len("scale(")
    sig, ok := sig_help(e, main_src, at, root, main_path)
    defer delete(sig.label)
    testing.expect(t, ok, "expected package-qualified signature help")
    testing.expectf(t, sig.label == "scale :: proc(v: int, by: int) -> int", "label: got %q", sig.label)
    testing.expectf(t, sig.label[sig.active_start:sig.active_end] == "v: int", "active param: got %q", sig.label[sig.active_start:sig.active_end])
}
