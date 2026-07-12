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
// spans (ascending, using `allocator`). Empty when no plugin claims the
// extension or highlighting fails.
highlight :: proc(m: ^Manager, source: string, ext: string, allocator := context.allocator) -> []Span {
    idx, ok := m.by_ext[ext]
    if !ok {
        return nil
    }
    lang := &m.languages[idx]

    if lang.grammar != "" {
        if !syntax.supports(&m.highlighter, lang.grammar) {
            return nil
        }
        caps := syntax.highlight(&m.highlighter, source, lang.grammar, context.temp_allocator)
        out := make([dynamic]Span, allocator)
        for cap in caps {
            append(&out, Span{cap.start, cap.end, role_for_capture(lang, cap.capture)})
        }
        return out[:]
    }

    if lang.lexer_ref != NOREF {
        return run_lexer(m, lang, source, allocator)
    }
    return nil
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
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(lang.lexer_ref))
    lua.pushstring(L, strings.clone_to_cstring(source, context.temp_allocator))
    if lua.pcall(L, 1, 1, 0) != 0 {
        log.warnf("lexer %q failed: %s", lang.name, lua.tostring(L, -1))
        lua.pop(L, 1)
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
