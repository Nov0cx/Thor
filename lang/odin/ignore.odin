// Diagnostic ids and the `// thor:ignore` comments that suppress them.
package odin

import "core:fmt"
import "core:slice"
import "core:strings"

import lang ".."
import odinsyntax "syntax"

CODE_SYNTAX     :: "syntax/error"
CODE_REDECLARED :: "name/redeclared"
CODE_UNDECLARED :: "name/undeclared"
CODE_PRIVATE    :: "name/private"
CODE_IMPORT     :: "import/unresolved"
CODE_CYCLE      :: "import/cycle"
CODE_ARITY      :: "call/arity"
CODE_NAMED      :: "call/named"
CODE_NO_MEMBER  :: "type/no-member"
CODE_SWITCH     :: "switch/non-exhaustive"
CODE_ASSERT     :: "assert/static"
CODE_MISMATCH   :: "type/mismatch"
CODE_OVERLOAD   :: "call/overload"
CODE_OVERFLOW   :: "const/overflow"
CODE_RETURN     :: "flow/missing-return"
CODE_OR_RETURN  :: "or_return/mismatch"
CODE_WHERE      :: "poly/where"
CODE_COUNT      :: "assign/count"
CODE_UNREACHABLE       :: "flow/unreachable"
CODE_UNREACHABLE_DEFER :: "flow/unreachable-defer"
CODE_UNUSED_VAR        :: "vet/unused-variable"
CODE_DEAD_STORE        :: "flow/dead-store"
CODE_UNUSED_IMPORT     :: "vet/unused-import"
CODE_SHADOWING         :: "vet/shadowing"
CODE_USING_STMT        :: "vet/using-stmt"
CODE_WHEN_SHADOWING    :: "vet/when-shadowing"
CODE_FMT_VERBS         :: "api/fmt-verbs"
CODE_IGNORED_ERROR     :: "api/ignored-error"
CODE_DANGLING_SLICE    :: "mem/dangling-slice"
CODE_TEMP_ESCAPE       :: "mem/temp-escape"
CODE_DEFER_IN_LOOP     :: "defer/in-loop"
CODE_DEPRECATED        :: "api/deprecated"
CODE_RANGE_COPY        :: "perf/range-copy"
CODE_SELF_ASSIGN       :: "logic/self-assign"
CODE_IDENTICAL_BRANCHES :: "logic/identical-branches"
CODE_CONST_CONDITION   :: "logic/const-condition"
CODE_NAMING            :: "style/naming"

// Every id the engine reports.
@(private = "file")
KNOWN_CODES := [?]string{CODE_SYNTAX, CODE_REDECLARED, CODE_UNDECLARED, CODE_PRIVATE, CODE_IMPORT, CODE_ARITY, CODE_NAMED, CODE_NO_MEMBER, CODE_SWITCH, CODE_ASSERT, CODE_MISMATCH, CODE_OVERLOAD, CODE_OVERFLOW, CODE_RETURN, CODE_OR_RETURN, CODE_WHERE, CODE_COUNT, CODE_CYCLE, CODE_UNREACHABLE, CODE_UNREACHABLE_DEFER, CODE_UNUSED_VAR, CODE_DEAD_STORE, CODE_UNUSED_IMPORT, CODE_SHADOWING, CODE_USING_STMT, CODE_WHEN_SHADOWING, CODE_FMT_VERBS, CODE_IGNORED_ERROR, CODE_DANGLING_SLICE, CODE_TEMP_ESCAPE, CODE_DEFER_IN_LOOP, CODE_DEPRECATED, CODE_RANGE_COPY, CODE_SELF_ASSIGN, CODE_IDENTICAL_BRANCHES, CODE_CONST_CONDITION, CODE_NAMING}

// True for an id the engine reports.
@(private)
known_code :: proc(id: string) -> bool {
    return slice.contains(KNOWN_CODES[:], id)
}

// Drops the items of `report` whose id the workspace config turns off, and gives the others the
// severity it sets.
@(private)
apply_severities :: proc(rc: ^Request_Context, report: ^lang.Diagnostic_Report) {
    severities := config_severities(rc.e, rc.req.workspace)
    if len(severities) == 0 {
        return
    }
    kept := 0
    for d in report.items {
        d := d
        if setting, ok := severities[d.code]; ok {
            switch setting {
            case .Off:
                delete(d.path)
                delete(d.message)
                continue
            case .Hint:
                d.severity = .Hint
            case .Warning:
                d.severity = .Warning
            case .Error:
                d.severity = .Error
            }
        }
        report.items[kept] = d
        kept += 1
    }
    resize(&report.items, kept)
}

