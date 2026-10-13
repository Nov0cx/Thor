package markdown

import "core:strings"

import ui "../vendor/loom/loom"

// A wrap unit produced by inline parsing. A `code` token keeps its spaces and
// draws on a chip background; the rest are single space-delimited words.
@(private)
Token :: struct {
    text:   string,
    color:  ui.Color,
    code:   bool,
    link:   bool,
    url:    string, // borrowed from the source, "" when not a link
    glue:   bool,   // no space between it and the token before
    strike: bool,
    brk:    bool,   // a hard line break follows
}

// The inline parse of one block: the token list it fills and whether white
// space came since the last token.
@(private)
Inline :: struct {
    b:      ^Build,
    tokens: ^[dynamic]Token,
    space:  bool,
}

@(private = "file")
Style :: struct {
    color:  ui.Color,
    strike: bool,
}

@(private)
inline_begin :: proc(b: ^Build, tokens: ^[dynamic]Token) -> Inline {
    return Inline{b = b, tokens = tokens, space = true}
}

// Adds one source line to the block. Two spaces or a backslash at its end make
// a hard break; a plain line end is a space.
@(private)
inline_line :: proc(st: ^Inline, line: string, color: ui.Color) {
    s := line
    hard := false
    switch {
    case strings.has_suffix(s, "  "):
        hard = true
    case strings.has_suffix(s, "\\") && !strings.has_suffix(s, "\\\\"):
        hard = true
        s = s[:len(s) - 1]
    }
    st.space = true
    inline_span(st, strings.trim_space(s), Style{color = color})
    if hard {
        inline_break(st)
    }
    st.space = true
}

// The tokens of a block that is one line of source.
@(private)
inline :: proc(b: ^Build, s: string, color: ui.Color) -> [dynamic]Token {
    tokens := make([dynamic]Token, context.temp_allocator)
    st := inline_begin(b, &tokens)
    inline_span(&st, s, Style{color = color})
    return tokens
}

@(private = "file")
inline_break :: proc(st: ^Inline) {
    if n := len(st.tokens); n > 0 {
        st.tokens[n - 1].brk = true
    }
    st.space = true
}

// Splits inline markdown into wrap tokens: code spans, emphasis, strikethrough,
// links, autolinks, `<br>` and backslash escapes. Every token text borrows from
// `s`; only colors and flags are computed here.
@(private = "file")
inline_span :: proc(st: ^Inline, s: string, style: Style) {
    i := 0
    run := 0
    for i < len(s) {
        c := s[i]
        switch c {
        case '\\':
            if i + 1 < len(s) && is_punct(s[i + 1]) {
                push_words(st, s[run:i], style)
                push_token(st, Token{text = s[i + 1:i + 2], color = style.color, strike = style.strike})
                i += 2
                run = i
                continue
            }

        case '`':
            n := 1
            for i + n < len(s) && s[i + n] == '`' {
                n += 1
            }
            if close := code_close(s, i + n, n); close >= 0 {
                push_words(st, s[run:i], style)
                inner := s[i + n:close]
                if len(inner) > 2 && inner[0] == ' ' && inner[len(inner) - 1] == ' ' {
                    inner = inner[1:len(inner) - 1]
                }
                push_token(st, Token{text = inner, color = st.b.pal.code, code = true, strike = style.strike})
                i = close + n
                run = i
                continue
            }
            i += n
            continue

        case '<':
            if n := br_tag(s[i:]); n > 0 {
                push_words(st, s[run:i], style)
                inline_break(st)
                i += n
                run = i
                continue
            }
            if url, past, ok := autolink(s, i); ok {
                push_words(st, s[run:i], style)
                push_token(st, Token{text = url, color = st.b.pal.link, link = true, url = url, strike = style.strike})
                i = past
                run = i
                continue
            }

        case '[':
            if close, url, past, ok := scan_link(st.b, s, i); ok {
                push_words(st, s[run:i], style)
                text, code := link_text(s[i + 1:close])
                push_token(st, Token{text = text, color = st.b.pal.link, code = code, link = true, url = url, strike = style.strike})
                i = past
                run = i
                continue
            }

        case '*', '_':
            // Strong and emphasis both take the strong color: the one face the
            // page draws in cannot bold or slant.
            n := i + 1 < len(s) && s[i + 1] == c ? 2 : 1
            close := emphasis_close(s, i, n)
            if close < 0 && n == 2 {
                n = 1
                close = emphasis_close(s, i, n)
            }
            if close >= 0 {
                push_words(st, s[run:i], style)
                inline_span(st, s[i + n:close], Style{color = st.b.pal.strong, strike = style.strike})
                i = close + n
                run = i
                continue
            }
            i += n
            continue

        case '~':
            if i + 1 < len(s) && s[i + 1] == '~' {
                if close := strings.index(s[i + 2:], "~~"); close > 0 {
                    at := i + 2 + close
                    push_words(st, s[run:i], style)
                    inline_span(st, s[i + 2:at], Style{color = style.color, strike = true})
                    i = at + 2
                    run = i
                    continue
                }
            }
        }
        i += 1
    }
    push_words(st, s[run:], style)
}

