// The LSP snippet template an accepted completion candidate can carry, parsed
// into plain text plus the ranges the caret stops at. The parser is the whole of
// the grammar Thor honors; the live session that walks the stops is in
// editor.odin.
package snippet

import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// One stop in a parsed snippet: the byte range Tab moves to, relative to the
// snippet's own text, and the tabstop number the template gave it. Index 0 is
// the exit stop and is always visited last. Two stops may share an index — the
// later one mirrors the first's text.
Stop :: struct {
    start:        int,
    end:          int,
    index:        int,
    transform:    int, // 1-based into Snippet.transforms; 0 when the stop has none
    choice_first: int, // into Snippet.choices
    choice_count: int, // 0 when the stop is not a choice
    depth:        int, // placeholders around the stop
}

// A parsed template: the text to insert and its stops, in visit order.
Snippet :: struct {
    text:       string,               // owned
    stops:      [dynamic]Stop,        // owned
    transforms: [dynamic]Transform,   // owned, with their strings
    choices:    [dynamic]string,      // owned, with their strings
}

// What the LSP snippet variables resolve to. All optional: an unset one, and any
// variable Thor does not know, resolves to its written default or to nothing.
Vars :: struct {
    filename:   string, // TM_FILEPATH; TM_FILENAME is its last element
    directory:  string, // TM_DIRECTORY
    workspace:  string, // WORKSPACE_FOLDER
    selection:  string, // TM_SELECTED_TEXT
    line_text:  string, // TM_CURRENT_LINE
    clipboard:  string, // CLIPBOARD
    line:       int,    // TM_LINE_NUMBER, 1-based; 0 leaves it empty
    // The local clock for the CURRENT_* variables. Read only when has_time is set.
    has_time:   bool,
    year:       int,
    month:      int, // 1 to 12
    day:        int, // 1 to 31
    weekday:    int, // 0 is Sunday
    hour:       int,
    minute:     int,
    second:     int,
    unix:       i64, // seconds
    utc_offset: int, // minutes east of UTC
}

destroy :: proc(snip: ^Snippet) {
    delete(snip.text)
    delete(snip.stops)
    for tr in snip.transforms {
        delete(tr.pattern)
        delete(tr.format)
    }
    delete(snip.transforms)
    for choice in snip.choices {
        delete(choice)
    }
    delete(snip.choices)
    snip^ = {}
}

// Parses `template`: `$1`, `${1}`, `${1:default}`, `${1|a,b|}` (the first choice
// is the default), `${1/regex/format/opts}`, `$0`, `$VAR` / `${VAR}` /
// `${VAR:default}` / `${VAR/regex/format/opts}`, and the escapes `\$`, `\}` and
// `\\`. Anything that does not parse stays in the text as it was written.
parse :: proc(template: string, vars := Vars{}, allocator := context.allocator) -> Snippet {
    p := Parser {
        src        = template,
        vars       = vars,
        allocator  = allocator,
        out        = strings.builder_make(allocator),
        stops      = make([dynamic]Stop, allocator),
        transforms = make([dynamic]Transform, allocator),
        choices    = make([dynamic]string, allocator),
    }
    snippet_body(&p, false)
    snip := Snippet {
        text       = strings.to_string(p.out),
        stops      = p.stops,
        transforms = p.transforms,
        choices    = p.choices,
    }
    snippet_order(&snip)
    return snip
}

// Puts the snippet at the indent of the line it lands on: `line_indent` goes
// after each newline, and each leading tab of a template line becomes `unit`.
// A blank line stays blank. The stops move with the text.
indent :: proc(snip: ^Snippet, line_indent, unit: string, allocator := context.allocator) {
    if !strings.contains_rune(snip.text, '\n') && !strings.has_prefix(snip.text, "\t") {
        return
    }
    old := snip.text
    out := strings.builder_make(0, len(old) + 16, allocator)
    moved := make([]int, len(old) + 1, context.temp_allocator)
    line_start := true // no character but a tab on this line yet
    indented := true   // the first line is at the indent already
    for i := 0; i < len(old); i += 1 {
        c := old[i]
        if !indented && c != '\n' {
            strings.write_string(&out, line_indent)
            indented = true
        }
        moved[i] = strings.builder_len(out)
        switch {
        case line_start && c == '\t':
            strings.write_string(&out, unit)
        case:
            strings.write_byte(&out, c)
            line_start = c == '\n'
            if line_start {
                indented = false
            }
        }
    }
    if !indented {
        strings.write_string(&out, line_indent)
    }
    moved[len(old)] = strings.builder_len(out)

    for &stop in snip.stops {
        stop.start = moved[stop.start]
        stop.end = moved[stop.end]
    }
    delete(old, allocator)
    snip.text = strings.to_string(out)
}

