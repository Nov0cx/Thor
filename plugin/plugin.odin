// Plugin host: owns the Lua VM, the tree-sitter engine, and the language
// registry plugins fill at load time. A language is backed by a tree-sitter
// grammar or a pure-Lua lexer. Highlighting resolves to color roles.
//
// Each plugin runs sandboxed (see sandbox.odin): its own `_ENV`, a trimmed
// standard library, and a `thor` table holding only what its plugin.json grants.
package plugin

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import lua "vendor:lua/5.4"

import "../input"
import "../syntax"
import ts "../vendor/odin-tree-sitter"

// Lua's LUA_NOREF; marks a callback slot with no Lua function.
NOREF :: -2

// Color roles exposed to plugins as `thor.theme.<role>`.
@(private)
ROLES := []string {
    "background", "foreground", "keywords", "functions", "strings", "operators",
    "comments", "numbers", "parameters", "attributes", "variables", "tags", "links",
    "warning", "conflict", "submodule", "accent_secondary", "info", "danger", "success",
    "muted", "accent", "error",
}

// A registered language; `grammar` is empty when `lexer` names a Lua lexer.
Language :: struct {
    name:       string,
    extensions: [dynamic]string,
    grammar:    string,
    colors:     map[string]string, // capture name (or its head) -> color role
    lexer:      Callback,          // pure-Lua lexer, or an unset ref
    // The lexer reads each line on its own, so it can be given the visible lines
    // instead of the whole buffer. False for one that carries state across a
    // line — a block comment, a fence, a multi-line string.
    line_based: bool,
}

// Host services a plugin can call back into, as plain function pointers so the
// package stays free of any dependency on the app.
Print_Proc :: #type proc(host: rawptr, text: string)
Keybind_Proc :: #type proc(host: rawptr, action: string) -> (chord: string, ok: bool)
// Renders `text` into a document tab at `path`; `focus` reveals and focuses it.
Doc_Proc :: #type proc(host: rawptr, path: string, text: string, focus: bool)
// Runs `command` in the workspace and returns its owned stdout+stderr; the host
// owns the result and the caller frees it after copying into Lua. The host must
// stop the command after `timeout`, which holds the frame no longer than the
// budget hook would.
Exec_Proc :: #type proc(host: rawptr, command: string, timeout: time.Duration) -> string
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

// Everything the app hands the manager. Grouped so adding a service does not
// re-shuffle a positional argument list.
Host :: struct {
    data:        rawptr,
    print:       Print_Proc,
    keybind:     Keybind_Proc,
    doc:         Doc_Proc,
    exec:        Exec_Proc,
    button:      Button_Proc,
    workspace:   Workspace_Proc,
    active_path: Active_Path_Proc,
    read:        Read_Proc,
    write:       Write_Proc,
    refresh_git: Refresh_Git_Proc,
    menu:        Menu_Proc,
    prompt:      Prompt_Proc,
    pick:        Pick_Proc,
    confirm:     Confirm_Proc,
    // Dockable panels a plugin builds (see view.odin).
    panel:        Panel_Proc,
    panel_render: Panel_Render_Proc,
    panel_show:   Panel_Show_Proc,
    panel_close:  Panel_Close_Proc,
    // Immediate-mode drawing inside a canvas node.
    draw_rect:    Draw_Rect_Proc,
    draw_text:    Draw_Text_Proc,
    draw_line:    Draw_Line_Proc,
    measure_text: Measure_Text_Proc,
}

