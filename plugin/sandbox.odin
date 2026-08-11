// Per-plugin sandbox. Every plugin runs in its own `_ENV` table holding a
// curated standard library and a `thor` API trimmed to the permissions its
// plugin.json grants. The VM stays shared, so this contains buggy and rogue
// plugins — it is not a boundary against native code.
package plugin

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import lua "vendor:lua/5.4"

// A capability a plugin must list in plugin.json to reach the matching host
// service. What is not listed here is always granted: register_language, print,
// on_command, theme, workspace, active_path, keybind, refresh_git, permissions
// and the thor.ts bindings — every one of them waits to be called.
Permission :: enum {
    Exec,  // thor.exec
    Read,  // thor.read
    Write, // thor.write, thor.doc
    Ui,    // thor.button, menu, panel, prompt, pick, confirm
    Keys,  // thor.on_key
    Tick,  // thor.on_tick
}

Permissions :: distinct bit_set[Permission]

// Wall-clock time one call into a plugin may take. The editor draws on this
// thread, so a runaway loop would otherwise freeze the window.
CALL_BUDGET :: 2 * time.Second

// Instructions between budget checks.
@(private)
HOOK_STEP :: 10_000

// Least time a blocking host call gets, so a command that answers at once still
// can when the budget is already spent.
@(private)
MIN_NATIVE_BUDGET :: 100 * time.Millisecond

// Base library functions dropped from the shared globals: each one either runs
// code the sandbox never saw (load/dofile/loadfile) or reaches the collector.
@(private)
UNSAFE_BASE := []cstring {"load", "loadstring", "dofile", "loadfile", "collectgarbage"}

// The only `os` entries a plugin keeps. execute/remove/rename/exit/getenv and
// tmpname all reach past the sandbox.
@(private)
OS_KEPT := []cstring {"clock", "date", "difftime", "time"}

// A loaded plugin: the folder it came from, what it may do, and the environment
// its chunk runs in.
Plugin :: struct {
    id:         string, // owned; the folder name
    dir:        string, // owned; absolute plugin folder
    perms:      Permissions,
    env_ref:    int,    // registry ref of the _ENV table, or NOREF
    module_ref: int,    // registry ref of the require() cache, or NOREF
    tick_ref:   int,    // registry ref of the thor.on_tick handler, or NOREF
}

// A Lua callback plus the plugin that registered it, so a failure is reported
// against its author and runs under that plugin's budget.
Callback :: struct {
    owner: int, // index into Manager.plugins, or -1 for a hostless caller
    ref:   int, // registry ref, or NOREF
}

// Opens only the standard libraries a plugin may use, then trims what is left.
// io, package and debug are never loaded at all, so no path through the VM can
// reach them.
@(private)
open_safe_libs :: proc(L: ^lua.State) {
    lua.L_requiref(L, "_G", lua.open_base, 1)
    lua.pop(L, 1)
    lua.L_requiref(L, lua.TABLIBNAME, lua.open_table, 1)
    lua.pop(L, 1)
    lua.L_requiref(L, lua.STRLIBNAME, lua.open_string, 1)
    lua.pop(L, 1)
    lua.L_requiref(L, lua.MATHLIBNAME, lua.open_math, 1)
    lua.pop(L, 1)
    lua.L_requiref(L, lua.UTF8LIBNAME, lua.open_utf8, 1)
    lua.pop(L, 1)
    lua.L_requiref(L, lua.COLIBNAME, lua.open_coroutine, 1)
    lua.pop(L, 1)
    lua.L_requiref(L, lua.OSLIBNAME, lua.open_os, 1)
    lua.pop(L, 1)

    for name in UNSAFE_BASE {
        lua.pushnil(L)
        lua.setglobal(L, name)
    }
    trim_os(L)
    lock_string_metatable(L)
    guard_coroutines(L)
}

