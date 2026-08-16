// The LSP snippet template an accepted completion candidate can carry, parsed
// into plain text plus the ranges the caret stops at. The parser is the whole of
// the grammar Thor honors; the live session that walks the stops is in
// editor.odin.
package widgets

import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

// One stop in a parsed snippet: the byte range Tab moves to, relative to the
// snippet's own text, and the tabstop number the template gave it. Index 0 is
// the exit stop and is always visited last. Two stops may share an index — the
// later one mirrors the first's text as it was at insert time.
Snippet_Stop :: struct {
    start: int,
    end:   int,
    index: int,
}

// A parsed template: the text to insert and its stops, in visit order.
Snippet :: struct {
    text:  string,               // owned
    stops: [dynamic]Snippet_Stop, // owned
}

// What the LSP snippet variables resolve to. All optional: an unset one, and any
// variable Thor does not know, resolves to its written default or to nothing.
Snippet_Vars :: struct {
    filename:  string, // TM_FILENAME
    directory: string, // TM_DIRECTORY
    selection: string, // TM_SELECTED_TEXT
    line_text: string, // TM_CURRENT_LINE
    line:      int,    // TM_LINE_NUMBER, 1-based; 0 leaves it empty
}

snippet_destroy :: proc(snip: ^Snippet) {
    delete(snip.text)
    delete(snip.stops)
    snip^ = {}
}

// Parses `template`: `$1`, `${1}`, `${1:default}`, `${1|a,b|}` (the first choice
// becomes the default), `$0`, `$VAR` / `${VAR}` / `${VAR:default}`, and the
// escapes `\$`, `\}` and `\\`. A `${1/regex/format/opts}` transform is not
// supported — the transform is dropped and the stop kept, so the text is right
// and only the substitution is missing. Anything that does not parse stays in
// the text as it was written.
snippet_parse :: proc(template: string, vars := Snippet_Vars{}, allocator := context.allocator) -> Snippet {
    p := Snippet_Parser {
        src   = template,
        vars  = vars,
        out   = strings.builder_make(allocator),
        stops = make([dynamic]Snippet_Stop, allocator),
    }
    snippet_body(&p, false)
    snip := Snippet {
        text  = strings.to_string(p.out),
        stops = p.stops,
    }
    snippet_order(&snip)
    return snip
}

@(private = "file")
Snippet_Parser :: struct {
    src:   string,
    at:    int,
    out:   strings.Builder,
    stops: [dynamic]Snippet_Stop,
    vars:  Snippet_Vars,
}

// Visit order: ascending tabstop number with 0 last, since 0 is where the caret
// leaves the snippet. Stable, so two stops sharing a number keep the order the
// template wrote them in and the first is the one Tab lands on.
@(private = "file")
snippet_order :: proc(snip: ^Snippet) {
    slice.stable_sort_by(snip.stops[:], proc(a, b: Snippet_Stop) -> bool {
        a_key := a.index == 0 ? max(int) : a.index
        b_key := b.index == 0 ? max(int) : b.index
        return a_key < b_key
    })
}

// The template's text, up to the end or — when `nested` — the `}` that closes
// the construct being parsed. The `}` itself is left for the caller.
@(private = "file")
snippet_body :: proc(p: ^Snippet_Parser, nested: bool) {
    for p.at < len(p.src) {
        c := p.src[p.at]
        if c == '\\' && p.at + 1 < len(p.src) {
            if n := p.src[p.at + 1]; n == '$' || n == '}' || n == '\\' {
                strings.write_byte(&p.out, n)
                p.at += 2
                continue
            }
        }
        if nested && c == '}' {
            return
        }
        if c == '$' && snippet_dollar(p) {
            continue
        }
        strings.write_byte(&p.out, c)
        p.at += 1
    }
}

