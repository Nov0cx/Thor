package odin

import "core:strings"
import "core:testing"

import lang ".."

// Runs a Signature_Help request at the first `needle` in `source`, plus `skip` bytes.
@(private = "file")
sig_at :: proc(e: ^Engine, source, needle: string, skip := 0, workspace := "", path := "buffer.odin") -> lang.Result {
    req := lang.Request {
        kind      = .Signature_Help,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = strings.index(source, needle) + skip,
        workspace = workspace,
    }
    res := lang.Result{kind = .Signature_Help}
    resolve(e, &req, &res)
    return res
}

@(private = "file")
sig_free :: proc(res: ^lang.Result) {
    for entry in res.signature.entries {
        delete(entry.label)
    }
    delete(res.signature.entries)
}

// The label of the active entry and the text of its active parameter.
@(private = "file")
sig_active :: proc(res: ^lang.Result) -> (label, param: string) {
    sig := res.signature
    if sig.active < 0 || sig.active >= len(sig.entries) {
        return "", ""
    }
    entry := sig.entries[sig.active]
    if entry.active_start < 0 || entry.active_end > len(entry.label) {
        return entry.label, ""
    }
    return entry.label, entry.label[entry.active_start:entry.active_end]
}

// Expects the active entry `label` with the active parameter `param` at the first `needle` plus `skip`.
@(private = "file")
expect_sig :: proc(t: ^testing.T, e: ^Engine, src, needle: string, skip: int, label, param: string, entries := 1, workspace := "", path := "buffer.odin", loc := #caller_location) {
    res := sig_at(e, src, needle, skip, workspace, path)
    defer sig_free(&res)
    if !testing.expectf(t, res.ok, "%q+%d: expected signature help", needle, skip, loc = loc) {
        return
    }
    testing.expectf(t, len(res.signature.entries) == entries, "%q+%d: %d entries, want %d", needle, skip, len(res.signature.entries), entries, loc = loc)
    got_label, got_param := sig_active(&res)
    testing.expectf(t, got_label == label, "%q+%d: label %q, want %q", needle, skip, got_label, label, loc = loc)
    testing.expectf(t, got_param == param, "%q+%d: active %q, want %q", needle, skip, got_param, param, loc = loc)
}

@(private = "file")
expect_no_sig :: proc(t: ^testing.T, e: ^Engine, src, needle: string, skip: int, loc := #caller_location) {
    res := sig_at(e, src, needle, skip)
    defer sig_free(&res)
    testing.expectf(t, !res.ok, "%q+%d: want no signature help, got %v", needle, skip, res.signature.entries, loc = loc)
}

@(private = "file")
SIG_SRC :: `package demo

add :: proc(a: int, b: string = "x") -> bool {
	return a > 0
}

pair :: proc(x, y: f32) {}

log :: proc(level: int, args: ..any) {}

Widget :: struct {
	on_click: proc(x: int, y: int) -> bool,
	draw:     proc(w: ^Widget, scale: f32),
}

sized_one :: proc(a: int) -> int {
	return a
}

sized_two :: proc(a: int, b: int) -> int {
	return a + b
}

sizes :: proc{sized_one, sized_two}

take_s :: proc(v: string) -> int { return 1 }
take_f :: proc(v: f32) -> int { return 2 }
take :: proc{take_s, take_f}

main :: proc() {
	_ = add(1, "s") // plain
	_ = add(len("abc"), "t") // nested
	_ = add(b = "n", a = 2) // named
	pair(1, 2)
	log(1, "a", "b", "c")
	_ = sizes(1, 2)
	_ = sizes(1)
	_ = sizes(1,)
	f: f32
	_ = take(f)
	w: Widget
	_ = w.on_click(3, 4)
	w->draw(2)
	xs := make([]int, 4)
	_ = xs
	// add(1, 2) in a comment
	s := "add(1, 2)"
	_ = s
}
`

@(test)
test_signature_plain :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    label :: `add :: proc(a: int, b: string = "x") -> bool`
    expect_sig(t, e, SIG_SRC, `add(1, "s")`, len("add("), label, "a: int")
    expect_sig(t, e, SIG_SRC, `add(1, "s")`, len("add(1"), label, "a: int")
    expect_sig(t, e, SIG_SRC, `add(1, "s")`, len("add(1,"), label, `b: string = "x"`)
    expect_sig(t, e, SIG_SRC, `add(1, "s")`, len(`add(1, "s"`), label, `b: string = "x"`)
}

@(test)
test_signature_label_range :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    res := sig_at(e, SIG_SRC, `add(1, "s")`, len("add(1, "))
    defer sig_free(&res)
    if !testing.expect(t, res.ok && len(res.signature.entries) == 1) {
        return
    }
    entry := res.signature.entries[0]
    testing.expect_value(t, entry.active_start, len("add :: proc(a: int, "))
    testing.expect_value(t, entry.active_end, len(`add :: proc(a: int, b: string = "x"`))
}