// Replaces the global `os` table with one holding only the clock entries.
@(private)
trim_os :: proc(L: ^lua.State) {
    lua.getglobal(L, "os")
    if !lua.istable(L, -1) {
        lua.pop(L, 1)
        return
    }
    source := lua.gettop(L)
    lua.createtable(L, 0, c.int(len(OS_KEPT)))
    kept := lua.gettop(L)
    for name in OS_KEPT {
        lua.getfield(L, source, name)
        lua.setfield(L, kept, name)
    }
    lua.setglobal(L, "os") // pops the trimmed table
    lua.pop(L, 1)          // the original
}

// Locks the metatable every string shares, so one plugin cannot redefine
// `("x"):gsub` under another plugin's feet.
@(private)
lock_string_metatable :: proc(L: ^lua.State) {
    lua.pushstring(L, "")
    if lua.getmetatable(L, -1) != 0 {
        lua.pushstring(L, "locked")
        lua.setfield(L, -2, "__metatable")
        lua.pop(L, 1)
    }
    lua.pop(L, 1)
}

// Shallow-clones the table at the top of the stack, replacing it there. Used
// so a plugin's copy of a stdlib table (`string`, `table`, `math`, …) is its
// own object — mutating it cannot reach another plugin or the host.
@(private)
clone_table_shallow :: proc(L: ^lua.State) {
    src := lua.gettop(L)
    lua.createtable(L, 0, 0)
    dst := lua.gettop(L)
    lua.pushnil(L)
    for lua.next(L, src) != 0 {
        lua.pushvalue(L, -2) // key
        lua.pushvalue(L, -2) // value
        lua.rawset(L, dst)
        lua.pop(L, 1)
    }
    lua.remove(L, src)
}

// Builds the plugin's `_ENV`: a copy of the trimmed globals, its own `thor`
// table, `print` routed to the console, and a folder-local `require`. Leaves
// the table on the stack.
@(private)
push_sandbox_env :: proc(m: ^Manager, index: int) {
    L := m.state
    lua.createtable(L, 0, 32)
    env := lua.gettop(L)

    // Copy the surviving globals. A table (`string`, `table`, `math`, `os`,
    // `coroutine`, `utf8`) is cloned one level deep, so a plugin mutating its own
    // copy — `string.format = ...` — cannot reach any other plugin or the host,
    // which would otherwise share that exact table object. Non-table values
    // (functions, numbers) stay shared: a function value cannot be mutated in
    // place, and each plugin already has its own binding for the name.
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.RIDX_GLOBALS)
    globals := lua.gettop(L)
    lua.pushnil(L)
    for lua.next(L, globals) != 0 {
        lua.pushvalue(L, -2) // key
        lua.pushvalue(L, -2) // value
        if lua.istable(L, -1) {
            clone_table_shallow(L)
        }
        lua.rawset(L, env)
        lua.pop(L, 1)
    }
    lua.pop(L, 1)

    // `_G` inside a plugin means its own environment, never the real globals.
    lua.pushvalue(L, env)
    lua.setfield(L, env, "_G")

    push_closure(L, m, index, api_print)
    lua.setfield(L, env, "print")
    push_closure(L, m, index, api_require)
    lua.setfield(L, env, "require")

    push_api_table(m, index)
    lua.setfield(L, env, "thor")
}

// Pushes a C closure carrying the manager and the calling plugin's index, the
// two upvalues every API function reads.
@(private)
push_closure :: proc(L: ^lua.State, m: ^Manager, index: int, fn: lua.CFunction) {
    lua.pushlightuserdata(L, rawptr(m))
    lua.pushinteger(L, lua.Integer(index))
    lua.pushcclosure(L, fn, 2)
}

// The manager and plugin index behind the running API call.
@(private)
caller :: proc "c" (L: ^lua.State) -> (m: ^Manager, index: int) {
    m = cast(^Manager) lua.touserdata(L, upvalueindex(1))
    index = int(lua.tointeger(L, upvalueindex(2)))
    return
}

// The plugin behind the running API call, or nil when the index is out of range.
@(private)
caller_plugin :: proc(m: ^Manager, index: int) -> ^Plugin {
    if m == nil || index < 0 || index >= len(m.plugins) {
        return nil
    }
    return &m.plugins[index]
}

