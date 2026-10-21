package odin

import "core:testing"

import lang ".."

@(private = "file")
run_syntax_check :: proc(source: string) -> lang.Result {
    req := lang.Request {
        kind   = .Syntax_Diagnostics,
        path   = "pkg/file.odin",
        ext    = ".odin",
        source = source,
    }
    res: lang.Result
    syntax_diagnostics(&req, &res)
    return res
}

@(private = "file")
free_report :: proc(res: ^lang.Result) {
    for d in res.report.items {
        delete(d.path)
        delete(d.message)
    }
    delete(res.report.items)
    delete(res.report.scope)
}

@(test)
test_syntax_check_clean_file :: proc(t: ^testing.T) {
    res := run_syntax_check("package p\n\nmain :: proc() {\n    x := 1\n    _ = x\n}\n")
    defer free_report(&res)
    testing.expect(t, res.ok, "a parsed file must answer ok")
    testing.expect_value(t, res.report.scope, "pkg/file.odin")
    testing.expect_value(t, len(res.report.items), 0)
}

@(test)
test_syntax_check_reports_line_and_col :: proc(t: ^testing.T) {
    res := run_syntax_check("package p\n\nmain :: proc() {\n    foo(1,\n}\n")
    defer free_report(&res)
    testing.expect(t, res.ok)
    testing.expect(t, len(res.report.items) > 0, "an unclosed call must be reported")
    if len(res.report.items) == 0 {
        return
    }
    d := res.report.items[0]
    testing.expect_value(t, d.path, "pkg/file.odin")
    testing.expect_value(t, d.severity, lang.Diagnostic_Severity.Error)
    testing.expect(t, d.line >= 4 && d.line <= 5, "the error must be on the call or the brace")
    testing.expect(t, d.col >= 1)
    testing.expect(t, d.message != "")
}

@(test)
test_syntax_check_first_line :: proc(t: ^testing.T) {
    res := run_syntax_check("x :: 1\n")
    defer free_report(&res)
    testing.expect(t, res.ok)
    testing.expect(t, len(res.report.items) > 0, "a missing package declaration must be reported")
    if len(res.report.items) == 0 {
        return
    }
    testing.expect_value(t, res.report.items[0].line, 1)
    testing.expect_value(t, res.report.items[0].col, 1)
}