// The ids one `thor:ignore` comment names, and the line it applies to. No ids means every id.
@(private)
Ignore :: struct {
    line: int, // 1-based; 0 for the whole file
    ids:  []string,
}

// Drops the items of `report` that a `// thor:ignore <id>...` comment suppresses, and warns
// about an id no diagnostic has. `thor:ignore` on its own line applies to the next line, after
// code to its own line; `thor:ignore-file` applies to the whole file.
@(private)
apply_ignores :: proc(rc: ^Request_Context, report: ^lang.Diagnostic_Report) {
    src := rc.req.source
    ignores, unknown := file_ignores(src)
    if len(ignores) == 0 && len(unknown) == 0 {
        return
    }
    kept := 0
    for d in report.items {
        if ignored(ignores, d) {
            delete(d.path)
            delete(d.message)
            continue
        }
        report.items[kept] = d
        kept += 1
    }
    resize(&report.items, kept)
    for offset in unknown {
        end := offset
        for end < len(src) && !strings.is_space(rune(src[end])) {
            end += 1
        }
        message := fmt.aprintf("Unknown diagnostic id '%s'", src[offset:end])
        report_error(rc, report, offset, "", message, .Warning)
    }
    slice.sort_by(report.items[:], proc(a, b: lang.Diagnostic) -> bool {
        return a.line < b.line || (a.line == b.line && a.col < b.col)
    })
}

// The `thor:ignore` comments of `src`, and the offsets of the unknown ids they name. Temp-allocated.
@(private)
file_ignores :: proc(src: string) -> (ignores: []Ignore, unknown: []int) {
    if !strings.contains(src, "thor:ignore") {
        return
    }
    out := make([dynamic]Ignore, context.temp_allocator)
    bad := make([dynamic]int, context.temp_allocator)
    for tok in odinsyntax.lex_all(src, context.temp_allocator) {
        if tok.kind == .Line_Comment {
            read_ignore(src, int(tok.offset), int(tok.offset + tok.len), &out, &bad)
        }
    }
    return out[:], bad[:]
}

// Reads the comment at [start, end) as a `thor:ignore` comment when it is one.
@(private = "file")
read_ignore :: proc(src: string, start, end: int, out: ^[dynamic]Ignore, unknown: ^[dynamic]int) {
    text := src[start + 2:end]
    body := strings.trim_left_space(text)
    file := false
    switch {
    case strings.has_prefix(body, "thor:ignore-file"):
        file = true
        body = body[len("thor:ignore-file"):]
    case strings.has_prefix(body, "thor:ignore"):
        body = body[len("thor:ignore"):]
    case:
        return
    }
    if body != "" && !strings.is_space(rune(body[0])) {
        return
    }
    ids := make([dynamic]string, context.temp_allocator)
    first_unknown := len(unknown)
    rest := body
    for {
        rest = strings.trim_left_space(rest)
        if rest == "" {
            break
        }
        n := 0
        for n < len(rest) && !strings.is_space(rune(rest[n])) {
            n += 1
        }
        id := rest[:n]
        if known_code(id) {
            append(&ids, id)
        } else {
            append(unknown, end - len(rest))
        }
        rest = rest[n:]
    }
    if len(ids) == 0 && len(unknown) > first_unknown {
        // Only unknown ids: suppress nothing rather than everything.
        return
    }
    line := 0
    if !file {
        line = strings.count(src[:start], "\n") + 1
        if alone_on_line(src, start) {
            line += 1
        }
    }
    append(out, Ignore{line, ids[:]})
}

// True when only whitespace is before `offset` on its line.
@(private = "file")
alone_on_line :: proc(src: string, offset: int) -> bool {
    for i := offset - 1; i >= 0 && src[i] != '\n'; i -= 1 {
        if src[i] != ' ' && src[i] != '\t' {
            return false
        }
    }
    return true
}

// True when an ignore comment drops `d`.
@(private)
ignored :: proc(ignores: []Ignore, d: lang.Diagnostic) -> bool {
    for ig in ignores {
        if ig.line != 0 && ig.line != d.line {
            continue
        }
        if len(ig.ids) == 0 || slice.contains(ig.ids, d.code) {
            return true
        }
    }
    return false
}
