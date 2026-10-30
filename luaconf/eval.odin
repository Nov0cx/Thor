// Runs a config file as sandboxed Lua and returns the table it returns as a
// core:encoding/json Value tree, so a loader walks it as it walked JSON.
//
// Each call gets its own Lua state with the string, table, math and utf8
// libraries, a trimmed base library and a read-only `thor` table. There is no
// io, os, load or require, and a call has a time and a memory budget.
package luaconf

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import lua "vendor:lua/5.4"

// Wall-clock time one config file may run.
BUDGET :: 1 * time.Second

// Most memory one config file may hold.
MEMORY_CAP :: 64 * 1024 * 1024

// Deepest table nesting a result may have; a cycle stops here.
MAX_DEPTH :: 64

@(private)
HOOK_STEP :: 10_000

// Base functions a config cannot have: they run code the sandbox never saw,
// reach the collector, catch the budget error or touch metatables.
@(private)
UNSAFE_BASE := []cstring {
    "load", "loadstring", "dofile", "loadfile", "collectgarbage",
    "pcall", "xpcall", "setmetatable", "getmetatable", "print", "require",
}

Status :: enum {
    Ok,
    Missing,  // the file does not exist; a supported state
    Failed,   // read, syntax, runtime or shape error; see the message
}

// The state one evaluation runs under, read back through the Lua extraspace.
@(private)
Eval_State :: struct {
    start:    time.Tick,
    mem_used: uint,
    spent:    bool,
}

// Evaluates the file at `path`. On .Failed, `message` names the file and line.
// The value and the message are allocated with `allocator`.
eval_file :: proc(path: string, allocator := context.temp_allocator) -> (value: json.Value, status: Status, message: string) {
    if !os.exists(path) {
        return nil, .Missing, ""
    }
    data, err := os.read_entire_file_from_path(path, context.temp_allocator)
    if err != nil {
        return nil, .Failed, fmt.aprintf("%s: cannot read: %v", path, err, allocator = allocator)
    }
    return eval_text(string(data), path, allocator)
}

// Evaluates `text` as a config chunk. `name` is the file name errors report.
eval_text :: proc(text, name: string, allocator := context.temp_allocator) -> (value: json.Value, status: Status, message: string) {
    st: Eval_State
    L := lua.newstate(eval_alloc, &st)
    if L == nil {
        return nil, .Failed, fmt.aprintf("%s: cannot start Lua", name, allocator = allocator)
    }
    defer lua.close(L)
    (^rawptr)(lua.getextraspace(L))^ = &st
    open_config_libs(L)

    chunk := strings.concatenate({"@", name}, context.temp_allocator)
    if lua.L_loadbuffer(L, raw_data(text), len(text), strings.clone_to_cstring(chunk, context.temp_allocator), "t") != .OK {
        return nil, .Failed, strings.clone(string(lua.tostring(L, -1)), allocator)
    }

    st.start = time.tick_now()
    lua.sethook(L, eval_hook, lua.MASKCOUNT, HOOK_STEP)
    status_code := lua.pcall(L, 0, 1, 0)
    lua.sethook(L, nil, lua.HookMask{}, 0)
    if status_code != 0 {
        msg := lua.tostring(L, -1)
        if msg == nil {
            msg = "error object is not a string"
        }
        return nil, .Failed, strings.clone(string(msg), allocator)
    }

    if lua.type(L, -1) != .TABLE {
        return nil, .Failed, fmt.aprintf("%s: the file must return a table", name, allocator = allocator)
    }
    path := make([dynamic]string, context.temp_allocator)
    result, convert_err := to_value(L, lua.gettop(L), &path, allocator)
    if convert_err != "" {
        json.destroy_value(result, allocator)
        return nil, .Failed, fmt.aprintf("%s: %s", name, convert_err, allocator = allocator)
    }
    return result, .Ok, ""
}

// Opens the libraries a config may use and adds the `thor` table.
@(private)
open_config_libs :: proc(L: ^lua.State) {
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
    for name in UNSAFE_BASE {
        lua.pushnil(L)
        lua.setglobal(L, name)
    }

    lua.createtable(L, 0, 3)
    lua.pushstring(L, OS_NAME)
    lua.setfield(L, -2, "os")
    lua.pushstring(L, ARCH_NAME)
    lua.setfield(L, -2, "arch")
    lua.pushcfunction(L, thor_env)
    lua.setfield(L, -2, "env")
    lua.setglobal(L, "thor")
}

// The `thor.os` value: "windows", "linux", "darwin", ...
@(private)
OS_NAME :: "windows" when ODIN_OS == .Windows else "linux" when ODIN_OS == .Linux else "darwin" when ODIN_OS == .Darwin else "freebsd" when ODIN_OS == .FreeBSD else "openbsd" when ODIN_OS == .OpenBSD else "netbsd" when ODIN_OS == .NetBSD else "unknown"

// The `thor.arch` value: "amd64", "arm64", ...
@(private)
ARCH_NAME :: "amd64" when ODIN_ARCH == .amd64 else "arm64" when ODIN_ARCH == .arm64 else "i386" when ODIN_ARCH == .i386 else "arm32" when ODIN_ARCH == .arm32 else "unknown"

