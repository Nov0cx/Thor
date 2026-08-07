// Signature help: the resolved callee's signature line and its active parameter,
// and the expansion of a procedure group into one signature per member.
package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

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
    defer sig_free(sig1)
    label1, param1 := sig_active(sig1)
    testing.expect(t, ok1, "expected signature help on the first argument")
    testing.expectf(t, len(sig1.entries) == 1, "a plain call is one signature: got %d", len(sig1.entries))
    testing.expectf(t, label1 == "add :: proc(a: int, b: int) -> int", "label: got %q", label1)
    testing.expectf(t, param1 == "a: int", "active param 0: got %q", param1)

    // Caret on the second argument: same signature, second parameter active.
    sig2, ok2 := sig_help(e, src, strings.index(src, ", 2)") + 2)
    defer sig_free(sig2)
    _, param2 := sig_active(sig2)
    testing.expect(t, ok2, "expected signature help on the second argument")
    testing.expectf(t, param2 == "b: int", "active param 1: got %q", param2)
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
    defer sig_free(sig)
    label, param := sig_active(sig)
    testing.expect(t, ok, "expected cross-file signature help")
    testing.expectf(t, label == "scale :: proc(v: int, by: int) -> int", "label: got %q", label)
    testing.expectf(t, param == "by: int", "active param: got %q", param)
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
    defer sig_free(sig)
    label, param := sig_active(sig)
    testing.expect(t, ok, "expected package-qualified signature help")
    testing.expectf(t, label == "scale :: proc(v: int, by: int) -> int", "label: got %q", label)
    testing.expectf(t, param == "v: int", "active param: got %q", param)
}

// A call of a procedure group signs every member, not the group: the group's own
// declaration names no parameters at all.
@(test)
test_signature_help_overload_set :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

sized_one :: proc(a: int) -> int {
	return a
}

sized_two :: proc(a: int, b: int) -> int {
	return a + b
}

sizes :: proc{sized_one, sized_two}

main :: proc() {
	_ = sizes(1, 2)
}
`
    at := strings.index(src, "sizes(1, 2)") + len("sizes(")
    sig, ok := sig_help(e, src, at)
    defer sig_free(sig)
    testing.expect(t, ok, "expected signature help on a procedure group")
    testing.expectf(t, len(sig.entries) == 2, "expected one entry per member: got %d", len(sig.entries))
    testing.expect(t, sig_has(sig, "sized_one :: proc(a: int) -> int"), "missing the one-parameter member")
    testing.expect(t, sig_has(sig, "sized_two :: proc(a: int, b: int) -> int"), "missing the two-parameter member")

    // Two arguments are written, so the two-parameter member is the active one
    // even though the caret sits in the first argument.
    label, param := sig_active(sig)
    testing.expectf(t, label == "sized_two :: proc(a: int, b: int) -> int", "active entry: got %q", label)
    testing.expectf(t, param == "a: int", "active param: got %q", param)
}

// The arity match tracks the arguments as they are written: one argument selects
// the one-parameter member, and typing the comma moves it to the other.
@(test)
test_signature_help_overload_tracks_arity :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    one := `package demo

sized_one :: proc(a: int) -> int {
	return a
}

sized_two :: proc(a: int, b: int) -> int {
	return a + b
}

sizes :: proc{sized_one, sized_two}

