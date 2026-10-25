package odin

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import lang ".."

// Runs a Semantic_Tokens request over `source`. Free the tokens with delete.
@(private = "file")
semantic_at :: proc(e: ^Engine, source: string, workspace := "", path := "buffer.odin", offset := 0, end := 0) -> lang.Result {
    req := lang.Request {
        kind      = .Semantic_Tokens,
        path      = path,
        ext       = ".odin",
        source    = source,
        offset    = offset,
        end       = end,
        workspace = workspace,
    }
    res := lang.Result{kind = .Semantic_Tokens}
    resolve(e, &req, &res)
    return res
}

// The token that starts at the first `needle` after the first `after`, plus `skip`.
@(private = "file")
token_at :: proc(res: ^lang.Result, src, needle: string, after := "", skip := 0) -> (lang.Semantic_Token, bool) {
    at := after == "" ? strings.index(src, needle) : offset_after(src, needle, after)
    if at < 0 {
        return {}, false
    }
    at += skip
    for tok in res.tokens {
        if tok.start == at {
            return tok, true
        }
    }
    return {}, false
}

@(private = "file")
expect_kind :: proc(t: ^testing.T, res: ^lang.Result, src, needle: string, want: lang.Token_Kind, after := "", skip := 0, loc := #caller_location) {
    tok, ok := token_at(res, src, needle, after, skip)
    if !testing.expectf(t, ok, "%q (after %q): expected a token", needle, after, loc = loc) {
        return
    }
    testing.expectf(t, tok.kind == want, "%q (after %q): got %v, want %v", needle, after, tok.kind, want, loc = loc)
}

@(private = "file")
expect_none :: proc(t: ^testing.T, res: ^lang.Result, src, needle: string, after := "", skip := 0, loc := #caller_location) {
    tok, ok := token_at(res, src, needle, after, skip)
    testing.expectf(t, !ok, "%q (after %q): want no token, got %v", needle, after, tok.kind, loc = loc)
}

// Expects the tokens ascending and non-overlapping, each on an identifier of `src`.
@(private = "file")
expect_ordered :: proc(t: ^testing.T, res: ^lang.Result, src: string, loc := #caller_location) {
    cut := 0
    for tok, i in res.tokens {
        if !testing.expectf(t, tok.start >= cut && tok.start < tok.end && tok.end <= len(src), "token %d [%d, %d) after %d", i, tok.start, tok.end, cut, loc = loc) {
            return
        }
        cut = tok.end
    }
}

@(private = "file")
KINDS_SRC :: `package demo

import "core:fmt"

Axis :: enum {
	Vertical,
	Horizontal,
}

Point :: struct {
	x: int,
	on_move: proc(),
}

My_Int :: int
LIMIT :: 4
counter: int
helper :: other

other :: proc() {}

scale :: proc(p: Point, factor: int) -> (total: int) {
	Local_Kind :: struct { v: int }
	local_proc :: proc() {}
	sum := factor * 2
	fmt.println(sum, LIMIT, counter, len("x"))
	n: My_Int = 3
	a := Axis.Vertical
	b: Axis = .Horizontal
	p.on_move()
	local_proc()
	k := Local_Kind{v = 1}
	_ = k.v
	helper()
	return sum + p.x + int(n)
}
`

