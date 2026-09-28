package markdown

import "core:fmt"
import "core:strconv"
import "core:strings"

import ui "../vendor/loom/loom"

// A wrap unit produced by inline parsing. A `code` token keeps its spaces and
// draws on a chip background; the rest are single space-delimited words.
@(private)
Token :: struct {
    text:  string,
    color: ui.Color,
    code:  bool,
    link:  bool,
    url:   string, // borrowed from the source, "" when not a link
}

@(private)
Build :: struct {
    page:  ^Page,
    pal:   Palette,
    m:     Metrics,
    base:  i32,
    avail: f32,
    y:     f32,
}

// Parses the source into the page's item list. Block detection is line-oriented;
// inline styling and word wrap happen per block. Every item text borrows from
// `source`, so the caller keeps that alive as long as the page.
layout :: proc(page: ^Page, source: string, avail: f32, base: i32, pal: Palette, m: Metrics) {
    page_clear(page)
    b := Build {
        page  = page,
        pal   = pal,
        m     = m,
        base  = base,
        avail = avail,
        y     = PAD_TOP,
    }

    lines := make([dynamic]string, context.temp_allocator)
    it := source
    for line in strings.split_lines_iterator(&it) {
        append(&lines, line)
    }

    i := 0
    for i < len(lines) {
        trimmed := strings.trim_left_space(lines[i])

        // Fenced code block: gather verbatim lines until the closing fence.
        if strings.has_prefix(trimmed, "```") {
            start := i + 1
            end := start
            for end < len(lines) && !strings.has_prefix(strings.trim_left_space(lines[end]), "```") {
                end += 1
            }
            emit_code_block(&b, lines[start:end])
            i = end < len(lines) ? end + 1 : end
            continue
        }

        // Blank line: paragraph spacing.
        if len(trimmed) == 0 {
            b.y += f32(base) * 0.5
            i += 1
            continue
        }

        // Horizontal rule: a line of only -, * or _, three or more.
        if is_rule(trimmed) {
            b.y += 6
            append(&page.items, Item{kind = .Rect, y = b.y, w = avail, h = 2, color = pal.rule})
            b.y += line_height(m, base)
            i += 1
            continue
        }

        if level, rest, ok := heading(trimmed); ok {
            emit_heading(&b, level, rest)
            i += 1
            continue
        }

        if strings.has_prefix(trimmed, ">") {
            emit_quote(&b, strings.trim_left_space(trimmed[1:]))
            i += 1
            continue
        }

        if marker, content, ordered, num, ok := list_item(trimmed); ok {
            emit_list_item(&b, marker, content, ordered, num)
            i += 1
            continue
        }

        // Paragraph: consecutive plain lines fold into one wrapped block, so a
        // soft line break flows, which is what markdown means by it.
        para := make([dynamic]Token, context.temp_allocator)
        for i < len(lines) {
            pline := strings.trim_left_space(lines[i])
            if len(pline) == 0 ||
               is_rule(pline) ||
               strings.has_prefix(pline, "```") ||
               strings.has_prefix(pline, ">") {
                break
            }
            if _, _, is_h := heading(pline); is_h {
                break
            }
            if _, _, _, _, is_list := list_item(pline); is_list {
                break
            }
            toks := inline(&b, pline, pal.text, base)
            append(&para, ..toks[:])
            i += 1
        }
        wrap(&b, para[:], 0, avail, base)
        b.y += f32(base) * 0.35
    }

    page.content_height = b.y + PAD_BOTTOM
}

// Font size for a heading level (1..6), stepping down toward the body size.
@(private = "file")
heading_size :: proc(base: i32, level: int) -> i32 {
    switch level {
    case 1:
        return base + 13
    case 2:
        return base + 8
    case 3:
        return base + 5
    case 4:
        return base + 3
    case 5:
        return base + 1
    }
    return base
}

@(private = "file")
emit_heading :: proc(b: ^Build, level: int, rest: string) {
    size := heading_size(b.base, level)
    b.y += f32(b.base) * (level <= 2 ? 0.8 : 0.4)
    tokens := inline(b, rest, b.pal.heading, size)
    wrap(b, tokens[:], 0, b.avail, size)
    if level <= 2 {
        b.y += 4
        append(&b.page.items, Item{kind = .Rect, y = b.y, w = b.avail, h = 1, color = b.pal.rule})
        b.y += 6
    }
}

