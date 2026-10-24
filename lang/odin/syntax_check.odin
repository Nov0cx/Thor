package odin

import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Reports the syntax errors of the request's buffer as a file-scoped report.
@(private)
syntax_diagnostics :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    if req.path == "" {
        return
    }
    snap: odinsema.Snapshot
    input := odinsema.Snapshot_Input {
        target    = odinsema.target_host(),
        has_live  = true,
        live_path = req.path,
        live_text = req.source,
        cancel    = req.cancel,
    }
    opened := odinsema.snapshot_begin(&e.db, &snap, input)
    defer odinsema.snapshot_end(&snap)
    if !opened {
        return
    }
    id := odinsema.snapshot_live_file(&snap)
    parsed := odinsema.db_parse(&snap, id)
    data := odinsema.db_file(&snap, id)
    if parsed == nil || data == nil || lang.request_cancelled(req) {
        return
    }

    res.report.scope = strings.clone(req.path)
    res.report.items = make([dynamic]lang.Diagnostic, 0, len(parsed.errors))
    for e in parsed.errors {
        line, col := offset_line_col(data.lines, int(e.offset))
        append(
            &res.report.items,
            lang.Diagnostic {
                path     = strings.clone(req.path),
                line     = line,
                col      = col,
                severity = .Error,
                message  = odinsyntax.error_message(e),
            },
        )
    }
    res.ok = true
}

@(private)
line_starts :: proc(source: string) -> []int {
    return odinsema.line_starts(source)
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
