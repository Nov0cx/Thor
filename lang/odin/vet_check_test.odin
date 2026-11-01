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
    }
    for c in cases {
        code, ok := vet_code(c.message)
        testing.expectf(t, code == c.code && ok == (c.code != ""), "%q: got %q", c.message, code)
    }
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