// One `$...` construct. False leaves the `$` to be written as plain text, which
// is what a lone `$` or an unclosed brace comes to.
@(private = "file")
snippet_dollar :: proc(p: ^Snippet_Parser) -> bool {
    at := p.at + 1
    if at >= len(p.src) {
        return false
    }
    if p.src[at] == '{' {
        if index, next, ok := snippet_int(p.src, at + 1); ok {
            return snippet_braced_stop(p, index, next)
        }
        if name, next, ok := snippet_name(p.src, at + 1); ok {
            return snippet_braced_var(p, name, next)
        }
        return false
    }
    if index, next, ok := snippet_int(p.src, at); ok {
        snippet_add_stop(p, index, snippet_mirror(p, index))
        p.at = next
        return true
    }
    if name, next, ok := snippet_name(p.src, at); ok {
        strings.write_string(&p.out, snippet_var_value(p, name))
        p.at = next
        return true
    }
    return false
}

// `${N}`, `${N:default}`, `${N|a,b|}` or `${N/regex/format/opts}`, with `at` just
// past the digits.
@(private = "file")
snippet_braced_stop :: proc(p: ^Snippet_Parser, index, at: int) -> bool {
    if at >= len(p.src) {
        return false
    }
    switch p.src[at] {
    case '}':
        snippet_add_stop(p, index, snippet_mirror(p, index))
        p.at = at + 1
        return true
    case ':':
        start := strings.builder_len(p.out)
        mark := len(p.stops)
        p.at = at + 1
        snippet_body(p, true)
        if p.at >= len(p.src) || p.src[p.at] != '}' {
            return snippet_rewind(p, start, mark)
        }
        append(&p.stops, Snippet_Stop{start = start, end = strings.builder_len(p.out), index = index})
        p.at += 1
        return true
    case '|':
        choice, next, ok := snippet_choice(p.src, at + 1)
        if !ok {
            return false
        }
        snippet_add_stop(p, index, choice)
        p.at = next
        return true
    case '/':
        next, ok := snippet_skip_braced(p.src, at)
        if !ok {
            return false
        }
        // The transform is dropped: the stop is still where the caret goes, and
        // its text is whatever an earlier stop of the same number produced.
        snippet_add_stop(p, index, snippet_mirror(p, index))
        p.at = next
        return true
    }
    return false
}

// `${NAME}`, `${NAME:default}` or `${NAME/regex/format/opts}`, with `at` just
// past the name. A variable with no value falls back to its written default.
@(private = "file")
snippet_braced_var :: proc(p: ^Snippet_Parser, name: string, at: int) -> bool {
    if at >= len(p.src) {
        return false
    }
    value := snippet_var_value(p, name)
    switch p.src[at] {
    case '}':
        strings.write_string(&p.out, value)
        p.at = at + 1
        return true
    case ':':
        start := strings.builder_len(p.out)
        mark := len(p.stops)
        p.at = at + 1
        snippet_body(p, true)
        if p.at >= len(p.src) || p.src[p.at] != '}' {
            return snippet_rewind(p, start, mark)
        }
        p.at += 1
        if value != "" {
            // The default was parsed to find the closing brace; the value wins.
            snippet_rewind(p, start, mark)
            strings.write_string(&p.out, value)
        }
        return true
    case '/':
        next, ok := snippet_skip_braced(p.src, at)
        if !ok {
            return false
        }
        strings.write_string(&p.out, value)
        p.at = next
        return true
    }
    return false
}

// Undoes a partly written construct: the text back to `start` and the stops back
// to `mark`. Always false, so a caller can `return snippet_rewind(...)`.
@(private = "file")
snippet_rewind :: proc(p: ^Snippet_Parser, start, mark: int) -> bool {
    resize(&p.out.buf, start)
    resize(&p.stops, mark)
    return false
}

@(private = "file")
snippet_add_stop :: proc(p: ^Snippet_Parser, index: int, text: string) {
    start := strings.builder_len(p.out)
    strings.write_string(&p.out, text)
    append(&p.stops, Snippet_Stop{start = start, end = strings.builder_len(p.out), index = index})
}

