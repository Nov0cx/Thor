package thor

import "core:path/filepath"
import "core:strconv"
import "core:strings"

// Lines at the head of a file that may hold a `% !TEX root` comment.
@(private = "file")
LATEX_MAGIC_LINES :: 40

// Extensions of a LaTeX document a build can start from.
LATEX_SOURCE_EXTS :: [?]string{".tex", ".ltx", ".latex"}

// Whether a file of this name is a LaTeX document.
latex_is_source :: proc(name: string) -> bool {
    ext := filepath.ext(name)
    for e in LATEX_SOURCE_EXTS {
        if strings.equal_fold(ext, e) {
            return true
        }
    }
    return false
}

// The path a `% !TEX root = <path>` comment in the head of `text` names, as written.
latex_magic_root :: proc(text: string) -> (root: string, ok: bool) {
    rest := text
    for _ in 0 ..< LATEX_MAGIC_LINES {
        line, more := strings.split_lines_iterator(&rest)
        if !more {
            break
        }
        t := strings.trim_space(line)
        if !strings.has_prefix(t, "%") {
            continue
        }
        t = strings.trim_left(t, "% \t")
        if !strings.has_prefix(t, "!") {
            continue
        }
        t = strings.trim_space(t[1:])
        if len(t) < 3 || !strings.equal_fold(t[:3], "TEX") {
            continue
        }
        t = strings.trim_space(t[3:])
        if len(t) < 4 || !strings.equal_fold(t[:4], "root") {
            continue
        }
        t = strings.trim_space(t[4:])
        if !strings.has_prefix(t, "=") {
            continue
        }
        t = strings.trim_space(t[1:])
        if t != "" {
            return t, true
        }
    }
    return "", false
}

// The PDF a build of `root` writes: the root's name with .pdf, beside it.
latex_pdf_path :: proc(root: string, allocator := context.allocator) -> string {
    stem := root[:len(root) - len(filepath.ext(root))]
    return strings.concatenate({stem, ".pdf"}, allocator)
}

// Whether `line` holds `:<digits>: `, the mark of a -file-line-error message.
@(private = "file")
latex_line_has_location :: proc(line: string) -> bool {
    for i := 0; i < len(line); i += 1 {
        if line[i] != ':' {
            continue
        }
        j := i + 1
        for j < len(line) && line[j] >= '0' && line[j] <= '9' {
            j += 1
        }
        if j > i + 1 && j + 1 < len(line) && line[j] == ':' && line[j + 1] == ' ' {
            return true
        }
    }
    return false
}

// The first error line of a build output: `file:line: message`, else a TeX `! message`.
latex_first_error :: proc(output: string) -> string {
    rest := output
    bang := ""
    for line in strings.split_lines_iterator(&rest) {
        t := strings.trim_space(line)
        if latex_line_has_location(t) {
            return t
        }
        if bang == "" && strings.has_prefix(t, "! ") {
            bang = t
        }
    }
    return bang
}

// The number after `key` in `line`, or false.
@(private = "file")
field_f32 :: proc(line, key: string) -> (value: f32, ok: bool) {
    at := strings.index(line, key)
    if at < 0 {
        return 0, false
    }
    rest := strings.trim_left_space(line[at + len(key):])
    end  := 0
    for end < len(rest) && (rest[end] == '-' || rest[end] == '.' || (rest[end] >= '0' && rest[end] <= '9')) {
        end += 1
    }
    return strconv.parse_f32(rest[:end])
}

