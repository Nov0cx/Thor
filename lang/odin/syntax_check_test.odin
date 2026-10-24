package odin

import "core:fmt"
import "core:sync"
import "core:testing"

import lang ".."
import odinsema "sema"

@(private = "file")
run_syntax_check :: proc(source: string, e: ^Engine = nil, path := "pkg/file.odin") -> lang.Result {
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
        path   = path,
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
    s := db_stats(e)
    testing.expect_value(t, s.parses, 1)
    testing.expect_value(t, s.reparses, len(sources) - 1)
}

// The database keeps the last parse of the odinsema.LIVE_SLOTS buffers used last.
@(test)
test_syntax_check_evicts_the_oldest :: proc(t: ^testing.T) {
    base :: "package p\n\nmain :: proc() {\n    x := 1\n}\n"
    edit :: "package p\n\nmain :: proc() {\n    x := 12\n}\n"
    e := engine_create()
    defer engine_destroy(e)
    for i in 0 ..< odinsema.LIVE_SLOTS + 2 {
        res := run_syntax_check(base, e, fmt.tprintf("pkg/f%d.odin", i))
        free_report(&res)
    }
    testing.expect_value(t, db_stats(e).parses, odinsema.LIVE_SLOTS + 2)
    res := run_syntax_check(edit, e, fmt.tprintf("pkg/f%d.odin", odinsema.LIVE_SLOTS + 1))
    free_report(&res)
    testing.expect_value(t, db_stats(e).reparses, 1)
    res = run_syntax_check(edit, e, "pkg/f0.odin")
    free_report(&res)
    s := db_stats(e)
    testing.expect_value(t, s.reparses, 1)
    testing.expect_value(t, s.parses, odinsema.LIVE_SLOTS + 3)
}

@(private = "file")
db_stats :: proc(e: ^Engine) -> odinsema.Db_Stats {
    return odinsema.Db_Stats {
        reads        = sync.atomic_load(&e.db.stats.reads),
        parses       = sync.atomic_load(&e.db.stats.parses),
        reparses     = sync.atomic_load(&e.db.stats.reparses),
        trees        = sync.atomic_load(&e.db.stats.trees),
        scopes       = sync.atomic_load(&e.db.stats.scopes),
        local_scopes = sync.atomic_load(&e.db.stats.local_scopes),
    }
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
