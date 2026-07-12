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

// Loads the real plugins/markdown/plugin.lua and highlights Markdown through
// its pure-Lua line lexer, confirming block and inline constructs resolve to the
// expected color roles and that the returned spans stay ascending and
// non-overlapping (the editor renders them with a single forward cursor).
@(test)
test_markdown_plugin_highlights :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)
    manager_load(&m)
    testing.expect(t, supports(&m, ".md"), "markdown language registered")

    src := "# Title\n\nSome **bold** and *slant* and `code`.\n\n- item one\n> quote\n\n```\nfenced\n```\n"
    spans := highlight(&m, src, ".md", context.allocator)
    defer {
        for s in spans {
            delete(s.role)
        }
        delete(spans)
    }
    testing.expect(t, len(spans) > 0, "markdown spans produced")

    expect :: proc(t: ^testing.T, spans: []Span, src, needle, want: string) {
        got := role_covering(spans, src, needle)
        testing.expectf(t, got == want, "%q: role %q, want %q", needle, got, want)
    }
    expect(t, spans, src, "# Title", "keywords")
    expect(t, spans, src, "**bold**", "orange")
    expect(t, spans, src, "*slant*", "attributes")
    expect(t, spans, src, "`code`", "strings")
    expect(t, spans, src, "- ", "operators")
    expect(t, spans, src, "> quote", "comments")
    expect(t, spans, src, "fenced", "strings")

    // Spans must be ordered and non-overlapping for the editor's row renderer.
    for i in 1 ..< len(spans) {
        testing.expect(t, spans[i - 1].end <= spans[i].start, "spans overlap or unordered")
    }
}

// Loads the real plugins/batch/plugin.lua and highlights a Windows batch script
// through its pure-Lua lexer, confirming comments, keywords, variables, labels
// and operators resolve to the expected roles and that spans stay ordered and
// non-overlapping.
@(test)
test_batch_plugin_highlights :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)
    manager_load(&m)
    testing.expect(t, supports(&m, ".bat"), "batch language registered")

    src := "@echo off\nREM build script\nset NAME=thor\necho Building %NAME%\nif not exist bin goto :end\n:end\nexit /b 0\n"
    spans := highlight(&m, src, ".bat", context.allocator)
    defer {
        for s in spans {
            delete(s.role)
        }
        delete(spans)
    }
    testing.expect(t, len(spans) > 0, "batch spans produced")

    expect :: proc(t: ^testing.T, spans: []Span, src, needle, want: string) {
        got := role_covering(spans, src, needle)
        testing.expectf(t, got == want, "%q: role %q, want %q", needle, got, want)
    }
    expect(t, spans, src, "@", "operators")
    expect(t, spans, src, "echo", "keywords")
    expect(t, spans, src, "REM build script", "comments")
    expect(t, spans, src, "set", "keywords")
    expect(t, spans, src, "%NAME%", "variables")
    expect(t, spans, src, "goto", "keywords")
    expect(t, spans, src, ":end", "functions")
    expect(t, spans, src, "exit", "keywords")

    for i in 1 ..< len(spans) {
        testing.expect(t, spans[i - 1].end <= spans[i].start, "spans overlap or unordered")
    }
}

// Loads the real plugins/shell/plugin.lua and highlights a shell script through
// its pure-Lua lexer, confirming comments, keywords, variables and function
// definitions resolve to the expected roles.
@(test)
test_shell_plugin_highlights :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)
    manager_load(&m)
    testing.expect(t, supports(&m, ".sh"), "shell language registered")

    src := "#!/bin/bash\n# build\nNAME=thor\ncd $NAME\ngreet() {\n    echo hello\n}\nif [ -f bin ]; then\n    greet\nfi\n"
    spans := highlight(&m, src, ".sh", context.allocator)
    defer {
        for s in spans {
            delete(s.role)
        }
        delete(spans)
    }
    testing.expect(t, len(spans) > 0, "shell spans produced")

    expect :: proc(t: ^testing.T, spans: []Span, src, needle, want: string) {
        got := role_covering(spans, src, needle)
        testing.expectf(t, got == want, "%q: role %q, want %q", needle, got, want)
    }
    expect(t, spans, src, "#!/bin/bash", "comments")
    expect(t, spans, src, "# build", "comments")
    expect(t, spans, src, "cd", "keywords")
    expect(t, spans, src, "$NAME", "variables")
    expect(t, spans, src, "greet", "functions")
    expect(t, spans, src, "echo", "keywords")

    for i in 1 ..< len(spans) {
        testing.expect(t, spans[i - 1].end <= spans[i].start, "spans overlap or unordered")
    }
}

// Loads the real plugins/json/plugin.lua and highlights JSON through its
// pure-Lua lexer, confirming object keys, string values, numbers and literals
// resolve to distinct roles.
@(test)
test_json_plugin_highlights :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)
    manager_load(&m)
    testing.expect(t, supports(&m, ".json"), "json language registered")

    src := "{\n  \"name\": \"thor\",\n  \"version\": 2,\n  \"debug\": true,\n  \"nested\": null\n}\n"
    spans := highlight(&m, src, ".json", context.allocator)
    defer {
        for s in spans {
            delete(s.role)
        }
        delete(spans)
    }
    testing.expect(t, len(spans) > 0, "json spans produced")

    expect :: proc(t: ^testing.T, spans: []Span, src, needle, want: string) {
        got := role_covering(spans, src, needle)
        testing.expectf(t, got == want, "%q: role %q, want %q", needle, got, want)
    }
    expect(t, spans, src, "\"name\"", "tags")   // object key
    expect(t, spans, src, "\"thor\"", "strings") // string value
    expect(t, spans, src, "2", "numbers")
    expect(t, spans, src, "true", "keywords")
    expect(t, spans, src, "null", "keywords")

    for i in 1 ..< len(spans) {
        testing.expect(t, spans[i - 1].end <= spans[i].start, "spans overlap or unordered")
    }
}
