package odin

import "core:fmt"
import "core:strings"
import "core:testing"

import lang ".."

// The live report of `source` as the buffer of `path` in `workspace`.
@(private = "file")
live_check :: proc(e: ^Engine, source, workspace, path: string) -> lang.Result {
    req := lang.Request {
        kind      = .Syntax_Diagnostics,
        path      = path,
        ext       = ".odin",
        source    = source,
        workspace = workspace,
    }
    res: lang.Result
    syntax_diagnostics(e, &req, &res)
    return res
}

@(private = "file")
free_live :: proc(res: ^lang.Result) {
    for d in res.report.items {
        delete(d.path)
        delete(d.message)
    }
    delete(res.report.items)
    delete(res.report.scope)
}

// An expected error: the message at the `skip`th occurrence of `needle`.
@(private = "file")
Want :: struct {
    needle:  string,
    message: string,
    skip:    int,
}

// Expects the report to hold exactly `wants`, in order.
@(private = "file")
expect_errors :: proc(t: ^testing.T, res: ^lang.Result, source: string, wants: []Want, loc := #caller_location) {
    testing.expect(t, res.ok, "the live check must answer", loc = loc)
    got := make([dynamic]string, context.temp_allocator)
    for d in res.report.items {
        append(&got, fmt.tprintf("%d:%d %s", d.line, d.col, d.message))
    }
    want := make([dynamic]string, context.temp_allocator)
    for w in wants {
        at := -1
        from := 0
        for _ in 0 ..= w.skip {
            i := strings.index(source[from:], w.needle)
            if i < 0 {
                at = -1
                break
            }
            at = from + i
            from = at + 1
        }
        if at < 0 {
            testing.expectf(t, false, "needle %q not found", w.needle, loc = loc)
            return
        }
        line := strings.count(source[:at], "\n") + 1
        col := at - (strings.last_index_byte(source[:at], '\n') + 1) + 1
        append(&want, fmt.tprintf("%d:%d %s", line, col, w.message))
    }
    testing.expectf(t, len(got) == len(want), "got %v, want %v", got[:], want[:], loc = loc)
    for g, i in got {
        if i < len(want) {
            testing.expectf(t, g == want[i], "item %d: got %q, want %q", i, g, want[i], loc = loc)
        }
    }
}

@(test)
test_live_redeclared_in_package :: proc(t: ^testing.T) {
    root := fixture(t, "live_redeclared_package", {
        {"app/other.odin", "package app\n\nshared :: proc() {}\n"},
        {"app/other_linux.odin", "package app\n\nposix_only :: 1\n"},
        {"app/hidden.odin", "#+private file\npackage app\n\nhidden :: 1\n"},
    })
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

g :: proc() {}
g :: proc() {}
shared :: 1
hidden :: 2

when ODIN_OS == .Windows {
	twin :: 1
} else {
	twin :: 2
}

main :: proc() {}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"g ::", "Redeclaration of 'g' in this scope", 1},
        {"shared ::", "Redeclaration of 'shared' in this scope", 0},
    })
}

@(test)
test_live_redeclared_import :: proc(t: ^testing.T) {
    root := fixture(t, "live_redeclared_import", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "core:fmt"
import fmt "core:strings"
import _ "core:mem"
import _ "core:os"

fmt_value :: 1

main :: proc() { fmt.println("a") }
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {{"fmt \"core:strings\"", "Redeclaration of 'fmt' in this scope", 0}})
}

@(test)
test_live_redeclared_locals :: proc(t: ^testing.T) {
    root := fixture(t, "live_redeclared_locals", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

g :: proc() -> int { return 1 }

f :: proc(x: int, x: int) {
	y := 1
	y := 2
	z, y := 3, 4
	A :: 1
	A :: 2
	_ = z
}

h :: proc(a: int) -> (r: int) {
	a := a
	r := 1
	{
		r := 2
		_ = r
	}
	return
}

k :: proc() {
	s: union{int, f32}
	switch v in s {
	case int:
		v := v
		_ = v
	case f32:
	}
	for i in 0 ..< 2 {
		i := i
		_ = i
	}
	if n := g(); n > 0 {
		n := 3
		_ = n
	}
	L: for {
		break L
	}
	L := 1
	_ = L
	when ODIN_OS == .Windows {
		w := 1
		_ = w
	} else {
		w := 2
		_ = w
	}
}

main :: proc() {}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"x: int) {", "Redeclaration of 'x' in this scope", 0},
        {"y := 2", "Redeclaration of 'y' in this scope", 0},
        {"y := 3", "Redeclaration of 'y' in this scope", 0},
        {"A :: 2", "Redeclaration of 'A' in this scope", 0},
        {"r := 1", "Direct shadowing of the named return value 'r' in this scope", 0},
        {"v := v", "Redeclaration of 'v' in this scope", 0},
    })
}

// A file with syntax errors reports only those.
@(test)
test_live_syntax_errors_first :: proc(t: ^testing.T) {
    root := fixture(t, "live_syntax_first", {{"app/a.odin", "package app\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := "package app\n\ng :: proc() {}\ng :: proc() {}\nmain :: proc() {\n    foo(1,\n}\n"
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    testing.expect(t, res.ok)
    for d in res.report.items {
        testing.expectf(t, !strings.has_prefix(d.message, "Redeclaration"), "a broken file must report syntax errors only, got %q", d.message)
    }
}

@(test)
test_live_undeclared_names :: proc(t: ^testing.T) {
    root := fixture(t, "live_undeclared", {
        {"app/other.odin", "package app\n\nsibling :: proc() -> int { return 1 }\n"},
        {"app/other_linux.odin", "package app\n\nposix_only :: 1\n"},
        {"app/q/q.odin", "package q\n\nopen :: proc() {}\n@(private) hidden :: proc() {}\n@(private = \"file\") secret :: proc() {}\n"},
        {"app/q/q_private.odin", "#+private\npackage q\n\ntagged :: proc() {}\n"},
    })
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "q"

Point :: struct { x: int }

main :: proc() {
	_ = zork
	_ = sibling() + posix_only + len("a")
	_ = offset_of(Point, x)
	q.open()
	q.hidden()
	q.secret()
	q.tagged()
	q.missing()
}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"zork", "Undeclared name: zork", 0},
        {"q.hidden", "'hidden' is not exported by 'q'", 0},
        {"q.secret", "'secret' is not declared by 'q'", 0},
        {"q.tagged", "'tagged' is not exported by 'q'", 0},
        {"q.missing", "'missing' is not declared by 'q'", 0},
    })
}

@(test)
test_live_unresolved_imports :: proc(t: ^testing.T) {
    root := fixture(t, "live_imports", {{"app/q/q.odin", "package q\n"}})
    e := engine_create()
    defer engine_destroy(e)

    src := `package app

import "q"
import "nothere"
import "core:fmt/nothere"
import "nope:x"
import "core:fmt"

main :: proc() {}
`
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"import \"nothere\"", "Path does not exist: nothere", 0},
        {"import \"core:fmt/", "Path does not exist: core:fmt/nothere", 0},
        {"import \"nope", "Unknown library collection: 'nope'", 0},
    })
}
