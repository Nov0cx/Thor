// Plugin host: owns the Lua VM, the tree-sitter engine, and the language
// registry plugins fill at load time. A language is backed by a tree-sitter
// grammar or a pure-Lua lexer. Highlighting resolves to color roles.
package plugin

import "base:runtime"
import "core:c"
import "core:log"
import "core:path/filepath"
import "core:strings"

import lua "vendor:lua/5.4"

import "../syntax"

// Lua's LUA_NOREF; marks a language with no Lua lexer.
NOREF :: -2

// Color roles exposed to plugins as `thor.theme.<role>`.
@(private)
ROLES := []string {
    "background", "foreground", "keywords", "functions", "strings", "operators",
    "comments", "numbers", "parameters", "attributes", "variables", "tags", "links",
    "yellow", "orange", "purple", "cyan", "blue", "red", "green", "gray", "accent", "error",
}

// A registered language; `grammar` is empty when `lexer_ref` names a Lua lexer.
Language :: struct {
    name:       string,
    extensions: [dynamic]string,
    grammar:    string,
    colors:     map[string]string, // capture name (or its head) -> color role
    lexer_ref:  int,               // Lua registry ref, or NOREF
}

// Host services a plugin can call back into, as plain function pointers so the
// package stays free of any dependency on the app.
Print_Proc :: #type proc(host: rawptr, text: string)
Keybind_Proc :: #type proc(host: rawptr, action: string) -> (chord: string, ok: bool)
// Renders `text` into a document tab at `path`; `focus` reveals and focuses it.
Doc_Proc :: #type proc(host: rawptr, path: string, text: string, focus: bool)
// Runs `command` in the workspace and returns its owned stdout+stderr; the host
// owns the result and the caller frees it after copying into Lua.
Exec_Proc :: #type proc(host: rawptr, command: string) -> string
// Adds a top-bar button labelled `label` that runs the named command on click.
Button_Proc :: #type proc(host: rawptr, label: string, command: string)

// The single Lua state shared by all plugins. Not reentrant: one thread only.
Manager :: struct {
    state:       ^lua.State,
    highlighter: syntax.Highlighter,
    languages:   [dynamic]Language,
    by_ext:      map[string]int, // ".odin" -> index into languages
    // Used for every alloc and free, since Lua C callbacks run under a default context.
    allocator:   runtime.Allocator,
    // on_key handler ref (NOREF when unset); host/print/keybind wired by the app.
    key_ref:      int,
    host:         rawptr,
    print_proc:   Print_Proc,
    keybind_proc: Keybind_Proc,
    doc_proc:     Doc_Proc,
    exec_proc:    Exec_Proc,
    button_proc:  Button_Proc,
    // Named commands registered via thor.on_command -> Lua ref; keys are owned.
    command_refs: map[string]int,
}

// Wires the host services a plugin can call. Call once after manager_init.
manager_set_host :: proc(
    m: ^Manager,
    host: rawptr,
    print_proc: Print_Proc,
    keybind_proc: Keybind_Proc,
    doc_proc: Doc_Proc,
    exec_proc: Exec_Proc,
    button_proc: Button_Proc,
) {
    m.host = host
    m.print_proc = print_proc
    m.keybind_proc = keybind_proc
    m.doc_proc = doc_proc
    m.exec_proc = exec_proc
    m.button_proc = button_proc
}

// Initializes a manager in place. The caller must own it: install_api captures
// its address as a Lua upvalue.
manager_init :: proc(m: ^Manager) {
    m.allocator = context.allocator
    m.state = lua.L_newstate()
    lua.L_openlibs(m.state)
    m.highlighter = syntax.highlighter_create()
    m.languages = make([dynamic]Language)
    m.by_ext = make(map[string]int)
    m.key_ref = NOREF
    m.command_refs = make(map[string]int)
    install_api(m)
}

manager_destroy :: proc(m: ^Manager) {
    context.allocator = m.allocator
    if m.key_ref != NOREF {
        lua.L_unref(m.state, lua.REGISTRYINDEX, c.int(m.key_ref))
        m.key_ref = NOREF
    }
    for name, ref in m.command_refs {
        lua.L_unref(m.state, lua.REGISTRYINDEX, c.int(ref))
        delete(name)
    }
    delete(m.command_refs)
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

// Loads every plugin matching `pattern` (a folder per plugin, each a plugin.lua).
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

// Builds the `thor` global: a `theme` table of role handles plus the entry points.
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

    // The manager travels as a lightuserdata upvalue so each routes calls to itself.
    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, register_language, 1)
    lua.setfield(L, -2, "register_language")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_on_key, 1)
    lua.setfield(L, -2, "on_key")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_print, 1)
    lua.setfield(L, -2, "print")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_keybind, 1)
    lua.setfield(L, -2, "keybind")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_on_command, 1)
    lua.setfield(L, -2, "on_command")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_doc, 1)
    lua.setfield(L, -2, "doc")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_exec, 1)
    lua.setfield(L, -2, "exec")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_button, 1)
    lua.setfield(L, -2, "button")

    lua.setglobal(L, "thor")
}

// thor.on_key(fn): handler run for every key press, given {chord, ctrl, shift,
// alt}; returning true consumes the key.
@(private)
api_on_key :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || !lua.isfunction(L, 1) {
        return 0
    }
    if m.key_ref != NOREF {
        lua.L_unref(L, lua.REGISTRYINDEX, c.int(m.key_ref))
    }
    lua.pushvalue(L, 1) // ref pops the top, so copy the argument up
    m.key_ref = int(lua.L_ref(L, lua.REGISTRYINDEX))
    return 0
}

