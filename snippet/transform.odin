package snippet

import "core:mem"
import "core:strings"
import "core:text/regex"
import "core:text/regex/common"
import vm "core:text/regex/virtual_machine"
import "core:unicode"
import "core:unicode/utf8"

// The `/regex/format/opts` part of a variable or a tabstop.
Transform :: struct {
    pattern:   string, // owned by the Snippet that holds it
    format:    string, // owned by the Snippet that holds it
    global:    bool,   // `g`: every match, not the first only
    icase:     bool,   // `i`
    multiline: bool,   // `m`
}

// The result of `tr` on `text`. Text outside a match is kept. A pattern that
// does not compile, and a text with no match, give `text` back.
//
// The format takes `$N` and `${N}` for a capture group, `${N:/upcase}`,
// `/downcase`, `/capitalize`, `/camelcase` and `/pascalcase`, `${N:+if}`,
// `${N:?if:else}`, `${N:-else}` and `${N:else}`, and the escapes `\n`, `\t` and
// `\` before any other character.
transform_apply :: proc(text: string, tr: Transform, allocator := context.temp_allocator) -> string {
    flags: regex.Flags = {.Unicode}
    if tr.icase {
        flags += {.Case_Insensitive}
    }
    if tr.multiline {
        flags += {.Multiline}
    }
    rx, err := regex.create(tr.pattern, flags, context.temp_allocator, context.temp_allocator)
    if err != nil {
        return text
    }
    // The machine is run here and not through regex.match_iterator: that one
    // drops a group that took no part, which moves the number of each later group.
    m := vm.create(rx.program, text, context.temp_allocator)
    m.class_data = rx.class_data
    threads := max(1, vm.opcode_count(m.code) - 1)

    b := strings.builder_make(0, len(text), allocator)
    groups: [common.MAX_CAPTURE_GROUPS][2]int
    last := 0
    matched := false
    for run := 0;; run += 1 {
        if run > 0 {
            m.top_thread = 0
            m.current_rune = 0
            m.current_rune_size = 0
            for i in 0 ..< threads {
                m.threads[i] = {}
                m.next_threads[i] = {}
            }
        }
        saved: ^[2 * common.MAX_CAPTURE_GROUPS]int
        ok: bool
        {
            context.allocator = context.temp_allocator
            saved, ok = vm.run(&m, true)
        }
        if !ok || saved == nil {
            break
        }
        for &span, i in groups {
            span = {saved[2 * i], saved[2 * i + 1]}
        }
        start, end := groups[0][0], groups[0][1]
        if start < last || end < start {
            break
        }
        matched = true
        strings.write_string(&b, text[last:start])
        transform_format(&b, text, groups[:], tr.format)
        last = end
        if !tr.global || end >= len(text) {
            break
        }
        if end <= start {
            // A match that takes no text leaves the machine where it was. Step one rune.
            _, width := utf8.decode_rune_in_string(text[start:])
            m.string_pointer = start + width
            m.last_rune, _ = utf8.decode_last_rune_in_string(text[:start + width])
        }
    }
    if !matched {
        return text
    }
    strings.write_string(&b, text[last:])
    return strings.to_string(b)
}

// Reads `/regex/format/opts}` with `at` on the first slash. The strings are in
// the temp allocator; `next` is past the closing brace.
@(private)
transform_parse :: proc(src: string, at: int) -> (tr: Transform, next: int, ok: bool) {
    pattern := strings.builder_make(context.temp_allocator)
    i := at + 1
    for {
        if i >= len(src) {
            return
        }
        c := src[i]
        if c == '/' {
            break
        }
        if c == '\\' && i + 1 < len(src) {
            // An escaped slash is a slash for the engine; the rest is its own.
            if src[i + 1] != '/' {
                strings.write_byte(&pattern, c)
            }
            strings.write_byte(&pattern, src[i + 1])
            i += 2
            continue
        }
        strings.write_byte(&pattern, c)
        i += 1
    }

    // A slash inside `${...}` belongs to the format (`${1:/upcase}`).
    format_start := i + 1
    depth := 0
    i = format_start
    for {
        if i >= len(src) {
            return
        }
        c := src[i]
        if c == '\\' && i + 1 < len(src) {
            i += 2
            continue
        }
        if c == '$' && i + 1 < len(src) && src[i + 1] == '{' {
            depth += 1
            i += 2
            continue
        }
        if c == '}' {
            if depth == 0 {
                return
            }
            depth -= 1
        } else if c == '/' && depth == 0 {
            break
        }
        i += 1
    }
    tr.pattern = strings.to_string(pattern)
    tr.format = src[format_start:i]

    i += 1
    for i < len(src) && src[i] != '}' {
        switch src[i] {
        case 'g':
            tr.global = true
        case 'i':
            tr.icase = true
        case 'm':
            tr.multiline = true
        }
        i += 1
    }
    if i >= len(src) {
        return
    }
    return tr, i + 1, true
}

@(private)
transform_clone :: proc(tr: Transform, allocator: mem.Allocator) -> Transform {
    out := tr
    out.pattern = strings.clone(tr.pattern, allocator)
    out.format = strings.clone(tr.format, allocator)
    return out
}

