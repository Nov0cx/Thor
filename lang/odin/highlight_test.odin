package odin

import "core:strings"
import "core:testing"

import lang ".."

// Runs a Document_Highlight request at the first occurrence of `needle` in `source`, plus `skip` bytes.
@(private = "file")
highlight_at :: proc(e: ^Engine, source, needle: string, skip := 0) -> lang.Result {
    req := lang.Request{kind = .Document_Highlight, path = "buffer.odin", ext = ".odin", source = source, offset = strings.index(source, needle) + skip}
    res := lang.Result{kind = .Document_Highlight}
    resolve(e, &req, &res)
    return res
}

// One expected highlight: the `skip`th occurrence of `needle`, plus `shift` bytes.
@(private = "file")
Want :: struct {
    needle: string,
    skip:   int,
    shift:  int,
    write:  bool,
}

@(private = "file")
expect_highlights :: proc(t: ^testing.T, src: string, res: ^lang.Result, name: string, want: []Want, loc := #caller_location) {
    testing.expectf(t, len(res.highlights) == len(want), "highlights: got %v, want %d", res.highlights[:], len(want), loc = loc)
    if len(res.highlights) != len(want) {
        return
    }
    for w, i in want {
        at   := nth_index(src, w.needle, w.skip) + w.shift
        h    := res.highlights[i]
        kind := w.write ? lang.Highlight_Kind.Write : lang.Highlight_Kind.Read
        testing.expectf(
            t,
            h.start == at && h.end == at + len(name),
            "highlight %d: got [%d, %d), want [%d, %d)",
            i,
            h.start,
            h.end,
            at,
            at + len(name),
            loc = loc,
        )
        testing.expectf(t, h.kind == kind, "highlight %d: got %v, want %v", i, h.kind, kind, loc = loc)
    }
}

// The offset of the `skip`th occurrence of `needle` in `src`; -1 when there is none.
@(private = "file")
nth_index :: proc(src, needle: string, skip: int) -> int {
    from := 0
    for _ in 0 ..< skip {
        i := strings.index(src[from:], needle)
        if i < 0 {
            return -1
        }
        from += i + len(needle)
    }
    i := strings.index(src[from:], needle)
    return i < 0 ? -1 : from + i
}

@(test)
test_highlight_supported :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    testing.expect(t, supports(e, ".odin", .Document_Highlight))
}

// A local: the declaration and a store are writes, the uses reads; another procedure's local is not one.
@(test)
test_highlight_local :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src  := `package demo

use :: proc() -> int {
	total := 1
	total = total + 2
	return total
}

other :: proc() -> int {
	total := 9
	return total
}
`
    want := []Want{{"total :=", 0, 0, true}, {"total =", 0, 0, true}, {"total + 2", 0, 0, false}, {"return total", 0, len("return "), false}}
    res  := highlight_at(e, src, "total + 2")
    defer delete(res.highlights)
    testing.expect(t, res.ok)
    expect_highlights(t, src, &res, "total", want)
}

// An inner block that declares the name again hides the outer local.
@(test)
test_highlight_shadowed_local :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

use :: proc() -> int {
	total := 1
	{
		total := 2
		_ = total
	}
	return total
}
`
    res := highlight_at(e, src, "total := 1")
    defer delete(res.highlights)
    expect_highlights(t, src, &res, "total", {{"total := 1", 0, 0, true}, {"return total", 0, len("return "), false}})

    inner := highlight_at(e, src, "_ = total", len("_ = "))
    defer delete(inner.highlights)
    expect_highlights(t, src, &inner, "total", {{"total := 2", 0, 0, true}, {"_ = total", 0, len("_ = "), false}})
}

// A parameter and its uses in the body.
@(test)
test_highlight_param :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

grow :: proc(size: int) -> int {
	return size + size
}
`
    res := highlight_at(e, src, "size + size")
    defer delete(res.highlights)
    expect_highlights(t, src, &res, "size", {{"size:", 0, 0, true}, {"size + size", 0, 0, false}, {"size + size", 0, len("size + "), false}})
}

// A package procedure: its declaration and both calls.
@(test)
test_highlight_package_proc :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

step :: proc() {}

main :: proc() {
	step()
	step()
}
`
    res := highlight_at(e, src, "step()")
    defer delete(res.highlights)
    expect_highlights(t, src, &res, "step", {{"step ::", 0, 0, true}, {"step()", 0, 0, false}, {"step()", 1, 0, false}})
}

// A field through a selector and a literal field name; the field of another type is not one.
@(test)
test_highlight_typed_field :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Item :: struct {
	id: int,
}

Other :: struct {
	id: int,
}

main :: proc() {
	it := Item{id = 1}
	o := Other{id = 2}
	_ = it.id + o.id
}
`
    res := highlight_at(e, src, "it.id", len("it."))
    defer delete(res.highlights)
    expect_highlights(t, src, &res, "id", {{"id: int", 0, 0, true}, {"Item{id", 0, len("Item{"), false}, {"it.id", 0, len("it."), false}})
}

// An enum member through implicit selectors.
@(test)
test_highlight_enum_member :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Color :: enum {
	Red,
	Green,
}

main :: proc() {
	c: Color = .Red
	if c == .Red {}
}
`
    res := highlight_at(e, src, "Red,")
    defer delete(res.highlights)
    expect_highlights(t, src, &res, "Red", {{"Red,", 0, 0, true}, {".Red", 0, 1, false}, {".Red", 1, 1, false}})
}

// An import alias: its declaration and the qualified uses.
@(test)
test_highlight_import_alias :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

import str "core:strings"

main :: proc() {
	_ = str.to_upper("a")
	_ = str.to_lower("a")
}
`
    res := highlight_at(e, src, "str.to_upper")
    defer delete(res.highlights)
    expect_highlights(t, src, &res, "str", {{"str \"", 0, 0, true}, {"str.to_upper", 0, 0, false}, {"str.to_lower", 0, 0, false}})
}

// A keyword or a literal names nothing.
@(test)
test_highlight_nothing :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

main :: proc() {
	x := 42
	_ = x
}
`
    res := highlight_at(e, src, "42")
    defer delete(res.highlights)
    testing.expect(t, !res.ok)
    testing.expect_value(t, len(res.highlights), 0)

    kw := highlight_at(e, src, "proc")
    defer delete(kw.highlights)
    testing.expect(t, !kw.ok)
}
