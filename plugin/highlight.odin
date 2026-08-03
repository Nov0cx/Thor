package plugin

import "base:runtime"
import "core:c"
import "core:log"
import "core:strings"

import lua "vendor:lua/5.4"

import "../syntax"

// A highlight span tagged with a theme color role (see ui.theme_role_color).
// An empty role means "use the default foreground".
Span :: struct {
    start: int,
    end:   int,
    role:  string,
}

// True when some registered language handles the given file extension.
supports :: proc(m: ^Manager, ext: string) -> bool {
    return ext in m.by_ext
}

// Highlights `source` for the language bound to `ext`, returning role-tagged
// spans (ascending, using `allocator`). `path` identifies the buffer so a
// grammar-backed language re-parses only what changed since its last call; ""
// for a buffer with no stable identity. Empty when no plugin claims the
// extension or highlighting fails.
highlight :: proc(m: ^Manager, path, source, ext: string, allocator := context.allocator) -> []Span {
    idx, ok := m.by_ext[ext]
    if !ok {
        return nil
    }
    lang := &m.languages[idx]

    if lang.grammar != "" {
        if !syntax.supports(&m.highlighter, lang.grammar) {
            return nil
        }
        caps := syntax.highlight(&m.highlighter, path, source, lang.grammar, context.temp_allocator)
        out := make([dynamic]Span, allocator)
        for cap in caps {
            append(&out, Span{cap.start, cap.end, role_for_capture(lang, cap.capture)})
        }
        return out[:]
    }

    if lang.lexer.ref != NOREF {
        return run_lexer(m, lang, source, allocator)
    }
    return nil
}

// A foldable line range for a buffer (0-based lines); folding hides
// start_line+1 .. end_line. Mirrors syntax.Fold_Range so callers need not import
// the syntax package.
Fold_Range :: struct {
    start_line: int,
    end_line:   int,
}

// Foldable line ranges for `source` under the language bound to `ext`, with
// `path` identifying the buffer as for `highlight`. Only tree-sitter grammars
// fold (a pure-Lua lexer has no parse tree); empty when no grammar-backed plugin
// claims the extension.
fold_ranges :: proc(m: ^Manager, path, source, ext: string, allocator := context.allocator) -> []Fold_Range {
    idx, ok := m.by_ext[ext]
    if !ok {
        return nil
    }
    lang := &m.languages[idx]
    if lang.grammar == "" || !syntax.supports(&m.highlighter, lang.grammar) {
        return nil
    }
    ranges := syntax.fold_ranges(&m.highlighter, path, source, lang.grammar, context.temp_allocator)
    out := make([dynamic]Fold_Range, 0, len(ranges), allocator)
    for r in ranges {
        append(&out, Fold_Range{r.start_line, r.end_line})
    }
    return out[:]
}

// The color role the language bound to `ext` gives `capture`. For a caller that
// arrived at a classification some way other than running the highlights query —
// the analyzer's semantic tokens name the capture they mean, so a semantically
// classified identifier takes exactly the color the grammar would have given it
// had the parse been able to prove the same thing, and the mapping stays in the
// language's plugin instead of being compiled into the editor. "" when no plugin
// claims the extension or the language leaves the capture unmapped.
role_for :: proc(m: ^Manager, ext, capture: string) -> string {
    idx, ok := m.by_ext[ext]
    if !ok {
        return ""
    }
    return role_for_capture(&m.languages[idx], capture)
}

// Resolves a tree-sitter capture to a color role: exact match first, then the
// capture's head ("type.builtin" -> "type"), else "" for the default.
@(private)
role_for_capture :: proc(lang: ^Language, capture: string) -> string {
    if role, ok := lang.colors[capture]; ok {
        return role
    }
    if head := capture_head(capture); head != capture {
        if role, ok := lang.colors[head]; ok {
            return role
        }
    }
    return ""
}

@(private)
capture_head :: proc(name: string) -> string {
    if dot := strings.index_byte(name, '.'); dot >= 0 {
        return name[:dot]
    }
    return name
}

// Calls a language's Lua lexer with the source and collects the returned list
// of { start, end, role } triples (byte offsets, half-open). Roles are cloned
// into `allocator` since the Lua strings are freed when the stack unwinds.
@(private)
run_lexer :: proc(m: ^Manager, lang: ^Language, source: string, allocator: runtime.Allocator) -> []Span {
    L := m.state
    if lang.lexer.ref == NOREF {
        return nil
    }
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(lang.lexer.ref))
    if !lua.isfunction(L, -1) {
        lua.pop(L, 1)
        return nil
    }
    lua.pushstring(L, strings.clone_to_cstring(source, context.temp_allocator))
    if !call_guarded(m, lang.lexer.owner, 1, 1, "lexer") {
        return nil
    }
    if !lua.istable(L, -1) {
        lua.pop(L, 1)
        return nil
    }

    tbl := lua.gettop(L)
    n := lua.L_len(L, tbl)
    out := make([dynamic]Span, allocator)
    for i in 1 ..= n {
        lua.rawgeti(L, tbl, i)
        if lua.istable(L, -1) {
            elem := lua.gettop(L)
            s := elem_int(L, elem, 1)
            e := elem_int(L, elem, 2)
            role := elem_string(L, elem, 3)
            if e > s {
                append(&out, Span{s, e, strings.clone(role, allocator)})
            }
        }
        lua.pop(L, 1)
    }
    lua.pop(L, 1)
    return out[:]
}

@(private)
elem_int :: proc(L: ^lua.State, tbl: c.int, key: lua.Integer) -> int {
    lua.rawgeti(L, tbl, key)
    defer lua.pop(L, 1)
    return int(lua.tointeger(L, -1))
}

@(private)
elem_string :: proc(L: ^lua.State, tbl: c.int, key: lua.Integer) -> string {
    lua.rawgeti(L, tbl, key)
    defer lua.pop(L, 1)
    if lua.type(L, -1) == .STRING {
        return string(lua.tostring(L, -1))
    }
    return ""
}
