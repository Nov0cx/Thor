// Plugin linting: the thor.lint linters run on a buffer that went still, and their items show as
// lint items beside the language backend's.
package thor

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"

import "../editview"
import "../lang"
import "../plugin"
import "../textedit"

// How long a buffer must sit unedited before the plugin linters run on it.
PLUGIN_LINT_IDLE :: 300 * time.Millisecond

// Runs the linters of the file's routing key once per revision, after PLUGIN_LINT_IDLE.
@(private = "package")
thor_update_plugin_lints :: proc(thor: ^Thor, file: ^Open_File) {
    if !file.loaded || thor_big_file(file) || file.plugin_lint_asked_valid && file.plugin_lint_asked == file.state.revision {
        return
    }
    if time.tick_since(file.last_edit) < PLUGIN_LINT_IDLE {
        return
    }
    file.plugin_lint_asked = file.state.revision
    file.plugin_lint_asked_valid = true
    key := thor_lang_key(thor, file.name)
    if !plugin.manager_has_linters(&thor.plugins, key) {
        if len(file.plugin_lints) > 0 {
            thor_clear_file_plugin_lints(file)
        }
        return
    }
    items := plugin.manager_run_linters(&thor.plugins, key, file.path, textedit.text(&file.state), context.temp_allocator)
    thor_clear_file_plugin_lints(file)
    text := textedit.text(&file.state)
    for item in items {
        line0 := item.line - 1
        if line0 >= textedit.state_line_count(&file.state) {
            continue
        }
        line_start := textedit.state_line_start(&file.state, line0)
        line_end   := line_start
        for line_end < len(text) && text[line_end] != '\n' {
            line_end += 1
        }
        start := clamp(line_start + item.col - 1, line_start, line_end)
        end   := diagnostic_token_end(text, start)
        if item.end_col > item.col {
            end = clamp(line_start + item.end_col - 1, start, line_end)
        }
        source := thor_diagnostic_source(thor, fmt.tprintf("plugin:%s", plugin.manager_plugin_id(&thor.plugins, item.owner)))
        append(
            &file.plugin_lints,
            editview.Diagnostic{
                start = start,
                end = max(end, start),
                line = line0,
                severity = thor_lint_severity(item.severity),
                message = strings.clone(item.message),
                lint = true,
                source = source,
            },
        )
    }
    file.plugin_lint_revision = file.state.revision
    file.plugin_view_valid = false
}

@(private = "file")
thor_lint_severity :: proc(s: plugin.Lint_Severity) -> editview.Diagnostic_Severity {
    switch s {
    case .Error:
        return .Error
    case .Warning:
        return .Warning
    case .Information:
        return .Information
    case .Hint:
        return .Hint
    }
    return .Warning
}

// Frees the plugin lint items of a file.
thor_clear_file_plugin_lints :: proc(file: ^Open_File) {
    for d in file.plugin_lints {
        delete(d.message)
    }
    clear(&file.plugin_lints)
    file.plugin_view_valid = false
}

// Frees the plugin lint state of a closing file.
thor_destroy_file_plugin_lints :: proc(file: ^Open_File) {
    thor_clear_file_plugin_lints(file)
    delete(file.plugin_lints)
    delete(file.plugin_view)
}

// `base` with the plugin lint items of the file when they are of its text. The joined list is
// kept on the file and built again when `base` or the items change.
@(private = "package")
thor_with_plugin_lints :: proc(file: ^Open_File, base: []editview.Diagnostic) -> []editview.Diagnostic {
    if len(file.plugin_lints) == 0 || file.plugin_lint_revision != file.state.revision {
        return base
    }
    if file.plugin_view_valid &&
        file.plugin_view_epoch == file.diagnostics_epoch &&
        file.plugin_view_base == raw_data(base) &&
        file.plugin_view_len == len(base) {
        return file.plugin_view[:]
    }
    clear(&file.plugin_view)
    append(&file.plugin_view, ..base)
    append(&file.plugin_view, ..file.plugin_lints[:])
    file.plugin_view_valid = true
    file.plugin_view_epoch = file.diagnostics_epoch
    file.plugin_view_base = raw_data(base)
    file.plugin_view_len = len(base)
    return file.plugin_view[:]
}

// Host proc of thor.lint.symbols: the document symbols of the file, from the in-process backend.
thor_lint_symbols :: proc(host: rawptr, path: string, allocator: runtime.Allocator) -> []plugin.Lint_Symbol {
    thor            := cast(^Thor)host
    source, ext, ok := thor_lint_source(thor, path)
    if !ok {
        return nil
    }
    res := lang.manager_resolve_now(&thor.lang_manager, .Document_Symbols, path, ext, source, 0, thor.workspace_dir)
    defer lang.result_release(&res)
    out := make([]plugin.Lint_Symbol, len(res.symbols), allocator)
    for s, i in res.symbols {
        out[i] = plugin.Lint_Symbol{name = strings.clone(s.name, allocator), kind = strings.clone(s.kind, allocator), line = s.line}
    }
    return out
}

// Host proc of thor.lint.type_at: the hover text of the name at `offset`, from the in-process backend.
thor_lint_type :: proc(host: rawptr, path: string, offset: int, allocator: runtime.Allocator) -> string {
    thor            := cast(^Thor)host
    source, ext, ok := thor_lint_source(thor, path)
    if !ok || offset < 0 || offset > len(source) {
        return ""
    }
    res := lang.manager_resolve_now(&thor.lang_manager, .Hover, path, ext, source, offset, thor.workspace_dir)
    defer lang.result_release(&res)
    return res.ok ? strings.clone(res.hover.text, allocator) : ""
}

// The text of the file at `path`: its buffer when open, else the file on disk. Temp-allocated.
@(private = "file")
thor_lint_source :: proc(thor: ^Thor, path: string) -> (source, ext: string, ok: bool) {
    if file := thor_open_file_at(thor, path); file != nil && file.loaded {
        return textedit.text_clone(&file.state, context.temp_allocator), thor_lang_key(thor, file.name), true
    }
    text, read := lang.source_read(path, context.temp_allocator)
    if !read {
        return "", "", false
    }
    name := path
    if at := strings.last_index_any(path, "/\\"); at >= 0 {
        name = path[at + 1:]
    }
    return text, thor_lang_key(thor, name), true
}