// Name used in log lines for the plugin at `index`.
@(private)
plugin_id :: proc(m: ^Manager, index: int) -> string {
    if p := caller_plugin(m, index); p != nil {
        return p.id
    }
    return "<host>"
}

// Cuts a call short once it has held the frame for CALL_BUDGET. Only `L` comes
// through the Lua hook signature, so the manager is read back from the state's
// extraspace (set once in manager_init; a coroutine's state inherits it).
@(private)
budget_hook :: proc "c" (L: ^lua.State, _: ^lua.Debug) {
    context = runtime.default_context()
    m := (^Manager)((^rawptr)(lua.getextraspace(L))^)
    if time.tick_since(m.active_start) < CALL_BUDGET {
        return
    }
    lua.pushstring(L, "plugin exceeded its time budget")
    lua.error(L)
}

// What is left of the running call's budget. The hook counts instructions, so
// it cannot cut short a host call that blocks — such a call bounds itself with
// this instead.
@(private)
budget_left :: proc(m: ^Manager) -> time.Duration {
    return max(CALL_BUDGET - time.tick_since(m.active_start), MIN_NATIVE_BUDGET)
}

// Replaces coroutine.create and coroutine.wrap with versions that hook the
// thread they make. A Lua hook is per thread, so a stock coroutine runs with no
// budget and a loop inside it never ends.
@(private)
guard_coroutines :: proc(L: ^lua.State) {
    lua.getglobal(L, "coroutine")
    if !lua.istable(L, -1) {
        lua.pop(L, 1)
        return
    }
    lua.pushcfunction(L, co_create)
    lua.setfield(L, -2, "create")
    lua.pushcfunction(L, co_wrap)
    lua.setfield(L, -2, "wrap")
    lua.pop(L, 1)
}

// coroutine.create(f): the stock body, plus the budget hook on the new thread.
@(private)
co_create :: proc "c" (L: ^lua.State) -> c.int {
    lua.L_checktype(L, 1, c.int(lua.TFUNCTION))
    co := lua.newthread(L)
    lua.sethook(co, budget_hook, lua.MASKCOUNT, HOOK_STEP)
    lua.pushvalue(L, 1)
    lua.xmove(L, co, 1)
    return 1
}

// coroutine.wrap(f): a hooked thread behind a closure that resumes it.
@(private)
co_wrap :: proc "c" (L: ^lua.State) -> c.int {
    co_create(L)
    lua.pushcclosure(L, co_wrap_resume, 1)
    return 1
}

// The function coroutine.wrap returns: resumes the thread it carries and raises
// what the thread failed with, budget errors included.
@(private)
co_wrap_resume :: proc "c" (L: ^lua.State) -> c.int {
    co := lua.tothread(L, upvalueindex(1))
    if co == nil {
        return c.int(lua.L_error(L, "cannot resume dead coroutine"))
    }
    nargs := lua.gettop(L)
    if lua.checkstack(co, nargs) == 0 {
        return c.int(lua.L_error(L, "too many arguments to resume"))
    }
    lua.xmove(L, co, nargs)

    nres: c.int
    status := lua.resume(co, L, nargs, &nres)
    if status != .OK && status != .YIELD {
        lua.xmove(co, L, 1)
        return c.int(lua.error(L))
    }
    if lua.checkstack(L, nres + 1) == 0 {
        lua.settop(co, -nres - 1)
        return c.int(lua.L_error(L, "too many results to resume"))
    }
    lua.xmove(co, L, nres)
    return nres
}

// Calls the function sitting under `nargs` arguments on the stack, under the
// time budget. Logs a failure against the owning plugin and returns whether the
// call completed; on success `nres` results are left on the stack.
// A nested call keeps the outer call's start, so re-entry cannot extend the
// budget or clear the hook the outer call still needs.
@(private)
call_guarded :: proc(m: ^Manager, owner: int, nargs, nres: c.int, what: string) -> bool {
    nested := lua.gethook(m.state) != nil
    if !nested {
        m.active_start = time.tick_now()
        lua.sethook(m.state, budget_hook, lua.MASKCOUNT, HOOK_STEP)
    }
    status := lua.pcall(m.state, nargs, nres, 0)
    if !nested {
        lua.sethook(m.state, nil, lua.HookMask {}, 0)
    }
    if status != 0 {
        log.warnf("plugin %s: %s failed: %s", plugin_id(m, owner), what, lua.tostring(m.state, -1))
        lua.pop(m.state, 1)
        return false
    }
    return true
}

