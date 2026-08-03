package thor

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// A source location parsed from a console line: the path slice plus 1-based
// line/col and the byte span of the clickable text within the line.
Console_Location :: struct {
    path:       string,
    line:       int,
    col:        int,
    span_start: int,
    span_end:   int,
}

// Parses a compiler/tool error line for a `PATH(LINE[:COL])` source location —
// the form odin, MSVC, and similar emit (the separator may be ':' or ','). The
// path must carry a file extension so an ordinary "(1:2)" run in prose does not
// match. Returns the location and whether one was found.
parse_console_location :: proc(raw: string) -> (Console_Location, bool) {
    line := strings.trim_right(raw, "\r")

    for i := 0; i < len(line); i += 1 {
        if line[i] != '(' {
            continue
        }
        // "(LINE" — at least one digit.
        j := i + 1
        ls := j
        for j < len(line) && line[j] >= '0' && line[j] <= '9' {
            j += 1
        }
        if j == ls {
            continue
        }
        lineno, _ := strconv.parse_int(line[ls:j])

        // Optional ":COL" / ",COL".
        colno := 0
        if j < len(line) && (line[j] == ':' || line[j] == ',') {
            k := j + 1
            cs := k
            for k < len(line) && line[k] >= '0' && line[k] <= '9' {
                k += 1
            }
            if k == cs {
                continue
            }
            colno, _ = strconv.parse_int(line[cs:k])
            j = k
        }

        if j >= len(line) || line[j] != ')' {
            continue
        }

        raw_path := line[:i]
        path := strings.trim_space(raw_path)
        if !path_has_extension(path) {
            continue
        }

        return Console_Location {
            path       = path,
            line       = lineno,
            col        = colno,
            span_start = leading_space_count(raw_path),
            span_end   = j + 1,
        }, true
    }
    return {}, false
}

// True when the basename of `path` has a short alphanumeric extension. Filters
// out prose so only real file references become clickable links.
@(private = "file")
path_has_extension :: proc(path: string) -> bool {
    base := path
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '/' || path[i] == '\\' {
            base = path[i + 1:]
            break
        }
    }
    dot := strings.last_index_byte(base, '.')
    if dot <= 0 || dot == len(base) - 1 {
        return false
    }
    ext := base[dot + 1:]
    if len(ext) > 8 {
        return false
    }
    for c in transmute([]u8) ext {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
            return false
        }
    }
    return true
}

@(private = "file")
leading_space_count :: proc(s: string) -> int {
    n := 0
    for n < len(s) && (s[n] == ' ' || s[n] == '\t') {
        n += 1
    }
    return n
}

// Console_Link_Proc: reports the clickable span of a scrollback line that names
// an existing source file, for the hover underline.
thor_console_link :: proc(data: rawptr, line: string) -> (start: int, end: int, ok: bool) {
    thor := cast(^Thor) data
    loc, found := parse_console_location(line)
    if !found {
        return 0, 0, false
    }
    if !os.exists(thor_console_resolve_path(thor, loc.path)) {
        return 0, 0, false
    }
    return loc.span_start, loc.span_end, true
}

// Console_Activate_Proc: opens the source file named by a clicked scrollback
// line at its reported line/column.
thor_console_activate :: proc(data: rawptr, line: string) {
    thor := cast(^Thor) data
    loc, found := parse_console_location(line)
    if !found {
        return
    }
    abs := thor_console_resolve_path(thor, loc.path)
    if !os.exists(abs) {
        return
    }
    thor_goto_file_line_col(thor, abs, loc.line, max(loc.col, 1))
}

// Resolves a console-reported path against the workspace directory when it is
// relative (tool output prints paths relative to where the command ran).
@(private = "file")
thor_console_resolve_path :: proc(thor: ^Thor, path: string) -> string {
    if filepath.is_abs(path) {
        return path
    }
    joined, err := filepath.join({thor.workspace_dir, path}, context.temp_allocator)
    if err != nil {
        return path
    }
    return joined
}