@(private = "file")
emit_quote :: proc(b: ^Build, content: string) {
    line_h := line_height(b.m, b.base)
    top := b.y
    tokens := inline(b, content, b.pal.quote, b.base)
    wrap(b, tokens[:], 18, b.avail - 18, b.base)
    append(
        &b.page.items,
        Item {
            kind = .Rect,
            y = top,
            w = 3,
            h = max(line_h, b.y - top),
            color = b.pal.accent,
        },
    )
}

@(private = "file")
is_rule :: proc(s: string) -> bool {
    if len(s) < 3 {
        return false
    }
    c := s[0]
    if c != '-' && c != '*' && c != '_' {
        return false
    }
    count := 0
    for i in 0 ..< len(s) {
        switch s[i] {
        case c:
            count += 1
        case ' ', '\t':
        // spacing between markers is allowed
        case:
            return false
        }
    }
    return count >= 3
}

// Splits an ATX heading `### Title` into its level and title text.
@(private = "file")
heading :: proc(s: string) -> (level: int, rest: string, ok: bool) {
    n := 0
    for n < len(s) && s[n] == '#' {
        n += 1
    }
    if n == 0 || n > 6 || n >= len(s) || s[n] != ' ' {
        return 0, "", false
    }
    return n, strings.trim_space(s[n + 1:]), true
}

// Recognizes a list marker at the head of a line, returning the display marker,
// the remaining content and, for an ordered item, the parsed number.
@(private = "file")
list_item :: proc(
    s: string,
) -> (
    marker: string,
    content: string,
    ordered: bool,
    num: int,
    ok: bool,
) {
    if len(s) >= 2 && (s[0] == '-' || s[0] == '*' || s[0] == '+') && s[1] == ' ' {
        return "•", strings.trim_left_space(s[2:]), false, 0, true
    }
    // Ordered: one or more digits, then '.' or ')', then a space.
    d := 0
    for d < len(s) && s[d] >= '0' && s[d] <= '9' {
        d += 1
    }
    if d > 0 && d + 1 < len(s) && (s[d] == '.' || s[d] == ')') && s[d + 1] == ' ' {
        value, _ := strconv.parse_int(s[:d])
        return "", strings.trim_left_space(s[d + 2:]), true, value, true
    }
    return "", "", false, 0, false
}

// Emits a bullet or number and its wrapped content, indented under the marker.
@(private = "file")
emit_list_item :: proc(b: ^Build, marker, content: string, ordered: bool, num: int) {
    label := marker
    if ordered {
        s := fmt.aprintf("%d.", num)
        append(&b.page.owned, s)
        label = s
    }
    indent := f32(24)
    append(
        &b.page.items,
        Item{kind = .Text, x = 6, y = b.y, text = label, size = b.base, color = b.pal.accent},
    )
    tokens := inline(b, content, b.pal.text, b.base)
    wrap(b, tokens[:], indent, b.avail - indent, b.base)
}

// A background panel and each source line verbatim. No wrap: the host clips.
@(private = "file")
emit_code_block :: proc(b: ^Build, lines: []string) {
    if len(lines) == 0 {
        return
    }
    line_h := line_height(b.m, b.base)
    pad := f32(8)
    top := b.y
    height := line_h * f32(len(lines)) + pad * 2
    append(
        &b.page.items,
        Item{kind = .Rect, y = top, w = b.avail, h = height, color = b.pal.code_bg},
    )
    ty := top + pad
    for line in lines {
        append(
            &b.page.items,
            Item {
                kind = .Text,
                x = pad,
                y = ty,
                text = line,
                size = b.base,
                color = b.pal.code,
            },
        )
        ty += line_h
    }
    b.y = top + height + f32(b.base) * 0.4
}

