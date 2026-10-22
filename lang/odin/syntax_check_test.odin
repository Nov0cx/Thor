package odin

import "core:fmt"
import "core:testing"

import lang ".."

@(private = "file")
run_syntax_check :: proc(source: string, e: ^Engine = nil) -> lang.Result {
    e := e
    own := e == nil
    if own {
        e = engine_create()
    }
    defer if own {
        engine_destroy(e)
    }
    req := lang.Request {
        kind   = .Syntax_Diagnostics,
        path   = "pkg/file.odin",
        ext    = ".odin",
        source = source,
    }
    res: lang.Result
    syntax_diagnostics(e, &req, &res)
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

// Requests in a row on one buffer reuse its cached parse and report what a fresh parse reports.
@(test)
test_syntax_check_reuses_the_parse :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    sources := []string {
        "package p\n\nmain :: proc() {\n    x := 1\n}\n",
        "package p\n\nmain :: proc() {\n    x := 12\n}\n",
        "package p\n\nmain :: proc() {\n    x := 12\n    foo(1,\n}\n",
        "package p\n\nmain :: proc() {\n    x := 12\n    foo(1)\n}\n",
    }
    for source in sources {
        res := run_syntax_check(source, e)
        cold := run_syntax_check(source)
        testing.expect(t, res.ok && cold.ok)
        testing.expect_value(t, len(res.report.items), len(cold.report.items))
        for d, i in res.report.items {
            if i < len(cold.report.items) {
                c := cold.report.items[i]
                testing.expectf(t, d.line == c.line && d.col == c.col && d.message == c.message, "%q: got %v, want %v", source, d, c)
            }
        }
        free_report(&res)
        free_report(&cold)
    }
    testing.expect_value(t, len(e.parses.entries), 1)
    if len(e.parses.entries) == 1 {
        testing.expect_value(t, e.parses.entries[0].parse.tree.text, sources[len(sources) - 1])
        testing.expect(t, e.parses.entries[0].parse.tree.generation > 0, "the later requests must reparse, not parse cold")
    }
}

// The cache keeps the PARSE_CACHE_SLOTS buffers used last.
@(test)
test_parse_cache_evicts_the_oldest :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)
    for i in 0 ..< PARSE_CACHE_SLOTS + 2 {
        path := fmt.tprintf("pkg/f%d.odin", i)
        parsed, ok := parse_cache_get(&e.parses, path, "package p\n")
        if !testing.expect(t, ok) {
            return
        }
        parse_cache_put(&e.parses, path, parsed)
    }
    testing.expect_value(t, len(e.parses.entries), PARSE_CACHE_SLOTS)
    testing.expect_value(t, e.parses.entries[0].path, "pkg/f2.odin")
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
