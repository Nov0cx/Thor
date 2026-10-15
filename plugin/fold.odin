package plugin

import "core:c"
import "core:slice"

import lua "vendor:lua/5.4"

// Columns one tab counts as when indents are compared.
@(private = "file")
FOLD_TAB_WIDTH :: 4

// Folds by indentation, for a language with no parse tree: a line folds over
// the lines after it that are indented deeper. Blank lines inside the block
// fold with it, blank lines after it do not. A closing `}`, `]` or `)` at the
// start line's indent folds too, as a grammar fold does. Ascending by start line.
indent_fold_ranges :: proc(source: string, allocator := context.allocator) -> []Fold_Range {
    Open :: struct {
        line:   int,
        indent: int,
    }
    out := make([dynamic]Fold_Range, allocator)
    open := make([dynamic]Open, context.temp_allocator)

    line := 0
    last_text := -1 // the last line with text
    at := 0
    for at <= len(source) {
        end := at
        for end < len(source) && source[end] != '\n' {
            end += 1
        }
        indent, first, blank := line_indent(source[at:end])
        if !blank {
            closer := first == '}' || first == ']' || first == ')'
            for len(open) > 0 && open[len(open) - 1].indent >= indent {
                top := pop(&open)
                close_line := last_text
                if closer && top.indent == indent {
                    close_line = line
                }
                if close_line > top.line {
                    append(&out, Fold_Range{top.line, close_line})
                }
            }
            append(&open, Open{line, indent})
            last_text = line
        }
        at = end + 1
        line += 1
    }
    for len(open) > 0 {
        top := pop(&open)
        if last_text > top.line {
            append(&out, Fold_Range{top.line, last_text})
        }
    }
    slice.sort_by(out[:], proc(a, b: Fold_Range) -> bool {
        return a.start_line < b.start_line
    })
    return out[:]
}

// The indent width of a line, its first character after the indent, and
// whether it holds only white space.
@(private = "file")
line_indent :: proc(line: string) -> (indent: int, first: u8, blank: bool) {
    for i in 0 ..< len(line) {
        switch line[i] {
        case ' ':
            indent += 1
        case '\t':
            indent += FOLD_TAB_WIDTH - indent % FOLD_TAB_WIDTH
        case '\r':
        case:
            return indent, line[i], false
        }
    }
    return indent, 0, true
}

// Calls a language's Lua `fold` function with the source and collects the
// `{ first, last }` line pairs it returns (1-based, inclusive). A pair out of
// the source or with `last <= first` is dropped. Ascending by start line.
@(private)
run_folder :: proc(m: ^Manager, lang: ^Language, source: string, allocator := context.allocator) -> []Fold_Range {
    L := m.state
    if lang.folder.ref == NOREF {
        return nil
    }
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(lang.folder.ref))
    if !lua.isfunction(L, -1) {
        lua.pop(L, 1)
        return nil
    }
    lua.pushlstring(L, cstring(raw_data(source)), c.size_t(len(source)))
    if !call_guarded(m, m.state, lang.folder.owner, 1, 1, "fold") {
        return nil
    }
    if !lua.istable(L, -1) {
        lua.pop(L, 1)
        return nil
    }

    lines := 1
    for i in 0 ..< len(source) {
        if source[i] == '\n' {
            lines += 1
        }
    }
    tbl := lua.gettop(L)
    n := list_len(L, tbl)
    out := make([dynamic]Fold_Range, allocator)
    for i in 1 ..= n {
        lua.rawgeti(L, tbl, i)
        if lua.isnil(L, -1) {
            lua.pop(L, 1)
            break
        }
        if lua.istable(L, -1) {
            elem := lua.gettop(L)
            first := elem_int(L, elem, 1)
            last := elem_int(L, elem, 2)
            if first >= 1 && last > first && last <= lines {
                append(&out, Fold_Range{first - 1, last - 1})
            }
        }
        lua.pop(L, 1)
    }
    lua.pop(L, 1)
    slice.sort_by(out[:], proc(a, b: Fold_Range) -> bool {
        return a.start_line < b.start_line
    })
    return out[:]
}
