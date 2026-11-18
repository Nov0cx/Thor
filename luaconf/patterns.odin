package luaconf

import "base:runtime"
import "core:c"
import "core:math"

import lua "vendor:lua/5.4"

// Longest pattern a script may pass to the string library.
MAX_PATTERN_BYTES :: 256

// Most work, as subject length to the power of the pattern's backtracking items,
// one match call may start. A call over it raises a Lua error.
MAX_PATTERN_COST :: f64(1 << 36)

// Replaces find, match, gmatch and gsub of the global `string` table with
// wrappers that refuse a call whose backtracking cost is unbounded: C code runs
// without the instruction hook, so a hostile pattern would hang the host.
// `max_subject` is the longest subject a call takes.
guard_string_patterns :: proc(L: ^lua.State, max_subject: int) {
    lua.getglobal(L, "string")
    if !lua.istable(L, -1) {
        lua.pop(L, 1)
        return
    }
    for name in ([]cstring{"find", "match", "gmatch", "gsub"}) {
        lua.getfield(L, -1, name)
        if !lua.iscfunction(L, -1) {
            lua.pop(L, 1)
            continue
        }
        lua.pushinteger(L, lua.Integer(max_subject))
        lua.pushboolean(L, b32(name == "find"))
        lua.pushcclosure(L, guarded_pattern, 3)
        lua.setfield(L, -2, name)
    }
    lua.pop(L, 1)
}

// The backtracking items of a Lua pattern: a quantifier (`*`, `-`, `+`, `?`) on
// `.`, or one that directly follows another quantified element. Those chains
// are what makes a failing match cost the subject length to the power of the count.
pattern_items :: proc(p: string) -> int {
    items := 0
    chain := false
    i     := 0
    for i < len(p) {
        is_dot := false
        switch p[i] {
        case '(', ')':
            i += 1
            continue
        case '%':
            if i + 1 < len(p) && p[i + 1] == 'b' {
                i += 4
            } else if i + 1 < len(p) && p[i + 1] == 'f' {
                i += 2
                continue
            } else {
                i += 2
            }
        case '[':
            i += 1
            if i < len(p) && p[i] == '^' {
                i += 1
            }
            if i < len(p) && p[i] == ']' {
                i += 1
            }
            for i < len(p) && p[i] != ']' {
                if p[i] == '%' {
                    i += 1
                }
                i += 1
            }
            i += 1
        case '.':
            is_dot = true
            i += 1
        case:
            i += 1
        }
        if i < len(p) && (p[i] == '*' || p[i] == '-' || p[i] == '+' || p[i] == '?') {
            if is_dot || chain {
                items += 1
            }
            chain = true
            i += 1
        } else {
            chain = false
        }
    }
    return items
}

// Whether matching `pattern` against a subject of `subject_len` bytes may run
// for an unbounded time.
pattern_too_costly :: proc(pattern: string, subject_len: int) -> bool {
    items := pattern_items(pattern)
    if items < 2 {
        return false
    }
    return math.pow(f64(max(subject_len, 1)), f64(items)) > MAX_PATTERN_COST
}

@(private)
upvalue :: proc "c"(i: c.int) -> c.int {
    return lua.REGISTRYINDEX - i
}

// upvalue 1 is the stock function, 2 the subject cap, 3 whether it is `find`.
@(private)
guarded_pattern :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()
    args        := lua.gettop(L)
    max_subject := int(lua.tointeger(L, upvalue(2)))
    is_find     := bool(lua.toboolean(L, upvalue(3)))

    subject_len := 0
    if lua.type(L, 1) == .STRING {
        n: c.size_t
        lua.tolstring(L, 1, &n)
        subject_len = int(n)
        if subject_len > max_subject {
            lua.L_error(L, "string too long for a pattern call")
        }
    }
    plain := is_find && args >= 4 && bool(lua.toboolean(L, 4))
    if lua.type(L, 2) == .STRING && !plain {
        n: c.size_t
        text := lua.tolstring(L, 2, &n)
        if n > MAX_PATTERN_BYTES {
            lua.L_error(L, "pattern too long")
        }
        if pattern_too_costly(string((cast([^]u8)text)[:n]), subject_len) {
            lua.L_error(L, "pattern too complex for this subject")
        }
    }
    lua.pushvalue(L, upvalue(1))
    lua.insert(L, 1)
    lua.call(L, args, lua.MULTRET)
    return lua.gettop(L)
}
