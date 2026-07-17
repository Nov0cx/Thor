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
// Returns the workspace directory (absolute). The host owns the string.
Workspace_Proc :: #type proc(host: rawptr) -> string
// Returns the active editor file's absolute path, or "" when nothing is open.
// The host owns the string.
Active_Path_Proc :: #type proc(host: rawptr) -> string
// Returns the current text of the buffer at `path` (in-memory when the file is
// open, else read from disk). The host owns the result; the caller frees it.
Read_Proc :: #type proc(host: rawptr, path: string) -> string
// Writes `text` to `path` on disk without opening a tab, creating parent dirs.
Write_Proc :: #type proc(host: rawptr, path: string, text: string)
// Recomputes the tree's git-status colouring; called after a plugin mutates the
// working tree (stage, commit, discard, ...).
Refresh_Git_Proc :: #type proc(host: rawptr)

// One row of a plugin dropdown: a labelled entry that runs `command`, or a
// divider when `separator` is set.
Menu_Entry :: struct {
    label:     string,
    command:   string,
    separator: bool,
}
// Adds a top-bar dropdown button labelled `label` whose rows are `entries`.
Menu_Proc :: #type proc(host: rawptr, label: string, entries: []Menu_Entry)
// Opens a single-line text prompt titled `label`; the entered text comes back
// through manager_dialog_text.
Prompt_Proc :: #type proc(host: rawptr, label: string)
// Opens a fuzzy picker over `items`; the chosen item comes back through
// manager_dialog_text.
Pick_Proc :: #type proc(host: rawptr, label: string, items: []string)
// Opens a yes/no confirmation showing `message`; a confirm comes back through
// manager_dialog_confirm.
Confirm_Proc :: #type proc(host: rawptr, message: string)

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
    workspace_proc:   Workspace_Proc,
    active_path_proc: Active_Path_Proc,
    read_proc:        Read_Proc,
    write_proc:       Write_Proc,
    refresh_git_proc: Refresh_Git_Proc,
    menu_proc:        Menu_Proc,
    prompt_proc:      Prompt_Proc,
    pick_proc:        Pick_Proc,
    confirm_proc:     Confirm_Proc,
    // The Lua callback awaiting a dialog result (prompt/pick/confirm), or NOREF.
    // Only one dialog is open at a time, so a single slot suffices.
    dialog_ref:   int,
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
    workspace_proc: Workspace_Proc,
    active_path_proc: Active_Path_Proc,
    read_proc: Read_Proc,
    write_proc: Write_Proc,
    refresh_git_proc: Refresh_Git_Proc,
    menu_proc: Menu_Proc,
    prompt_proc: Prompt_Proc,
    pick_proc: Pick_Proc,
    confirm_proc: Confirm_Proc,
) {
    m.host = host
    m.print_proc = print_proc
    m.keybind_proc = keybind_proc
    m.doc_proc = doc_proc
    m.exec_proc = exec_proc
    m.button_proc = button_proc
    m.workspace_proc = workspace_proc
    m.active_path_proc = active_path_proc
    m.read_proc = read_proc
    m.write_proc = write_proc
    m.refresh_git_proc = refresh_git_proc
    m.menu_proc = menu_proc
    m.prompt_proc = prompt_proc
    m.pick_proc = pick_proc
    m.confirm_proc = confirm_proc
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
    m.dialog_ref = NOREF
    m.command_refs = make(map[string]int)
    install_api(m)
}

