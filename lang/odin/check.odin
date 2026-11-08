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
import "core:time"

import lang ".."
import "../../shell"
import odinsema "sema"
import odinsyntax "syntax"

// Longest an `odin check` may run. A compiler that hangs holds the check lock.
CHECK_TIMEOUT :: 2 * time.Minute

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

    if _, ok := sync.atomic_compare_exchange_strong(&e.checking, false, true); !ok {
        return
    }
    defer sync.atomic_store(&e.checking, false)
    if lang.request_cancelled(req) {
        return
    }

    // The workspace is the natural place to run from — it is what the console and
    // git use, and what a relative path in the output would be relative to. With
    // no workspace open, the package's own directory serves.
    cwd := req.workspace != "" ? req.workspace : dir
    args := make([dynamic]string, context.temp_allocator)
    append(&args, "check", dir, "-no-entry-point")
    collection_flags(e, req.workspace, &args)
    target_flags(e, req.workspace, &args, req.path)
    vet_flag_args(e, req.workspace, req.path, &args)
    // An argument list, not a shell line: the directory and the collection
    // roots come from the workspace.
    output, code, ran := shell.exec_status("odin", args[:], cwd, CHECK_TIMEOUT)
    defer delete(output)
    if !ran {
        return
    }

    res.report.scope = strings.clone(dir)
    res.report.items = make([dynamic]lang.Diagnostic)
    vet := Vet_Context{severities = config_severities(e, req.workspace), files = make(map[string]Vet_File, context.temp_allocator)}
    it := output
    previous := ""
    for line in strings.split_lines_iterator(&it) {
        p, ok := parse_diagnostic_line(line)
        if !ok {
            continue
        }
        // The call site of a failed `where` clause takes the message of the clause.
        if p.message == "at caller location" && previous != "" {
            p.message = previous
        }
        previous = p.message
        d := lang.Diagnostic {
            path     = absolute_path(p.path, cwd),
            line     = p.line,
            col      = p.col,
            severity = p.severity,
        }
        if !vet_item(&vet, &d, p.message) {
            delete(d.path)
            continue
        }
        d.message = strings.clone(p.message)
        append(&res.report.items, d)
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
    if req.workspace != "" && req.source != "" && config_telemetry(e, req.workspace) {
        log_disagreements(e, req, res.report.items[:])
    }
}

// `-collection:<name>=<dir>` for every collection the workspace config declares.
// The compiler reads no `.thor/odin-analyzer.lua`.
// Each flag is one argument — a collection root can hold spaces. An entry the
// compiler would reject (a reserved name, a path that is not a directory) aborts
// the run before it checks anything, so such entries are dropped instead.
// Scratch-allocated.
@(private = "file")
collection_flags :: proc(e: ^Engine, workspace: string, args: ^[dynamic]string) {
    for c in config_collections(e, workspace) {
        if c.name == "core" || c.name == "vendor" || c.name == "base" {
            continue
        }
        if !is_collection_name(c.name) || !os.is_dir(c.dir) {
            continue
        }
        append(args, fmt.tprintf("-collection:%s=%s", c.name, c.dir))
    }
}

// `-target:<os>_<arch>` when the editor sets a target for the file at `path` or the workspace config sets
// one, then `-define:<name>=<value>` for each define of the config. A name the compiler owns (`ODIN_*`) is
// left out. Scratch-allocated.
@(private)
target_flags :: proc(e: ^Engine, workspace: string, args: ^[dynamic]string, path := "") {
    cache := &e.config
    sync.lock(&cache.mutex)
    defer sync.unlock(&cache.mutex)
    choice, own := file_target_lookup(cache, path)
    if own {
        if triple := target_triple(choice.os, choice.arch); triple != "" {
            append(args, fmt.tprintf("-target:%s", triple))
        }
    }
    if workspace == "" {
        return
    }
    config_ensure(cache, workspace)
    if !own && (cache.cfg.target_os != .Unknown || cache.cfg.target_arch != .Unknown) {
        host := odinsema.target_host()
        target_os := cache.cfg.target_os != .Unknown ? cache.cfg.target_os : host.os
        arch := cache.cfg.target_arch != .Unknown ? cache.cfg.target_arch : host.arch
        if triple := target_triple(target_os, arch); triple != "" {
            append(args, fmt.tprintf("-target:%s", triple))
        }
    }
    for d in cache.cfg.defines {
        if strings.has_prefix(d.name, "ODIN_") {
            continue
        }
        switch v in d.value {
        case bool:   append(args, fmt.tprintf("-define:%s=%v", d.name, v))
        case i64:    append(args, fmt.tprintf("-define:%s=%d", d.name, v))
        case string: append(args, fmt.tprintf("-define:%s=%s", d.name, v))
        }
    }
}

// One `-vet-*` argument for each check of the `-vet` set the workspace config does not turn off, and
// `-vet-packages` with the package of `path`, since the compiler vets the imported packages too.
@(private = "file")
vet_flag_args :: proc(e: ^Engine, workspace, path: string, args: ^[dynamic]string) {
    flags := workspace_vet_flags(e, workspace)
    name, ok := file_package_name(path)
    if !ok || flags == {} {
        return
    }
    append(args, fmt.tprintf("-vet-packages:%s", name))
    for flag in flags {
        switch flag {
        case .Unused_Variables: append(args, "-vet-unused-variables")
        case .Unused_Imports:   append(args, "-vet-unused-imports")
        case .Shadowing:        append(args, "-vet-shadowing")
        case .Using_Stmt:       append(args, "-vet-using-stmt")
        case .When_Shadowing:   append(args, "-vet-when-shadowing")
        case .Cast:             append(args, "-vet-cast")
        case .Unused_Procedures: append(args, "-vet-unused-procedures")
        // A syntax-level vet error stops the compiler before it types the package, so these three are served live only.
        case .Style, .Semicolon, .Tabs:
        }
    }
}

