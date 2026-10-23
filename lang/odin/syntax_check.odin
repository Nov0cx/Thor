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
    parsed, ok := parse_cache_get(&e.parses, req.path, req.source)
    if !ok {
        return
    }
    defer parse_cache_put(&e.parses, req.path, parsed)
    if lang.request_cancelled(req) {
        return
    }

    starts := line_starts(req.source)
    res.report.scope = strings.clone(req.path)
    res.report.items = make([dynamic]lang.Diagnostic, 0, len(parsed.errors))
    for e in parsed.errors {
        line, col := offset_line_col(starts, int(e.offset))
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