manager_destroy :: proc(m: ^Manager) {
    context.allocator = m.allocator
    if m.key_ref != NOREF {
        lua.L_unref(m.state, lua.REGISTRYINDEX, c.int(m.key_ref))
        m.key_ref = NOREF
    }
    if m.dialog_ref != NOREF {
        lua.L_unref(m.state, lua.REGISTRYINDEX, c.int(m.dialog_ref))
        m.dialog_ref = NOREF
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

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_workspace, 1)
    lua.setfield(L, -2, "workspace")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_active_path, 1)
    lua.setfield(L, -2, "active_path")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_read, 1)
    lua.setfield(L, -2, "read")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_write, 1)
    lua.setfield(L, -2, "write")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_refresh_git, 1)
    lua.setfield(L, -2, "refresh_git")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_menu, 1)
    lua.setfield(L, -2, "menu")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_prompt, 1)
    lua.setfield(L, -2, "prompt")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_pick, 1)
    lua.setfield(L, -2, "pick")

    lua.pushlightuserdata(L, rawptr(m))
    lua.pushcclosure(L, api_confirm, 1)
    lua.setfield(L, -2, "confirm")

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

// thor.workspace(): the absolute path of the workspace directory.
@(private)
api_workspace :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.workspace_proc == nil {
        lua.pushstring(L, "")
        return 1
    }
    context.allocator = m.allocator
    dir := m.workspace_proc(m.host)
    lua.pushstring(L, strings.clone_to_cstring(dir, context.temp_allocator))
    return 1
}

// thor.active_path(): the absolute path of the file in the active tab, or nil
// when no file is open.
@(private)
api_active_path :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.active_path_proc == nil {
        lua.pushnil(L)
        return 1
    }
    context.allocator = m.allocator
    path := m.active_path_proc(m.host)
    if path == "" {
        lua.pushnil(L)
        return 1
    }
    lua.pushstring(L, strings.clone_to_cstring(path, context.temp_allocator))
    return 1
}

// thor.read(path): the current text of the buffer at `path`, taking the open
// buffer's contents when it is open and falling back to disk otherwise.
@(private)
api_read :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.read_proc == nil || lua.type(L, 1) != .STRING {
        lua.pushstring(L, "")
        return 1
    }
    context.allocator = m.allocator
    out := m.read_proc(m.host, string(lua.tostring(L, 1)))
    lua.pushstring(L, strings.clone_to_cstring(out, context.temp_allocator))
    delete(out) // host-owned result, freed after copying into Lua
    return 1
}

// thor.write(path, text): writes `text` to `path` on disk without opening a tab.
@(private)
api_write :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.write_proc == nil || lua.type(L, 1) != .STRING || lua.type(L, 2) != .STRING {
        return 0
    }
    context.allocator = m.allocator
    m.write_proc(m.host, string(lua.tostring(L, 1)), string(lua.tostring(L, 2)))
    return 0
}

// thor.refresh_git(): recomputes the file tree's git-status colouring.
@(private)
api_refresh_git :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.refresh_git_proc == nil {
        return 0
    }
    context.allocator = m.allocator
    m.refresh_git_proc(m.host)
    return 0
}

// thor.menu(label, entries): adds a top-bar dropdown button. `entries` is an
// array of tables, each { label = "...", command = "..." } or { separator = true }.
@(private)
api_menu :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.menu_proc == nil || lua.type(L, 1) != .STRING || !lua.istable(L, 2) {
        return 0
    }
    context.allocator = m.allocator

    entries := make([dynamic]Menu_Entry, context.temp_allocator)
    n := lua.L_len(L, 2)
    for i in 1 ..= n {
        lua.rawgeti(L, 2, i)
        ti := lua.gettop(L)
        if lua.istable(L, ti) {
            entry: Menu_Entry
            lua.getfield(L, ti, "separator")
            entry.separator = bool(lua.toboolean(L, -1))
            lua.pop(L, 1)
            lua.getfield(L, ti, "label")
            if lua.type(L, -1) == .STRING {
                entry.label = strings.clone(string(lua.tostring(L, -1)), context.temp_allocator)
            }
            lua.pop(L, 1)
            lua.getfield(L, ti, "command")
            if lua.type(L, -1) == .STRING {
                entry.command = strings.clone(string(lua.tostring(L, -1)), context.temp_allocator)
            }
            lua.pop(L, 1)
            append(&entries, entry)
        }
        lua.pop(L, 1)
    }

    m.menu_proc(m.host, string(lua.tostring(L, 1)), entries[:])
    return 0
}

