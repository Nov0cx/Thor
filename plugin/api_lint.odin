// thor.lint: plugins that hold the `lint` permission check a buffer and read what the language
// backend knows of it. A linter runs on the main thread under the call budget.
package plugin

import "base:runtime"
import "core:c"
import "core:strings"

import lua "vendor:lua/5.4"

// A registered linter: the routing key it checks, "*" for every file.
@(private)
Linter :: struct {
    key: string, // owned
    cb:  Callback,
}

Lint_Severity :: enum {
    Error,
    Warning,
    Information,
    Hint,
}

// One problem a linter found. `line` and `col` are 1-based; `end_col` 0 runs to the end of the word.
Lint_Item :: struct {
    line:     int,
    col:      int,
    end_col:  int,
    message:  string, // owned by the caller's allocator
    severity: Lint_Severity,
    owner:    int, // the plugin index
}

// One declaration of a file, as the language backend lists it.
Lint_Symbol :: struct {
    name: string,
    kind: string,
    line: int, // 1-based
}

// What the backend knows of a file at `path`. Each answers from the buffer when the file is open.
Lint_Symbols_Proc :: #type proc(host: rawptr, path: string, allocator: runtime.Allocator) -> []Lint_Symbol
// The type or the declaration of the name at byte `offset`; "" when there is none.
Lint_Type_Proc    :: #type proc(host: rawptr, path: string, offset: int, allocator: runtime.Allocator) -> string

// Builds the `thor.lint` table of plugin `index`.
@(private)
push_lint_table :: proc(m: ^Manager, index: int) {
    L := m.state
    lua.createtable(L, 0, 3)
    t := lua.gettop(L)
    push_closure(L, m, index, api_lint_register)
    lua.setfield(L, t, "register")
    push_closure(L, m, index, api_lint_symbols)
    lua.setfield(L, t, "symbols")
    push_closure(L, m, index, api_lint_type_at)
    lua.setfield(L, t, "type_at")
}

// thor.lint.register(key, fn): runs fn(path, text) for a file of the routing key `key` ("odin",
// ".odin", a file name, or "*"). fn returns a list of {line, col, end_col?, message, severity?}.
@(private)
api_lint_register :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || index < 0 || lua.type(L, 1) != .STRING || !lua.isfunction(L, 2) {
        return 0
    }
    context.allocator = m.allocator
    key := lint_key(string(lua.tostring(L, 1)))
    lua.pushvalue(L, 2) // ref pops the top, so copy the argument up
    ref := int(lua.L_ref(L, lua.REGISTRYINDEX))
    append(&m.linters, Linter{key = strings.clone(key), cb = Callback{index, ref}})
    return 0
}

// A key as the host routes it: "odin" becomes ".odin"; a name with a dot, a file name and "*" stay.
@(private = "file")
lint_key :: proc(key: string) -> string {
    if key == "*" || strings.contains_rune(key, '.') || len(key) > 0 && key[0] >= 'A' && key[0] <= 'Z' {
        return key
    }
    return strings.concatenate({".", key}, context.temp_allocator)
}

// thor.lint.symbols(path): the declarations of the file, as {name, kind, line}; nil when the host
// cannot tell. Confined like thor.read.
@(private)
api_lint_symbols :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || m.lint_symbols_proc == nil || lua.type(L, 1) != .STRING {
        lua.pushnil(L)
        return 1
    }
    context.allocator = m.allocator
    path, inside := resolve_path(m, index, string(lua.tostring(L, 1)))
    if !inside {
        lua.pushnil(L)
        return 1
    }
    symbols := m.lint_symbols_proc(m.host, path, context.temp_allocator)
    lua.createtable(L, c.int(len(symbols)), 0)
    for s, i in symbols {
        lua.createtable(L, 0, 3)
        lua.pushstring(L, strings.clone_to_cstring(s.name, context.temp_allocator))
        lua.setfield(L, -2, "name")
        lua.pushstring(L, strings.clone_to_cstring(s.kind, context.temp_allocator))
        lua.setfield(L, -2, "kind")
        lua.pushinteger(L, lua.Integer(s.line))
        lua.setfield(L, -2, "line")
        lua.rawseti(L, -2, lua.Integer(i + 1))
    }
    return 1
}

