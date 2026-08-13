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

// Display name of the language registered for `ext` ("Odin", "Dockerfile"), ""
// when no plugin claims it. Borrowed from the plugin's own registration.
language_name :: proc(m: ^Manager, ext: string) -> string {
    index, ok := m.by_ext[ext]
    if !ok {
        return ""
    }
    return m.languages[index].name
}

// Highlights `source` for the language bound to `ext`, returning role-tagged
// spans (ascending, using `allocator`). `path` identifies the buffer so a
// grammar-backed language re-parses only what changed since its last call; ""
// for a buffer with no stable identity. Empty when no plugin claims the
// extension or highlighting fails.
highlight :: proc(m: ^Manager, path, source, ext: string, allocator := context.allocator) -> []Span {
    spans, _, _ := highlight_range(m, path, source, ext, 0, max(int), allocator)
    return spans
}

// Highlights only the captures intersecting [range_start, range_end), so a
// caller showing one screen of a large buffer pays for that screen.
//
// `covered_start`/`covered_end` are the byte range the spans actually describe,
// which is not always the range asked for: a pure-Lua lexer that does not
// declare `line_based` answers for the whole source. A caller that caches the
// spans must record the covered range, or it re-highlights a buffer it already
// holds in full every time the view moves.
highlight_range :: proc(
    m: ^Manager,
    path, source, ext: string,
    range_start, range_end: int,
    allocator := context.allocator,
) -> (
    spans: []Span,
    covered_start: int,
    covered_end: int,
) {
    idx, ok := m.by_ext[ext]
    if !ok {
        return nil, 0, 0
    }
    lang := &m.languages[idx]
    lo := clamp(range_start, 0, len(source))
    hi := clamp(range_end, lo, len(source))

    if lang.grammar != "" {
        if !syntax.supports(&m.highlighter, lang.grammar) {
            return nil, 0, 0
        }
        caps := syntax.highlight_range(
            &m.highlighter,
            path,
            source,
            lang.grammar,
            range_start,
            range_end,
            context.temp_allocator,
        )
        out := make([dynamic]Span, allocator)
        for cap in caps {
            append(&out, Span{cap.start, cap.end, role_for_capture(lang, cap.capture)})
        }
        return out[:], lo, hi
    }

    if lang.lexer.ref != NOREF {
        // A line_based lexer reads each line on its own, so it can be given the
        // window alone. It must start at a line start, or the first line arrives
        // truncated and colors as something else.
        if lang.line_based {
            lo, hi = line_window(source, lo, hi)
            return run_lexer(m, lang, source[lo:hi], lo, allocator), lo, hi
        }
        return run_lexer(m, lang, source, 0, allocator), 0, len(source)
    }
    return nil, 0, 0
}

// Widens [start, end) to whole lines. The caller's range comes from visual rows,
// which under soft wrap begin mid-line.
@(private)
line_window :: proc(source: string, start, end: int) -> (lo, hi: int) {
    lo = start
    if nl := strings.last_index_byte(source[:lo], '\n'); nl >= 0 {
        lo = nl + 1
    } else {
        lo = 0
    }
    hi = end
    if nl := strings.index_byte(source[hi:], '\n'); nl >= 0 {
        hi += nl + 1
    } else {
        hi = len(source)
    }
    return
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
// of { start, end, role } triples (byte offsets, half-open). `offset` is added
// to each one, for a lexer given a slice of the buffer rather than all of it.
// Roles are cloned into `allocator` since the Lua strings are freed when the
// stack unwinds.
//
// The spans a plugin returns are unproven, so each is clipped to the source and
// to the end of the one before it: the editor draws them with a single
// forward-only cursor, which needs them ascending and non-overlapping.
@(private)
run_lexer :: proc(
    m: ^Manager,
    lang: ^Language,
    source: string,
    offset: int,
    allocator: runtime.Allocator,
) -> []Span {
    L := m.state
    if lang.lexer.ref == NOREF {
        return nil
    }
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(lang.lexer.ref))
    if !lua.isfunction(L, -1) {
        lua.pop(L, 1)
        return nil
    }
    // pushlstring, not a cstring: it copies the source once instead of twice and
    // keeps a buffer holding a NUL byte whole.
    lua.pushlstring(L, cstring(raw_data(source)), c.size_t(len(source)))
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
    cut := 0
    for i in 1 ..= n {
        lua.rawgeti(L, tbl, i)
        if lua.istable(L, -1) {
            elem := lua.gettop(L)
            s := clamp(elem_int(L, elem, 1), cut, len(source))
            e := clamp(elem_int(L, elem, 2), s, len(source))
            role := elem_string(L, elem, 3)
            if e > s {
                append(&out, Span{s + offset, e + offset, strings.clone(role, allocator)})
                cut = e
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
