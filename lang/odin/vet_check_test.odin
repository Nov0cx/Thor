package odin

import "core:log"
import "core:path/filepath"
import "core:testing"

import lang ".."

@(private = "file")
VET_SRC :: `package app

import "core:fmt"
import "core:strings"
@(require) import "core:mem"

g := 1

when ODIN_OS == .Windows {
	len :: proc() {}
}

f :: proc(u: union { int, bool }) {
	x := 1
	{
		x := 2
		_ = x
	}
	{
		x := x
		_ = x
	}
	{
		g := 3
		_ = g
	}
	if x, ok := u.(bool); ok {
		_ = x
	}
	{
		// thor:ignore vet/shadowing
		x := 4
		_ = x
	}
	y := 5
	_ = x
	fmt.println()
	n := 1
	#partial switch n in u {
	case int:
		_ = n
	}
	#partial switch v in u {
	case int:
		#partial switch v in u {
		case bool:
			_ = v
		}
	}
	_ = n
}
`

@(test)
test_live_vet :: proc(t: ^testing.T) {
    root := fixture(t, "live_vet", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    res := live_check(e, VET_SRC, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, VET_SRC, {
        {"\"core:strings\"", "'strings' declared but not used", 0},
        {"len ::", "Declaration of 'len' within a global 'when' shadows the builtin 'len'", 0},
        {"x := 2", "Declaration of 'x' shadows declaration at line 14", 0},
        {"g := 3", "Declaration of 'g' shadows declaration at line 7", 0},
        {"y := 5", "'y' declared but not used", 0},
        {"n in u", "Declaration of 'n' shadows declaration at line 38", 0},
    })
    for d in res.report.items {
        testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Warning)
        testing.expect(t, !d.lint, "a vet item is no lint: the on-save check reports it too")
    }
}

// A `#+vet !name` tag and an id set "off" each turn a check off.
@(test)
test_live_vet_tags_and_config :: proc(t: ^testing.T) {
    root := fixture(t, "live_vet_off", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" }, diagnostics = { ["vet/unused-import"] = "off" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    src := "#+vet !shadowing\n" + VET_SRC
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"len ::", "Declaration of 'len' within a global 'when' shadows the builtin 'len'", 0},
        {"y := 5", "'y' declared but not used", 0},
    })
}

@(test)
test_vet_code :: proc(t: ^testing.T) {
    Case :: struct {
        message: string,
        code:    string,
    }
    cases := []Case {
        {"'x' declared but not used ", CODE_UNUSED_VAR},
        {"Declaration of 'x' shadows declaration at line 25", CODE_SHADOWING},
        {"Declaration of 'x' from 'using' shadows declaration at line 25", CODE_SHADOWING},
        {"Declaration of 'len' within a global 'when' shadows the builtin 'len'", CODE_WHEN_SHADOWING},
        {"Undeclared name: x", ""},
        {"Unneeded cast of 'c' to identical type 'int' ", CODE_CAST},
        {"Unneeded transmute of 'transmute(int)c' to identical type 'int' ", CODE_CAST},
        {"Found unneeded semicolon ", CODE_SEMICOLON},
        {"With '-vet-tabs', tabs must be used for indentation ", CODE_TABS},
        {"Expected a comma, got a newline ", CODE_STYLE},
        {"Dereferencing 'p', which is always nil here ", CODE_NIL_DEREF},
        {"Calling 'fn', which is always nil here ", CODE_NIL_DEREF},
    }
    for c in cases {
        code, ok := vet_code(c.message)
        testing.expectf(t, code == c.code && ok == (c.code != ""), "%q: got %q", c.message, code)
    }
}

@(test)
test_vet_line_helpers :: proc(t: ^testing.T) {
    testing.expect(t, declares_procedure("unused :: proc() {", "'unused' declared but not used"))
    testing.expect(t, declares_procedure("@(private) unused :: proc(a: int) {", "'unused' declared but not used"))
    testing.expect(t, !declares_procedure("x := 1", "'x' declared but not used"))
    testing.expect(t, !declares_procedure("x :: 1", "'x' declared but not used"))
    testing.expect(t, closer_follows("a\n\n\t)\n", 1))
    testing.expect(t, closer_follows("a\n}\n", 1))
    testing.expect(t, !closer_follows("a\nb: int,\n", 1))
    testing.expect(t, !closer_follows("a\n", 1))
}