@(test)
test_semantic_token_kinds :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := KINDS_SRC
    res := semantic_at(e, src)
    defer delete(res.tokens)
    expect_ordered(t, &res, src)

    expect_kind(t, &res, src, "p: Point", .Parameter)
    expect_kind(t, &res, src, "factor * 2", .Parameter)
    expect_kind(t, &res, src, "factor: int", .Parameter)
    expect_kind(t, &res, src, "total: int", .Parameter)
    expect_kind(t, &res, src, "sum :=", .Local)
    expect_kind(t, &res, src, "sum, LIMIT", .Local)
    expect_kind(t, &res, src, "a :=", .Local)
    expect_kind(t, &res, src, "x: int", .Field)
    expect_kind(t, &res, src, "x + int", .Field)
    expect_kind(t, &res, src, "v: int", .Field)
    expect_kind(t, &res, src, "v = 1", .Field)
    expect_kind(t, &res, src, "v\n", .Field, after = "k.")
    expect_kind(t, &res, src, "on_move()", .Procedure)
    expect_kind(t, &res, src, "on_move:", .Procedure)
    expect_kind(t, &res, src, "scale ::", .Procedure)
    expect_kind(t, &res, src, "other ::", .Procedure)
    expect_kind(t, &res, src, "other\n", .Procedure, after = "helper ::")
    expect_kind(t, &res, src, "helper ::", .Procedure)
    expect_kind(t, &res, src, "helper()", .Procedure)
    expect_kind(t, &res, src, "local_proc ::", .Procedure)
    expect_kind(t, &res, src, "local_proc()", .Procedure)
    expect_kind(t, &res, src, "println", .Procedure)
    expect_kind(t, &res, src, "Point ::", .Type)
    expect_kind(t, &res, src, "Point, factor", .Type)
    expect_kind(t, &res, src, "Axis ::", .Type)
    expect_kind(t, &res, src, "Axis.Vertical", .Type)
    expect_kind(t, &res, src, "My_Int ::", .Type)
    expect_kind(t, &res, src, "My_Int = 3", .Type)
    expect_kind(t, &res, src, "Local_Kind ::", .Type)
    expect_kind(t, &res, src, "Local_Kind{", .Type)
    expect_kind(t, &res, src, "Vertical,", .Enum_Member)
    expect_kind(t, &res, src, "Vertical\n", .Enum_Member, after = "Axis.")
    expect_kind(t, &res, src, "Horizontal\n", .Enum_Member, after = "= .")
    expect_kind(t, &res, src, "fmt.println", .Package)

    // A constant value, a package variable, a builtin and a basic type keep the grammar's color.
    expect_none(t, &res, src, "LIMIT ::")
    expect_none(t, &res, src, "LIMIT, counter")
    expect_none(t, &res, src, "counter: int")
    expect_none(t, &res, src, "counter, len")
    expect_none(t, &res, src, "len(")
    expect_none(t, &res, src, "int,")
    expect_none(t, &res, src, "demo")
    for tok in res.tokens {
        testing.expectf(t, tok.kind != .Unresolved, "no workspace: no Unresolved, got one at %d", tok.start)
    }
}

@(test)
test_semantic_selectors_through_using_and_pointer :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Base :: struct {
	id: int,
}

Node :: struct {
	using base: Base,
	next: ^Node,
	kind: Kind,
}

Kind :: enum { Leaf, Branch }

walk :: proc(n: ^Node, using b: ^Base) -> int {
	m := n.next
	if m.kind == .Leaf {
		return m.next.id + n.base.id + id
	}
	return n.id
}
`
    res := semantic_at(e, src)
    defer delete(res.tokens)
    expect_ordered(t, &res, src)

    expect_kind(t, &res, src, "next\n", .Field, after = "n.")
    expect_kind(t, &res, src, "kind ==", .Field)
    expect_kind(t, &res, src, "next.id", .Field)
    expect_kind(t, &res, src, "id + n", .Field)
    expect_kind(t, &res, src, "base.id", .Field)
    expect_kind(t, &res, src, "id + id", .Field, after = "base.")
    expect_kind(t, &res, src, "id\n", .Field, after = "return n.")
    expect_kind(t, &res, src, "Leaf {", .Enum_Member, after = "== .")
    expect_kind(t, &res, src, "b: ^Base", .Parameter)
    // A name a `using` parameter brings in is not a free name of the package.
    expect_none(t, &res, src, "id\n", after = "+ n.base.id + ")
}

@(test)
test_semantic_implicit_members_fields_and_named_arguments :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := `package demo

Axis :: enum { X, Y, Z }

Box :: struct {
	axis: Axis,
	size: int,
}

take :: proc(axis: Axis, count := 1) {}

main :: proc() {
	b := Box{axis = .Y, size = 2}
	take(.Z, count = 3)
	s := bit_set[Axis]{.X}
	switch b.axis {
	case .X:
	}
	_ = s
}
`
    res := semantic_at(e, src)
    defer delete(res.tokens)
    expect_ordered(t, &res, src)

    expect_kind(t, &res, src, "axis = .Y", .Field)
    expect_kind(t, &res, src, "size = 2", .Field)
    expect_kind(t, &res, src, "Y, size", .Enum_Member)
    expect_kind(t, &res, src, "Z, count", .Enum_Member)
    expect_kind(t, &res, src, "count = 3", .Parameter)
    expect_kind(t, &res, src, "X}", .Enum_Member)
    expect_kind(t, &res, src, "X:", .Enum_Member)
    expect_kind(t, &res, src, "axis {", .Field)
}

@(test)
test_semantic_cross_package :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    lib_src := `package lib

Shape :: struct {
	width: int,
}

Mode :: enum { Fast, Slow }

area :: proc(s: Shape) -> int {
	return s.width
}

DEFAULT_WIDTH :: 3
global_count: int
`
    main_src := `package app

import "../lib"