// thor.lint.type_at(path, offset): what the backend says of the name at the 0-based byte `offset`;
// nil when it says nothing. Confined like thor.read.
@(private)
api_lint_type_at :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || m.lint_type_proc == nil || lua.type(L, 1) != .STRING || !bool(lua.isinteger(L, 2)) {
        lua.pushnil(L)
        return 1
    }
    context.allocator = m.allocator
    path, inside := resolve_path(m, index, string(lua.tostring(L, 1)))
    if !inside {
        lua.pushnil(L)
        return 1
    }
    text := m.lint_type_proc(m.host, path, int(lua.tointeger(L, 2)), context.temp_allocator)
    if text == "" {
        lua.pushnil(L)
        return 1
    }
    lua.pushlstring(L, cstring(raw_data(text)), c.size_t(len(text)))
    return 1
}

// The id of the plugin at `index`, as a lint item's `owner` names it.
manager_plugin_id :: proc(m: ^Manager, index: int) -> string {
    return plugin_id(m, index)
}

// True when a linter checks files of `key`.
manager_has_linters :: proc(m: ^Manager, key: string) -> bool {
    for l in m.linters {
        if l.key == "*" || l.key == key {
            return true
        }
    }
    return false
}

// Runs every linter of `key` on `text`. Messages are cloned into `allocator`; a linter that fails or
// returns no list adds nothing.
manager_run_linters :: proc(m: ^Manager, key, path, text: string, allocator := context.allocator) -> []Lint_Item {
    out := make([dynamic]Lint_Item, allocator)
    L   := m.state
    for l in m.linters {
        if l.key != "*" && l.key != key {
            continue
        }
        lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(l.cb.ref))
        if !lua.isfunction(L, -1) {
            lua.pop(L, 1)
            continue
        }
        lua.pushlstring(L, cstring(raw_data(path)), c.size_t(len(path)))
        lua.pushlstring(L, cstring(raw_data(text)), c.size_t(len(text)))
        if !call_guarded(m, L, l.cb.owner, 2, 1, "lint") {
            continue
        }
        if !lua.istable(L, -1) {
            lua.pop(L, 1)
            continue
        }
        tbl := lua.gettop(L)
        n   := list_len(L, tbl)
        for i in 1 ..= n {
            lua.rawgeti(L, tbl, i)
            if lua.istable(L, -1) {
                if item, ok := lint_item(L, lua.gettop(L), allocator); ok {
                    item.owner = l.cb.owner
                    append(&out, item)
                }
            }
            lua.pop(L, 1)
        }
        lua.pop(L, 1)
    }
    return out[:]
}

// One entry of a linter's list. False without a positive line and a message.
@(private = "file")
lint_item :: proc(L: ^lua.State, elem: c.int, allocator: runtime.Allocator) -> (item: Lint_Item, ok: bool) {
    item.line = table_int(L, elem, "line")
    item.col = max(table_int(L, elem, "col"), 1)
    item.end_col = table_int(L, elem, "end_col")
    lua.getfield(L, elem, "message")
    if lua.type(L, -1) == .STRING {
        item.message = strings.clone(string(lua.tostring(L, -1)), allocator)
    }
    lua.pop(L, 1)
    if item.line < 1 || item.message == "" {
        delete(item.message, allocator)
        return {}, false
    }
    item.severity = .Warning
    lua.getfield(L, elem, "severity")
    if lua.type(L, -1) == .STRING {
        switch string(lua.tostring(L, -1)) {
        case "error":
            item.severity = .Error
        case "info", "information":
            item.severity = .Information
        case "hint":
            item.severity = .Hint
        }
    }
    lua.pop(L, 1)
    return item, true
}

@(private = "file")
table_int :: proc(L: ^lua.State, tbl: c.int, key: cstring) -> int {
    lua.getfield(L, tbl, key)
    defer lua.pop(L, 1)
    if !bool(lua.isinteger(L, -1)) {
        return 0
    }
    return int(lua.tointeger(L, -1))
}
