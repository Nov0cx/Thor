package thor

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

import "../textedit"
import "../widgets"

// Compiler diagnostics via the real toolchain: a save of an Odin file runs
// `odin check` on its package directory on a worker thread; the output is parsed
// on the main thread (where the open buffers are available to map line:col to
// byte offsets) and applied as squiggles + gutter markers. Correct results with
// no type checker to reimplement — the compiler is the source of truth.

// One `odin check` run. The raw stdout+stderr comes back as `output`, parsed on
// the main thread. `dir` is the checked package directory, so the reap knows
// which open files' old diagnostics to clear even when the new run reports none.
Diagnostics_Job :: struct {
    owner:     ^Thor,
    command:   string, // owned
    dir:       string, // owned, absolute package directory checked
    allocator: runtime.Allocator,
    worker:    ^thread.Thread,
    output:    string, // owned, freed on the main thread
}

// Runs a check for the package directory containing `path` (its diagnostics
// cover the whole package). A no-op for anything but the coalescing entry below.
thor_run_diagnostics_for_file :: proc(thor: ^Thor, path: string) {
    thor_run_diagnostics(thor, path_dir(path))
}

// Kicks off `odin check` for `dir`. Coalesced: while one run is in flight a new
// request only records the pending directory, so a single re-run follows rather
// than a pile-up. `-no-entry-point` lets a library package (no `main`) check.
thor_run_diagnostics :: proc(thor: ^Thor, dir: string) {
    if thor.diagnostics_inflight {
        delete(thor.diagnostics_pending_dir)
        thor.diagnostics_pending_dir = strings.clone(dir)
        thor.diagnostics_dirty = true
        return
    }
    thor.diagnostics_inflight = true

    job := new(Diagnostics_Job)
    job.owner = thor
    job.dir = strings.clone(dir)
    job.command = fmt.aprintf("odin check \"%s\" -no-entry-point", dir)
    job.allocator = context.allocator
    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, diagnostics_worker)
}

@(private = "file")
diagnostics_worker :: proc(job: ^Diagnostics_Job) {
    // Output uses the owner's allocator (freed on the main thread); scratch stays
    // on the worker's temp.
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    job.output = run_command(job.command, job.owner.workspace_dir)

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_diagnostics, job)
    sync.unlock(&job.owner.io_mutex)
}

// Reaps a finished check on the main thread: clears the checked package's open
// files, re-parses the output onto them, then frees the job and starts any
// pending re-run. Called from thor_process_io.
thor_reap_diagnostics :: proc(thor: ^Thor, job: ^Diagnostics_Job) {
    thread.join(job.worker)
    thread.destroy(job.worker)

    // Clear diagnostics on every open file in the checked package first, so a
    // file whose errors were fixed (and thus dropped out of the output) loses its
    // squiggles. Files in other packages keep theirs.
    for file in thor.open_files {
        if file.loaded && !file.closed && file_in_dir(file.path, job.dir) {
            thor_clear_file_diagnostics(file)
        }
    }

    it := job.output
    for line in strings.split_lines_iterator(&it) {
        if p, ok := parse_diagnostic_line(line); ok {
            thor_apply_diagnostic(thor, p)
        }
    }

    delete(job.output)
    delete(job.command)
    delete(job.dir)
    free(job)

    thor.diagnostics_inflight = false
    thor.inflight_jobs -= 1

    if thor.diagnostics_dirty {
        thor.diagnostics_dirty = false
        pending := thor.diagnostics_pending_dir
        thor.diagnostics_pending_dir = ""
        thor_run_diagnostics(thor, pending)
        delete(pending)
    }
}

// Frees a file's diagnostics (and their owned messages) and empties the list.
thor_clear_file_diagnostics :: proc(file: ^Open_File) {
    for d in file.diagnostics {
        delete(d.message)
    }
    clear(&file.diagnostics)
}

// A parsed diagnostic line: slices into the source line plus the decoded fields.
@(private)
Parsed_Diagnostic :: struct {
    path:     string,
    line:     int, // 1-based
    col:      int, // 1-based
    severity: widgets.Diagnostic_Severity,
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
level_severity :: proc(level: string) -> (widgets.Diagnostic_Severity, bool) {
    if strings.contains(level, "Warning") {
        return .Warning, true
    }
    if strings.contains(level, "Error") {
        return .Error, true
    }
    return .Error, false
}

// Adds a parsed diagnostic to its matching open file, converting line:col to a
// byte range against the live buffer. Skips a file that has been edited since it
// was saved (revision moved), because the compiler's positions no longer line up
// — a re-check follows that edit's next save.
@(private = "file")
thor_apply_diagnostic :: proc(thor: ^Thor, p: Parsed_Diagnostic) {
    abs := p.path
    if a, err := filepath.abs(p.path, context.temp_allocator); err == nil {
        abs = a
    }
    for file in thor.open_files {
        if !file.loaded || file.closed || file.path != abs {
            continue
        }
        if file.state.revision != file.saved_revision {
            return
        }
        text := textedit.text(&file.state)
        line0 := p.line - 1
        start := textedit.line_start_of_index(text, line0) + (p.col - 1)
        start = clamp(start, 0, len(text))
        end := diagnostic_token_end(text, start)
        append(&file.diagnostics, widgets.Diagnostic {
            start    = start,
            end      = end,
            line     = line0,
            severity = p.severity,
            message  = strings.clone(p.message),
        })
        file.diagnostics_revision = file.state.revision
        return
    }
}

// End of the token to underline from `start`: the run of identifier characters,
// or a short fixed span (bounded to the line) when the caret is not on one, so a
// point diagnostic still shows something.
@(private)
diagnostic_token_end :: proc(text: string, start: int) -> int {
    end := start
    for end < len(text) {
        c := text[end]
        if c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
            end += 1
        } else {
            break
        }
    }
    if end == start {
        for end < len(text) && end < start + 6 && text[end] != '\n' && text[end] != '\r' {
            end += 1
        }
        end = max(end, min(start + 1, len(text)))
    }
    return end
}

// True when `path` sits directly in `dir` (same package directory). Both are
// absolute; the compare tolerates a trailing separator on `dir`.
@(private = "file")
file_in_dir :: proc(path, dir: string) -> bool {
    return strings.equal_fold(strings.trim_right(path_dir(path), "/\\"), strings.trim_right(dir, "/\\"))
}

// The directory part of `path` as a slice (no allocation): everything up to the
// last path separator, or "." when there is none.
@(private = "file")
path_dir :: proc(path: string) -> string {
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '/' || path[i] == '\\' {
            return path[:i]
        }
    }
    return "."
}