main :: proc() {
	s := lib.Shape{width = lib.DEFAULT_WIDTH}
	_ = lib.area(s) + s.width + lib.global_count
	m := lib.Mode.Slow
	_ = m
}
`
    root := fixture(t, "semantic_packages", {{"lib/lib.odin", lib_src}, {"app/main.odin", main_src}})
    res := semantic_at(e, main_src, workspace = root, path = fixture_path(root, "app/main.odin"))
    defer delete(res.tokens)
    expect_ordered(t, &res, main_src)

    expect_kind(t, &res, main_src, "lib.Shape", .Package)
    expect_kind(t, &res, main_src, "Shape{", .Type)
    expect_kind(t, &res, main_src, "width = ", .Field)
    expect_kind(t, &res, main_src, "area(", .Procedure)
    expect_kind(t, &res, main_src, "width +", .Field)
    expect_kind(t, &res, main_src, "Mode.", .Type)
    expect_kind(t, &res, main_src, "Slow", .Enum_Member)
    expect_none(t, &res, main_src, "DEFAULT_WIDTH")
    expect_none(t, &res, main_src, "global_count")
    for tok in res.tokens {
        testing.expectf(t, tok.kind != .Unresolved, "unexpected Unresolved at %q", main_src[tok.start:tok.end])
    }
}

@(test)
test_semantic_unresolved_only_when_undeclared :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    main_src := `package app

Point :: struct { x: int }

FLAG :: #config(APP_FLAG, false)

main :: proc() {
	v := not_declared_anywhere(1)
	w := v.missing_field
	o := offset_of(Point, x)
	_ = sibling_proc() + w + o + len("a")
	_ = posix_only
	when ODIN_OS == .Windows {
	}
}
`
    sibling_src := `package app

sibling_proc :: proc() -> int { return 1 }
`
    // Out of the build on every target but its own, and still a declaration of the package.
    other_src := `package app

posix_only :: 1
`
    root := fixture(t, "semantic_unresolved", {{"app/main.odin", main_src}, {"app/sibling.odin", sibling_src}, {"app/other_haiku.odin", other_src}})
    res := semantic_at(e, main_src, workspace = root, path = fixture_path(root, "app/main.odin"))
    defer delete(res.tokens)
    expect_ordered(t, &res, main_src)

    expect_kind(t, &res, main_src, "not_declared_anywhere", .Unresolved)
    // Declared, though the checker cannot type it.
    expect_kind(t, &res, main_src, "v :=", .Local)
    expect_kind(t, &res, main_src, "v.missing", .Local)
    expect_none(t, &res, main_src, "missing_field")
    expect_none(t, &res, main_src, "APP_FLAG")
    expect_none(t, &res, main_src, "x)")
    expect_kind(t, &res, main_src, "sibling_proc()", .Procedure)
    expect_none(t, &res, main_src, "posix_only")
    expect_none(t, &res, main_src, "len(")
    expect_none(t, &res, main_src, "ODIN_OS")
    unresolved := 0
    for tok in res.tokens {
        if tok.kind == .Unresolved {
            unresolved += 1
        }
    }
    testing.expectf(t, unresolved == 1, "got %d Unresolved tokens, want 1", unresolved)

    // A buffer with no workspace cannot prove a name undeclared.
    bare := semantic_at(e, main_src)
    defer delete(bare.tokens)
    expect_none(t, &bare, main_src, "not_declared_anywhere")
}

@(test)
test_semantic_range_request :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    src := KINDS_SRC
    lo := strings.index(src, "scale ::")
    hi := strings.index(src, "fmt.println")
    res := semantic_at(e, src, offset = lo, end = hi)
    defer delete(res.tokens)
    expect_ordered(t, &res, src)
    testing.expect(t, len(res.tokens) > 0, "expected tokens in the range")
    for tok in res.tokens {
        testing.expectf(t, tok.start >= lo && tok.end <= hi, "token [%d, %d) outside [%d, %d)", tok.start, tok.end, lo, hi)
    }
    expect_kind(t, &res, src, "factor * 2", .Parameter)
}

// Real files of the repository: ascending, non-overlapping, and no name marked undeclared.
@(test)
test_semantic_real_files :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    for path in ([]string{"lang/odin/sema/check.odin", "thor/view.odin", "editview/editor.odin", "thor/lang_host.odin"}) {
        data, err := os.read_entire_file(path, context.allocator)
        if !testing.expectf(t, err == nil, "%s: could not read", path) {
            continue
        }
        defer delete(data)
        src := string(data)
        start := time.tick_now()
        res := semantic_at(e, src, workspace = ".", path = path)
        cold := time.tick_since(start)
        delete(res.tokens)
        start = time.tick_now()
        res = semantic_at(e, src, workspace = ".", path = path)
        warm := time.tick_since(start)
        defer delete(res.tokens)
        log.infof("%s: %d tokens, cold %v, warm %v", path, len(res.tokens), cold, warm)
        testing.expectf(t, len(res.tokens) > 100, "%s: only %d tokens", path, len(res.tokens))
        expect_ordered(t, &res, src)
        for tok in res.tokens {
            if tok.kind == .Unresolved {
                testing.expectf(t, false, "%s: %q marked Unresolved at %d", path, src[tok.start:tok.end], tok.start)
            }
        }
    }
}