@(test)
test_signature_several_names :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    expect_sig(t, e, SIG_SRC, "pair(1, 2)", len("pair("), "pair :: proc(x, y: f32)", "x")
    expect_sig(t, e, SIG_SRC, "pair(1, 2)", len("pair(1, "), "pair :: proc(x, y: f32)", "y: f32")
}

@(test)
test_signature_named_arg :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    label :: `add :: proc(a: int, b: string = "x") -> bool`
    expect_sig(t, e, SIG_SRC, `add(b = "n"`, len("add(b = "), label, `b: string = "x"`)
    expect_sig(t, e, SIG_SRC, `a = 2)`, len("a = "), label, "a: int")
}

@(test)
test_signature_nested_call :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    expect_sig(t, e, SIG_SRC, `len("abc")`, len("len("), "len :: proc(array: Array_Type) -> int", "array: Array_Type")
    // After the inner call closes, the outer call is the one the caret is in.
    expect_sig(t, e, SIG_SRC, `len("abc")`, len(`len("abc")`), `add :: proc(a: int, b: string = "x") -> bool`, "a: int")
}

@(test)
test_signature_unclosed_paren :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    src := "package demo\n\nadd :: proc(a: int, b: int) -> int { return a + b }\n\nmain :: proc() {\n\tx := add(1, \n}\n"
    expect_sig(t, src = src, e = e, needle = "add(1, ", skip = len("add(1, "), label = "add :: proc(a: int, b: int) -> int", param = "b: int")
    open := "package demo\n\nadd :: proc(a: int, b: int) -> int { return a + b }\n\nmain :: proc() {\n\tadd(\n}\n"
    expect_sig(t, e, open, "add(\n", len("add("), "add :: proc(a: int, b: int) -> int", "a: int")
    named := "package demo\n\nadd :: proc(a: int, b: int) -> int { return a + b }\n\nmain :: proc() {\n\tadd(b = \n}\n"
    expect_sig(t, e, named, "add(b = ", len("add(b = "), "add :: proc(a: int, b: int) -> int", "b: int")
}

@(test)
test_signature_variadic :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    label :: "log :: proc(level: int, args: ..any)"
    expect_sig(t, e, SIG_SRC, `log(1, "a"`, len("log("), label, "level: int")
    expect_sig(t, e, SIG_SRC, `log(1, "a"`, len("log(1, "), label, "args: ..any")
    expect_sig(t, e, SIG_SRC, `"c")`, 3, label, "args: ..any")
}

// Past the parameters of a non-variadic procedure there is no active parameter.
@(test)
test_signature_past_params :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    src := "package demo\n\none :: proc(a: int) {}\n\nmain :: proc() {\n\tone(1, 2)\n}\n"
    expect_sig(t, e, src, "one(1, 2)", len("one(1, "), "one :: proc(a: int)", "")
}

@(test)
test_signature_group :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    two :: "sized_two :: proc(a: int, b: int) -> int"
    one :: "sized_one :: proc(a: int) -> int"
    // Two arguments are written, so the two-parameter member is active from the first argument.
    expect_sig(t, e, SIG_SRC, "sizes(1, 2)", len("sizes("), two, "a: int", entries = 2)
    expect_sig(t, e, SIG_SRC, "sizes(1, 2)", len("sizes(1, "), two, "b: int", entries = 2)
    expect_sig(t, e, SIG_SRC, "sizes(1)", len("sizes("), one, "a: int", entries = 2)
    // A trailing comma opens a second slot.
    expect_sig(t, e, SIG_SRC, "sizes(1,)", len("sizes(1,"), two, "b: int", entries = 2)
    // Members of one arity are told apart by the argument types.
    expect_sig(t, e, SIG_SRC, "take(f)", len("take("), "take_f :: proc(v: f32) -> int", "v: f32", entries = 2)
}

@(test)
test_signature_group_lists_members :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    res := sig_at(e, SIG_SRC, "sizes(1)", len("sizes("))
    defer sig_free(&res)
    if !testing.expect(t, res.ok && len(res.signature.entries) == 2) {
        return
    }
    testing.expect_value(t, res.signature.entries[0].label, "sized_one :: proc(a: int) -> int")
    testing.expect_value(t, res.signature.entries[1].label, "sized_two :: proc(a: int, b: int) -> int")
}

@(test)
test_signature_proc_field :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    expect_sig(t, e, SIG_SRC, "on_click(3, 4)", len("on_click(3, "), "on_click: proc(x: int, y: int) -> bool", "y: int")
    // `x->f(`: the receiver is the first parameter.
    expect_sig(t, e, SIG_SRC, "draw(2)", len("draw("), "draw: proc(w: ^Widget, scale: f32)", "scale: f32")
}

@(test)
test_signature_local_proc :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    src := "package demo\n\nmain :: proc() {\n\tinner :: proc(n: int, s: string) {}\n\tinner(1, \"a\")\n\tcb: proc(k: int) -> int\n\t_ = cb(3)\n}\n"
    expect_sig(t, e, src, "inner(1, ", len("inner(1, "), "inner :: proc(n: int, s: string)", "s: string")
    expect_sig(t, e, src, "cb(3)", len("cb("), "cb: proc(k: int) -> int", "k: int")
}