// The single Lua state shared by all plugins. Not reentrant: one thread only.
Manager :: struct {
    state:       ^lua.State, // owned
    highlighter: syntax.Highlighter, // owned
    languages:   [dynamic]Language, // owned
    by_ext:      map[string]int, // ".odin" -> index into languages; keys borrowed from languages
    // Used for every alloc and free, since Lua C callbacks run under a default context.
    allocator:   runtime.Allocator,
    plugins:     [dynamic]Plugin, // owned
    // Host services; `host` is the app pointer every proc takes.
    host:             rawptr, // borrowed
    print_proc:       Print_Proc,
    keybind_proc:     Keybind_Proc,
    doc_proc:         Doc_Proc,
    exec_proc:        Exec_Proc,
    button_proc:      Button_Proc,
    workspace_proc:   Workspace_Proc,
    active_path_proc: Active_Path_Proc,
    read_proc:        Read_Proc,
    write_proc:       Write_Proc,
    refresh_git_proc: Refresh_Git_Proc,
    menu_proc:        Menu_Proc,
    prompt_proc:      Prompt_Proc,
    pick_proc:        Pick_Proc,
    confirm_proc:     Confirm_Proc,
    panel_proc:        Panel_Proc,
    panel_render_proc: Panel_Render_Proc,
    panel_show_proc:   Panel_Show_Proc,
    panel_close_proc:  Panel_Close_Proc,
    draw_rect_proc:    Draw_Rect_Proc,
    draw_text_proc:    Draw_Text_Proc,
    draw_line_proc:    Draw_Line_Proc,
    measure_text_proc: Measure_Text_Proc,
    // The on_key handler; only one plugin holds it, the last with `keys` to ask.
    key:          Callback,
    // The on_key_up handler, registered apart from `key` so a plugin that wants
    // presses only never sees a release.
    key_up:       Callback,
    // When the on_tick handlers last ran (see manager_dispatch_tick).
    tick_at:      time.Tick,
    // Start of the call running in this state (see call_guarded); one manager,
    // one Lua state, so this lives on the manager rather than as a package global.
    active_start: time.Tick,
    // Plugin the next tick pass starts at, so a pass cut short by TICK_BUDGET
    // resumes where it stopped.
    tick_next:    int,
    // The Lua callback awaiting a dialog result (prompt/pick/confirm). Only one
    // dialog is open at a time, so a single slot suffices.
    dialog:       Callback,
    // Named commands registered via thor.on_command; keys are owned.
    commands:     map[string]Callback, // owned, with the registry ref of every callback
    // Callbacks a rendered panel holds, so a re-render releases the old ones.
    panel_refs:   map[string][dynamic]Callback, // owned, keys and refs both
    // Bounds of the canvas being drawn, so a plugin draws in canvas coordinates.
    canvas:       Canvas_Rect,
    // Tree-sitter state backing thor.ts (see api_ts.odin).
    ts_state:     Ts_State,
    // `.scm` files read on behalf of a plugin query, keyed by resolved path so
    // a `tree:query()` from a draw callback re-reads the file at most once
    // per manager lifetime rather than every visible frame. The failure case
    // is cached too (found = false), so a bad name is neither re-read nor
    // re-logged. Keys and sources owned; dies with the manager, so editing a
    // plugin's .scm while Thor runs takes effect on the next reload.
    query_files:  map[string]Query_File,
}

@(private)
Query_File :: struct {
    source: string, // owned; empty when found == false
    found:  bool,
}

// Wires the host services a plugin can call. Call once after manager_init.
manager_set_host :: proc(m: ^Manager, host: Host) {
    m.host = host.data
    m.print_proc = host.print
    m.keybind_proc = host.keybind
    m.doc_proc = host.doc
    m.exec_proc = host.exec
    m.button_proc = host.button
    m.workspace_proc = host.workspace
    m.active_path_proc = host.active_path
    m.read_proc = host.read
    m.write_proc = host.write
    m.refresh_git_proc = host.refresh_git
    m.menu_proc = host.menu
    m.prompt_proc = host.prompt
    m.pick_proc = host.pick
    m.confirm_proc = host.confirm
    m.panel_proc = host.panel
    m.panel_render_proc = host.panel_render
    m.panel_show_proc = host.panel_show
    m.panel_close_proc = host.panel_close
    m.draw_rect_proc = host.draw_rect
    m.draw_text_proc = host.draw_text
    m.draw_line_proc = host.draw_line
    m.measure_text_proc = host.measure_text
}

// Initializes a manager in place. The caller must own it: the API closures
// capture its address as a Lua upvalue.
manager_init :: proc(m: ^Manager) {
    m.allocator = context.allocator
    m.state = lua.L_newstate()
    (^rawptr)(lua.getextraspace(m.state))^ = m
    open_safe_libs(m.state)
    m.highlighter = syntax.highlighter_create()
    m.languages = make([dynamic]Language)
    m.by_ext = make(map[string]int)
    m.plugins = make([dynamic]Plugin)
    m.key = Callback {-1, NOREF}
    m.key_up = Callback {-1, NOREF}
    m.dialog = Callback {-1, NOREF}
    m.tick_at = time.tick_now()
    m.commands = make(map[string]Callback)
    m.panel_refs = make(map[string][dynamic]Callback)
    m.query_files = make(map[string]Query_File)
    ts_init(m)
}

