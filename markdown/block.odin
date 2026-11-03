package markdown

import "core:strconv"
import "core:strings"

@(private)
Block_Kind :: enum u8 {
    Paragraph,
    Heading,
    List,
    Item,
    Quote,
    Alert,
    Code,
    Table,
    Rule,
    Details,
}

Task :: enum u8 {
    None,
    Open,
    Done,
}

Alert_Kind :: enum u8 {
    Note,
    Tip,
    Important,
    Warning,
    Caution,
}

// One block of the parsed document. Every string is a slice of the source.
@(private)
Block :: struct {
    kind:     Block_Kind,
    lines:    []string, // Paragraph, Heading and Code text; Table rows with the delimiter row
    children: [dynamic]^Block,
    level:    int, // Heading
    ordered:  bool, // List
    start:    int, // List: the first number
    loose:    bool, // List: blank lines between or inside its items
    task:     Task, // Item
    alert:    Alert_Kind,
    lang:     string, // Code: the first word of the info string
    summary:  string, // Details
}

// A `[^label]: text` definition, laid out at the end of the page.
@(private)
Footnote :: struct {
    label: string,
    lines: []string,
}

@(private = "file")
new_block :: proc(kind: Block_Kind) -> ^Block {
    blk := new(Block, context.temp_allocator)
    blk.kind = kind
    blk.children = make([dynamic]^Block, context.temp_allocator)
    return blk
}

@(private)
is_blank :: proc(line: string) -> bool {
    return len(strings.trim_space(line)) == 0
}

// The width of a line's leading white space, a tab counting four.
@(private)
indent_columns :: proc(line: string) -> int {
    columns := 0
    for i in 0 ..< len(line) {
        switch line[i] {
        case ' ':
            columns += 1
        case '\t':
            columns += 4
        case:
            return columns
        }
    }
    return columns
}

// `line` with up to `n` columns of leading white space removed. A tab that
// spans the cut is removed whole.
@(private)
strip_columns :: proc(line: string, n: int) -> string {
    columns := 0
    i := 0
    for i < len(line) && columns < n {
        switch line[i] {
        case ' ':
            columns += 1
        case '\t':
            columns += 4
        case:
            return line[i:]
        }
        i += 1
    }
    return line[i:]
}

// Parses `lines` into blocks. Containers strip their prefix and parse what is
// left again, so every block nests in every container.
@(private)
parse_blocks :: proc(b: ^Build, lines: []string) -> [dynamic]^Block {
    out := make([dynamic]^Block, context.temp_allocator)
    i := 0
    for i < len(lines) {
        line := lines[i]
        if is_blank(line) {
            i += 1
            continue
        }
        indent := indent_columns(line)
        t := strings.trim_left_space(line)

        if indent >= 4 {
            i = parse_indented_code(&out, lines, i)
            continue
        }
        if fence, count := fence_open(t); count > 0 {
            i = parse_fence(&out, lines, i, indent, fence, count)
            continue
        }
        if strings.has_prefix(t, "<!--") {
            i = skip_comment(lines, i)
            continue
        }
        if html_open(t, "details") {
            i = parse_details(b, &out, lines, i)
            continue
        }
        if html_only_tags(t) {
            i += 1
            continue
        }
        if is_rule(t) {
            append(&out, new_block(.Rule))
            i += 1
            continue
        }
        if level, rest, ok := heading(t); ok {
            blk := new_block(.Heading)
            blk.level = level
            blk.lines = one_line(rest)
            append(&out, blk)
            i += 1
            continue
        }
        if t[0] == '>' {
            i = parse_quote(b, &out, lines, i)
            continue
        }
        if _, _, _, _, ok := list_item(t); ok {
            i = parse_list(b, &out, lines, i)
            continue
        }
        if label, text, ok := footnote_definition(t); ok {
            i = parse_footnote(b, lines, i, label, text)
            continue
        }
        if table_at(lines, i) {
            i = parse_table(&out, lines, i)
            continue
        }
        i = parse_paragraph(b, &out, lines, i)
    }
    return out
}

