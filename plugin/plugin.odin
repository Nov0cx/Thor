// Plugin host. Owns the Lua VM plus the tree-sitter engine and the language
// registry that plugins fill at load time. A language is either backed by a
// tree-sitter grammar (declarative: capture name -> theme color role) or by a
// pure-Lua lexer for formats without a grammar. Highlighting resolves to color
// roles; the editor maps roles to the active theme's colors.
package plugin

import "base:runtime"
import "core:c"
import "core:log"
import "core:path/filepath"
import "core:strings"

import lua "vendor:lua/5.4"

import "../syntax"

// Lua's LUA_NOREF: "no reference", used when a language has no Lua lexer.
NOREF :: -2

// Color roles exposed to plugins as `thor.theme.<role>`; each resolves to a
// theme color in the editor (see ui.theme_role_color).
@(private)
ROLES := []string {
    "background", "foreground", "keywords", "functions", "strings", "operators",
    "comments", "numbers", "parameters", "attributes", "variables", "tags", "links",
    "yellow", "orange", "purple", "cyan", "blue", "red", "green", "gray", "accent", "error",
}

// A registered language. `grammar` names a compiled-in tree-sitter grammar, or
// is empty when `lexer_ref` refers to a Lua highlight function instead.
Language :: struct {
    name:       string,
    extensions: [dynamic]string,
    grammar:    string,
    colors:     map[string]string, // capture name (or its head) -> color role
    lexer_ref:  int,               // Lua registry ref, or NOREF
}

// Manager holds the single Lua state shared by all plugins. Lua is not
// reentrant, so every call into `state` must happen on one thread.
Manager :: struct {
    state:       ^lua.State,
    highlighter: syntax.Highlighter,
    languages:   [dynamic]Language,
    by_ext:      map[string]int, // ".odin" -> index into languages
    // Registration runs inside Lua C callbacks with their own context, so the
    // registry's allocator is captured here and used for every alloc and free.
    allocator:   runtime.Allocator,
}

// Initializes a manager in place. The address is captured as a Lua upvalue by
// install_api, so the Manager must be owned by the caller (not returned by
// value, which would leave the upvalue dangling).
manager_init :: proc(m: ^Manager) {
    m.allocator = context.allocator
    m.state = lua.L_newstate()
    lua.L_openlibs(m.state)
    m.highlighter = syntax.highlighter_create()
    m.languages = make([dynamic]Language)
    m.by_ext = make(map[string]int)
    install_api(m)
}

manager_destroy :: proc(m: ^Manager) {
    context.allocator = m.allocator
    for &lang in m.languages {
        if lang.lexer_ref != NOREF {
            lua.L_unref(m.state, lua.REGISTRYINDEX, c.int(lang.lexer_ref))
        }
        free_language(&lang)
    }
    delete(m.languages)
    delete(m.by_ext)
    syntax.highlighter_destroy(&m.highlighter)
    if m.state != nil {
        lua.close(m.state)
        m.state = nil
    }
}

// Loads every plugin matching `pattern` (a folder per plugin, each with a
// plugin.lua). Safe to call once after manager_create.
manager_load :: proc(m: ^Manager, pattern := "plugins/*/plugin.lua") {
    matches, err := filepath.glob(pattern, context.temp_allocator)
    if err != nil {
        return
    }
    for path in matches {
        if lua.L_dofile(m.state, strings.clone_to_cstring(path, context.temp_allocator)) != 0 {
            log.warnf("plugin %q failed: %s", path, lua.tostring(m.state, -1))
            lua.pop(m.state, 1)
        }
    }
}

@(private)
free_language :: proc(lang: ^Language) {
    delete(lang.name)
    delete(lang.grammar)
    for ext in lang.extensions {
        delete(ext)
    }
    delete(lang.extensions)
    for k, v in lang.colors {
        delete(k)
        delete(v)
    }
    delete(lang.colors)
}

// Builds the `thor` global: a `theme` table of role handles plus the
// register_language entry point.
@(private)
install_api :: proc(m: ^Manager) {
    L := m.state
    lua.createtable(L, 0, 2)

    lua.createtable(L, 0, c.int(len(ROLES)))
    for role in ROLES {
        cs := strings.clone_to_cstring(role, context.temp_allocator)
        lua.pushstring(L, cs)
        lua.setfield(L, -2, cs)
    }
    lua.setfield(L, -2, "theme")

    // register_language carries the manager as a lightuserdata upvalue, so each
    // manager routes its registrations to itself (no shared global state).
    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, register_language, 1)
    lua.setfield(L, -2, "register_language")

    lua.setglobal(L, "thor")
}

// lua_upvalueindex: the pseudo-index of a C closure's i-th upvalue.
@(private)
upvalueindex :: proc "c" (i: c.int) -> c.int {
    return lua.REGISTRYINDEX - i
}

@(private)
register_language :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || !lua.istable(L, 1) {
        return 0
    }
    context.allocator = m.allocator

    lang: Language
    lang.lexer_ref = NOREF
    lang.colors = make(map[string]string)
    lang.extensions = make([dynamic]string)

    if name, ok := field_string(L, "name"); ok {
        lang.name = strings.clone(name)
    }
    if grammar, ok := field_string(L, "grammar"); ok {
        lang.grammar = strings.clone(grammar)
    }

    lua.getfield(L, 1, "extensions")
    if lua.istable(L, -1) {
        tbl := lua.gettop(L)
        n := lua.L_len(L, tbl)
        for i in 1 ..= n {
            lua.rawgeti(L, tbl, i)
            if lua.type(L, -1) == .STRING {
                append(&lang.extensions, strings.clone(string(lua.tostring(L, -1))))
            }
            lua.pop(L, 1)
        }
    }
    lua.pop(L, 1)

    lua.getfield(L, 1, "colors")
    if lua.istable(L, -1) {
        tbl := lua.gettop(L)
        lua.pushnil(L)
        for lua.next(L, tbl) != 0 {
            if lua.type(L, -2) == .STRING && lua.type(L, -1) == .STRING {
                lang.colors[strings.clone(string(lua.tostring(L, -2)))] = strings.clone(string(lua.tostring(L, -1)))
            }
            lua.pop(L, 1)
        }
    }
    lua.pop(L, 1)

    lua.getfield(L, 1, "highlight")
    if lua.isfunction(L, -1) {
        lang.lexer_ref = int(lua.L_ref(L, lua.REGISTRYINDEX)) // pops the function
    } else {
        lua.pop(L, 1)
    }

    if lang.grammar == "" && lang.lexer_ref == NOREF {
        free_language(&lang)
        return 0
    }

    idx := len(m.languages)
    append(&m.languages, lang)
    for ext in m.languages[idx].extensions {
        m.by_ext[ext] = idx
    }
    return 0
}

// Reads a string field from the argument table at stack index 1.
@(private)
field_string :: proc "c" (L: ^lua.State, key: cstring) -> (string, bool) {
    lua.getfield(L, 1, key)
    defer lua.pop(L, 1)
    if lua.type(L, -1) == .STRING {
        return string(lua.tostring(L, -1)), true
    }
    return "", false
}
