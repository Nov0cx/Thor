// Implicit enum selectors: a leading `.` resolving against the enum the
// surrounding context expects.
package odin

import "core:strings"
import "core:testing"

import lang ".."

@(test)
test_enum_selector_completion :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `a: Axis = .` offers the enum's members as implicit selectors (the `.` is
    // already typed, so the candidates are the bare member names).
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

main :: proc() {
	a: Axis = .
	_ = a
}
`
    at := strings.index(src, "= .") + len("= .")
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected enum selector completions")
    testing.expect(t, has_completion(&res, "Horizontal"), "missing member Horizontal")
    testing.expect(t, has_completion(&res, "Vertical"), "missing member Vertical")
    for sym in res.symbols {
        if sym.name == "Horizontal" {
            testing.expectf(t, sym.kind == "enum_member", "Horizontal kind: got %q", sym.kind)
        }
    }
}

@(test)
test_enum_selector_assignment :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `a = .Ho` (reassignment of a typed var, with a prefix) filters the enum's
    // members: only Horizontal shares the `Ho` prefix.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

main :: proc() {
	a: Axis
	a = .Ho
	_ = a
}
`
    at := strings.index(src, "= .Ho") + len("= .Ho")
    req := lang.Request{kind = .Completion, path = "buffer.odin", ext = ".odin", source = src, offset = at}
    res := lang.Result{kind = .Completion}
    resolve(e, &req, &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected filtered enum selector completions")
    testing.expect(t, has_completion(&res, "Horizontal"), "missing member Horizontal")
    testing.expect(t, !has_completion(&res, "Vertical"), "Vertical does not share the Ho prefix")
}

@(test)
test_enum_selector_call_argument :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `f(1, .)` offers the members of the *second* parameter's enum — the argument
    // index comes from the commas before the caret.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

Mode :: enum {
	Fast,
	Slow,
}

f :: proc(m: Mode, a: Axis) {}

main :: proc() {
	f(.Fast, .)
}
`
    res: lang.Result
    selector_completions(e, src, "f(.Fast, .", &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected enum selector completions for the argument")
    testing.expect(t, has_completion(&res, "Horizontal"), "missing member Horizontal")
    testing.expect(t, !has_completion(&res, "Fast"), "Fast belongs to the first parameter's enum")
}

@(test)
test_enum_selector_grouped_and_variadic_params :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A grouped parameter (`a, b: Axis`) writes its type once, on the last name of
    // the group; a variadic tail (`..Axis`) answers for every argument past it.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

g :: proc(a, b: Axis) {}
h :: proc(n: int, rest: ..Axis) {}

main :: proc() {
	g(., .Vertical)
	h(1, .Horizontal, .)
}
`
    grouped: lang.Result
    selector_completions(e, src, "g(.", &grouped)
    defer free_symbols(&grouped)
    testing.expect(t, grouped.ok, "expected completions for a grouped parameter")
    testing.expect(t, has_completion(&grouped, "Horizontal"), "grouped: missing member Horizontal")

    variadic: lang.Result
    selector_completions(e, src, ".Horizontal, .", &variadic)
    defer free_symbols(&variadic)
    testing.expect(t, variadic.ok, "expected completions past a variadic parameter")
    testing.expect(t, has_completion(&variadic, "Vertical"), "variadic: missing member Vertical")
}

@(test)
test_enum_selector_composite_literal_field :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `Config{axis = .}` resolves the literal's struct, then that field's type.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

Config :: struct {
	axis: Axis,
	size: int,
}

main :: proc() {
	c := Config{axis = .}
	_ = c
}
`
    res: lang.Result
    selector_completions(e, src, "axis = .", &res)
    defer free_symbols(&res)

    testing.expect(t, res.ok, "expected enum selector completions for the literal field")
    testing.expect(t, has_completion(&res, "Horizontal"), "missing member Horizontal")
}

@(test)
test_enum_selector_return :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A bare `.` derails the parse outright here — the repaired re-parse is what
    // finds the return statement, and with it the procedure's result type. The
    // second procedure takes slot 1 of a named result list.
    src := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

one :: proc() -> Axis {
	return .
}

two :: proc() -> (n: int, a: Axis) {
	return 0, .
}
`
    single: lang.Result
    selector_completions(e, src, "return .", &single)
    defer free_symbols(&single)
    testing.expect(t, single.ok, "expected completions for a lone result")
    testing.expect(t, has_completion(&single, "Vertical"), "single: missing member Vertical")

    tuple: lang.Result
    selector_completions(e, src, "return 0, .", &tuple)
    defer free_symbols(&tuple)
    testing.expect(t, tuple.ok, "expected completions for the second result slot")
    testing.expect(t, has_completion(&tuple, "Vertical"), "tuple: missing member Vertical")
}

@(test)
test_enum_selector_comparison_and_switch :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // `a == .` takes the type of the other operand; `case .` takes the type of the
    // value the switch is over. One buffer each: the repair puts a single selector
    // back together, and a second broken one swallows whatever follows it.
    comparison := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

main :: proc() {
	a: Axis
	if a == . {
	}
}
`
    cmp: lang.Result
    selector_completions(e, comparison, "a == .", &cmp)
    defer free_symbols(&cmp)
    testing.expect(t, cmp.ok, "expected completions on the other side of a comparison")
    testing.expect(t, has_completion(&cmp, "Horizontal"), "comparison: missing member Horizontal")

    switched := `package demo

Axis :: enum {
	Horizontal,
	Vertical,
}

main :: proc() {
	a: Axis
	switch a {
	case .:
	}
}
`
    sw: lang.Result
    selector_completions(e, switched, "case .", &sw)
    defer free_symbols(&sw)
    testing.expect(t, sw.ok, "expected completions for a switch case")
    testing.expect(t, has_completion(&sw, "Vertical"), "switch: missing member Vertical")
}