@(test)
test_signature_builtin_group :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    res := sig_at(e, SIG_SRC, "make([]int, 4)", len("make([]int, "))
    defer sig_free(&res)
    if !testing.expect(t, res.ok, "expected signature help on make") {
        return
    }
    testing.expectf(t, len(res.signature.entries) > 1, "make is a group: %d entries", len(res.signature.entries))
    label, param := sig_active(&res)
    testing.expectf(t, strings.has_prefix(label, "make_slice :: proc("), "active entry %q", label)
    testing.expectf(t, strings.has_prefix(param, "len: int") || strings.contains(param, "len"), "active param %q", param)
}

@(test)
test_signature_cross_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    lib_src := "package lib\n\nscale :: proc(v: int, by: int) -> int {\n\treturn v * by\n}\n\nsized_one :: proc(a: int) {}\nsized_two :: proc(a: int, b: int) {}\nsizes :: proc{sized_one, sized_two}\n"
    sib_src := "package app\n\nhelper :: proc(\n\tname: string, // the name\n\tcount := 2,\n) {}\n"
    root := fixture(t, "signature_packages", {{"lib/lib.odin", lib_src}, {"app/sibling.odin", sib_src}})
    main_src := "package app\n\nimport \"../lib\"\n\nmain :: proc() {\n\t_ = lib.scale(2, 3)\n\tlib.sizes(1, 2)\n\thelper(\"a\", 3)\n}\n"
    main_path := fixture_path(root, "app/main.odin")
    expect_sig(t, e, main_src, "scale(2, 3)", len("scale(2, "), "scale :: proc(v: int, by: int) -> int", "by: int", workspace = root, path = main_path)
    expect_sig(t, e, main_src, "sizes(1, 2)", len("sizes("), "sized_two :: proc(a: int, b: int)", "a: int", entries = 2, workspace = root, path = main_path)
    // A multi-line parameter list is one line, comments and the trailing comma dropped.
    expect_sig(t, e, main_src, "helper(\"a\", 3)", len("helper(\"a\", "), "helper :: proc(name: string, count := 2)", "count := 2", workspace = root, path = main_path)
}

@(test)
test_signature_none :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    expect_no_sig(t, e, SIG_SRC, "_ = add(1", 0)
    expect_no_sig(t, e, SIG_SRC, "add(1, \"s\")", 0)
    expect_no_sig(t, e, SIG_SRC, "add(1, \"s\")", len("add(1, \"s\")"))
    expect_no_sig(t, e, SIG_SRC, "add(1, 2) in a comment", len("add(1, "))
    expect_no_sig(t, e, SIG_SRC, "\"add(1, 2)\"", len("\"add(1, "))
    expect_no_sig(t, e, SIG_SRC, "w: Widget", 0)
    expect_no_sig(t, e, SIG_SRC, "\"s\")", 1)
}

@(private = "file")
SIG_TYPE_SRC :: `package demo

List :: struct($T: typeid, $N: int) {
	items: [N]T,
}

Maybe :: union($T: typeid) {
	T,
}

Vec :: struct {
	x, y: f32,
}

Meters :: distinct f64

main :: proc() {
	l: List(int, 4)
	m: Maybe(string)
	_ = int(3.5)
	v: Vec
	_ = Vec(v)
	_ = Meters(2)
	_, _ = l, m
}
`

@(test)
test_signature_record_params :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    expect_sig(t, e, SIG_TYPE_SRC, "List(int, 4)", len("List("), "List($T: typeid, $N: int)", "$T: typeid")
    expect_sig(t, e, SIG_TYPE_SRC, "List(int, 4)", len("List(int, "), "List($T: typeid, $N: int)", "$N: int")
    expect_sig(t, e, SIG_TYPE_SRC, "Maybe(string)", len("Maybe("), "Maybe($T: typeid)", "$T: typeid")
}

@(test)
test_signature_conversion :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    expect_sig(t, e, SIG_TYPE_SRC, "int(3.5)", len("int("), "int(value)", "value")
    // A struct without parameters converts.
    expect_sig(t, e, SIG_TYPE_SRC, "Vec(v)", len("Vec("), "Vec(value)", "value")
    expect_sig(t, e, SIG_TYPE_SRC, "Meters(2)", len("Meters("), "Meters(value)", "value")
}

@(test)
test_signature_local_group :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    src := "package demo\n\nmain :: proc() {\n\tone :: proc(a: int) {}\n\ttwo :: proc(a: int, b: string) {}\n\tboth :: proc{one, two}\n\tboth(1, \"s\")\n\tboth(1)\n}\n"
    expect_sig(t, e, src, "both(1, ", len("both(1, "), "two :: proc(a: int, b: string)", "b: string", entries = 2)
    expect_sig(t, e, src, "both(1)", len("both("), "one :: proc(a: int)", "a: int", entries = 2)
}