@(private = "file")
one_line :: proc(s: string) -> []string {
    lines := make([]string, 1, context.temp_allocator)
    lines[0] = s
    return lines
}

// True when `line` ends a paragraph above it. In a list any list marker does;
// in running text only a bullet or a list that starts at 1.
@(private)
interrupts :: proc(line: string, in_list := false) -> bool {
    if is_blank(line) || indent_columns(line) >= 4 {
        return is_blank(line)
    }
    t := strings.trim_left_space(line)
    if t[0] == '>' || is_rule(t) || strings.has_prefix(t, "<!--") || html_open(t, "details") {
        return true
    }
    if _, count := fence_open(t); count > 0 {
        return true
    }
    if _, _, ok := heading(t); ok {
        return true
    }
    if _, _, ordered, num, ok := list_item(t); ok && (in_list || !ordered || num == 1) {
        return true
    }
    return false
}

@(private = "file")
parse_paragraph :: proc(b: ^Build, out: ^[dynamic]^Block, lines: []string, at: int) -> int {
    i := at
    // Reference definitions at the head of a paragraph are taken out of it.
    for i < len(lines) {
        label, url, ok := ref_definition(lines[i])
        if !ok {
            break
        }
        key := ref_key(label)
        if !(key in b.refs) {
            b.refs[key] = url
        }
        i += 1
    }
    if i >= len(lines) || is_blank(lines[i]) || (i > at && interrupts(lines[i])) {
        return i
    }
    if i > at {
        // What follows the definitions starts a block of its own.
        return i
    }

    end := i + 1
    for end < len(lines) && !interrupts(lines[end]) && setext_level(lines[end]) == 0 && !table_at(lines, end) {
        end += 1
    }
    if end < len(lines) {
        if level := setext_level(lines[end]); level > 0 {
            blk := new_block(.Heading)
            blk.level = level
            blk.lines = lines[i:end]
            append(out, blk)
            return end + 1
        }
    }
    blk := new_block(.Paragraph)
    blk.lines = lines[i:end]
    append(out, blk)
    return end
}

@(private = "file")
parse_indented_code :: proc(out: ^[dynamic]^Block, lines: []string, at: int) -> int {
    rows := make([dynamic]string, context.temp_allocator)
    i := at
    for i < len(lines) && (is_blank(lines[i]) || indent_columns(lines[i]) >= 4) {
        append(&rows, strip_columns(lines[i], 4))
        i += 1
    }
    for len(rows) > 0 && is_blank(rows[len(rows) - 1]) {
        pop(&rows)
    }
    blk := new_block(.Code)
    blk.lines = rows[:]
    append(out, blk)
    return i
}

@(private = "file")
parse_fence :: proc(out: ^[dynamic]^Block, lines: []string, at, indent: int, fence: u8, count: int) -> int {
    info := strings.trim_space(strings.trim_left_space(lines[at])[count:])
    if space := strings.index_any(info, " \t{"); space >= 0 {
        info = info[:space]
    }
    rows := make([dynamic]string, context.temp_allocator)
    i := at + 1
    for i < len(lines) && !fence_close(lines[i], fence, count) {
        append(&rows, strip_columns(lines[i], indent))
        i += 1
    }
    blk := new_block(.Code)
    blk.lines = rows[:]
    blk.lang = info
    append(out, blk)
    return i < len(lines) ? i + 1 : i
}

// Skips an HTML comment, which can run over several lines.
@(private = "file")
skip_comment :: proc(lines: []string, at: int) -> int {
    for i in at ..< len(lines) {
        if strings.contains(lines[i], "-->") {
            return i + 1
        }
    }
    return len(lines)
}

