package plugin

import "core:testing"
import lua "vendor:lua/5.4"

// Runs a Lua script and reads a global back: proves the VM links and executes.
@(test)
test_lua_runs :: proc(t: ^testing.T) {
    m := manager_create()
    defer manager_destroy(&m)

    testing.expect(t, lua.L_dostring(m.state, "result = 2 + 3 * 7") == 0, "script runs")
    lua.getglobal(m.state, "result")
    testing.expect(t, lua.tointeger(m.state, -1) == 23, "read global back")
}

// Calls an Odin CFunction from Lua and reads its result: proves the boundary
// the plugin registration API relies on works in both directions.
@(test)
test_lua_calls_odin :: proc(t: ^testing.T) {
    m := manager_create()
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