manager_destroy :: proc(m: ^Manager) {
    context.allocator = m.allocator
    release(m, &m.key)
    release(m, &m.key_up)
    release(m, &m.dialog)
    for name, cb in m.commands {
        unref(m, cb.ref)
        delete(name)
    }
    delete(m.commands)
    for id, refs in m.panel_refs {
        for cb in refs {
            unref(m, cb.ref)
        }
        delete(refs)
        delete(id)
    }
    delete(m.panel_refs)
    for &lang in m.languages {
        release(m, &lang.lexer)
        free_language(&lang)
    }
    delete(m.languages)
    delete(m.by_ext)
    for &p in m.plugins {
        unref(m, p.tick_ref)
        if p.env_ref != NOREF {
            lua.L_unref(m.state, lua.REGISTRYINDEX, c.int(p.env_ref))
        }
        if p.module_ref != NOREF {
            lua.L_unref(m.state, lua.REGISTRYINDEX, c.int(p.module_ref))
        }
        delete(p.id)
        delete(p.dir)
    }
    delete(m.plugins)
    for path, qf in m.query_files {
        delete(path)
        delete(qf.source)
    }
    delete(m.query_files)
    ts_destroy(m)
    syntax.highlighter_destroy(&m.highlighter)
    if m.state != nil {
        lua.close(m.state)
        m.state = nil
    }
}

// Releases a registry ref. NOREF is a no-op.
@(private)
unref :: proc(m: ^Manager, ref: int) {
    if ref != NOREF {
        lua.L_unref(m.state, lua.REGISTRYINDEX, c.int(ref))
    }
}

// Releases a callback's registry ref and clears the slot.
@(private)
release :: proc(m: ^Manager, cb: ^Callback) {
    unref(m, cb.ref)
    cb.ref = NOREF
}

// A plugin found on disk and not yet run, with what its manifest asks for. The
// strings use the allocator manager_scan was given.
Pending_Plugin :: struct {
    id:    string,
    dir:   string,
    perms: Permissions,
}

// Finds the plugins matching `pattern` (a folder per plugin, each a plugin.lua)
// without running any of them, so the host can settle their permissions first.
manager_scan :: proc(m: ^Manager, pattern := "plugins/*/plugin.lua", allocator := context.temp_allocator) -> []Pending_Plugin {
    matches, err := filepath.glob(pattern, context.temp_allocator)
    if err != nil {
        return nil
    }
    out := make([dynamic]Pending_Plugin, 0, len(matches), allocator)
    for path in matches {
        dir := filepath.dir(path) // borrowed substring of path
        append(&out, Pending_Plugin {
            id    = strings.clone(filepath.base(dir), allocator),
            dir   = strings.clone(dir, allocator),
            perms = manifest_permissions(dir),
        })
    }
    return out[:]
}

// Finds the plugins directly under `root` (a folder per plugin, each holding a
// plugin.lua), like manager_scan but without running any of them. Reads the
// directory instead of globbing it: `root` may be a folder the user picked, and
// a `*` or `[` in its name would read as pattern syntax.
manager_scan_dir :: proc(m: ^Manager, root: string, allocator := context.temp_allocator) -> []Pending_Plugin {
    handle, open_err := os.open(root)
    if open_err != nil {
        return nil
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return nil
    }

    out := make([dynamic]Pending_Plugin, 0, len(infos), allocator)
    for info in infos {
        if info.type != .Directory {
            continue
        }
        script, jerr := filepath.join({info.fullpath, "plugin.lua"}, context.temp_allocator)
        if jerr != nil || !os.is_file(script) {
            continue
        }
        append(&out, Pending_Plugin {
            id    = strings.clone(info.name, allocator),
            dir   = strings.clone(info.fullpath, allocator),
            perms = manifest_permissions(info.fullpath),
        })
    }
    return out[:]
}

// Loads one scanned plugin with exactly the permissions the host granted, which
// may be fewer than its manifest asked for.
manager_load_plugin :: proc(m: ^Manager, id, dir: string, perms: Permissions) -> bool {
    path, jerr := filepath.join({dir, "plugin.lua"}, context.temp_allocator)
    if jerr != nil {
        return false
    }
    index := new_plugin(m, id, dir, perms)
    return load_chunk(m, index, path, nil)
}