// The name of the package clause of the file at `path`.
@(private = "file")
file_package_name :: proc(path: string) -> (string, bool) {
    src, ok := lang.source_read(path, context.temp_allocator)
    if !ok {
        return "", false
    }
    seen_package := false
    for tok in odinsyntax.lex_all(src, context.temp_allocator) {
        #partial switch tok.kind {
        case .Package:
            seen_package = true
        case .Ident:
            if seen_package {
                return src[tok.offset:tok.offset + tok.len], true
            }
            return "", false
        case .Whitespace, .Newline, .Line_Comment, .Block_Comment, .File_Tag:
        case:
            if seen_package {
                return "", false
            }
        }
    }
    return "", false
}

// What the vet lines of one report read from the config and the files.
@(private = "file")
Vet_Context :: struct {
    severities: map[string]Severity_Setting,
    files:      map[string]Vet_File, // by path
}

// The source and the `thor:ignore` comments of a file a vet line names.
@(private = "file")
Vet_File :: struct {
    src:     string,
    ignores: []Ignore,
    ok:      bool,
}

// Gives a vet line of the compiler its id and severity. False when the config or a `thor:ignore`
// comment drops it. Any other line is kept as it is.
@(private = "file")
vet_item :: proc(vet: ^Vet_Context, d: ^lang.Diagnostic, message: string) -> bool {
    if d.severity != .Error {
        return true
    }
    code, ok := vet_code(message)
    if !ok {
        return true
    }
    file, cached := vet.files[d.path]
    if !cached {
        src, read := lang.source_read(d.path, context.temp_allocator)
        file = Vet_File{src = src, ok = read}
        if read {
            file.ignores, _ = file_ignores(src)
        }
        vet.files[d.path] = file
    }
    text := file.ok ? line_text(file.src, d.line) : ""
    switch code {
    case CODE_UNUSED_VAR:
        if file.ok && strings.has_prefix(strings.trim_left_space(text), "import") {
            code = CODE_UNUSED_IMPORT
        } else if file.ok && declares_procedure(text, message) {
            code = CODE_UNUSED_PROC
        }
    case CODE_STYLE:
        // Without `-vet-style` the same line is a real syntax error, unless a closer follows.
        if !file.ok || !closer_follows(file.src, d.line) {
            return true
        }
    }
    d.code = code
    d.severity = code == CODE_NIL_DEREF ? .Hint : .Warning
    if setting, set := vet.severities[code]; set {
        switch setting {
        case .Off:     return false
        case .Hint:    d.severity = .Hint
        case .Warning:
        case .Error:   d.severity = .Error
        }
    }
    return !ignored(file.ignores, d^)
}

// True when `text` is the line of a `name :: proc` declaration, `message` being `'name' declared but not used`.
@(private)
declares_procedure :: proc(text, message: string) -> bool {
    open := strings.index_byte(message, '\'')
    if open < 0 {
        return false
    }
    rest := message[open + 1:]
    name := rest[:max(strings.index_byte(rest, '\''), 0)]
    at := strings.index(text, name)
    if name == "" || at < 0 {
        return false
    }
    after := strings.trim_left_space(text[at + len(name):])
    return strings.has_prefix(after, "::") && strings.has_prefix(strings.trim_left_space(after[2:]), "proc")
}

// True when the first line after 1-based `line` that holds text starts with a closing bracket.
@(private)
closer_follows :: proc(src: string, line: int) -> bool {
    rest := src
    n := 1
    for l in strings.split_lines_iterator(&rest) {
        if n > line {
            t := strings.trim_space(l)
            if t == "" {
                continue
            }
            return t[0] == ')' || t[0] == '}' || t[0] == ']'
        }
        n += 1
    }
    return false
}

// The id of a vet message of the compiler. An unused import reads like an unused variable.
@(private)
vet_code :: proc(message: string) -> (string, bool) {
    m := strings.trim_space(message)
    switch {
    case strings.has_suffix(m, "declared but not used"):
        return CODE_UNUSED_VAR, true
    case strings.contains(m, "within a global 'when' shadows the builtin"):
        return CODE_WHEN_SHADOWING, true
    case strings.has_prefix(m, "Declaration of '") && strings.contains(m, " shadows declaration at line "):
        return CODE_SHADOWING, true
    case strings.has_prefix(m, "Unneeded cast of '") || strings.has_prefix(m, "Unneeded transmute of '"):
        return CODE_CAST, true
    case m == "Found unneeded semicolon":
        return CODE_SEMICOLON, true
    case strings.has_prefix(m, "With '-vet-tabs'"):
        return CODE_TABS, true
    case m == "Expected a comma, got a newline":
        return CODE_STYLE, true
    case strings.has_suffix(m, ", which is always nil here") && (strings.has_prefix(m, "Dereferencing '") || strings.has_prefix(m, "Calling '")):
        return CODE_NIL_DEREF, true
    }
    return "", false
}

// The text of 1-based line `line` of `src`; "" past its end.
@(private = "file")
line_text :: proc(src: string, line: int) -> string {
    rest := src
    n := 1
    for l in strings.split_lines_iterator(&rest) {
        if n == line {
            return l
        }
        n += 1
    }
    return ""
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
        // An error with no level word (`Unhandled switch case: C`); a snippet or `at` line is indented.
        if rest == "" || line[0] == ' ' || line[0] == '\t' {
            return {}, false
        }
        p.message = rest
        if tab := strings.index_byte(rest, '\t'); tab >= 0 {
            p.message = strings.trim_space(rest[:tab])
        }
        p.severity = .Error
        return p, true
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