@(private = "file")
Parser :: struct {
    src:        string,
    at:         int,
    out:        strings.Builder,
    stops:      [dynamic]Stop,
    transforms: [dynamic]Transform,
    choices:    [dynamic]string,
    vars:       Vars,
    allocator:  mem.Allocator,
    depth:      int, // placeholders open around `at`
}

// Visit order: ascending tabstop number with 0 last, since 0 is where the caret
// leaves the snippet. Stable, so two stops sharing a number keep the order the
// template wrote them in and the first is the one Tab lands on.
@(private = "file")
snippet_order :: proc(snip: ^Snippet) {
    slice.stable_sort_by(snip.stops[:], proc(a, b: Stop) -> bool {
        a_key := a.index == 0 ? max(int) : a.index
        b_key := b.index == 0 ? max(int) : b.index
        return a_key < b_key
    })
}

// The template's text, up to the end or — when `nested` — the `}` that closes
// the construct being parsed. The `}` itself is left for the caller.
@(private = "file")
snippet_body :: proc(p: ^Parser, nested: bool) {
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
snippet_dollar :: proc(p: ^Parser) -> bool {
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
snippet_braced_stop :: proc(p: ^Parser, index, at: int) -> bool {
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
        p.depth += 1
        snippet_body(p, true)
        p.depth -= 1
        if p.at >= len(p.src) || p.src[p.at] != '}' {
            return snippet_rewind(p, start, mark)
        }
        append(&p.stops, Stop{start = start, end = strings.builder_len(p.out), index = index, depth = p.depth})
        p.at += 1
        return true
    case '|':
        choices, next, ok := snippet_choice(p.src, at + 1)
        if !ok || len(choices) == 0 {
            return false
        }
        first := len(p.choices)
        for choice in choices {
            append(&p.choices, strings.clone(choice, p.allocator))
        }
        snippet_add_stop(p, index, choices[0])
        stop := &p.stops[len(p.stops) - 1]
        stop.choice_first = first
        stop.choice_count = len(choices)
        p.at = next
        return true
    case '/':
        tr, next, ok := transform_parse(p.src, at)
        if !ok {
            return false
        }
        // The stop mirrors the first stop of its number through the transform.
        snippet_add_stop(p, index, transform_apply(snippet_mirror(p, index), tr))
        append(&p.transforms, transform_clone(tr, p.allocator))
        p.stops[len(p.stops) - 1].transform = len(p.transforms)
        p.at = next
        return true
    }
    return false
}

// `${NAME}`, `${NAME:default}` or `${NAME/regex/format/opts}`, with `at` just
// past the name. A variable with no value falls back to its written default.
@(private = "file")
snippet_braced_var :: proc(p: ^Parser, name: string, at: int) -> bool {
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
        tr, next, ok := transform_parse(p.src, at)
        if !ok {
            return false
        }
        strings.write_string(&p.out, transform_apply(value, tr))
        p.at = next
        return true
    }
    return false
}

// Undoes a partly written construct: the text back to `start` and the stops back
// to `mark`. Always false, so a caller can `return snippet_rewind(...)`.
@(private = "file")
snippet_rewind :: proc(p: ^Parser, start, mark: int) -> bool {
    resize(&p.out.buf, start)
    resize(&p.stops, mark)
    return false
}

@(private = "file")
snippet_add_stop :: proc(p: ^Parser, index: int, text: string) {
    start := strings.builder_len(p.out)
    strings.write_string(&p.out, text)
    append(&p.stops, Stop{start = start, end = strings.builder_len(p.out), index = index, depth = p.depth})
}

