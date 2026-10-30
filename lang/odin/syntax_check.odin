package odin

import "core:slice"
import "core:strings"

import lang ".."
import odinsyntax "syntax"

// Reports the live errors of the request's buffer as a file-scoped report: its syntax errors, or
// its name errors when it parses clean in a workspace.
@(private)
syntax_diagnostics :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    if req.path == "" {
        return
    }
    rc: Request_Context
    opened := request_open(e, req, &rc)
    defer request_close(&rc)
    if !opened || lang.request_cancelled(req) {
        return
    }

    res.report.scope = strings.clone(req.path)
    res.report.items = make([dynamic]lang.Diagnostic, 0, len(rc.parsed.errors))
    for err in rc.parsed.errors {
        report_error(&rc, &res.report, int(err.offset), odinsyntax.error_message(err))
    }
    if len(rc.parsed.errors) == 0 && req.workspace != "" {
        name_diagnostics(&rc, &res.report)
    }
    if lang.request_cancelled(req) {
        return
    }
    res.ok = true
}

// Appends an error at byte `offset` of the buffer. Takes ownership of `message`.
@(private)
report_error :: proc(rc: ^Request_Context, report: ^lang.Diagnostic_Report, offset: int, message: string) {
    line, col := offset_line_col(rc.live.lines, offset)
    append(
        &report.items,
        lang.Diagnostic {
            path     = strings.clone(rc.req.path),
            line     = line,
            col      = col,
            severity = .Error,
            message  = message,
        },
    )
}

// 1-based line and byte column of `offset`.
@(private)
offset_line_col :: proc(starts: []int, offset: int) -> (line, col: int) {
    i, found := slice.binary_search(starts, offset)
    if !found {
        i -= 1
    }
    i = max(i, 0)
    return i + 1, offset - starts[i] + 1
}
