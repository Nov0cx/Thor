// Semantic classification: the kinds the analyzer proves that the grammar
// cannot, the positions it deliberately says nothing about, and the guards that
// give up the right to dim an undeclared name.
package odin

import "core:os"
import "core:strings"
import "core:testing"

import lang ".."

// Classifies `source` whole. Callers own res.tokens.
@(private)
semantic_at :: proc(e: ^Engine, source: string, workspace := "", path := "buffer.odin") -> lang.Result {
    req := lang.Request{kind = .Semantic_Tokens, path = path, ext = ".odin", source = source, workspace = workspace}
    res := lang.Result{kind = .Semantic_Tokens}
    resolve(e, &req, &res)
    return res
}

// The kind classified at the first occurrence of `needle`, if any.
@(private)
kind_at :: proc(res: ^lang.Result, source, needle: string) -> (lang.Token_Kind, bool) {
    at := strings.index(source, needle)
    for tok in res.tokens {
        if tok.start == at {
            return tok.kind, true
        }
    }
    return {}, false
}

// True when any token was emitted for the first occurrence of `needle`.
@(private)
classified :: proc(res: ^lang.Result, source, needle: string) -> bool {
    _, ok := kind_at(res, source, needle)
    return ok
}

@(test)
test_semantic_separates_parameter_from_local :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The grammar paints every one of these `@variable`: only resolution tells a
    // parameter from a local from a package from a procedure.
    src := `package demo

import "core:fmt"

Point :: struct {
	x: int,
}

scale :: proc(p: Point, factor: int) -> int {
	total := factor * 2
	fmt.println(total)
	return total
}
`
    res := semantic_at(e, src)
    defer delete(res.tokens)

    cases := [][2]string {
        {"factor * 2", "parameter use"},
        {"p: Point", "parameter declaration"},
    }
    for c in cases {
        kind, ok := kind_at(&res, src, c[0])
        testing.expectf(t, ok, "expected a token for the %s", c[1])
        if ok {
            testing.expectf(t, kind == .Parameter, "%s: got %v, want Parameter", c[1], kind)
        }
    }

    local, lok := kind_at(&res, src, "total\n")
    testing.expect(t, lok, "expected a token for the local's use")
    if lok {
        testing.expectf(t, local == .Local, "local use: got %v, want Local", local)
    }

    pkg, pok := kind_at(&res, src, "fmt.println")
    testing.expect(t, pok, "expected a token for the package operand")
    if pok {
        testing.expectf(t, pkg == .Package, "package operand: got %v, want Package", pkg)
    }

    proc_kind, prok := kind_at(&res, src, "scale ::")
    testing.expect(t, prok, "expected a token for the procedure name")
    if prok {
        testing.expectf(t, proc_kind == .Procedure, "procedure: got %v, want Procedure", proc_kind)
    }

    type_kind, tok := kind_at(&res, src, "Point, factor")
    testing.expect(t, tok, "expected a token for the parameter's type")
    if tok {
        testing.expectf(t, type_kind == .Type, "type use: got %v, want Type", type_kind)
    }
}

@(test)
test_semantic_skips_grammar_positions :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Everywhere the parse already proves what the identifier is. A token here
    // could only overrule a correct color with a worse one.
    src := `package demo

import rl "core:fmt"

Axis :: enum {
	Vertical,
}

Point :: struct {
	x: int,
}

read :: proc(p: Point) -> int {
	return p.x
}
`
    res := semantic_at(e, src)
    defer delete(res.tokens)

    skipped := [][2]string {
        {"demo", "the package clause"},
        {"rl \"core:fmt\"", "an import alias"},
        {"Vertical", "an enum member"},
        {"x: int", "a struct field"},
        {"x\n}", "a selector's right-hand side"},
    }
    for s in skipped {
        testing.expectf(t, !classified(&res, src, s[0]), "expected no token for %s", s[1])
    }

    // Both type declarations are named the same way, so both keep a token.
    for needle in ([]string{"Axis ::", "Point ::"}) {
        kind, ok := kind_at(&res, src, needle)
        testing.expectf(t, ok, "expected a token for %q", needle)
        if ok {
            testing.expectf(t, kind == .Type, "%q: got %v, want Type", needle, kind)
        }
    }
}

@(test)
test_semantic_tokens_are_ordered :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The seam promises the editor ascending, non-overlapping tokens: it merges
    // them against the syntax spans with one cursor that only moves forward.
    src := `package demo

add :: proc(a: int, b: int) -> int {
	sum := a + b
	doubled := sum + sum
	return doubled
}
`
    res := semantic_at(e, src)
    defer delete(res.tokens)

    testing.expect(t, len(res.tokens) > 0, "expected the file to classify something")
    prev := 0
    for tok in res.tokens {
        testing.expectf(t, tok.start >= prev, "token at %d starts before the previous one ended (%d)", tok.start, prev)
        testing.expectf(t, tok.end > tok.start, "empty token at %d", tok.start)
        prev = tok.end
    }
}

