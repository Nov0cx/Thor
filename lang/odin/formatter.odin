// Per-workspace formatter configuration, read from
// `<workspace>/.thor/odin-formatter.json`, and the .Format request handler
// that layers it onto the odinfmt package. Mirrors config.odin's cache
// exactly — same stat-invalidation, same allocator discipline — since the
// two config files sit side by side in the same `.thor/` folder.
package odin

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import lang ".."
import "format"

@(private)
FORMATTER_CONFIG :: "odin-formatter.json"

// The engine's cached view of one workspace's `.thor/odin-formatter.json`,
// stat-invalidated exactly like Config_Cache: re-read only when the
// workspace changes or the file's modtime/size moves. `newline_present`
// tracks whether the file names `newline_style` at all — see
// lang.Newline_Preference for why an absent key must stay Unspecified.
@(private)
Format_Config_Cache :: struct {
    mutex:           sync.Mutex,
    alloc:           runtime.Allocator,
    workspace:       string, // engine-owned
    loaded:          bool,
    modtime:         i64,
    size:            i64,
    opts:            format.Options,
    newline_present: bool,
}

@(private)
format_config_ensure :: proc(cache: ^Format_Config_Cache, workspace: string) {
    if workspace == "" {
        return
    }
    context.allocator = cache.alloc

    path, jerr := filepath.join({workspace, WORKSPACE_CONFIG_DIR, FORMATTER_CONFIG}, context.temp_allocator)
    if jerr != nil {
        return
    }
    present := false
    mt, sz: i64
    if info, err := os.stat(path, context.temp_allocator); err == nil {
        present = true
        mt = info.modification_time._nsec
        sz = info.size
    }

    if cache.loaded && cache.workspace == workspace && cache.modtime == mt && cache.size == sz {
        return
    }

    cache.opts = format.default_options()
    cache.newline_present = false
    if cache.workspace != workspace {
        delete(cache.workspace, cache.alloc)
        cache.workspace = strings.clone(workspace)
    }
    cache.loaded = true
    cache.modtime = mt
    cache.size = sz

    if present {
        format_config_parse(cache, path)
    }
}

@(private)
format_config_parse :: proc(cache: ^Format_Config_Cache, path: string) {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        return
    }
    value, perr := json.parse(data, allocator = context.temp_allocator)
    if perr != .None {
        return
    }
    obj, ook := value.(json.Object)
    if !ook {
        return
    }

    // A plain integer ("tabs_width": 4) tokenizes as json.Integer, not
    // json.Float — only a literal decimal point or exponent produces a
    // Float. Checking Float alone silently ignores every ordinarily-written
    // integer setting in the file.
    read_int :: proc(obj: json.Object, key: string, dst: ^int) {
        if n, ok := obj[key].(json.Integer); ok {
            dst^ = int(n)
            return
        }
        if n, ok := obj[key].(json.Float); ok {
            dst^ = int(n)
        }
    }
    read_bool :: proc(obj: json.Object, key: string, dst: ^bool) {
        if b, ok := obj[key].(json.Boolean); ok {
            dst^ = bool(b)
        }
    }

    read_int(obj, "character_width", &cache.opts.character_width)
    read_int(obj, "spaces", &cache.opts.spaces)
    read_int(obj, "newline_limit", &cache.opts.newline_limit)
    read_bool(obj, "tabs", &cache.opts.tabs)
    read_int(obj, "tabs_width", &cache.opts.tabs_width)
    read_bool(obj, "convert_do", &cache.opts.convert_do)
    read_bool(obj, "exp_multiline_composite_literals", &cache.opts.exp_multiline_composite_literals)
    read_bool(obj, "indent_cases", &cache.opts.indent_cases)
    read_bool(obj, "inline_single_stmt_case", &cache.opts.inline_single_stmt_case)
    read_bool(obj, "spaces_around_colons", &cache.opts.spaces_around_colons)
    read_bool(obj, "sort_imports", &cache.opts.sort_imports)
    read_bool(obj, "space_single_line_blocks", &cache.opts.space_single_line_blocks)
    read_bool(obj, "align_struct_fields", &cache.opts.align_struct_fields)
    read_bool(obj, "align_struct_values", &cache.opts.align_struct_values)
    read_bool(obj, "align_struct_declarations", &cache.opts.align_struct_declarations)
    read_bool(obj, "align_constant_definitions", &cache.opts.align_constant_definitions)

    if s, ok := obj["brace_style"].(json.String); ok {
        switch s {
        case "_1TBS":      cache.opts.brace_style = ._1TBS
        case "Allman":     cache.opts.brace_style = .Allman
        case "Stroustrup": cache.opts.brace_style = .Stroustrup
        case "K_And_R":    cache.opts.brace_style = .K_And_R
        }
    }
    if s, ok := obj["newline_style"].(json.String); ok {
        cache.newline_present = true
        switch s {
        case "LF":   cache.opts.newline_style = .LF
        case "CRLF": cache.opts.newline_style = .CRLF
        }
    }
}

@(private)
format_config_clear :: proc(e: ^Engine) {
    cache := &e.format_config
    delete(cache.workspace, cache.alloc)
    cache.workspace = ""
    cache.loaded = false
}

// The .Format request handler: parses req.source with the format package
// (core:odin/parser under it, not the tree-sitter grammar this engine uses
// everywhere else), diffs against the original, and answers with the
// minimal Text_Edit set — never a whole-buffer replace, which would drag
// every cursor in the file to wherever the edit ends.
@(private)
format_document :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    if lang.request_cancelled(req) {
        return
    }

    cache := &e.format_config
    sync.lock(&cache.mutex)
    format_config_ensure(cache, req.workspace)
    opts := cache.opts
    newline_present := cache.newline_present
    sync.unlock(&cache.mutex)

    out_alloc := context.allocator
    context.allocator = context.temp_allocator

    formatted, ok := format.format(req.source, opts)
    if !ok {
        return // syntax error — never guess at broken code
    }
    if formatted == req.source {
        res.ok = true
        return
    }

    spans := lang.diff_spans(req.source, formatted)
    context.allocator = out_alloc // res.edits must live in the Manager allocator result_free frees it with
    for span in spans {
        append(&res.edits, lang.Text_Edit{
            path     = strings.clone(req.path, out_alloc),
            start    = span.start,
            end      = span.end,
            old_text = strings.clone(req.source[span.start:span.end], out_alloc),
            new_text = strings.clone(span.text, out_alloc),
        })
    }

    if newline_present {
        switch opts.newline_style {
        case .LF:          res.newline = .LF
        case .CRLF:         res.newline = .CRLF
        case .Unspecified:
        }
    }
    res.ok = true
}
