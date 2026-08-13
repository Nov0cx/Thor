// Compiler diagnostics: `odin check` over a package directory, with its output
// parsed into lang.Diagnostic. Alone among this package's requests it analyzes
// nothing itself — the compiler is the source of truth, which is the point:
// correct errors with no type checker to reimplement.
package odin

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"

import lang ".."
import "../../shell"

// Checks the package directory holding `req.path` — one `odin check` run, whose
// every diagnostic line lands in `res.report`. `-no-entry-point` lets a library
// package (no `main`) check. A run that never reached the compiler answers
// `ok = false`, which leaves the existing diagnostics standing.
//
// Serialized on the engine: a check is a whole compiler invocation, so two at
// once would only contend for the machine. The lock is never waited on — a
// compiler run cannot be interrupted, so waiting would hold a pool worker for
// the run's whole duration. The editor cannot reach here twice anyway: the seam
// holds a second Diagnostics request in its debounce slot (EXCLUSIVE_KINDS)
// until this one is reaped, so this only backstops a hand-built request, which
// answers `ok = false` and leaves the existing diagnostics standing.
@(private)
check_package :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    if req.path == "" {
        return
    }
    dir := filepath.dir(req.path) // a slice of req.path, no allocation
    if dir == "" {
        return
    }

    if !sync.mutex_try_lock(&e.check_mutex) {
        return
    }
    defer sync.unlock(&e.check_mutex)
    if lang.request_cancelled(req) {
        return
    }

    // The workspace is the natural place to run from — it is what the console and
    // git use, and what a relative path in the output would be relative to. With
    // no workspace open, the package's own directory serves.
    cwd := req.workspace != "" ? req.workspace : dir
    command := fmt.tprintf("odin check \"%s\" -no-entry-point%s", dir, collection_flags(e, req.workspace))
    output, code, ran := shell.run_status(command, cwd)
    defer delete(output)
    if !ran {
        return
    }

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
    // A failed exit with nothing parsed means the compiler never ran: it is
    // absent from PATH, or it rejected a flag. An empty report would read as
    // "clean" and retire every squiggle in the package, so drop it. result_free
    // frees whatever the report still owns, hence the reset.
    if code != 0 && len(res.report.items) == 0 {
        delete(res.report.scope)
        delete(res.report.items)
        res.report = {}
        return
    }
    // The compiler ran, so `items` is the whole truth for `dir` — including the
    // empty case, which is how the editor learns a fixed file is clean again.
    res.ok = true
}

// `-collection:<name>=<dir>` for every collection the workspace config declares.
// The compiler reads no `.thor/odin-analyzer.json`.
// Each flag is quoted whole — a collection root can hold spaces. An entry the
// compiler would reject (a reserved name, a path that is not a directory) aborts
// the run before it checks anything, so such entries are dropped instead.
// Scratch-allocated.
@(private = "file")
collection_flags :: proc(e: ^Engine, workspace: string) -> string {
    b := strings.builder_make(context.temp_allocator)
    for c in config_collections(e, workspace) {
        if c.name == "core" || c.name == "vendor" || c.name == "base" {
            continue
        }
        if !os.is_dir(c.dir) {
            continue
        }
        fmt.sbprintf(&b, " \"-collection:%s=%s\"", c.name, c.dir)
    }
    return strings.to_string(b)
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
    // A failed parse yields 0, which the guard below rejects with the rest.
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
