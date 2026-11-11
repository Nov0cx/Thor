package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

// Runs an Inlay_Hints request over `source`. Free with inlays_free.
@(private = "file")
inlays_at :: proc(e: ^Engine, source: string, workspace := "", path := "buffer.odin", offset := 0, end := 0) -> lang.Result {
    req := lang.Request{kind = .Inlay_Hints, path = path, ext = ".odin", source = source, offset = offset, end = end, workspace = workspace}
    res := lang.Result{kind = .Inlay_Hints}
    resolve(e, &req, &res)
    return res
}

@(private = "file")
inlays_free :: proc(res: ^lang.Result) {
    for hint in res.inlays {
        delete(hint.label)
    }
    delete(res.inlays)
}

// The label of the hint at the end of the first `needle` (after `after`), or at its start with `at_start`.
@(private = "file")
hint_at :: proc(res: ^lang.Result, src, needle: string, after := "", at_start := false) -> (string, bool) {
    from := strings.index(src, after)
    if from < 0 {
        return "", false
    }
    at := strings.index(src[from:], needle)
    if at < 0 {
        return "", false
    }
    offset := from + at + (at_start ? 0 : len(needle))
    for hint in res.inlays {
        if hint.offset == offset {
            return hint.label, true
        }
    }
    return "", false
}

@(private = "file")
expect_hint :: proc(t: ^testing.T, res: ^lang.Result, src, needle, label: string, after := "", at_start := false, loc := #caller_location) {
    got, ok := hint_at(res, src, needle, after, at_start)
    testing.expectf(t, ok, "no hint at %q", needle, loc = loc)
    if ok {
        testing.expect_value(t, got, label, loc = loc)
    }
}

@(private = "file")
expect_no_hint :: proc(t: ^testing.T, res: ^lang.Result, src, needle: string, after := "", at_start := false, loc := #caller_location) {
    got, ok := hint_at(res, src, needle, after, at_start)
    testing.expectf(t, !ok, "unexpected hint %q at %q", got, needle, loc = loc)
}

@(private = "file")
INLAY_SRC :: `package demo

Point :: struct { x, y: int }

pair :: proc() -> (int, string) { return 1, "a" }

scale :: proc(value: int, by: int = 2) -> f32 { return f32(value * by) }

sum :: proc(nums: ..int) -> int { return 0 }

set_value :: proc(value: int) {}

show :: proc { show_int, show_str }
show_int :: proc(n: int) {}
show_str :: proc(s: string) {}

Box :: struct { add: proc(b: ^Box, amount: int) }

LIMIT :: 10
LIMIT_INT : int : 4
DOUBLE :: LIMIT_INT * 2

main :: proc() {
	count := 3
	ratio := scale(count, 4)
	n, label := pair()
	p := Point{1, 2}
	q := cast(f64)count
	r := new(Point)
	typed: int = 5
	items := []int{1, 2}
	for item in items {}
	m: map[string]f32
	for key, val in m {}
	value := 1
	scale(value, by = 3)
	sum(1, 2, 3)
	set_value(9)
	show(7)
	b: Box
	b->add(5)
	_ = ratio + f32(n) + f32(len(label)) + f32(p.x) + f32(q) + f32(r.x) + f32(typed)
}
`