// Wraps a token run into the item list at the given indent and max width,
// advancing past the block. A code token gets a chip, a link gets an underline.
@(private = "file")
wrap :: proc(b: ^Build, tokens: []Token, indent, max_w: f32, size: i32) {
    line_h := line_height(b.m, size)
    if len(tokens) == 0 {
        b.y += line_h
        return
    }
    space_w := measure(b.m, " ", size)
    x := indent
    first := true
    for tok in tokens {
        tw := measure(b.m, tok.text, size)
        gap := first ? f32(0) : space_w
        if !first && x + gap + tw > indent + max_w {
            b.y += line_h
            x = indent
            first = true
            gap = 0
        }
        x += gap
        if tok.code {
            append(
                &b.page.items,
                Item {
                    kind = .Rect,
                    x = x - 2,
                    y = b.y,
                    w = tw + 4,
                    h = line_h,
                    color = b.pal.code_bg,
                },
            )
        }
        // A text item carries its whole box: the draw culls with it, and a link
        // is hit-tested against it.
        append(
            &b.page.items,
            Item {
                kind = .Text,
                x = x,
                y = b.y,
                w = tw,
                h = line_h,
                text = tok.text,
                size = size,
                color = tok.color,
                url = tok.url,
            },
        )
        if tok.link {
            append(
                &b.page.items,
                Item {
                    kind = .Rect,
                    x = x,
                    y = b.y + line_h - 3,
                    w = tw,
                    h = 1,
                    color = tok.color,
                },
            )
        }
        x += tw
        first = false
    }
    b.y += line_h
}

// Splits inline markdown (`code`, **strong**, *em*, [text](url)) into wrap
// tokens. Every token text borrows from `s`; only colors and flags are computed
// here. A plain word splits on spaces; a code span stays whole.
@(private = "file")
inline :: proc(b: ^Build, s: string, base_color: ui.Color, size: i32) -> [dynamic]Token {
    tokens := make([dynamic]Token, context.temp_allocator)

    i := 0
    run_start := 0
    for i < len(s) {
        c := s[i]

        if c == '`' {
            j := i + 1
            for j < len(s) && s[j] != '`' {
                j += 1
            }
            if j < len(s) {
                push_words(&tokens, s[run_start:i], base_color)
                append(&tokens, Token{text = s[i + 1:j], color = b.pal.code, code = true})
                i = j + 1
                run_start = i
                continue
            }
        }

        // Link [text](url). The text draws, the url rides along for the click.
        if c == '[' {
            if close, url, url_end, ok := scan_link(s, i); ok {
                push_words(&tokens, s[run_start:i], base_color)
                append(
                    &tokens,
                    Token{text = s[i + 1:close], color = b.pal.link, link = true, url = url},
                )
                i = url_end
                run_start = i
                continue
            }
        }

        // Emphasis: ** or __ (strong), * or _ (em). Both map to the strong color,
        // since the one face the page draws in cannot bold or slant.
        if c == '*' || c == '_' {
            double := i + 1 < len(s) && s[i + 1] == c
            marker := double ? s[i:i + 2] : s[i:i + 1]
            search := i + len(marker)
            close := strings.index(s[search:], marker)
            if close >= 0 {
                at := search + close
                push_words(&tokens, s[run_start:i], base_color)
                push_words(&tokens, s[search:at], b.pal.strong)
                i = at + len(marker)
                run_start = i
                continue
            }
        }

        i += 1
    }
    push_words(&tokens, s[run_start:len(s)], base_color)
    return tokens
}

// Splits plain text into space-delimited word tokens, skipping empty spans.
@(private = "file")
push_words :: proc(tokens: ^[dynamic]Token, text: string, color: ui.Color) {
    rest := text
    for word in strings.split_iterator(&rest, " ") {
        if len(word) > 0 {
            append(tokens, Token{text = word, color = color})
        }
    }
}

// From a '[' at `open`, finds the matching `](url)` and returns the text-close
// index, the url (a slice of `s`) and the position just past the closing paren.
@(private = "file")
scan_link :: proc(s: string, open: int) -> (text_close: int, url: string, past: int, ok: bool) {
    close := strings.index(s[open:], "]")
    if close < 0 {
        return 0, "", 0, false
    }
    close += open
    if close + 1 >= len(s) || s[close + 1] != '(' {
        return 0, "", 0, false
    }
    paren := strings.index(s[close + 2:], ")")
    if paren < 0 {
        return 0, "", 0, false
    }
    return close, s[close + 2:close + 2 + paren], close + 2 + paren + 1, true
}