// The on-save check passes the vet flags and gives each vet line its id and the warning severity; a
// `thor:ignore` comment drops one, and the config sets another one's severity.
@(test)
test_check_vet_lines :: proc(t: ^testing.T) {
    src := `package app

import "core:fmt"

f :: proc() {
	x := 1
	{
		x := 2
		_ = x
	}
	_ = x
	y := 1
	// thor:ignore vet/unused-variable
	z := 1
}
`
    rel := fixture(t, "check_vet", {
        {".thor/odin-analyzer.lua", `return { diagnostics = { ["vet/shadowing"] = "error" } }`},
        {"app/main.odin", src},
    })
    // The compiler runs in the workspace, so the paths it is given must be absolute.
    root, aerr := filepath.abs(rel, context.temp_allocator)
    if !testing.expect_value(t, aerr, nil) {
        return
    }
    if !odin_on_path(root) {
        log.info("odin is not on PATH; skipping the compiler check test")
        return
    }
    e := engine_create()
    defer engine_destroy(e)

    req := lang.Request{kind = .Diagnostics, path = fixture_path(root, "app/main.odin"), ext = ".odin", workspace = root}
    res := lang.Result{kind = .Diagnostics}
    resolve(e, &req, &res)
    defer free_live(&res)

    testing.expect(t, res.ok, "the check should have run")
    Want :: struct {
        line:     int,
        code:     string,
        severity: lang.Diagnostic_Severity,
    }
    wants := []Want{{3, CODE_UNUSED_IMPORT, .Warning}, {8, CODE_SHADOWING, .Error}, {12, CODE_UNUSED_VAR, .Warning}}
    if !testing.expectf(t, len(res.report.items) == len(wants), "got %d items", len(res.report.items)) {
        for d in res.report.items {
            log.infof("%d %s %s", d.line, d.code, d.message)
        }
        return
    }
    for w, i in wants {
        d := res.report.items[i]
        testing.expect_value(t, d.line, w.line)
        testing.expect_value(t, d.code, w.code)
        testing.expect_value(t, d.severity, w.severity)
    }
}

// An import used only in a polymorphic body counts when another file of the package instantiates
// the body, and is unused when nothing does. A use in the signature always counts.
@(test)
test_live_vet_poly_imports :: proc(t: ^testing.T) {
    src := `package app

import "core:fmt"
import "core:strings"
import "core:mem"

called :: proc(v: $T) {
	fmt.println(v)
}

never :: proc(v: $T) {
	_ = strings.to_upper("")
}

sig :: proc(a: mem.Allocator, v: $T) {}
`
    root := fixture(t, "live_vet_poly", {
        {".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`},
        {"app/other.odin", "package app\n\nuse :: proc() {\n\tcalled(1)\n}\n"},
    })
    e := engine_create()
    defer engine_destroy(e)

    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"\"core:strings\"", "'strings' declared but not used", 0},
    })
}

// A field a `using` brings in shadows a variable as the compiler reports it: at the variable the
// `using` names, once per `using`, the lowest shadowed line first.
@(test)
test_live_vet_using_shadowing :: proc(t: ^testing.T) {
    src := `#+feature using-stmt
package app

Point :: struct {
	a: int,
	b: int,
	s: f32,
	using inner: Inner,
}
Inner :: struct { z: int }

g := 1

two :: proc() {
	b := 1
	a := 1
	{
		using p: Point
		_ = p
	}
	_ = a; _ = b
}

nested_field :: proc() {
	z := 1
	{
		pp: ^Point
		using pp
	}
	_ = z
}

param :: proc(a: int) {
	for i in 0..<1 {
		using q: Point
		_ = q
		_ = i
	}
}

no_report :: proc() {
	s := 1
	{
		using r: Point
		_ = r
	}
	k := 1
	_ = k; _ = s
}

global :: proc() {
	{
		using w: struct { g: int }
		_ = w
	}
}
`
    root := fixture(t, "live_vet_using", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e := engine_create()
    defer engine_destroy(e)

    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    expect_errors(t, &res, src, {
        {"p: Point", "Declaration of 'b' from 'using' shadows declaration at line 15", 0},
        {"pp: ^Point", "Declaration of 'z' from 'using' shadows declaration at line 25", 0},
        {"q: Point", "Declaration of 'a' from 'using' shadows declaration at line 33", 0},
        {"w: struct", "Declaration of 'g' from 'using' shadows declaration at line 12", 0},
    })
}