// The page sizes in points that `pdfinfo -f 1 -l <n>` prints, one per page. A
// plain `pdfinfo` prints one `Page size:` and a `Pages:` count instead.
pdfinfo_parse_sizes :: proc(output: string, allocator := context.allocator) -> [dynamic][2]f32 {
    sizes := make([dynamic][2]f32, allocator)
    shared: [2]f32
    count := 0
    rest  := output
    for line in strings.split_lines_iterator(&rest) {
        t := strings.trim_space(line)
        if strings.has_prefix(t, "Pages:") {
            if n, ok := strconv.parse_int(strings.trim_space(t[len("Pages:"):])); ok {
                count = n
            }
            continue
        }
        if !strings.has_prefix(t, "Page") {
            continue
        }
        size_at := strings.index(t, "size:")
        if size_at < 0 {
            continue
        }
        dims := t[size_at + len("size:"):]
        x    := strings.index(dims, " x ")
        if x < 0 {
            continue
        }
        w, w_ok := strconv.parse_f32(strings.trim_space(dims[:x]))
        h, h_ok := field_f32(dims[x + 3:], "")
        if !w_ok || !h_ok || w <= 0 || h <= 0 {
            continue
        }
        if strings.has_prefix(t, "Page size:") {
            shared = {w, h}
        } else {
            append(&sizes, [2]f32{w, h})
        }
    }
    if len(sizes) == 0 && shared != {} {
        for _ in 0 ..< max(count, 1) {
            append(&sizes, shared)
        }
    }
    return sizes
}

// The page sizes in points from `mutool pages`: one `<MediaBox l= b= r= t=>` per page.
mutool_parse_sizes :: proc(output: string, allocator := context.allocator) -> [dynamic][2]f32 {
    sizes := make([dynamic][2]f32, allocator)
    rest  := output
    for line in strings.split_lines_iterator(&rest) {
        if !strings.contains(line, "<MediaBox") {
            continue
        }
        l, l_ok := field_f32(line, "l=\"")
        b, b_ok := field_f32(line, "b=\"")
        r, r_ok := field_f32(line, "r=\"")
        t, t_ok := field_f32(line, "t=\"")
        if l_ok && b_ok && r_ok && t_ok && r > l && t > b {
            append(&sizes, [2]f32{r - l, t - b})
        }
    }
    return sizes
}

// What `synctex edit` gives for a point in the PDF. `input` borrows the output.
Synctex_Edit :: struct {
    input:  string,
    line:   int,
    column: int, // 0 when synctex does not know it
}

// The first record of a `synctex edit` output.
synctex_parse_edit :: proc(output: string) -> (edit: Synctex_Edit, ok: bool) {
    rest := output
    for line in strings.split_lines_iterator(&rest) {
        t := strings.trim_right_space(line)
        switch {
        case strings.has_prefix(t, "Input:") && edit.input == "":
            edit.input = t[len("Input:"):]
        case strings.has_prefix(t, "Line:") && edit.line == 0:
            edit.line, _ = strconv.parse_int(t[len("Line:"):])
        case strings.has_prefix(t, "Column:") && edit.column == 0:
            edit.column, _ = strconv.parse_int(t[len("Column:"):])
        }
    }
    edit.column = max(edit.column, 0)
    return edit, edit.input != "" && edit.line > 0
}

// A box in the PDF from `synctex view`, in points from the top-left of its page.
// `v` is the baseline, so the box spans v - height .. v.
Synctex_Box :: struct {
    page:   int,
    h:      f32,
    v:      f32,
    width:  f32,
    height: f32,
}

// The first record of a `synctex view` output.
synctex_parse_view :: proc(output: string) -> (box: Synctex_Box, ok: bool) {
    rest := output
    seen: bit_set[0 ..< 5]
    for line in strings.split_lines_iterator(&rest) {
        t := strings.trim_right_space(line)
        value :: proc(t, key: string) -> f32 {
            v, _ := strconv.parse_f32(t[len(key):])
            return v
        }
        switch {
        case strings.has_prefix(t, "Page:") && 0 not_in seen:
            box.page, _ = strconv.parse_int(t[len("Page:"):])
            seen += {0}
        case strings.has_prefix(t, "h:") && 1 not_in seen:
            box.h = value(t, "h:")
            seen += {1}
        case strings.has_prefix(t, "v:") && 2 not_in seen:
            box.v = value(t, "v:")
            seen += {2}
        case strings.has_prefix(t, "W:") && 3 not_in seen:
            box.width = value(t, "W:")
            seen += {3}
        case strings.has_prefix(t, "H:") && 4 not_in seen:
            box.height = value(t, "H:")
            seen += {4}
        }
    }
    return box, box.page > 0 && {0, 1, 2} <= seen
}