@(test)
test_semantic_dims_undeclared_name :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // With a workspace to check against, a name nothing declares is the one
    // thing the analyzer knows that no amount of parsing could.
    root := "thor_lang_sem_ws"
    _ = os.make_directory(root)
    helper := strings.concatenate({root, "/helper.odin"}, context.temp_allocator)
    _ = os.write_entire_file(helper, transmute([]byte) string("package demo\n\nknown :: 1\n"))
    defer os.remove(root)
    defer os.remove(helper)

    path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    src := `package demo

run :: proc(value: int) -> int {
	return value + known + missing_name
}
`
    res := semantic_at(e, src, root, path)
    defer delete(res.tokens)

    kind, ok := kind_at(&res, src, "missing_name")
    testing.expect(t, ok, "expected the undeclared name to classify")
    if ok {
        testing.expectf(t, kind == .Unresolved, "missing_name: got %v, want Unresolved", kind)
    }
    testing.expect(t, !classified(&res, src, "known +"), "a workspace declaration must not be dimmed")
    testing.expect(t, !classified(&res, src, "int"), "a builtin type must not be dimmed")
}

@(test)
test_semantic_dims_nothing_reachable :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Everything here is declared somewhere the engine can reach: the builtin
    // scope, an imported package, the file itself. Dimming any of it reads as an
    // error the compiler never reported, which is the one thing this pass must
    // never do.
    root := "thor_lang_sem_reach_ws"
    _ = os.make_directory(root)
    helper := strings.concatenate({root, "/helper.odin"}, context.temp_allocator)
    _ = os.write_entire_file(helper, transmute([]byte)string("package demo\n\nknown :: 1\n"))
    defer os.remove(root)
    defer os.remove(helper)

    path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    src := `package demo

import "core:fmt"
import "core:os"

Axis :: enum {
	Vertical,
}

sized_a :: proc(a: int) -> int {return a}
sized_b :: proc(a, b: int) -> int {return a + b}

sizes :: proc{sized_a, sized_b}

split :: proc(text: string) -> (head, tail: string, ok: bool) {
	head = text
	return head, tail, ok
}

run :: proc(loud: bool) -> int {
	items := make([]int, 4)
	defer delete(items)
	append(&items, known)
	for &item in items {
		item += 1
	}
	fmt.println(os.args, len(items), Axis.Vertical, sizes)
	total := split(fmt.tprintf("%v", loud))
	handle, _ := os.open("x")
	os.close(handle)
	a: Axis = .Vertical
	_ = a
	_ = total
	return run(loud = true)
}
`
    res := semantic_at(e, src, root, path)
    defer delete(res.tokens)

    dimmed := make([dynamic]string, context.temp_allocator)
    for tok in res.tokens {
        if tok.kind == .Unresolved {
            append(&dimmed, src[tok.start:tok.end])
        }
    }
    testing.expectf(t, len(dimmed) == 0, "nothing here is undeclared, but %v was dimmed", dimmed[:])

    // The guards did not simply give up: the file was judged, it just found
    // nothing to flag.
    testing.expect(t, len(res.tokens) > 0, "expected the file to classify something")

    kind, ok := kind_at(&res, src, "head = text")
    testing.expect(t, ok, "expected a token for a named result")
    if ok {
        testing.expectf(t, kind == .Parameter, "named result: got %v, want Parameter", kind)
    }
}

@(test)
test_semantic_dimming_needs_a_workspace :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // The kill switches all fail open, and each gives up dimming only —
    // classification carries on, so the file keeps its parameter and local colors.
    src := `package demo

run :: proc(value: int) -> int {
	return value + missing_name
}
`
    res := semantic_at(e, src)
    defer delete(res.tokens)

    testing.expect(t, !classified(&res, src, "missing_name"), "no workspace: nothing may be dimmed")
    kind, ok := kind_at(&res, src, "value +")
    testing.expect(t, ok, "no workspace: classification must continue")
    if ok {
        testing.expectf(t, kind == .Parameter, "value: got %v, want Parameter", kind)
    }
}

@(test)
test_semantic_dimming_gives_up_on_using :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // A `using` statement injects names from a scope this engine does not
    // follow, so nothing in the file can be called undeclared any more.
    root := "thor_lang_sem_using_ws"
    _ = os.make_directory(root)
    helper := strings.concatenate({root, "/helper.odin"}, context.temp_allocator)
    _ = os.write_entire_file(helper, transmute([]byte) string("package demo\n\nknown :: 1\n"))
    defer os.remove(root)
    defer os.remove(helper)

    path := strings.concatenate({root, "/main.odin"}, context.temp_allocator)
    src := `package demo

Point :: struct {
	x: int,
}

run :: proc(p: Point) -> int {
	using p
	return x + missing_name
}
`
    res := semantic_at(e, src, root, path)
    defer delete(res.tokens)

    testing.expect(t, !classified(&res, src, "missing_name"), "a using statement must stop dimming")
    kind, ok := kind_at(&res, src, "p: Point")
    testing.expect(t, ok, "classification must continue in a file holding a using statement")
    if ok {
        testing.expectf(t, kind == .Parameter, "p: got %v, want Parameter", kind)
    }
}