// thor.print(text): appends a line to the host's output. No-op without a sink.
@(private)
api_print :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.print_proc == nil || lua.type(L, 1) != .STRING {
        return 0
    }
    // Host appends into app-owned state, so free under the app's allocator.
    context.allocator = m.allocator
    m.print_proc(m.host, string(lua.tostring(L, 1)))
    return 0
}

// thor.doc(path, text[, focus]): renders `text` into a document tab at `path`,
// updating the open buffer in place. A truthy `focus` reveals and focuses it.
@(private)
api_doc :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.doc_proc == nil || lua.type(L, 1) != .STRING || lua.type(L, 2) != .STRING {
        return 0
    }
    // Host edits app-owned buffers, so run under the app's allocator rather than
    // the C callback's default context, or the main loop later bad-frees them.
    context.allocator = m.allocator
    focus := bool(lua.toboolean(L, 3))
    m.doc_proc(m.host, string(lua.tostring(L, 1)), string(lua.tostring(L, 2)), focus)
    return 0
}

// thor.exec(command): runs `command` in the workspace, returning its combined
// stdout+stderr as a string (empty string without a sink). Blocks until it exits.
@(private)
api_exec :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.exec_proc == nil || lua.type(L, 1) != .STRING {
        lua.pushstring(L, "")
        return 1
    }
    context.allocator = m.allocator
    out := m.exec_proc(m.host, string(lua.tostring(L, 1)))
    lua.pushstring(L, strings.clone_to_cstring(out, context.temp_allocator))
    delete(out) // host-owned result, freed after copying into Lua
    return 1
}

// thor.button(label, command): adds a top-bar button that runs the named
// command (registered via thor.on_command) when clicked.
@(private)
api_button :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.button_proc == nil || lua.type(L, 1) != .STRING || lua.type(L, 2) != .STRING {
        return 0
    }
    context.allocator = m.allocator
    m.button_proc(m.host, string(lua.tostring(L, 1)), string(lua.tostring(L, 2)))
    return 0
}

// thor.keybind(action): the chord bound to `action` (e.g. "Ctrl+S"), or nil.
@(private)
api_keybind :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.keybind_proc == nil || lua.type(L, 1) != .STRING {
        lua.pushnil(L)
        return 1
    }
    context.allocator = m.allocator
    chord, ok := m.keybind_proc(m.host, string(lua.tostring(L, 1)))
    if !ok {
        lua.pushnil(L)
        return 1
    }
    lua.pushstring(L, strings.clone_to_cstring(chord, context.temp_allocator))
    return 1
}

// thor.on_command(name, fn): registers a named command the host invokes by name
// (see manager_run_command), e.g. Help -> Tutorial.
@(private)
api_on_command :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || lua.type(L, 1) != .STRING || !lua.isfunction(L, 2) {
        return 0
    }
    context.allocator = m.allocator
    name := string(lua.tostring(L, 1))
    // Reuse the existing owned key on replace; clone for a new one.
    if existing, ok := m.command_refs[name]; ok {
        lua.L_unref(L, lua.REGISTRYINDEX, c.int(existing))
        lua.pushvalue(L, 2)
        m.command_refs[name] = int(lua.L_ref(L, lua.REGISTRYINDEX))
        return 0
    }
    lua.pushvalue(L, 2)
    m.command_refs[strings.clone(name)] = int(lua.L_ref(L, lua.REGISTRYINDEX))
    return 0
}

// Runs the plugin command registered under `name`. Returns whether it existed
// and ran without error.
manager_run_command :: proc(m: ^Manager, name: string) -> bool {
    ref, ok := m.command_refs[name]
    if !ok {
        return false
    }
    L := m.state

    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ref))
    if !lua.isfunction(L, -1) {
        lua.pop(L, 1)
        return false
    }
    if lua.pcall(L, 0, 0, 0) != 0 {
        log.warnf("plugin command %q failed: %s", name, lua.tostring(L, -1))
        lua.pop(L, 1)
        return false
    }
    return true
}

// Dispatches a key press to the on_key handler. `chord` is the display string
// (same format as thor.keybind). Returns whether the plugin consumed it.
manager_dispatch_key :: proc(m: ^Manager, chord: string, ctrl, shift, alt: bool) -> (consumed: bool) {
    if m.key_ref == NOREF {
        return false
    }
    L := m.state

    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(m.key_ref))
    if !lua.isfunction(L, -1) {
        lua.pop(L, 1)
        return false
    }

    lua.createtable(L, 0, 4)
    lua.pushstring(L, strings.clone_to_cstring(chord, context.temp_allocator))
    lua.setfield(L, -2, "chord")
    lua.pushboolean(L, b32(ctrl))
    lua.setfield(L, -2, "ctrl")
    lua.pushboolean(L, b32(shift))
    lua.setfield(L, -2, "shift")
    lua.pushboolean(L, b32(alt))
    lua.setfield(L, -2, "alt")

    if lua.pcall(L, 1, 1, 0) != 0 {
        log.warnf("plugin on_key failed: %s", lua.tostring(L, -1))
        lua.pop(L, 1)
        return false
    }
    consumed = bool(lua.toboolean(L, -1))
    lua.pop(L, 1)
    return consumed
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
