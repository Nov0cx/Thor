// Disagreement telemetry: where `odin check` and the live check give different errors.
package odin

import "core:log"

import lang ".."

// Which side reported an error the other side did not.
@(private)
Disagree_Side :: enum u8 {
    Compiler_Only,
    Native_Only,
}

// An error on a line only one of the two checks reports.
@(private)
Disagreement :: struct {
    side: Disagree_Side,
    diag: lang.Diagnostic, // borrowed from the report it came from
}

// The errors of `path` that only one of `native` and `compiler` reports, matched by line.
// A lint or a non-error is not compared. Allocated with context.temp_allocator.
@(private)
find_disagreements :: proc(native, compiler: []lang.Diagnostic, path: string) -> []Disagreement {
    out := make([dynamic]Disagreement, context.temp_allocator)
    for c in compiler {
        if comparable(c, path) && !has_error_on_line(native, path, c.line) {
            append(&out, Disagreement{.Compiler_Only, c})
        }
    }
    for n in native {
        if comparable(n, path) && !has_error_on_line(compiler, path, n.line) {
            append(&out, Disagreement{.Native_Only, n})
        }
    }
    return out[:]
}

@(private = "file")
comparable :: proc(d: lang.Diagnostic, path: string) -> bool {
    return d.severity == .Error && !d.lint && paths_equal(d.path, path)
}

@(private = "file")
has_error_on_line :: proc(items: []lang.Diagnostic, path: string, line: int) -> bool {
    for d in items {
        if d.line == line && comparable(d, path) {
            return true
        }
    }
    return false
}

// Logs each disagreement of the compiler report `compiler` with the live check of the buffer of
// `req`, the checker's to-do list.
@(private)
log_disagreements :: proc(e: ^Engine, req: ^lang.Request, compiler: []lang.Diagnostic) {
    if req.path == "" {
        return
    }
    rc: Request_Context
    opened := request_open(e, req, &rc)
    defer request_close(&rc)
    if !opened || lang.request_cancelled(req) {
        return
    }
    native: lang.Diagnostic_Report
    defer {
        for d in native.items {
            delete(d.path)
            delete(d.message)
        }
        delete(native.items)
    }
    if !live_report(&rc, &native) {
        return
    }
    for d in find_disagreements(native.items[:], compiler, req.path) {
        switch d.side {
        case .Compiler_Only:
            log.infof("odin check differs: compiler-only %s(%d:%d): %s", d.diag.path, d.diag.line, d.diag.col, d.diag.message)
        case .Native_Only:
            log.infof("odin check differs: native-only %s(%d:%d) [%s]: %s", d.diag.path, d.diag.line, d.diag.col, d.diag.code, d.diag.message)
        }
    }
}