// A run of `>` lines, with the lazy lines that continue its last paragraph.
// `> [!NOTE]` on the first line makes it an alert.
@(private = "file")
parse_quote :: proc(b: ^Build, out: ^[dynamic]^Block, lines: []string, at: int) -> int {
    inner := make([dynamic]string, context.temp_allocator)
    in_text := false
    i := at
    for i < len(lines) {
        t := strings.trim_left_space(lines[i])
        if len(t) > 0 && t[0] == '>' && indent_columns(lines[i]) < 4 {
            rest := t[1:]
            if len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t') {
                rest = rest[1:]
            }
            append(&inner, rest)
            in_text = !is_blank(rest) && !interrupts(rest)
            i += 1
            continue
        }
        if in_text && !interrupts(lines[i]) {
            append(&inner, lines[i])
            i += 1
            continue
        }
        break
    }

    blk := new_block(.Quote)
    body := inner[:]
    if len(body) > 0 {
        if kind, ok := alert_marker(body[0]); ok {
            blk.kind = .Alert
            blk.alert = kind
            body = body[1:]
        }
    }
    blk.children = parse_blocks(b, body)
    append(out, blk)
    return i
}

// The alert a `[!KIND]` line opens.
@(private = "file")
alert_marker :: proc(line: string) -> (Alert_Kind, bool) {
    s := strings.trim_space(line)
    if !strings.has_prefix(s, "[!") || !strings.has_suffix(s, "]") {
        return .Note, false
    }
    switch strings.to_upper(s[2:len(s) - 1], context.temp_allocator) {
    case "NOTE":
        return .Note, true
    case "TIP":
        return .Tip, true
    case "IMPORTANT":
        return .Important, true
    case "WARNING":
        return .Warning, true
    case "CAUTION":
        return .Caution, true
    }
    return .Note, false
}

// A list: items of one kind, each holding the lines indented to its content
// column, parsed again as blocks.
@(private = "file")
parse_list :: proc(b: ^Build, out: ^[dynamic]^Block, lines: []string, at: int) -> int {
    list := new_block(.List)
    first := true
    i := at
    for i < len(lines) {
        t := strings.trim_left_space(lines[i])
        marker, content, ordered, num, ok := list_item(t)
        if !ok || is_rule(t) {
            break
        }
        if first {
            list.ordered = ordered
            list.start = num
            first = false
        } else if ordered != list.ordered {
            break
        }

        column := indent_columns(lines[i]) + marker
        if !is_blank(content) {
            column += min(max(indent_columns(content), 1), 4)
        } else {
            column += 1
        }
        content = strings.trim_left_space(content)

        item := new_block(.Item)
        item.task, content = task_marker(content)
        body := make([dynamic]string, context.temp_allocator)
        append(&body, content)
        in_text := !is_blank(content)
        blank := false
        i += 1
        for i < len(lines) {
            line := lines[i]
            if is_blank(line) {
                append(&body, "")
                blank = true
                in_text = false
                i += 1
                continue
            }
            if indent_columns(line) >= column {
                if blank {
                    list.loose = true
                }
                rest := strip_columns(line, column)
                append(&body, rest)
                blank = false
                in_text = !interrupts(rest, true)
                i += 1
                continue
            }
            if !blank && in_text && !interrupts(line, true) {
                append(&body, line)
                i += 1
                continue
            }
            break
        }
        for len(body) > 0 && is_blank(body[len(body) - 1]) {
            pop(&body)
        }
        item.children = parse_blocks(b, body[:])
        append(&list.children, item)

        // A blank line before the next item makes the list loose.
        if i > 0 && i < len(lines) && is_blank(lines[i - 1]) {
            if _, _, _, _, next := list_item(strings.trim_left_space(lines[i])); next {
                list.loose = true
            }
        }
    }
    append(out, list)
    return i
}

// Splits a `[ ]` or `[x]` task marker off an item's first line.
@(private = "file")
task_marker :: proc(content: string) -> (Task, string) {
    if len(content) < 3 || content[0] != '[' || content[2] != ']' {
        return .None, content
    }
    if len(content) > 3 && content[3] != ' ' && content[3] != '\t' {
        return .None, content
    }
    rest := strings.trim_left_space(content[3:])
    switch content[1] {
    case ' ':
        return .Open, rest
    case 'x', 'X':
        return .Done, rest
    }
    return .None, content
}