@(private = "file")
push_token :: proc(st: ^Inline, tok: Token) {
    tok := tok
    tok.glue = !st.space && len(st.tokens) > 0
    append(st.tokens, tok)
    st.space = false
}

// Splits plain text into word tokens. A word with no space before it is glued
// to the token before.
@(private = "file")
push_words :: proc(st: ^Inline, text: string, style: Style) {
    i := 0
    for i < len(text) {
        if text[i] == ' ' || text[i] == '\t' {
            st.space = true
            i += 1
            continue
        }
        start := i
        for i < len(text) && text[i] != ' ' && text[i] != '\t' {
            i += 1
        }
        push_token(st, Token{text = text[start:i], color = style.color, strike = style.strike})
    }
}

@(private)
is_punct :: proc(c: u8) -> bool {
    return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')
}

@(private = "file")
is_alnum :: proc(c: u8) -> bool {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}

// The index of the run of exactly `n` backticks that closes a code span, or -1.
@(private = "file")
code_close :: proc(s: string, from, n: int) -> int {
    i := from
    for i < len(s) {
        if s[i] != '`' {
            i += 1
            continue
        }
        start := i
        for i < len(s) && s[i] == '`' {
            i += 1
        }
        if i - start == n {
            return start
        }
    }
    return -1
}

// The index of the marker that closes the emphasis opened at `open` with `n`
// marker bytes, or -1. An underscore inside a word is not a marker.
@(private = "file")
emphasis_close :: proc(s: string, open, n: int) -> int {
    c := s[open]
    first := open + n
    if first >= len(s) || s[first] == ' ' {
        return -1
    }
    if c == '_' && open > 0 && is_alnum(s[open - 1]) {
        return -1
    }
    for j := first + 1; j + n <= len(s); j += 1 {
        if s[j] == '\\' {
            j += 1
            continue
        }
        if s[j] != c || s[j - 1] == ' ' {
            continue
        }
        run := 1
        for j + run < len(s) && s[j + run] == c {
            run += 1
        }
        if run < n || (n == 1 && run == 2) {
            j += run - 1
            continue
        }
        // A longer run closes with its last `n` bytes, so `***a***` nests.
        at := j + run - n
        if c == '_' && at + n < len(s) && is_alnum(s[at + n]) {
            j += run - 1
            continue
        }
        return at
    }
    return -1
}

// The byte length of a `<br>` tag at the head of `s`, or 0.
@(private = "file")
br_tag :: proc(s: string) -> int {
    for tag in ([]string{"<br>", "<br/>", "<br />"}) {
        if len(s) >= len(tag) && strings.equal_fold(s[:len(tag)], tag) {
            return len(tag)
        }
    }
    return 0
}

// `<scheme://...>` or `<mailto:...>` with `open` on the `<`.
@(private = "file")
autolink :: proc(s: string, open: int) -> (url: string, past: int, ok: bool) {
    close := strings.index_byte(s[open:], '>')
    if close < 2 {
        return
    }
    inner := s[open + 1:open + close]
    if strings.contains_any(inner, " \t<") {
        return
    }
    if !strings.contains(inner, "://") && !strings.has_prefix(inner, "mailto:") {
        return
    }
    return inner, open + close + 1, true
}