// A `:=` name gets its type, a written or spelled type gets none.
@(test)
test_inlay_types :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    res := inlays_at(e, INLAY_SRC)
    defer inlays_free(&res)

    // Between the colons of `:=` and `::`.
    expect_hint(t, &res, INLAY_SRC, "=", "int", after = "\tcount :", at_start = true)
    expect_hint(t, &res, INLAY_SRC, "=", "f32", after = "\tratio :", at_start = true)
    expect_hint(t, &res, INLAY_SRC, "=", "int, string", after = "\tn, label :", at_start = true)
    expect_hint(t, &res, INLAY_SRC, ": LIMIT_INT", "int", after = "DOUBLE :", at_start = true)
    // After the name of a range variable.
    expect_hint(t, &res, INLAY_SRC, "item", "int", after = "for ")
    expect_hint(t, &res, INLAY_SRC, "key", "string", after = "for key")
    expect_hint(t, &res, INLAY_SRC, "val", "f32", after = "for key")
    // A spelled or written type, an untyped constant and a type declaration get none.
    expect_no_hint(t, &res, INLAY_SRC, "=", after = "\tp :", at_start = true)
    expect_no_hint(t, &res, INLAY_SRC, "=", after = "\tq :", at_start = true)
    expect_no_hint(t, &res, INLAY_SRC, "=", after = "\tr :", at_start = true)
    expect_no_hint(t, &res, INLAY_SRC, "=", after = "\ttyped: int ", at_start = true)
    expect_no_hint(t, &res, INLAY_SRC, ": 10", after = "LIMIT :", at_start = true)
    expect_no_hint(t, &res, INLAY_SRC, ": struct", after = "Point :", at_start = true)
}

// A positional argument gets its parameter name, unless it reads as one already.
@(test)
test_inlay_parameters :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    res := inlays_at(e, INLAY_SRC)
    defer inlays_free(&res)

    expect_hint(t, &res, INLAY_SRC, "count, 4", "value:", after = "ratio :=", at_start = true)
    expect_hint(t, &res, INLAY_SRC, "4)", "by:", after = "ratio :=", at_start = true)
    // The argument `value` is the parameter's own name; `by = 3` is named.
    expect_no_hint(t, &res, INLAY_SRC, "value, by", after = "\tscale(", at_start = true)
    expect_no_hint(t, &res, INLAY_SRC, "3)", after = "\tscale(", at_start = true)
    // A variadic gets its name on the first argument only.
    expect_hint(t, &res, INLAY_SRC, "1, 2, 3", "nums:", after = "sum(", at_start = true)
    expect_no_hint(t, &res, INLAY_SRC, "2, 3", after = "sum(1", at_start = true)
    // `set_value(9)`: the callee already names its one parameter.
    expect_no_hint(t, &res, INLAY_SRC, "9)", after = "set_value(", at_start = true)
    // A group call takes the parameter of the member it picks.
    expect_hint(t, &res, INLAY_SRC, "7)", "n:", after = "show(", at_start = true)
    // `b->add(5)`: the receiver takes the first parameter.
    expect_hint(t, &res, INLAY_SRC, "5)", "amount:", after = "b->add(", at_start = true)
    // A conversion, a builtin and a `$T` parameter get none.
    expect_no_hint(t, &res, INLAY_SRC, "Point)", after = "new(", at_start = true)
    expect_no_hint(t, &res, INLAY_SRC, "n)", after = "f32(", at_start = true)
    expect_no_hint(t, &res, INLAY_SRC, "label)", after = "len(", at_start = true)
}

// A range request answers only the hints inside it.
@(test)
test_inlay_range :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    lo  := strings.index(INLAY_SRC, "\tn, label")
    hi  := strings.index(INLAY_SRC, "\tp := ")
    res := inlays_at(e, INLAY_SRC, offset = lo, end = hi)
    defer inlays_free(&res)

    expect_hint(t, &res, INLAY_SRC, "=", "int, string", after = "\tn, label :", at_start = true)
    expect_no_hint(t, &res, INLAY_SRC, "=", after = "\tcount :", at_start = true)
    for hint in res.inlays {
        testing.expectf(t, hint.offset >= lo && hint.offset <= hi, "hint %q at %d is outside the range", hint.label, hint.offset)
    }
}

// `inlay_types` and `inlay_parameters` in odin-analyzer.lua turn each kind off.
@(test)
test_inlay_config :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    root := fixture(t, "inlay_config", {{".thor/odin-analyzer.lua", `return { inlay_types = false }`}})
    defer os.remove_all(root)
    res := inlays_at(e, INLAY_SRC, workspace = root, path = fixture_path(root, "main.odin"))
    defer inlays_free(&res)

    expect_no_hint(t, &res, INLAY_SRC, "=", after = "\tcount :", at_start = true)
    expect_hint(t, &res, INLAY_SRC, "count, 4", "value:", after = "ratio :=", at_start = true)
}