@(private = "file")
parse_table :: proc(out: ^[dynamic]^Block, lines: []string, at: int) -> int {
    next := at + 2
    for next < len(lines) {
        line := lines[next]
        if is_blank(line) || !strings.contains_rune(line, '|') || interrupts(line) {
            break
        }
        next += 1
    }
    blk := new_block(.Table)
    blk.lines = lines[at:next]
    append(out, blk)
    return next
}

// `<details>` up to its matching `</details>`. The `<summary>` is the toggle
// and the rest is parsed as blocks.
@(private = "file")
parse_details :: proc(b: ^Build, out: ^[dynamic]^Block, lines: []string, at: int) -> int {
    blk := new_block(.Details)
    blk.summary = "Details"
    depth := 0
    end := len(lines)
    for i in at ..< len(lines) {
        t := strings.trim_space(lines[i])
        depth += strings.count(t, "<details")
        depth -= strings.count(t, "</details>")
        if depth <= 0 {
            end = i
            break
        }
    }

    body := make([dynamic]string, context.temp_allocator)
    for i in at ..< min(end + 1, len(lines)) {
        line := lines[i]
        if i == at {
            line = after_tag(strings.trim_left_space(line), "details")
        }
        if i == end {
            if cut := strings.index(line, "</details>"); cut >= 0 {
                line = line[:cut]
            }
        }
        if open := strings.index(line, "<summary"); open >= 0 {
            rest := after_tag(line[open:], "summary")
            if close := strings.index(rest, "</summary>"); close >= 0 {
                blk.summary = strings.trim_space(rest[:close])
                line = rest[close + len("</summary>"):]
            }
        }
        append(&body, line)
    }
    blk.children = parse_blocks(b, body[:])
    append(out, blk)
    return min(end + 1, len(lines))
}

// What follows the `<name ...>` open tag at the head of `s`.
@(private = "file")
after_tag :: proc(s: string, name: string) -> string {
    if !html_open(s, name) {
        return s
    }
    close := strings.index_byte(s, '>')
    return close < 0 ? "" : s[close + 1:]
}

// True when `s` starts with the `<name` open tag.
@(private)
html_open :: proc(s: string, name: string) -> bool {
    if len(s) < len(name) + 2 || s[0] != '<' || !strings.equal_fold(s[1:1 + len(name)], name) {
        return false
    }
    c := s[1 + len(name)]
    return c == '>' || c == ' ' || c == '\t' || c == '/'
}

// The block tags a line made of only tags can hold. GitHub draws their content
// and drops the tags.
@(private = "file")
BLOCK_TAGS := [?]string{"div", "p", "center", "picture", "source", "section", "span", "br", "hr"}

// True when `s` is nothing but block-level open or close tags.
@(private = "file")
html_only_tags :: proc(s: string) -> bool {
    rest := strings.trim_space(s)
    if rest == "" || rest[0] != '<' {
        return false
    }
    for rest != "" {
        if rest[0] != '<' {
            return false
        }
        close := strings.index_byte(rest, '>')
        if close < 0 {
            return false
        }
        name := rest[1:close]
        name = strings.trim_prefix(name, "/")
        if cut := strings.index_any(name, " \t/"); cut >= 0 {
            name = name[:cut]
        }
        known := false
        for tag in BLOCK_TAGS {
            if strings.equal_fold(name, tag) {
                known = true
                break
            }
        }
        if !known {
            return false
        }
        rest = strings.trim_left_space(rest[close + 1:])
    }
    return true
}

// Reads a `[^label]: text` definition.
@(private = "file")
footnote_definition :: proc(t: string) -> (label, text: string, ok: bool) {
    if !strings.has_prefix(t, "[^") {
        return
    }
    close := strings.index(t, "]:")
    if close < 3 {
        return
    }
    return t[2:close], strings.trim_space(t[close + 2:]), true
}