// Writes `format` for one match. `groups` holds the byte range of each group.
@(private = "file")
transform_format :: proc(b: ^strings.Builder, text: string, groups: [][2]int, format: string) {
    group :: proc(text: string, groups: [][2]int, n: int) -> string {
        if n < 0 || n >= len(groups) {
            return ""
        }
        span := groups[n]
        if span[0] < 0 || span[1] > len(text) || span[1] < span[0] {
            return ""
        }
        return text[span[0]:span[1]]
    }

    i := 0
    for i < len(format) {
        c := format[i]
        if c == '\\' && i + 1 < len(format) {
            write_escaped(b, format[i + 1])
            i += 2
            continue
        }
        if c != '$' || i + 1 >= len(format) {
            strings.write_byte(b, c)
            i += 1
            continue
        }
        if n, next, ok := format_int(format, i + 1); ok {
            strings.write_string(b, group(text, groups, n))
            i = next
            continue
        }
        if format[i + 1] != '{' {
            strings.write_byte(b, c)
            i += 1
            continue
        }
        n, after, ok := format_int(format, i + 2)
        close := ok ? format_close(format, after) : -1
        if close < 0 {
            strings.write_byte(b, c)
            i += 1
            continue
        }
        value := group(text, groups, n)
        body := format[after:close]
        i = close + 1
        switch {
        case body == "":
            strings.write_string(b, value)
        case strings.has_prefix(body, ":/"):
            strings.write_string(b, format_case(value, body[2:]))
        case strings.has_prefix(body, ":+"):
            if value != "" {
                write_unescaped(b, body[2:])
            }
        case strings.has_prefix(body, ":?"):
            split := format_colon(body, 2)
            if value != "" {
                write_unescaped(b, body[2:split])
            } else if split < len(body) {
                write_unescaped(b, body[split + 1:])
            }
        case strings.has_prefix(body, ":"):
            if value != "" {
                strings.write_string(b, value)
            } else {
                write_unescaped(b, strings.has_prefix(body, ":-") ? body[2:] : body[1:])
            }
        case:
            strings.write_string(b, value)
        }
    }
}

@(private = "file")
write_escaped :: proc(b: ^strings.Builder, c: u8) {
    switch c {
    case 'n':
        strings.write_byte(b, '\n')
    case 't':
        strings.write_byte(b, '\t')
    case:
        strings.write_byte(b, c)
    }
}

@(private = "file")
write_unescaped :: proc(b: ^strings.Builder, s: string) {
    for i := 0; i < len(s); i += 1 {
        if s[i] == '\\' && i + 1 < len(s) {
            i += 1
            write_escaped(b, s[i])
            continue
        }
        strings.write_byte(b, s[i])
    }
}

@(private = "file")
format_int :: proc(s: string, at: int) -> (value, next: int, ok: bool) {
    next = at
    for next < len(s) && s[next] >= '0' && s[next] <= '9' {
        value = value * 10 + int(s[next] - '0')
        next += 1
    }
    return value, next, next > at
}

// The index of the `}` that closes a `${N...` opened before `at`, or -1.
@(private = "file")
format_close :: proc(s: string, at: int) -> int {
    for i := at; i < len(s); i += 1 {
        switch s[i] {
        case '\\':
            i += 1
        case '}':
            return i
        }
    }
    return -1
}

// The index of the first unescaped `:` at or after `at`, or len(s).
@(private = "file")
format_colon :: proc(s: string, at: int) -> int {
    for i := at; i < len(s); i += 1 {
        switch s[i] {
        case '\\':
            i += 1
        case ':':
            return i
        }
    }
    return len(s)
}

@(private = "file")
format_case :: proc(value, name: string) -> string {
    switch name {
    case "upcase":
        return strings.to_upper(value, context.temp_allocator)
    case "downcase":
        return strings.to_lower(value, context.temp_allocator)
    case "capitalize":
        return capitalize(value)
    case "pascalcase", "camelcase":
        b := strings.builder_make(0, len(value), context.temp_allocator)
        first := true
        rest := value
        for len(rest) > 0 {
            // A word is a run of letters and digits.
            start := 0
            for start < len(rest) {
                r, width := utf8.decode_rune_in_string(rest[start:])
                if unicode.is_letter(r) || unicode.is_digit(r) {
                    break
                }
                start += width
            }
            end := start
            for end < len(rest) {
                r, width := utf8.decode_rune_in_string(rest[end:])
                if !unicode.is_letter(r) && !unicode.is_digit(r) {
                    break
                }
                end += width
            }
            word := rest[start:end]
            rest = rest[end:]
            if word == "" {
                continue
            }
            if first && name == "camelcase" {
                r, width := utf8.decode_rune_in_string(word)
                strings.write_rune(&b, unicode.to_lower(r))
                strings.write_string(&b, word[width:])
            } else {
                strings.write_string(&b, capitalize(word))
            }
            first = false
        }
        return strings.to_string(b)
    }
    return value
}

@(private = "file")
capitalize :: proc(value: string) -> string {
    if value == "" {
        return value
    }
    r, width := utf8.decode_rune_in_string(value)
    b := strings.builder_make(0, len(value), context.temp_allocator)
    strings.write_rune(&b, unicode.to_upper(r))
    strings.write_string(&b, value[width:])
    return strings.to_string(b)
}
