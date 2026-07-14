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

// Host services a plugin can call back into (owned by the embedding app, e.g.
// Thor). Kept as plain function pointers so the plugin package stays free of any
// dependency on the app or its widgets.
Print_Proc :: #type proc(host: rawptr, text: string)
Keybind_Proc :: #type proc(host: rawptr, action: string) -> (chord: string, ok: bool)
// Renders `text` into a document tab at `path` (writing the file, then updating
// the open buffer in place so repeated calls don't churn tabs or steal focus).
// `focus` reveals and focuses the tab, used when the document is first shown.
Doc_Proc :: #type proc(host: rawptr, path: string, text: string, focus: bool)

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
    // Interactive hooks. `key_ref` is the Lua registry ref of the on_key
    // handler (NOREF when a plugin never registered one); host/print/keybind
    // are set by the app so plugins can print and read the live keybinds.
    key_ref:      int,
    host:         rawptr,
    print_proc:   Print_Proc,
    keybind_proc: Keybind_Proc,
    doc_proc:     Doc_Proc,
    // Named commands a plugin registered with thor.on_command, mapped to their
    // Lua registry ref; the host invokes one by name via manager_run_command
    // (e.g. Help -> Tutorial starts the interactive tutorial). Keys are owned.
    command_refs: map[string]int,
}

// Wires the host services a plugin can call (thor.print / thor.keybind). Call
// once after manager_init, before plugins are expected to interact.
manager_set_host :: proc(
    m: ^Manager,
    host: rawptr,
    print_proc: Print_Proc,
    keybind_proc: Keybind_Proc,
    doc_proc: Doc_Proc,
) {
    m.host = host
    m.print_proc = print_proc
    m.keybind_proc = keybind_proc
    m.doc_proc = doc_proc
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

    // Every entry point carries the manager as a lightuserdata upvalue, so each
    // manager routes calls to itself (no shared global state).
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

    lua.setglobal(L, "thor")
}

// thor.on_key(fn): registers (or replaces) the handler invoked for every key
// press. The handler receives a table {chord, ctrl, shift, alt}; returning true
// consumes the key so normal handling is skipped.
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

// thor.print(text): appends a line of text to the host's output (Thor's
// console). No-op if the host provided no sink.
@(private)
api_print :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.print_proc == nil || lua.type(L, 1) != .STRING {
        return 0
    }
    // Run under the app's allocator: the host appends into app-owned widget
    // state, which must be freed by the same allocator (see api_doc).
    context.allocator = m.allocator
    m.print_proc(m.host, string(lua.tostring(L, 1)))
    return 0
}

// thor.doc(path, text[, focus]): renders `text` into a document tab at `path`.
// The host writes the file and updates the open buffer in place, so a plugin can
// refresh a live view (e.g. the tutorial) without churning tabs. A truthy third
// argument reveals and focuses the tab (used the first time it is shown).
@(private)
api_doc :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.doc_proc == nil || lua.type(L, 1) != .STRING || lua.type(L, 2) != .STRING {
        return 0
    }
    // The host opens/edits app-owned buffers here; run under the app's allocator
    // (not the C callback's default context) so those allocations are freed by
    // the same allocator later (otherwise the main loop bad-frees the load job).
    context.allocator = m.allocator
    focus := bool(lua.toboolean(L, 3))
    m.doc_proc(m.host, string(lua.tostring(L, 1)), string(lua.tostring(L, 2)), focus)
    return 0
}

// thor.keybind(action): returns the chord string currently bound to `action`
// (e.g. "Ctrl+S"), or nil when the action is unbound / no host is set. Lets a
// plugin present the user's real, possibly-rebound shortcuts.
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

// thor.on_command(name, fn): registers (or replaces) a named command the host
// can invoke later by name (see manager_run_command). Lets a plugin expose an
// entry point the app can trigger from a menu, e.g. Help -> Tutorial.
@(private)
api_on_command :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || lua.type(L, 1) != .STRING || !lua.isfunction(L, 2) {
        return 0
    }
    context.allocator = m.allocator
    name := string(lua.tostring(L, 1))
    // Replacing an existing command reuses its owned key; a new one clones.
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

// Invokes the plugin command registered under `name` with no arguments.
// Returns whether such a command existed and ran without error.
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

// Dispatches a key press to the registered on_key handler. `chord` is the
// display string for the pressed combination (same format as thor.keybind), so
// a plugin can compare the two directly. Returns whether the plugin consumed it.
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