// A footnote and its indented or lazy continuation lines.
@(private = "file")
parse_footnote :: proc(b: ^Build, lines: []string, at: int, label, text: string) -> int {
    body := make([dynamic]string, context.temp_allocator)
    append(&body, text)
    i := at + 1
    for i < len(lines) {
        line := lines[i]
        if is_blank(line) || interrupts(line) {
            break
        }
        if _, _, ok := footnote_definition(strings.trim_left_space(line)); ok {
            break
        }
        append(&body, strings.trim_left_space(line))
        i += 1
    }
    append(&b.footnotes, Footnote{label = label, lines = body[:]})
    return i
}

@(private)
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
        case:
            return false
        }
    }
    return count >= 3
}

// Splits an ATX heading `### Title` into its level and title text. A closing
// run of `#` is not part of the title.
@(private)
heading :: proc(s: string) -> (level: int, rest: string, ok: bool) {
    n := 0
    for n < len(s) && s[n] == '#' {
        n += 1
    }
    if n == 0 || n > 6 {
        return 0, "", false
    }
    if n < len(s) && s[n] != ' ' && s[n] != '\t' {
        return 0, "", false
    }
    if n >= len(s) {
        return 0, "", false
    }
    rest = strings.trim_space(s[n + 1:])
    end := len(rest)
    for end > 0 && rest[end - 1] == '#' {
        end -= 1
    }
    if end < len(rest) && (end == 0 || rest[end - 1] == ' ') {
        rest = strings.trim_space(rest[:end])
    }
    return n, rest, true
}

// The heading level a setext underline gives the paragraph above it: 1 for a
// line of `=`, 2 for a line of `-`, 0 for any other line.
@(private)
setext_level :: proc(line: string) -> int {
    if indent_columns(line) >= 4 {
        return 0
    }
    s := strings.trim_space(line)
    if len(s) < 2 || (s[0] != '=' && s[0] != '-') {
        return 0
    }
    for i in 1 ..< len(s) {
        if s[i] != s[0] {
            return 0
        }
    }
    return s[0] == '=' ? 1 : 2
}

// The fence character and length when `s` opens a fenced code block.
@(private)
fence_open :: proc(s: string) -> (fence: u8, count: int) {
    if len(s) < 3 || (s[0] != '`' && s[0] != '~') {
        return 0, 0
    }
    for count < len(s) && s[count] == s[0] {
        count += 1
    }
    if count < 3 {
        return 0, 0
    }
    // A backtick fence has no backtick in its info string.
    if s[0] == '`' && strings.contains_rune(s[count:], '`') {
        return 0, 0
    }
    return s[0], count
}

// True when `line` closes a fence of `count` `fence` characters.
@(private)
fence_close :: proc(line: string, fence: u8, count: int) -> bool {
    s := strings.trim_space(line)
    if len(s) < count {
        return false
    }
    for i in 0 ..< len(s) {
        if s[i] != fence {
            return false
        }
    }
    return true
}

// Recognizes a list marker at the head of a line: the marker's byte length,
// the content after it and, for an ordered item, the parsed number.
@(private)
list_item :: proc(s: string) -> (marker: int, content: string, ordered: bool, num: int, ok: bool) {
    if len(s) >= 1 && (s[0] == '-' || s[0] == '*' || s[0] == '+') {
        if len(s) == 1 {
            return 1, "", false, 0, true
        }
        if s[1] == ' ' || s[1] == '\t' {
            return 1, s[1:], false, 0, true
        }
        return
    }
    // Ordered: up to nine digits, then '.' or ')', then a space or the end.
    d := 0
    for d < len(s) && s[d] >= '0' && s[d] <= '9' {
        d += 1
    }
    if d == 0 || d > 9 || d >= len(s) || (s[d] != '.' && s[d] != ')') {
        return
    }
    if d + 1 < len(s) && s[d + 1] != ' ' && s[d + 1] != '\t' {
        return
    }
    value, parsed := strconv.parse_int(s[:d])
    if !parsed {
        return
    }
    return d + 1, s[d + 1:], true, value, true
}
