package widgets

import "core:fmt"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

import "../ui"

// Rebuilds the item list when the source, column width, or font size has moved
// since the last build. Everything downstream reads `view.items`.
@(private)
markdown_ensure_layout :: proc(view: ^Markdown_View) {
    avail := markdown_content_width(view)
    if view.built &&
       view.built_rev == view.source_rev &&
       view.built_font == view.base_font_size &&
       abs(view.built_width - avail) < 0.5 {
        return
    }
    markdown_build(view, avail)
    view.built = true
    view.built_rev = view.source_rev
    view.built_width = avail
    view.built_font = view.base_font_size
}

// Font size for a heading level (1..6), stepping down toward the body size.
@(private = "file")
markdown_heading_size :: proc(base: i32, level: int) -> i32 {
    switch level {
    case 1: return base + 13
    case 2: return base + 8
    case 3: return base + 5
    case 4: return base + 3
    case 5: return base + 1
    }
    return base
}

// Parses the source into the flat item list. Block detection is line-oriented;
// inline styling and word wrap happen per block.
@(private = "file")
markdown_build :: proc(view: ^Markdown_View, avail: f32) {
    clear(&view.items)
    markdown_free_owned(view)

    base := view.base_font_size
    y := PAD_TOP
    src := view.source

    lines := make([dynamic]string, context.temp_allocator)
    it := src
    for line in strings.split_lines_iterator(&it) {
        append(&lines, line)
    }

    i := 0
    for i < len(lines) {
        raw := lines[i]
        trimmed := strings.trim_left_space(raw)

        // Fenced code block: gather verbatim lines until the closing fence.
        if strings.has_prefix(trimmed, "```") {
            start := i + 1
            end := start
            for end < len(lines) && !strings.has_prefix(strings.trim_left_space(lines[end]), "```") {
                end += 1
            }
            markdown_emit_code_block(view, lines[start:end], base, &y)
            i = end < len(lines) ? end + 1 : end
            continue
        }

        // Blank line: paragraph spacing.
        if len(trimmed) == 0 {
            y += f32(base) * 0.5
            i += 1
            continue
        }

        // Horizontal rule: a line of only -, *, or _ (three or more).
        if markdown_is_rule(trimmed) {
            y += 6
            append(&view.items, Md_Item {kind = .Rect, x = 0, y = y, w = avail, h = 2, color = view.rule_color})
            y += f32(ui.text_line_height(base))
            i += 1
            continue
        }

        // ATX heading.
        if level, rest, ok := markdown_heading(trimmed); ok {
            size := markdown_heading_size(base, level)
            y += f32(base) * (level <= 2 ? 0.8 : 0.4)
            tokens := markdown_inline(view, rest, view.heading_color, size)
            markdown_wrap(view, tokens[:], 0, avail, size, &y)
            if level <= 2 {
                y += 4
                append(&view.items, Md_Item {kind = .Rect, x = 0, y = y, w = avail, h = 1, color = view.rule_color})
                y += 6
            }
            i += 1
            continue
        }

        // Blockquote line.
        if strings.has_prefix(trimmed, ">") {
            content := strings.trim_left_space(trimmed[1:])
            line_h := f32(ui.text_line_height(base))
            bar_top := y
            tokens := markdown_inline(view, content, view.quote_color, base)
            start_y := y
            markdown_wrap(view, tokens[:], 18, avail - 18, base, &y)
            append(&view.items, Md_Item {kind = .Rect, x = 0, y = bar_top, w = 3, h = max(line_h, y - start_y), color = view.accent_color})
            i += 1
            continue
        }

        // List item (unordered - * +, or ordered N.).
        if marker, content, ordered, num, ok := markdown_list_item(trimmed); ok {
            markdown_emit_list_item(view, marker, content, ordered, num, base, avail, &y)
            i += 1
            continue
        }

        // Paragraph: fold consecutive plain lines into one wrapped block so soft
        // line breaks flow together, matching how markdown treats them.
        para := make([dynamic]Md_Token, context.temp_allocator)
        for i < len(lines) {
            pline := strings.trim_left_space(lines[i])
            if len(pline) == 0 || markdown_is_rule(pline) || strings.has_prefix(pline, "```") ||
               strings.has_prefix(pline, ">") {
                break
            }
            if _, _, is_h := markdown_heading(pline); is_h {
                break
            }
            if _, _, _, _, is_list := markdown_list_item(pline); is_list {
                break
            }
            toks := markdown_inline(view, pline, view.text_color, base)
            append(&para, ..toks[:])
            i += 1
        }
        markdown_wrap(view, para[:], 0, avail, base, &y)
        y += f32(base) * 0.35
    }

    view.content_height = y + PAD_BOTTOM
}

