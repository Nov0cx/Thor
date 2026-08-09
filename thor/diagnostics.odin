package thor

import "core:path/filepath"
import "core:strings"

import "../lang"
import "../textedit"
import "../widgets"

// Compiler diagnostics, editor side. The check itself lives behind the language
// seam — `lang/odin/check.odin` runs `odin check` on a pool worker and answers a
// lang.Diagnostic_Report like any other request — so what is left here is only
// what needs the live buffers: mapping the compiler's line:col onto piece-table
// byte ranges, and retiring the squiggles of files the new report no longer
// flags. A language whose backend does not check simply answers nothing.

// Queues a check for `file`'s package after a save. The manager debounces it, so
// a burst — save-all across a package, or an autosave landing behind an explicit
// save — costs one compiler run instead of one per file, and cancels any check
// already running for an older revision.
thor_request_diagnostics :: proc(thor: ^Thor, file: ^Open_File) {
    ext := thor_file_extension(file.name)
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    lang.manager_request_debounced(
        &thor.lang_manager,
        .Diagnostics,
        file.path,
        ext,
        "", // the compiler reads the package off disk, which the save just updated
        0,
        file.state.revision,
        thor.workspace_dir,
        delay = lang.DEBOUNCE_CHECK,
    )
}

// Applies a finished report: clears the checked scope's open files, then maps
// each diagnostic onto the buffer it belongs to.
thor_apply_diagnostics :: proc(thor: ^Thor, res: ^lang.Result) {
    if !res.ok {
        return
    }
    // Clear first, so a file whose errors were fixed — and which therefore
    // dropped out of the report entirely — loses its squiggles. Files outside
    // the checked scope keep theirs.
    for file in thor.open_files {
        if file.loaded && !file.closed && scope_covers(file.path, res.report.scope) {
            thor_clear_file_diagnostics(file)
        }
    }
    for d in res.report.items {
        thor_apply_diagnostic(thor, d, res.revision)
    }
}

// Frees a file's diagnostics (and their owned messages) and empties the list.
thor_clear_file_diagnostics :: proc(file: ^Open_File) {
    for d in file.diagnostics {
        delete(d.message)
    }
    clear(&file.diagnostics)
}

// Adds one diagnostic to its matching open file, converting line:col to a byte
// range against the live buffer. `revision` is the report's, i.e. the buffer
// state its producer measured.
@(private = "file")
thor_apply_diagnostic :: proc(thor: ^Thor, d: lang.Diagnostic, revision: u64) {
    for file in thor.open_files {
        if !file.loaded || file.closed || !same_path(file.path, d.path) {
            continue
        }
        // The positions describe the live buffer when the producer measured this
        // exact revision (a server checking the text the editor sent it), or when
        // the buffer still matches disk (a compiler checking the file). A package
        // check reports many files under one revision, so the disk test is what
        // keeps the files other than the saved one. Neither holds: an edit has
        // moved the positions, and a re-check follows it.
        if revision != file.state.revision && file.state.revision != file.saved_revision {
            return
        }
        text := textedit.text(&file.state)
        line0 := d.line - 1
        start := textedit.state_line_start(&file.state, line0) + (d.col - 1)
        start = clamp(start, 0, len(text))
        end := diagnostic_token_end(text, start)
        append(&file.diagnostics, widgets.Diagnostic {
            start    = start,
            end      = end,
            line     = line0,
            severity = editor_severity(d.severity),
            message  = strings.clone(d.message),
        })
        file.diagnostics_revision = file.state.revision
        return
    }
}

// The seam's severity as the editor's. Both carry the same two levels; the split
// is what keeps the language layer free of widget types.
@(private = "file")
editor_severity :: proc(severity: lang.Diagnostic_Severity) -> widgets.Diagnostic_Severity {
    return severity == .Warning ? .Warning : .Error
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

// True when a report's `scope` covers `path`: the scope names that file, or the
// directory it sits directly in. A compiler checks a package and answers a
// directory; a language server checks one buffer and answers its path. Both are
// absolute, but they reach here from different producers, so each is cleaned
// before the compare, which also tolerates a trailing separator.
@(private)
scope_covers :: proc(path, scope: string) -> bool {
    if scope == "" {
        return false
    }
    if same_path(path, scope) {
        return true
    }
    return strings.equal_fold(cleaned(filepath.dir(path)), cleaned(strings.trim_right(scope, "/\\")))
}

// True when two absolute paths name the same file, however each is spelled.
@(private = "file")
same_path :: proc(a, b: string) -> bool {
    return strings.equal_fold(a, b) || strings.equal_fold(cleaned(a), cleaned(b))
}

// `path` with its separators normalized and its `.`/`..` elements resolved, on
// scratch. Falls back to the input if the allocation fails — a compare against
// the raw spelling is still better than none. `filepath.clean` only treats `\`
// as a separator on Windows, but a compiler scope can carry Windows-style
// paths on any host, so `\` is folded to `/` first.
@(private = "file")
cleaned :: proc(path: string) -> string {
    slashed, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
    c, err := filepath.clean(slashed, context.temp_allocator)
    return err == nil ? c : path
}