// Loads every plugin matching `pattern` with the permissions its plugin.json
// asks for. For a host that grants without asking, and for tests.
manager_load :: proc(m: ^Manager, pattern := "plugins/*/plugin.lua") {
    for p in manager_scan(m, pattern) {
        manager_load_plugin(m, p.id, p.dir, p.perms)
    }
}

// The permissions a loaded plugin runs with. `ok` is false when it never loaded,
// which is how the host tells "denied" from "granted nothing".
manager_permissions :: proc(m: ^Manager, id: string) -> (perms: Permissions, ok: bool) {
    for p in m.plugins {
        if p.id == id {
            return p.perms, true
        }
    }
    return {}, false
}

// Loads `source` as a plugin named `id` rooted at `dir`, granting `perms`
// outright. For plugins that do not come from the plugins folder, and for tests.
manager_load_source :: proc(m: ^Manager, id, dir, source: string, perms: Permissions) -> bool {
    index := new_plugin(m, id, dir, perms)
    return load_chunk(m, index, "", transmute([]byte) source)
}

// Registers a plugin record and builds its sandbox environment.
@(private)
new_plugin :: proc(m: ^Manager, id, dir: string, perms: Permissions) -> int {
    granted := perms

    abs_dir := dir
    if resolved, err := filepath.abs(dir, context.temp_allocator); err == nil {
        abs_dir = resolved
    }

    index := len(m.plugins)
    append(&m.plugins, Plugin {
        id      = strings.clone(id),
        dir     = strings.clone(abs_dir),
        perms   = granted,
        env_ref = NOREF,
        module_ref = NOREF,
        tick_ref = NOREF,
    })

    L := m.state
    lua.createtable(L, 0, 4)
    m.plugins[index].module_ref = int(lua.L_ref(L, lua.REGISTRYINDEX))
    push_sandbox_env(m, index)
    m.plugins[index].env_ref = int(lua.L_ref(L, lua.REGISTRYINDEX))
    return index
}

// Chunk mode: text only. Lua 5.4 does not verify bytecode, so a precompiled
// chunk would run past `_ENV` and every sandbox limit — the same reason the
// sandbox drops `load` and `loadfile`.
@(private)
CHUNK_MODE :: cstring("t")

// Loads a plugin chunk from `path` (or from `source` when given), points its
// `_ENV` at the plugin's sandbox, and runs it under the time budget.
@(private)
load_chunk :: proc(m: ^Manager, index: int, path: string, source: []byte) -> bool {
    L := m.state
    status: lua.Status
    if source != nil {
        name := strings.concatenate({"@", m.plugins[index].id}, context.temp_allocator)
        status = lua.L_loadbuffer(L, raw_data(source), len(source), strings.clone_to_cstring(name, context.temp_allocator), CHUNK_MODE)
    } else {
        status = lua.L_loadfile(L, strings.clone_to_cstring(path, context.temp_allocator), CHUNK_MODE)
    }
    if status != .OK {
        log.warnf("plugin %s failed to load: %s", m.plugins[index].id, lua.tostring(L, -1))
        lua.pop(L, 1)
        return false
    }

    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(m.plugins[index].env_ref))
    lua.setupvalue(L, -2, 1) // a main chunk's first upvalue is _ENV
    return call_guarded(m, index, 0, 0, "load")
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