// Replaces any pending dialog callback with the function at stack index `idx`.
@(private)
set_dialog_ref :: proc "c" (m: ^Manager, L: ^lua.State, idx: c.int) {
    if m.dialog_ref != NOREF {
        lua.L_unref(L, lua.REGISTRYINDEX, c.int(m.dialog_ref))
    }
    lua.pushvalue(L, idx)
    m.dialog_ref = int(lua.L_ref(L, lua.REGISTRYINDEX))
}

// thor.prompt(label, fn): opens a single-line prompt; fn(text) runs on submit.
@(private)
api_prompt :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.prompt_proc == nil || lua.type(L, 1) != .STRING || !lua.isfunction(L, 2) {
        return 0
    }
    context.allocator = m.allocator
    set_dialog_ref(m, L, 2)
    m.prompt_proc(m.host, string(lua.tostring(L, 1)))
    return 0
}

// thor.pick(label, items, fn): opens a fuzzy picker over `items` (an array of
// strings); fn(choice) runs on selection.
@(private)
api_pick :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.pick_proc == nil || lua.type(L, 1) != .STRING || !lua.istable(L, 2) || !lua.isfunction(L, 3) {
        return 0
    }
    context.allocator = m.allocator
    set_dialog_ref(m, L, 3)

    items := make([dynamic]string, context.temp_allocator)
    n := lua.L_len(L, 2)
    for i in 1 ..= n {
        lua.rawgeti(L, 2, i)
        if lua.type(L, -1) == .STRING {
            append(&items, strings.clone(string(lua.tostring(L, -1)), context.temp_allocator))
        }
        lua.pop(L, 1)
    }

    m.pick_proc(m.host, string(lua.tostring(L, 1)), items[:])
    return 0
}

// thor.confirm(message, fn): opens a yes/no confirmation; fn() runs on confirm.
@(private)
api_confirm :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m := cast(^Manager) lua.touserdata(L, upvalueindex(1))
    if m == nil || m.confirm_proc == nil || lua.type(L, 1) != .STRING || !lua.isfunction(L, 2) {
        return 0
    }
    context.allocator = m.allocator
    set_dialog_ref(m, L, 2)
    m.confirm_proc(m.host, string(lua.tostring(L, 1)))
    return 0
}

// Invokes the pending dialog callback with `text` (prompt/pick result), then
// releases it. No-op when nothing is waiting.
manager_dialog_text :: proc(m: ^Manager, text: string) {
    if m.dialog_ref == NOREF {
        return
    }
    L := m.state
    ref := m.dialog_ref
    m.dialog_ref = NOREF
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ref))
    if lua.isfunction(L, -1) {
        lua.pushstring(L, strings.clone_to_cstring(text, context.temp_allocator))
        if lua.pcall(L, 1, 0, 0) != 0 {
            log.warnf("plugin dialog callback failed: %s", lua.tostring(L, -1))
            lua.pop(L, 1)
        }
    } else {
        lua.pop(L, 1)
    }
    lua.L_unref(L, lua.REGISTRYINDEX, c.int(ref))
}

// Invokes the pending confirm callback (no argument), then releases it.
manager_dialog_confirm :: proc(m: ^Manager) {
    if m.dialog_ref == NOREF {
        return
    }
    L := m.state
    ref := m.dialog_ref
    m.dialog_ref = NOREF
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ref))
    if lua.isfunction(L, -1) {
        if lua.pcall(L, 0, 0, 0) != 0 {
            log.warnf("plugin confirm callback failed: %s", lua.tostring(L, -1))
            lua.pop(L, 1)
        }
    } else {
        lua.pop(L, 1)
    }
    lua.L_unref(L, lua.REGISTRYINDEX, c.int(ref))
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
