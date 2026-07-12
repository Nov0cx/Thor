package plugin

import "core:strings"
import "core:testing"
import lua "vendor:lua/5.4"

// Runs a Lua script and reads a global back: proves the VM links and executes.
@(test)
test_lua_runs :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    testing.expect(t, lua.L_dostring(m.state, "result = 2 + 3 * 7") == 0, "script runs")
    lua.getglobal(m.state, "result")
    testing.expect(t, lua.tointeger(m.state, -1) == 23, "read global back")
}

// Calls an Odin CFunction from Lua and reads its result: proves the boundary
// the plugin registration API relies on works in both directions.
@(test)
test_lua_calls_odin :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    add :: proc "c" (L: ^lua.State) -> i32 {
        sum := lua.L_checkinteger(L, 1) + lua.L_checkinteger(L, 2)
        lua.pushinteger(L, sum)
        return 1
    }
    lua.register(m.state, "add", add)

    testing.expect(t, lua.L_dostring(m.state, "result = add(20, 22)") == 0, "call odin fn")
    lua.getglobal(m.state, "result")
    testing.expect(t, lua.tointeger(m.state, -1) == 42, "odin fn result")
}

// A plugin registers a pure-Lua lexer and highlighting runs it, returning
// role-tagged spans. Exercises the registry, the thor.theme role handles, and
// the Lua-lexer boundary.
@(test)
test_register_and_run_lexer :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    script := `thor.register_language {
        name = "ini", extensions = { ".ini" },
        highlight = function(src)
            return { { 0, 3, thor.theme.keywords }, { 4, 7, thor.theme.strings } }
        end,
    }`
    ok := lua.L_dostring(m.state, strings.clone_to_cstring(script, context.temp_allocator)) == 0
    testing.expect(t, ok, "plugin script runs")
    testing.expect(t, supports(&m, ".ini"), "extension registered")

    spans := highlight(&m, "abc defgh", ".ini", context.allocator)
    defer {
        for s in spans {
            delete(s.role)
        }
        delete(spans)
    }
    testing.expect(t, len(spans) == 2, "two spans")
    testing.expect(t, spans[0].role == "keywords", "first role")
    testing.expect(t, spans[1].role == "strings", "second role")
}

@(private = "file")
role_covering :: proc(spans: []Span, source, needle: string) -> string {
    at := strings.index(source, needle)
    if at < 0 {
        return ""
    }
    for s in spans {
        if s.start <= at && at < s.end {
            return s.role
        }
    }
    return ""
}

// Loads the real plugins/odin/plugin.lua and highlights Odin through the
// tree-sitter grammar, confirming captures resolve to the mapped color roles
// (including the named-parameter-in-#type-proc case).
@(test)
test_odin_plugin_highlights :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)
    manager_load(&m)
    testing.expect(t, supports(&m, ".odin"), "odin language registered")

    src := `package p

Handler :: #type proc(data: rawptr)

main :: proc() {
	s := "hi" // note
}
`
    spans := highlight(&m, src, ".odin", context.allocator)
    defer delete(spans)
    testing.expect(t, len(spans) > 0, "odin spans produced")

    expect :: proc(t: ^testing.T, spans: []Span, src, needle, want: string) {
        got := role_covering(spans, src, needle)
        testing.expectf(t, got == want, "%q: role %q, want %q", needle, got, want)
    }
    expect(t, spans, src, "main", "functions")
    expect(t, spans, src, "\"hi\"", "strings")
    expect(t, spans, src, "// note", "comments")
    expect(t, spans, src, "data", "variables") // named param, not a type
}