// Builds a plugin's `thor` table: the `theme` role handles, the always-granted
// entry points, and one entry per permission it holds. A denied service is
// simply absent, so calling it is a plain Lua "attempt to call a nil value"
// naming the function the plugin was not given.
@(private)
push_api_table :: proc(m: ^Manager, index: int) {
    L := m.state
    perms := m.plugins[index].perms
    lua.createtable(L, 0, 24)
    api := lua.gettop(L)

    lua.createtable(L, 0, c.int(len(ROLES)))
    for role in ROLES {
        cs := strings.clone_to_cstring(role, context.temp_allocator)
        lua.pushstring(L, cs)
        lua.setfield(L, -2, cs)
    }
    lua.setfield(L, api, "theme")

    bind :: proc(L: ^lua.State, m: ^Manager, index: int, api: c.int, name: cstring, fn: lua.CFunction) {
        push_closure(L, m, index, fn)
        lua.setfield(L, api, name)
    }

    bind(L, m, index, api, "register_language", api_register_language)
    bind(L, m, index, api, "print", api_print)
    bind(L, m, index, api, "keybind", api_keybind)
    bind(L, m, index, api, "on_command", api_on_command)
    bind(L, m, index, api, "workspace", api_workspace)
    bind(L, m, index, api, "active_path", api_active_path)
    bind(L, m, index, api, "refresh_git", api_refresh_git)
    bind(L, m, index, api, "permissions", api_permissions)

    if .Exec in perms {
        bind(L, m, index, api, "exec", api_exec)
    }
    if .Read in perms {
        bind(L, m, index, api, "read", api_read)
    }
    if .Write in perms {
        bind(L, m, index, api, "write", api_write)
        bind(L, m, index, api, "doc", api_doc)
    }
    if .Keys in perms {
        bind(L, m, index, api, "on_key", api_on_key)
        bind(L, m, index, api, "on_key_up", api_on_key_up)
    }
    if .Tick in perms {
        bind(L, m, index, api, "on_tick", api_on_tick)
    }
    if .Ui in perms {
        bind(L, m, index, api, "button", api_button)
        bind(L, m, index, api, "menu", api_menu)
        bind(L, m, index, api, "prompt", api_prompt)
        bind(L, m, index, api, "pick", api_pick)
        bind(L, m, index, api, "confirm", api_confirm)
        bind(L, m, index, api, "panel", api_panel)
    }

    push_ts_table(m, index, perms)
    lua.setfield(L, api, "ts")
}

// thor.permissions(): the permission names this plugin was granted, so it can
// degrade gracefully instead of erroring on a missing entry point.
@(private)
api_permissions :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    p := caller_plugin(m, index)
    if p == nil {
        lua.createtable(L, 0, 0)
        return 1
    }
    lua.createtable(L, 0, 5)
    for perm in Permission {
        if perm not_in p.perms {
            continue
        }
        lua.pushboolean(L, true)
        lua.setfield(L, -2, strings.clone_to_cstring(permission_name(perm), context.temp_allocator))
    }
    return 1
}

// How often on_tick handlers run: often enough for a document that follows what
// the user types, rarely enough that a slow plugin cannot cost the frame rate.
TICK_INTERVAL :: 100 * time.Millisecond

// thor.on_tick(fn): handler run every TICK_INTERVAL, for a plugin that must
// follow what the editor is doing rather than wait to be called. One per plugin.
// Needs the `tick` permission, so a plugin the user was never asked about only
// runs when the user starts it.
@(private)
api_on_tick :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || index < 0 || !lua.isfunction(L, 1) {
        return 0
    }
    context.allocator = m.allocator
    unref(m, m.plugins[index].tick_ref)
    lua.pushvalue(L, 1) // ref pops the top, so copy the argument up
    m.plugins[index].tick_ref = int(lua.L_ref(L, lua.REGISTRYINDEX))
    return 0
}

// Wall clock one tick pass may spend on all handlers together. The sandbox caps
// a single call, but several slow plugins add up, so a pass that runs over stops
// and the next one continues at the plugin it stopped on.
TICK_BUDGET :: 8 * time.Millisecond

// Runs every registered on_tick handler, at most once per TICK_INTERVAL and for
// at most TICK_BUDGET. Called from the app's frame loop.
manager_dispatch_tick :: proc(m: ^Manager) {
    now := time.tick_now()
    if len(m.plugins) == 0 || time.tick_diff(m.tick_at, now) < TICK_INTERVAL {
        return
    }
    m.tick_at = now
    start := m.tick_next % len(m.plugins)
    for offset in 0 ..< len(m.plugins) {
        index := (start + offset) % len(m.plugins)
        ref := m.plugins[index].tick_ref
        if ref == NOREF {
            continue
        }
        call_callback(m, Callback {index, ref}, 0, 0, "on_tick")
        if time.tick_since(now) >= TICK_BUDGET {
            m.tick_next = (index + 1) % len(m.plugins)
            return
        }
    }
    m.tick_next = start
}

// thor.on_key(fn): handler run for every key press, given {chord, ctrl, shift,
// alt}; returning true consumes the key. Needs the `keys` permission.
@(private)
api_on_key :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || !lua.isfunction(L, 1) {
        return 0
    }
    context.allocator = m.allocator
    release(m, &m.key)
    lua.pushvalue(L, 1) // ref pops the top, so copy the argument up
    m.key = Callback {index, int(lua.L_ref(L, lua.REGISTRYINDEX))}
    return 0
}