main :: proc() {
	_ = sizes(1)
}
`
    sig1, ok1 := sig_help(e, one, strings.index(one, "sizes(1)") + len("sizes("))
    defer sig_free(sig1)
    label1, _ := sig_active(sig1)
    testing.expect(t, ok1, "expected signature help with one argument")
    testing.expectf(t, label1 == "sized_one :: proc(a: int) -> int", "one argument picks: got %q", label1)

    // The same call with the comma typed: two argument slots, so the other member.
    two, _ := strings.replace(one, "sizes(1)", "sizes(1,)", 1, context.temp_allocator)
    sig2, ok2 := sig_help(e, two, strings.index(two, "sizes(1,)") + len("sizes(1,"))
    defer sig_free(sig2)
    label2, _ := sig_active(sig2)
    testing.expect(t, ok2, "expected signature help with a trailing comma")
    testing.expectf(t, label2 == "sized_two :: proc(a: int, b: int) -> int", "two slots pick: got %q", label2)
}

// The members live in a sibling file of the group's package, and the group is
// reached across files: both hops are the package-directory scan.
@(test)
test_signature_help_overload_cross_file :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    dir := "thor_lang_sig_overload_ws"
    _ = os.make_directory(dir)
    defer os.remove(dir)

    api := strings.concatenate({dir, "/api.odin"}, context.temp_allocator)
    api_src := "package demo\n\njoin_two :: proc(a: string, b: string) -> string {\n\treturn a\n}\n\njoin :: proc{join_two}\n"
    _ = os.write_entire_file(api, transmute([]byte)api_src)
    defer os.remove(api)

    main_path := strings.concatenate({dir, "/main.odin"}, context.temp_allocator)
    main_src := "package demo\n\nmain :: proc() {\n\t_ = join(\"a\", \"b\")\n}\n"

    at := strings.index(main_src, "join(\"a\"") + len("join(")
    sig, ok := sig_help(e, main_src, at, dir, main_path)
    defer sig_free(sig)
    label, param := sig_active(sig)
    testing.expect(t, ok, "expected cross-file signature help on a procedure group")
    testing.expectf(t, label == "join_two :: proc(a: string, b: string) -> string", "label: got %q", label)
    testing.expectf(t, param == "a: string", "active param: got %q", param)
}

// A member the package-local lookup cannot reach (written qualified) leaves the
// group with nothing to expand to, and the group's own declaration answers — the
// member list is still the most informative thing available.
@(test)
test_signature_help_overload_falls_back_to_group :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

import "lib"

sizes :: proc{lib.sized_one, lib.sized_two}

main :: proc() {
	_ = sizes(1)
}
`
    at := strings.index(src, "sizes(1)") + len("sizes(")
    sig, ok := sig_help(e, src, at)
    defer sig_free(sig)
    label, _ := sig_active(sig)
    testing.expect(t, ok, "expected the group declaration as a fallback")
    testing.expectf(t, len(sig.entries) == 1, "expected a single fallback entry: got %d", len(sig.entries))
    testing.expectf(
        t,
        label == "sizes :: proc{lib.sized_one, lib.sized_two}",
        "the group's member list is kept, not cut at the brace: got %q",
        label,
    )
}

// The parameter counts a signature label reports, which are what picks the
// overload: how many parameters there are, and how many the call has to write.
@(test)
test_param_arity :: proc(t: ^testing.T) {
    Case :: struct {
        label:    string,
        count:    int,
        required: int,
        variadic: bool,
    }
    cases := []Case {
        {"main :: proc()", 0, 0, false},
        {"add :: proc(a: int, b: int) -> int", 2, 2, false},
        // A comma inside a nested type does not split a parameter.
        {"run :: proc(f: proc(x: int, y: int), c: [dynamic]int)", 2, 2, false},
        // A result tuple comes after the parameter list and is never reached.
        {"split :: proc(s: string) -> (head: string, tail: string)", 1, 1, false},
        {"printf :: proc(fmt: string, args: ..any)", 2, 1, true},
        {"log :: proc(args: ..any)", 1, 0, true},
        // A defaulted parameter may be left out — `append(xs, 1)` reaches
        // append_elem, whose trailing `loc` the caller never writes.
        {"append_elem :: proc(array: ^[dynamic]int, arg: int, loc := #caller_location) -> int", 3, 2, false},
    }
    for c in cases {
        count, required, variadic := param_arity(c.label)
        testing.expectf(t, count == c.count, "%q: count %d, want %d", c.label, count, c.count)
        testing.expectf(t, required == c.required, "%q: required %d, want %d", c.label, required, c.required)
        testing.expectf(t, variadic == c.variadic, "%q: variadic %v, want %v", c.label, variadic, c.variadic)
    }
}

// Hover over a procedure group shows the members. The brace opens the member
// list, not a body, so the `{`-cut that keeps a procedure's signature off its
// body must not apply — it used to leave every group in the workspace reading
// `sizes :: proc`.
@(test)
test_hover_procedure_group_keeps_members :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

sized_one :: proc(a: int) -> int {
	return a
}

sizes :: proc{sized_one}

main :: proc() {
	_ = sizes(1)
}
`
    at := strings.index(src, "sizes(1)")
    req := lang.Request{kind = .Hover, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Hover}
    resolve(e, &req, &res)
    defer delete(res.hover.text)
    testing.expect(t, res.ok, "expected hover on a procedure group")
    testing.expectf(t, res.hover.text == "sizes :: proc{sized_one}", "hover text: got %q", res.hover.text)
}
