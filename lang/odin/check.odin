// Compiler diagnostics: `odin check` over a package directory, with its output
// parsed into lang.Diagnostic. Alone among this package's requests it analyzes
// nothing itself — the compiler is the source of truth, which is the point:
// correct errors with no type checker to reimplement.
package odin

import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

import lang ".."
import "../../shell"

// How often a queued check re-tests whether the running one has finished (or
// whether it has itself been superseded). Invisible next to a compiler run, and
// what keeps a waiting check from pinning a worker thread.
@(private = "file")
CHECK_POLL :: 50 * time.Millisecond

// Checks the package directory holding `req.path` — one `odin check` run, whose
// every diagnostic line lands in `res.report`. `-no-entry-point` lets a library
// package (no `main`) check.
//
// Serialized on the engine: a check is a whole compiler invocation, so two at
// once would only contend for the machine. The wait polls rather than blocking
// outright — a compiler run cannot be interrupted, so a request superseded while
// it queued would otherwise hold a pool worker for seconds, and enough rapid
// saves would park every worker behind a run nobody wants any more. Polling lets
// it give the worker back within a tick, and the winner re-tests cancellation
// once it holds the lock, so a superseded check never spawns a process at all.
@(private)
check_package :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    if req.path == "" {
        return
    }
    dir := filepath.dir(req.path) // a slice of req.path, no allocation
    if dir == "" {
        return
    }

    for !sync.mutex_try_lock(&e.check_mutex) {
        if lang.request_cancelled(req) {
            return
        }
        time.sleep(CHECK_POLL)
    }
    defer sync.unlock(&e.check_mutex)
    if lang.request_cancelled(req) {
        return
    }

    // The workspace is the natural place to run from — it is what the console and
    // git use, and what a relative path in the output would be relative to. With
    // no workspace open, the package's own directory serves.
    cwd := req.workspace != "" ? req.workspace : dir
    command := fmt.tprintf("odin check \"%s\" -no-entry-point", dir)
    output := shell.run(command, cwd)
    defer delete(output)

    res.report.scope = strings.clone(dir)
    res.report.items = make([dynamic]lang.Diagnostic)
    it := output
    for line in strings.split_lines_iterator(&it) {
        p, ok := parse_diagnostic_line(line)
        if !ok {
            continue
        }
        append(
            &res.report.items,
            lang.Diagnostic {
                path     = absolute_path(p.path, cwd),
                line     = p.line,
                col      = p.col,
                severity = p.severity,
                message  = strings.clone(p.message),
            },
        )
    }
    // The run completed, so `items` is the whole truth for `dir` — including the
    // empty case, which is how the editor learns a fixed file is clean again.
    res.ok = true
}

// A parsed diagnostic line: the decoded fields, with `path` and `message` still
// slices into the line the caller passed.
@(private)
Parsed_Diagnostic :: struct {
    path:     string,
    line:     int, // 1-based
    col:      int, // 1-based
    severity: lang.Diagnostic_Severity,
    message:  string,
}

// Parses one `odin check` line of the form `PATH(LINE:COL) Level: message`
// (Level is Error / Warning / Syntax Error). Source-snippet and summary lines do
// not match and return ok=false. The path must end in ".odin", which rules out a
// snippet line that happens to contain a "(1:2)"-shaped run.
@(private)
parse_diagnostic_line :: proc(raw: string) -> (Parsed_Diagnostic, bool) {
    line := strings.trim_right(raw, "\r")

    // Locate "(L:C)": a '(' followed by digits, ':', digits, ')'.
    open, colon, close := -1, -1, -1
    for i := 0; i < len(line); i += 1 {
        if line[i] != '(' {
            continue
        }
        j := i + 1
        d1 := 0
        for j < len(line) && line[j] >= '0' && line[j] <= '9' {
            j += 1; d1 += 1
        }
        if d1 == 0 || j >= len(line) || line[j] != ':' {
            continue
        }
        c := j
        j += 1
        d2 := 0
        for j < len(line) && line[j] >= '0' && line[j] <= '9' {
            j += 1; d2 += 1
        }
        if d2 == 0 || j >= len(line) || line[j] != ')' {
            continue
        }
        open, colon, close = i, c, j
        break
    }
    if open <= 0 {
        return {}, false
    }

    p: Parsed_Diagnostic
    p.path = line[:open]
    if !strings.has_suffix(p.path, ".odin") {
        return {}, false
    }
    p.line, _ = strconv.parse_int(line[open + 1:colon])
    p.col, _ = strconv.parse_int(line[colon + 1:close])
    if p.line <= 0 || p.col <= 0 {
        return {}, false
    }

    rest := strings.trim_space(line[close + 1:])
    level := rest
    if sep := strings.index(rest, ": "); sep >= 0 {
        level = rest[:sep]
        p.message = rest[sep + 2:]
    }
    sev, ok := level_severity(level)
    if !ok {
        return {}, false
    }
    p.severity = sev
    return p, true
}

// Maps an Odin diagnostic level word to a severity. A word without "Error" or
// "Warning" (e.g. a random "(1:2)" line) is rejected.
@(private = "file")
level_severity :: proc(level: string) -> (lang.Diagnostic_Severity, bool) {
    if strings.contains(level, "Warning") {
        return .Warning, true
    }
    if strings.contains(level, "Error") {
        return .Error, true
    }
    return .Error, false
}

// The compiler prints paths as it was handed them, so a relative one resolves
// against `base` — the directory the command ran in. Cleaned either way: the
// editor keys its open files on absolute paths in the platform's own separator,
// and `odin check` answers in forward slashes even on Windows. Cloned into
// context.allocator.
@(private = "file")
absolute_path :: proc(path, base: string) -> string {
    full := path
    if base != "" && !filepath.is_abs(path) {
        joined, err := filepath.join({base, path}, context.temp_allocator)
        if err != nil {
            return strings.clone(path)
        }
        full = joined
    }
    clean, err := filepath.clean(full, context.temp_allocator)
    if err != nil {
        return strings.clone(full)
    }
    return strings.clone(clean)
}