// thor.on_key_up(fn): handler run for every key release, given the table
// on_key gets. Needs the `keys` permission.
@(private)
api_on_key_up :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || !lua.isfunction(L, 1) {
        return 0
    }
    context.allocator = m.allocator
    release(m, &m.key_up)
    lua.pushvalue(L, 1) // ref pops the top, so copy the argument up
    m.key_up = Callback {index, int(lua.L_ref(L, lua.REGISTRYINDEX))}
    return 0
}

// thor.doc(path, text[, focus]): renders `text` into a document tab at `path`,
// updating the open buffer in place. A truthy `focus` reveals and focuses it.
@(private)
api_doc :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || m.doc_proc == nil || lua.type(L, 1) != .STRING || lua.type(L, 2) != .STRING {
        return 0
    }
    // Host edits app-owned buffers, so run under the app's allocator rather than
    // the C callback's default context, or the main loop later bad-frees them.
    context.allocator = m.allocator
    path, ok := resolve_path(m, index, string(lua.tostring(L, 1)))
    if !ok {
        return 0
    }
    m.doc_proc(m.host, path, string(lua.tostring(L, 2)), bool(lua.toboolean(L, 3)))
    return 0
}

// thor.exec(command): runs `command` in the workspace, returning its combined
// stdout+stderr as a string. Blocks until it exits or the call budget runs out,
// whichever comes first. Needs the `exec` permission.
@(private)
api_exec :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, _ := caller(L)
    if m == nil || m.exec_proc == nil || lua.type(L, 1) != .STRING {
        lua.pushstring(L, "")
        return 1
    }
    context.allocator = m.allocator
    out := m.exec_proc(m.host, string(lua.tostring(L, 1)), budget_left(m))
    lua.pushstring(L, strings.clone_to_cstring(out, context.temp_allocator))
    delete(out) // host-owned result, freed after copying into Lua
    return 1
}

// thor.button(label, command): adds a top-bar button that runs the named
// command (registered via thor.on_command) when clicked.
@(private)
api_button :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, _ := caller(L)
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
    m, _ := caller(L)
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
    m, _ := caller(L)
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
// buffer's contents when it is open and falling back to disk. Confined to the
// workspace and the plugin's own folder. Needs the `read` permission.
@(private)
api_read :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || m.read_proc == nil || lua.type(L, 1) != .STRING {
        lua.pushstring(L, "")
        return 1
    }
    context.allocator = m.allocator
    path, ok := resolve_path(m, index, string(lua.tostring(L, 1)))
    if !ok {
        lua.pushstring(L, "")
        return 1
    }
    out := m.read_proc(m.host, path)
    lua.pushstring(L, strings.clone_to_cstring(out, context.temp_allocator))
    delete(out) // host-owned result, freed after copying into Lua
    return 1
}

// thor.write(path, text): writes `text` to `path` on disk without opening a tab.
// Confined like thor.read. Needs the `write` permission.
@(private)
api_write :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || m.write_proc == nil || lua.type(L, 1) != .STRING || lua.type(L, 2) != .STRING {
        return 0
    }
    context.allocator = m.allocator
    path, ok := resolve_path(m, index, string(lua.tostring(L, 1)))
    if !ok {
        return 0
    }
    m.write_proc(m.host, path, string(lua.tostring(L, 2)))
    return 0
}

// thor.refresh_git(): recomputes the file tree's git-status colouring.
@(private)
api_refresh_git :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, _ := caller(L)
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
    m, _ := caller(L)
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
set_dialog :: proc(m: ^Manager, L: ^lua.State, index: int, idx: c.int) {
    release(m, &m.dialog)
    lua.pushvalue(L, idx)
    m.dialog = Callback {index, int(lua.L_ref(L, lua.REGISTRYINDEX))}
}

// thor.prompt(label, fn): opens a single-line prompt; fn(text) runs on submit.
@(private)
api_prompt :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || m.prompt_proc == nil || lua.type(L, 1) != .STRING || !lua.isfunction(L, 2) {
        return 0
    }
    context.allocator = m.allocator
    set_dialog(m, L, index, 2)
    m.prompt_proc(m.host, string(lua.tostring(L, 1)))
    return 0
}