// Pushes the callback `cb` and calls it under its owner's budget. `push_args`
// runs with the function already on the stack. False when the ref is unset or
// the call failed.
@(private)
call_callback :: proc(m: ^Manager, cb: Callback, nargs, nres: c.int, what: string, push_args: proc(L: ^lua.State) = nil) -> bool {
    if cb.ref == NOREF {
        return false
    }
    L := m.state
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(cb.ref))
    if !lua.isfunction(L, -1) {
        lua.pop(L, 1)
        return false
    }
    if push_args != nil {
        push_args(L)
    }
    return call_guarded(m, cb.owner, nargs, nres, what)
}

// thor.print(text) and the sandbox's `print`: appends a line to the host's
// output. Accepts any value, like Lua's own print.
@(private)
api_print :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, _ := caller(L)
    if m == nil || m.print_proc == nil {
        return 0
    }
    context.allocator = m.allocator
    text := lua.tostring(L, 1)
    if text == nil {
        return 0
    }
    m.print_proc(m.host, string(text))
    return 0
}

// require("name"): loads `<plugin dir>/name.lua` into the same sandbox and
// caches its result, so a plugin can span several files. Only plain names
// resolve — no separators, no `..`, nothing outside the plugin's own folder.
@(private)
api_require :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    p := caller_plugin(m, index)
    if p == nil || lua.type(L, 1) != .STRING {
        return 0
    }
    context.allocator = m.allocator

    name := string(lua.tostring(L, 1))
    if !is_module_name(name) {
        lua.L_error(L, "require: %s is not a module of this plugin", lua.tostring(L, 1))
        return 0
    }

    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(p.module_ref))
    cache := lua.gettop(L)
    lua.getfield(L, cache, strings.clone_to_cstring(name, context.temp_allocator))
    if !lua.isnil(L, -1) {
        return 1
    }
    lua.pop(L, 1)

    path, _ := filepath.join({p.dir, strings.concatenate({name, ".lua"}, context.temp_allocator)}, context.temp_allocator)
    if lua.L_loadfile(L, strings.clone_to_cstring(path, context.temp_allocator)) != .OK {
        lua.L_error(L, "require: %s", lua.tostring(L, -1))
        return 0
    }
    // A main chunk's first upvalue is _ENV; point it at the plugin's sandbox so
    // the module sees exactly what the plugin does.
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(p.env_ref))
    lua.setupvalue(L, -2, 1)
    if !call_guarded(m, index, 0, 1, "require") {
        lua.pushnil(L)
        return 1
    }
    if lua.isnil(L, -1) {
        lua.pop(L, 1)
        lua.pushboolean(L, true)
    }
    lua.pushvalue(L, -1)
    lua.setfield(L, cache, strings.clone_to_cstring(name, context.temp_allocator))
    return 1
}

// True for a bare module name: letters, digits, `_` and `-` only, so nothing
// can climb out of the plugin folder.
@(private)
is_module_name :: proc(name: string) -> bool {
    if name == "" {
        return false
    }
    for ch in name {
        switch ch {
        case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
            continue
        }
        return false
    }
    return true
}

// The name a permission goes by in plugin.json and in the console.
permission_name :: proc(perm: Permission) -> string {
    switch perm {
    case .Exec:  return "exec"
    case .Read:  return "read"
    case .Write: return "write"
    case .Ui:    return "ui"
    case .Keys:  return "keys"
    case .Tick:  return "tick"
    }
    return ""
}

// The permission a manifest name asks for.
permission_from_name :: proc(name: string) -> (Permission, bool) {
    for perm in Permission {
        if permission_name(perm) == name {
            return perm, true
        }
    }
    return .Exec, false
}