// The text the first stop of `index` produced, cloned out of the builder before
// anything more is written into it.
@(private = "file")
snippet_mirror :: proc(p: ^Parser, index: int) -> string {
    for stop in p.stops {
        if stop.index == index && stop.transform == 0 && stop.end > stop.start {
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

// The alternatives of `a,b,c|}`, with `at` just past the opening `|`. In the
// temp allocator.
@(private = "file")
snippet_choice :: proc(src: string, at: int) -> (choices: [dynamic]string, next: int, ok: bool) {
    choices = make([dynamic]string, context.temp_allocator)
    out := strings.builder_make(context.temp_allocator)
    i := at
    for i < len(src) {
        c := src[i]
        if c == '\\' && i + 1 < len(src) {
            if n := src[i + 1]; n == ',' || n == '|' || n == '\\' {
                strings.write_byte(&out, n)
                i += 2
                continue
            }
        }
        if c == ',' {
            append(&choices, strings.clone(strings.to_string(out), context.temp_allocator))
            strings.builder_reset(&out)
            i += 1
            continue
        }
        if c == '|' {
            if i + 1 < len(src) && src[i + 1] == '}' {
                append(&choices, strings.clone(strings.to_string(out), context.temp_allocator))
                return choices, i + 2, true
            }
            return
        }
        strings.write_byte(&out, c)
        i += 1
    }
    return
}

@(private = "file")
MONTH_NAMES := [12]string {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

@(private = "file")
DAY_NAMES := [7]string {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}

// An LSP snippet variable. Anything Thor cannot answer resolves to "", which
// leaves a written default in its place.
@(private = "file")
snippet_var_value :: proc(p: ^Parser, name: string) -> string {
    v := p.vars
    switch name {
    case "TM_SELECTED_TEXT":
        return v.selection
    case "TM_CURRENT_LINE":
        return v.line_text
    case "TM_LINE_NUMBER":
        return v.line > 0 ? fmt.tprintf("%d", v.line) : ""
    case "TM_LINE_INDEX":
        return v.line > 0 ? fmt.tprintf("%d", v.line - 1) : ""
    case "TM_FILEPATH":
        return v.filename
    case "TM_FILENAME":
        return filepath.base(v.filename) if v.filename != "" else ""
    case "TM_FILENAME_BASE":
        if v.filename == "" {
            return ""
        }
        base := filepath.base(v.filename)
        return base[:len(base) - len(filepath.ext(base))]
    case "TM_DIRECTORY":
        return v.directory
    case "RELATIVE_FILEPATH":
        if v.filename == "" || v.workspace == "" {
            return v.filename
        }
        rel, err := filepath.rel(v.workspace, v.filename, context.temp_allocator)
        return err == .None ? rel : v.filename
    case "WORKSPACE_FOLDER":
        return v.workspace
    case "WORKSPACE_NAME":
        return filepath.base(v.workspace) if v.workspace != "" else ""
    case "CLIPBOARD":
        return v.clipboard
    }
    if !v.has_time || !strings.has_prefix(name, "CURRENT_") {
        return ""
    }
    month := clamp(v.month, 1, 12) - 1
    weekday := clamp(v.weekday, 0, 6)
    switch name {
    case "CURRENT_YEAR":
        return fmt.tprintf("%04d", v.year)
    case "CURRENT_YEAR_SHORT":
        return fmt.tprintf("%02d", v.year %% 100)
    case "CURRENT_MONTH":
        return fmt.tprintf("%02d", v.month)
    case "CURRENT_MONTH_NAME":
        return MONTH_NAMES[month]
    case "CURRENT_MONTH_NAME_SHORT":
        return MONTH_NAMES[month][:3]
    case "CURRENT_DATE":
        return fmt.tprintf("%02d", v.day)
    case "CURRENT_DAY_NAME":
        return DAY_NAMES[weekday]
    case "CURRENT_DAY_NAME_SHORT":
        return DAY_NAMES[weekday][:3]
    case "CURRENT_HOUR":
        return fmt.tprintf("%02d", v.hour)
    case "CURRENT_MINUTE":
        return fmt.tprintf("%02d", v.minute)
    case "CURRENT_SECOND":
        return fmt.tprintf("%02d", v.second)
    case "CURRENT_SECONDS_UNIX":
        return fmt.tprintf("%d", v.unix)
    case "CURRENT_TIMEZONE_OFFSET":
        offset := abs(v.utc_offset)
        return fmt.tprintf("%s%02d:%02d", v.utc_offset < 0 ? "-" : "+", offset / 60, offset % 60)
    }
    return ""
}