// thor.pick(label, items, fn): opens a fuzzy picker over `items` (an array of
// strings); fn(choice) runs on selection.
@(private)
api_pick :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || m.pick_proc == nil || lua.type(L, 1) != .STRING || !lua.istable(L, 2) || !lua.isfunction(L, 3) {
        return 0
    }
    context.allocator = m.allocator
    set_dialog(m, L, index, 3)

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
    m, index := caller(L)
    if m == nil || m.confirm_proc == nil || lua.type(L, 1) != .STRING || !lua.isfunction(L, 2) {
        return 0
    }
    context.allocator = m.allocator
    set_dialog(m, L, index, 2)
    m.confirm_proc(m.host, string(lua.tostring(L, 1)))
    return 0
}

// Invokes the pending dialog callback with `text` (prompt/pick result), then
// releases it. No-op when nothing is waiting.
manager_dialog_text :: proc(m: ^Manager, text: string) {
    cb := m.dialog
    m.dialog = Callback {-1, NOREF}
    if cb.ref == NOREF {
        return
    }
    L := m.state
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(cb.ref))
    if lua.isfunction(L, -1) {
        lua.pushstring(L, strings.clone_to_cstring(text, context.temp_allocator))
        call_guarded(m, cb.owner, 1, 0, "dialog callback")
    } else {
        lua.pop(L, 1)
    }
    lua.L_unref(L, lua.REGISTRYINDEX, c.int(cb.ref))
}

// Invokes the pending confirm callback (no argument), then releases it.
manager_dialog_confirm :: proc(m: ^Manager) {
    cb := m.dialog
    m.dialog = Callback {-1, NOREF}
    if cb.ref == NOREF {
        return
    }
    L := m.state
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(cb.ref))
    if lua.isfunction(L, -1) {
        call_guarded(m, cb.owner, 0, 0, "confirm callback")
    } else {
        lua.pop(L, 1)
    }
    lua.L_unref(L, lua.REGISTRYINDEX, c.int(cb.ref))
}

// thor.keybind(action): the chord bound to `action` (e.g. "Ctrl+S"), or nil.
@(private)
api_keybind :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, _ := caller(L)
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
    m, index := caller(L)
    if m == nil || lua.type(L, 1) != .STRING || !lua.isfunction(L, 2) {
        return 0
    }
    context.allocator = m.allocator
    name := string(lua.tostring(L, 1))
    lua.pushvalue(L, 2)
    cb := Callback {index, int(lua.L_ref(L, lua.REGISTRYINDEX))}
    // Reuse the existing owned key on replace; clone for a new one.
    if existing, ok := m.commands[name]; ok {
        old := existing
        release(m, &old)
        m.commands[name] = cb
        return 0
    }
    m.commands[strings.clone(name)] = cb
    return 0
}

// Runs the plugin command registered under `name`. Returns whether it existed
// and ran without error.
manager_run_command :: proc(m: ^Manager, name: string) -> bool {
    cb, ok := m.commands[name]
    if !ok {
        return false
    }
    return call_callback(m, cb, 0, 0, "command")
}

// Dispatches a key press to the on_key handler. `chord` is the display string
// (same format as thor.keybind). Returns whether the plugin consumed it.
manager_dispatch_key :: proc(m: ^Manager, chord: string, mods: input.Modifiers) -> (consumed: bool) {
    return dispatch_key(m, m.key, "on_key", chord, mods)
}

// Dispatches a key release to the on_key_up handler, which gets the table
// on_key gets.
manager_dispatch_key_up :: proc(m: ^Manager, chord: string, mods: input.Modifiers) -> (consumed: bool) {
    return dispatch_key(m, m.key_up, "on_key_up", chord, mods)
}