// The text the first stop of `index` produced, cloned out of the builder before
// anything more is written into it. A tabstop number used twice mirrors that
// text once, at insert time; editing one stop afterwards does not follow.
@(private = "file")
snippet_mirror :: proc(p: ^Snippet_Parser, index: int) -> string {
    for stop in p.stops {
        if stop.index == index && stop.end > stop.start {
            return strings.clone(string(p.out.buf[stop.start:stop.end]), context.temp_allocator)
        }
    }
    return ""
}

// A run of digits, and where it ends.
@(private = "file")
snippet_int :: proc(src: string, at: int) -> (value, next: int, ok: bool) {
    next = at
    for next < len(src) && src[next] >= '0' && src[next] <= '9' {
        value = value * 10 + int(src[next] - '0')
        next += 1
    }
    return value, next, next > at
}

// A variable name: a letter or underscore, then letters, digits and underscores.
@(private = "file")
snippet_name :: proc(src: string, at: int) -> (name: string, next: int, ok: bool) {
    if at >= len(src) {
        return
    }
    c := src[at]
    if c != '_' && !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') {
        return
    }
    next = at + 1
    for next < len(src) {
        c = src[next]
        if c != '_' && !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') {
            break
        }
        next += 1
    }
    return src[at:next], next, true
}

// The first alternative of `a,b,c|}`, with `at` just past the opening `|`. The
// rest are dropped: the popup has no second list to offer them in.
@(private = "file")
snippet_choice :: proc(src: string, at: int) -> (choice: string, next: int, ok: bool) {
    out := strings.builder_make(context.temp_allocator)
    done := false
    i := at
    for i < len(src) {
        c := src[i]
        if c == '\\' && i + 1 < len(src) {
            if n := src[i + 1]; n == ',' || n == '|' || n == '\\' {
                if !done {
                    strings.write_byte(&out, n)
                }
                i += 2
                continue
            }
        }
        if c == ',' {
            done = true // keep scanning for the closing `|}`
            i += 1
            continue
        }
        if c == '|' {
            if i + 1 < len(src) && src[i + 1] == '}' {
                return strings.to_string(out), i + 2, true
            }
            return
        }
        if !done {
            strings.write_byte(&out, c)
        }
        i += 1
    }
    return
}

// Past the `}` that closes the construct starting at `at`, counting nested
// braces and honoring backslash escapes.
@(private = "file")
snippet_skip_braced :: proc(src: string, at: int) -> (next: int, ok: bool) {
    depth := 1
    i := at
    for i < len(src) {
        c := src[i]
        if c == '\\' && i + 1 < len(src) {
            i += 2
            continue
        }
        if c == '{' {
            depth += 1
        } else if c == '}' {
            depth -= 1
            if depth == 0 {
                return i + 1, true
            }
        }
        i += 1
    }
    return
}

// An LSP snippet variable. Anything Thor cannot answer resolves to "", which
// leaves a written default in its place.
@(private = "file")
snippet_var_value :: proc(p: ^Snippet_Parser, name: string) -> string {
    switch name {
    case "TM_SELECTED_TEXT":
        return p.vars.selection
    case "TM_CURRENT_LINE":
        return p.vars.line_text
    case "TM_LINE_NUMBER":
        if p.vars.line <= 0 {
            return ""
        }
        buf := make([]byte, 20, context.temp_allocator)
        return strconv.write_int(buf, i64(p.vars.line), 10)
    case "TM_FILENAME":
        return filepath.base(p.vars.filename) if p.vars.filename != "" else ""
    case "TM_FILENAME_BASE":
        if p.vars.filename == "" {
            return ""
        }
        base := filepath.base(p.vars.filename)
        return base[:len(base) - len(filepath.ext(base))]
    case "TM_DIRECTORY":
        return p.vars.directory
    }
    return ""
}