@(private = "file")
markdown_is_rule :: proc(s: string) -> bool {
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
markdown_heading :: proc(s: string) -> (level: int, rest: string, ok: bool) {
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
// the remaining content, and (for ordered items) the parsed number.
@(private = "file")
markdown_list_item :: proc(s: string) -> (marker: string, content: string, ordered: bool, num: int, ok: bool) {
    if len(s) >= 2 && (s[0] == '-' || s[0] == '*' || s[0] == '+') && s[1] == ' ' {
        return "•", strings.trim_left_space(s[2:]), false, 0, true
    }
    // Ordered: one or more digits then '.' or ')' then a space.
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

// Emits a bullet/number and its wrapped content, indented under the marker.
@(private = "file")
markdown_emit_list_item :: proc(view: ^Markdown_View, marker, content: string, ordered: bool, num: int, base: i32, avail: f32, y: ^f32) {
    label := marker
    if ordered {
        s := fmt.aprintf("%d.", num)
        append(&view.owned, s)
        label = s
    }
    indent := f32(24)
    append(&view.items, Md_Item {kind = .Text, x = 6, y = y^, text = label, size = base, color = view.accent_color})
    tokens := markdown_inline(view, content, view.text_color, base)
    markdown_wrap(view, tokens[:], indent, avail - indent, base, y)
}

// Draws a code block: a background panel and each source line verbatim (no wrap;
// overflow is clipped by the view).
@(private = "file")
markdown_emit_code_block :: proc(view: ^Markdown_View, lines: []string, base: i32, y: ^f32) {
    if len(lines) == 0 {
        return
    }
    line_h := f32(ui.text_line_height(base))
    pad := f32(8)
    top := y^
    height := line_h * f32(len(lines)) + pad * 2
    append(&view.items, Md_Item {kind = .Rect, x = 0, y = top, w = MAX_WIDTH, h = height, color = view.code_bg})
    ty := top + pad
    for line in lines {
        append(&view.items, Md_Item {kind = .Text, x = pad, y = ty, text = line, size = base, color = view.code_color})
        ty += line_h
    }
    y^ = top + height + f32(base) * 0.4
}

// Wraps a token run into the item list at the given indent and max width,
// advancing `y` past the block. Code tokens get a chip background; links get an
// underline.
@(private = "file")
markdown_wrap :: proc(view: ^Markdown_View, tokens: []Md_Token, indent, max_w: f32, size: i32, y: ^f32) {
    line_h := f32(ui.text_line_height(size))
    if len(tokens) == 0 {
        y^ += line_h
        return
    }
    space_w := f32(ui.measure_text(" ", size))
    x := indent
    first := true
    for tok in tokens {
        tw := f32(ui.measure_text(tok.text, size))
        gap := first ? f32(0) : space_w
        if !first && x + gap + tw > indent + max_w {
            y^ += line_h
            x = indent
            first = true
            gap = 0
        }
        x += gap
        if tok.code {
            append(&view.items, Md_Item {kind = .Rect, x = x - 2, y = y^, w = tw + 4, h = line_h, color = view.code_bg})
        }
        append(&view.items, Md_Item {kind = .Text, x = x, y = y^, text = tok.text, size = size, color = tok.color})
        if tok.link {
            append(&view.items, Md_Item {kind = .Rect, x = x, y = y^ + line_h - 3, w = tw, h = 1, color = tok.color})
        }
        x += tw
        first = false
    }
    y^ += line_h
}

// Splits inline markdown (`code`, **strong**, *em*, [text](url)) into wrap
// tokens. All token text slices borrow from `view.source`; only colors and flags
// are computed here. Plain words are split on spaces; code spans stay whole.
@(private = "file")
markdown_inline :: proc(view: ^Markdown_View, s: string, base_color: rl.Color, size: i32) -> [dynamic]Md_Token {
    tokens := make([dynamic]Md_Token, context.temp_allocator)

    i := 0
    run_start := 0
    for i < len(s) {
        c := s[i]

        // Inline code.
        if c == '`' {
            j := i + 1
            for j < len(s) && s[j] != '`' {
                j += 1
            }
            if j < len(s) {
                markdown_push_words(&tokens, s[run_start:i], base_color)
                append(&tokens, Md_Token {text = s[i + 1:j], color = view.code_color, code = true})
                i = j + 1
                run_start = i
                continue
            }
        }

        // Link [text](url) -- the url is parsed to bound the span but not shown.
        if c == '[' {
            if close, url_end, ok := markdown_scan_link(s, i); ok {
                markdown_push_words(&tokens, s[run_start:i], base_color)
                append(&tokens, Md_Token {text = s[i + 1:close], color = view.link_color, link = true})
                i = url_end
                run_start = i
                continue
            }
        }

        // Emphasis: ** / __ (strong) or * / _ (em). Both map to the strong color
        // since the monospace font cannot bold or slant.
        if c == '*' || c == '_' {
            double := i + 1 < len(s) && s[i + 1] == c
            marker := double ? s[i:i + 2] : s[i:i + 1]
            search := i + len(marker)
            close := strings.index(s[search:], marker)
            if close >= 0 {
                abs := search + close
                markdown_push_words(&tokens, s[run_start:i], base_color)
                markdown_push_words(&tokens, s[search:abs], view.strong_color)
                i = abs + len(marker)
                run_start = i
                continue
            }
        }

        i += 1
    }
    markdown_push_words(&tokens, s[run_start:len(s)], base_color)
    return tokens
}

// Splits plain text into space-delimited word tokens, skipping empty spans.
@(private = "file")
markdown_push_words :: proc(tokens: ^[dynamic]Md_Token, text: string, color: rl.Color) {
    rest := text
    for word in strings.split_iterator(&rest, " ") {
        if len(word) > 0 {
            append(tokens, Md_Token {text = word, color = color})
        }
    }
}

// From a '[' at `open`, finds the matching `](url)` and returns the text-close
// index and the position just past the closing paren.
@(private = "file")
markdown_scan_link :: proc(s: string, open: int) -> (text_close: int, past: int, ok: bool) {
    close := strings.index(s[open:], "]")
    if close < 0 {
        return 0, 0, false
    }
    close += open
    if close + 1 >= len(s) || s[close + 1] != '(' {
        return 0, 0, false
    }
    paren := strings.index(s[close + 2:], ")")
    if paren < 0 {
        return 0, 0, false
    }
    return close, close + 2 + paren + 1, true
}