// What a link shows. A text that is one code span or one strong run loses its
// markers, since a link token is not parsed again.
@(private = "file")
link_text :: proc(text: string) -> (shown: string, code: bool) {
    if len(text) > 2 && text[0] == '`' && text[len(text) - 1] == '`' {
        return text[1:len(text) - 1], true
    }
    if len(text) > 4 && strings.has_prefix(text, "**") && strings.has_suffix(text, "**") {
        return text[2:len(text) - 2], false
    }
    return text, false
}

// From a '[' at `open`: `[text](url "title")`, `[text][label]`, `[text][]` or a
// `[label]` the document defines. Returns the index of the `]` that closes the
// text, the url and the position past the whole link.
@(private)
scan_link :: proc(b: ^Build, s: string, open: int) -> (text_close: int, url: string, past: int, ok: bool) {
    close := -1
    depth := 0
    scan: for i := open + 1; i < len(s); i += 1 {
        switch s[i] {
        case '\\':
            i += 1
        case '[':
            depth += 1
        case ']':
            if depth == 0 {
                close = i
                break scan
            }
            depth -= 1
        }
    }
    if close < 0 {
        return
    }
    text := s[open + 1:close]

    if close + 1 < len(s) && s[close + 1] == '(' {
        if url, past, ok = link_target(s, close + 2); ok {
            return close, url, past, true
        }
        return
    }
    if close + 1 < len(s) && s[close + 1] == '[' {
        end := strings.index_byte(s[close + 2:], ']')
        if end < 0 {
            return
        }
        label := s[close + 2:close + 2 + end]
        if label == "" {
            label = text
        }
        url, ok = b.refs[ref_key(label)]
        return close, url, close + 2 + end + 1, ok
    }
    url, ok = b.refs[ref_key(text)]
    return close, url, close + 1, ok
}

// The `url "title")` part of an inline link, with `at` past the `(`.
@(private = "file")
link_target :: proc(s: string, at: int) -> (url: string, past: int, ok: bool) {
    i := at
    for i < len(s) && s[i] == ' ' {
        i += 1
    }
    if i < len(s) && s[i] == '<' {
        end := strings.index_byte(s[i:], '>')
        if end < 0 {
            return
        }
        url = s[i + 1:i + end]
        i += end + 1
    } else {
        start := i
        depth := 0
        for i < len(s) {
            c := s[i]
            if c == ' ' || (c == ')' && depth == 0) {
                break
            }
            if c == '(' {
                depth += 1
            } else if c == ')' {
                depth -= 1
            }
            i += 1
        }
        url = s[start:i]
    }
    for i < len(s) && s[i] == ' ' {
        i += 1
    }
    // The title is read and dropped.
    if i < len(s) && (s[i] == '"' || s[i] == '\'') {
        end := strings.index_byte(s[i + 1:], s[i])
        if end < 0 {
            return
        }
        i += end + 2
        for i < len(s) && s[i] == ' ' {
            i += 1
        }
    }
    if i >= len(s) || s[i] != ')' || url == "" {
        return "", 0, false
    }
    return url, i + 1, true
}

// The form a reference label is matched in: lower case, trimmed.
@(private)
ref_key :: proc(label: string) -> string {
    return strings.to_lower(strings.trim_space(label), context.temp_allocator)
}

// Reads a `[label]: url "title"` definition line.
@(private)
ref_definition :: proc(line: string) -> (label, url: string, ok: bool) {
    s := strings.trim_space(line)
    if len(s) < 5 || s[0] != '[' {
        return
    }
    close := strings.index(s, "]:")
    if close < 2 {
        return
    }
    label = s[1:close]
    rest := strings.trim_left_space(s[close + 2:])
    if rest == "" {
        return
    }
    if rest[0] == '<' {
        end := strings.index_byte(rest, '>')
        if end < 0 {
            return
        }
        return label, rest[1:end], end > 1
    }
    end := strings.index_any(rest, " \t")
    if end < 0 {
        return label, rest, true
    }
    // What follows the url must be a title.
    title := strings.trim_space(rest[end:])
    if title != "" && title[0] != '"' && title[0] != '\'' && title[0] != '(' {
        return
    }
    return label, rest[:end], true
}