@(private = "file")
dispatch_key :: proc(m: ^Manager, cb: Callback, name: string, chord: string, mods: input.Modifiers) -> (consumed: bool) {
    if cb.ref == NOREF {
        return false
    }
    L := m.state

    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(cb.ref))
    if !lua.isfunction(L, -1) {
        lua.pop(L, 1)
        return false
    }

    lua.createtable(L, 0, 5)
    lua.pushstring(L, strings.clone_to_cstring(chord, context.temp_allocator))
    lua.setfield(L, -2, "chord")
    lua.pushboolean(L, b32(.Ctrl in mods))
    lua.setfield(L, -2, "ctrl")
    lua.pushboolean(L, b32(.Shift in mods))
    lua.setfield(L, -2, "shift")
    lua.pushboolean(L, b32(.Alt in mods))
    lua.setfield(L, -2, "alt")
    lua.pushboolean(L, b32(.Cmd in mods))
    lua.setfield(L, -2, "cmd")

    if !call_guarded(m, cb.owner, 1, 1, name) {
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

// thor.register_language{...}: binds extensions to a grammar or a Lua lexer,
// with a capture-name -> theme-role map. `highlights` names a .scm file in the
// plugin folder that replaces the compiled-in highlights query for the grammar.
@(private)
api_register_language :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || !lua.istable(L, 1) {
        return 0
    }
    context.allocator = m.allocator

    lang: Language
    lang.lexer = Callback {index, NOREF}
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
        lang.lexer.ref = int(lua.L_ref(L, lua.REGISTRYINDEX)) // pops the function
    } else {
        lua.pop(L, 1)
    }

    if lang.grammar == "" && lang.lexer.ref == NOREF {
        free_language(&lang)
        return 0
    }
    lang.line_based = field_bool(L, "line_based")

    if source, ok := field_string(L, "highlights"); ok && lang.grammar != "" {
        apply_highlights_override(m, index, lang.grammar, source)
    }

    idx := len(m.languages)
    append(&m.languages, lang)
    for ext in m.languages[idx].extensions {
        m.by_ext[ext] = idx
    }
    return 0
}

// Installs a plugin-supplied highlights query for `grammar`. `source` is either
// a query, or the name of a .scm file in the plugin folder. A query that fails
// to compile is reported with its offset and left unchanged, so an author sees
// why the file lost its colors instead of guessing.
@(private)
apply_highlights_override :: proc(m: ^Manager, index: int, grammar, source: string) {
    query, ok := query_source(m, index, source)
    if !ok {
        return
    }
    if offset, err := syntax.set_highlights(&m.highlighter, grammar, query); err != .None {
        report_query_error(m, index, source, offset, err)
    }
}

// Reports a failed query compile to the console and the log, naming the byte
// offset the grammar choked on.
@(private)
report_query_error :: proc(m: ^Manager, index: int, source: string, offset: u32, err: ts.Query_Error) {
    text := fmt.tprintf("\n[%s] query %s failed: %s at byte %d\n", plugin_id(m, index), source, query_error_text(err), offset)
    log.warn(text)
    if m.print_proc != nil {
        m.print_proc(m.host, text)
    }
}

@(private)
query_error_text :: proc(err: ts.Query_Error) -> string {
    switch err {
    case .None:      return "ok"
    case .Syntax:    return "syntax error"
    case .Node_Type: return "unknown node type for this grammar"
    case .Field:     return "unknown field name"
    case .Capture:   return "unknown capture"
    case .Structure: return "invalid pattern structure"
    case .Language:  return "invalid grammar"
    }
    return "unknown error"
}

// Resolves a query argument: a `.scm` name loads from the plugin folder,
// anything else is the query itself. A `.scm` file is read at most once per
// manager lifetime, through query_files (the failure case cached too), so a
// plugin querying from a canvas draw callback does not re-read its file every
// visible frame. Allocates explicitly with m.allocator rather than through
// context, since the load-time caller (apply_highlights_override) does not
// set context.allocator to it.
@(private)
query_source :: proc(m: ^Manager, index: int, source: string) -> (string, bool) {
    if !strings.has_suffix(source, ".scm") {
        return source, true
    }
    p := caller_plugin(m, index)
    if p == nil {
        return "", false
    }
    path, jerr := filepath.join({p.dir, source}, context.temp_allocator)
    if jerr != nil || !is_within(path, p.dir) {
        log.warnf("plugin %s: query %q is outside the plugin folder", p.id, source)
        return "", false
    }

    if qf, cached := m.query_files[path]; cached {
        return qf.source, qf.found
    }

    key := strings.clone(path, m.allocator)
    data, read_err := os.read_entire_file(path, m.allocator)
    if read_err != nil {
        log.warnf("plugin %s: cannot read query %q", p.id, source)
        m.query_files[key] = Query_File{found = false}
        return "", false
    }
    qf := Query_File{source = string(data), found = true}
    m.query_files[key] = qf
    return qf.source, true
}

// Reads a boolean field from the argument table at stack index 1. A missing
// field reads as false.
@(private)
field_bool :: proc "c" (L: ^lua.State, key: cstring) -> bool {
    lua.getfield(L, 1, key)
    defer lua.pop(L, 1)
    return bool(lua.toboolean(L, -1))
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