// thor.env(name): the environment variable, or nil when it is unset.
@(private)
thor_env :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    n: c.size_t
    name := lua.L_checkstring(L, 1, &n)
    value, found := os.lookup_env(string((cast([^]u8) name)[:n]), context.allocator)
    if !found {
        lua.pushnil(L)
    } else {
        lua.pushlstring(L, cstring(raw_data(value)), c.size_t(len(value)))
        delete(value)
    }
    return 1
}

@(private)
eval_hook :: proc "c" (L: ^lua.State, _: ^lua.Debug) {
    context = runtime.default_context()
    st := (^Eval_State)((^rawptr)(lua.getextraspace(L))^)
    if time.tick_since(st.start) < BUDGET {
        return
    }
    st.spent = true
    lua.L_error(L, "config exceeded its time budget")
}

// Refuses a grow past MEMORY_CAP, which Lua raises as a memory error.
@(private)
eval_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: c.size_t) -> rawptr {
    st := (^Eval_State)(ud)
    old := ptr == nil ? 0 : uint(osize)
    if nsize == 0 {
        runtime.heap_free(ptr)
        st.mem_used -= old
        return nil
    }
    if uint(nsize) > old && st.mem_used - old + uint(nsize) > MEMORY_CAP {
        return nil
    }
    block := runtime.heap_resize(ptr, int(nsize))
    if block != nil {
        st.mem_used = st.mem_used - old + uint(nsize)
    }
    return block
}

// The key path of a value for an error: "servers[3].command".
@(private)
path_text :: proc(path: []string) -> string {
    if len(path) == 0 {
        return "the result"
    }
    b := strings.builder_make(context.temp_allocator)
    for part, i in path {
        if i > 0 && !strings.has_prefix(part, "[") {
            strings.write_byte(&b, '.')
        }
        strings.write_string(&b, part)
    }
    return strings.to_string(b)
}

// Converts the Lua value at `idx` into a Value. Returns an error text on a
// value that has no JSON form.
@(private)
to_value :: proc(L: ^lua.State, idx: c.int, path: ^[dynamic]string, allocator: runtime.Allocator) -> (json.Value, string) {
    #partial switch lua.type(L, idx) {
    case .NIL:
        return json.Null(nil), ""
    case .BOOLEAN:
        return json.Boolean(lua.toboolean(L, idx) != false), ""
    case .NUMBER:
        if lua.isinteger(L, idx) {
            return json.Integer(lua.tointeger(L, idx)), ""
        }
        return json.Float(lua.tonumber(L, idx)), ""
    case .STRING:
        n: c.size_t
        s := lua.tolstring(L, idx, &n)
        return json.String(strings.clone(string((cast([^]u8) s)[:n]), allocator)), ""
    case .TABLE:
        return table_value(L, idx, path, allocator)
    }
    tname := string(lua.typename(L, lua.type(L, idx)))
    return nil, fmt.tprintf("%s is a %s, which a config cannot hold", path_text(path[:]), tname)
}

@(private)
table_value :: proc(L: ^lua.State, at: c.int, path: ^[dynamic]string, allocator: runtime.Allocator) -> (json.Value, string) {
    if len(path) >= MAX_DEPTH {
        return nil, fmt.tprintf("%s is nested too deeply (a table holds itself?)", path_text(path[:]))
    }
    idx := lua.absindex(L, at)
    lua.checkstack(L, 4)

    // An array has only the keys 1..n; an object only string keys; an empty
    // table is an object.
    count, int_keys, string_keys := 0, 0, 0
    lua.pushnil(L)
    for lua.next(L, idx) != 0 {
        count += 1
        #partial switch lua.type(L, -2) {
        case .STRING:
            string_keys += 1
        case .NUMBER:
            if lua.isinteger(L, -2) {
                k := lua.tointeger(L, -2)
                if k >= 1 && int(k) <= int(lua.rawlen(L, idx)) {
                    int_keys += 1
                }
            }
        }
        lua.pop(L, 1)
    }

    if count > 0 && int_keys == count {
        arr := make(json.Array, 0, count, allocator)
        for i in 1 ..= count {
            lua.rawgeti(L, idx, lua.Integer(i))
            append(path, fmt.tprintf("[%d]", i))
            elem, err := to_value(L, -1, path, allocator)
            pop(path)
            lua.pop(L, 1)
            if err != "" {
                json.destroy_value(arr, allocator)
                return nil, err
            }
            append(&arr, elem)
        }
        return arr, ""
    }
    if string_keys != count {
        return nil, fmt.tprintf("%s mixes list entries and named keys", path_text(path[:]))
    }

    obj := make(json.Object, count, allocator)
    lua.pushnil(L)
    for lua.next(L, idx) != 0 {
        n: c.size_t
        k := lua.tolstring(L, -2, &n)
        key := string((cast([^]u8) k)[:n])
        append(path, key)
        elem, err := to_value(L, -1, path, allocator)
        pop(path)
        if err != "" {
            lua.pop(L, 2)
            json.destroy_value(obj, allocator)
            return nil, err
        }
        obj[strings.clone(key, allocator)] = elem
        lua.pop(L, 1)
    }
    return obj, ""
}
