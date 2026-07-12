// Plugin host. Owns the Lua VM and the registries that plugins fill at load
// time. Syntax highlighting is the first capability: a plugin either declares a
// tree-sitter language or supplies a pure-Lua lexer, and maps token categories
// to theme color roles resolved by the editor at draw time.
package plugin

import lua "vendor:lua/5.4"

// Manager holds the single Lua state shared by all plugins. Lua is not
// reentrant, so every call into `state` must happen on one thread.
Manager :: struct {
    state: ^lua.State,
}

manager_create :: proc() -> Manager {
    m: Manager
    m.state = lua.L_newstate()
    lua.L_openlibs(m.state)
    return m
}

manager_destroy :: proc(m: ^Manager) {
    if m.state != nil {
        lua.close(m.state)
        m.state = nil
    }
}