// The names of every permission in `perms`, in declaration order.
permission_names :: proc(perms: Permissions, allocator := context.allocator) -> []string {
    out := make([dynamic]string, 0, len(Permission), allocator)
    for perm in Permission {
        if perm in perms {
            append(&out, permission_name(perm))
        }
    }
    return out[:]
}

// The permissions named by `names`; unknown names are skipped.
permissions_from_names :: proc(names: []string) -> Permissions {
    perms: Permissions
    for name in names {
        if perm, ok := permission_from_name(name); ok {
            perms += {perm}
        }
    }
    return perms
}

// Reads plugin.json beside plugin.lua. A missing or malformed file grants
// nothing, which is all a syntax-only plugin needs.
manifest_permissions :: proc(dir: string) -> Permissions {
    path, _ := filepath.join({dir, "plugin.json"}, context.temp_allocator)
    data, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil {
        return {}
    }
    parsed, err := json.parse(data, allocator = context.temp_allocator)
    if err != nil {
        log.warnf("plugin %q: plugin.json is malformed, granting no permissions", dir)
        return {}
    }
    root, is_object := parsed.(json.Object)
    if !is_object {
        return {}
    }
    list, has_list := root["permissions"].(json.Array)
    if !has_list {
        return {}
    }

    perms: Permissions
    for entry in list {
        name, is_string := entry.(json.String)
        if !is_string {
            continue
        }
        if perm, known := permission_from_name(name); known {
            perms += {perm}
        } else {
            log.warnf("plugin %q: unknown permission %q", dir, name)
        }
    }
    return perms
}

// Resolves `path` for a plugin and checks it stays inside a root the plugin may
// touch: the open workspace or its own folder. A relative path is taken against
// the workspace, so `thor.doc(".thor/git/status.md")` lands where the user
// expects rather than beside the executable. The result uses the temp allocator.
@(private)
resolve_path :: proc(m: ^Manager, index: int, path: string) -> (resolved: string, ok: bool) {
    p := caller_plugin(m, index)
    if p == nil || path == "" {
        return "", false
    }

    full := path
    if !filepath.is_abs(path) {
        root := m.workspace_proc != nil ? m.workspace_proc(m.host) : ""
        if root == "" {
            return "", false
        }
        full, _ = filepath.join({root, path}, context.temp_allocator)
    }
    clean, aerr := filepath.abs(full, context.temp_allocator)
    if aerr != nil {
        clean, _ = filepath.clean(full, context.temp_allocator)
    }

    if m.workspace_proc != nil {
        if root := m.workspace_proc(m.host); root != "" && is_within(clean, root) {
            return clean, true
        }
    }
    if is_within(clean, p.dir) {
        return clean, true
    }
    log.warnf("plugin %s: %q is outside the workspace and the plugin folder", p.id, path)
    return "", false
}

// True when `path` is `root` or sits under it. Windows folds case and separators,
// because `C:\Work` and `c:/work` are one folder there. POSIX compares exactly:
// case and `\` are significant, so folding would make two different folders equal.
@(private)
is_within :: proc(path, root: string) -> bool {
    base, err := filepath.abs(root, context.temp_allocator)
    if err != nil {
        base, _ = filepath.clean(root, context.temp_allocator)
    }
    cleaned, _ := filepath.clean(path, context.temp_allocator)
    lhs, rhs := cleaned, base
    when ODIN_OS == .Windows {
        lhs = strings.to_lower(lhs, context.temp_allocator)
        rhs = strings.to_lower(rhs, context.temp_allocator)
        lhs, _ = strings.replace_all(lhs, "\\", "/", context.temp_allocator)
        rhs, _ = strings.replace_all(rhs, "\\", "/", context.temp_allocator)
    }
    rhs = strings.trim_suffix(rhs, "/")
    if lhs == rhs {
        return true
    }
    return strings.has_prefix(lhs, strings.concatenate({rhs, "/"}, context.temp_allocator))
}
