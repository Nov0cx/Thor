package plugin

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import lua "vendor:lua/5.4"

// Host stub: records what a plugin asked the editor to do.
@(private = "file")
Recorder :: struct {
    workspace: string,
    data_root: string,
    output:    strings.Builder,
    written:   [dynamic]string,
    text:      string, // owned; the text of the last write
    panels:    [dynamic]string,
    kinds:     [dynamic]View_Kind,
    labels:    [dynamic]string,
    depth:     int, // of the last rendered tree
    count:     int, // nodes in the last rendered tree
}

@(private = "file")
recorder_init :: proc(r: ^Recorder) {
    r.workspace, _ = os.get_working_directory(context.allocator)
    r.data_root = strings.concatenate({r.workspace, "/thor_plugin_data"})
    r.output = strings.builder_make()
    r.written = make([dynamic]string)
    r.panels = make([dynamic]string)
    r.kinds = make([dynamic]View_Kind)
    r.labels = make([dynamic]string)
}

@(private = "file")
recorder_destroy :: proc(r: ^Recorder) {
    delete(r.workspace)
    delete(r.data_root)
    strings.builder_destroy(&r.output)
    for path in r.written {
        delete(path)
    }
    delete(r.written)
    delete(r.text)
    for id in r.panels {
        delete(id)
    }
    delete(r.panels)
    delete(r.kinds)
    for label in r.labels {
        delete(label)
    }
    delete(r.labels)
}

@(private = "file")
rec_print :: proc(host: rawptr, text: string) {
    r := cast(^Recorder) host
    strings.write_string(&r.output, text)
    strings.write_byte(&r.output, '\n')
}

@(private = "file")
rec_workspace :: proc(host: rawptr) -> string {
    return (cast(^Recorder) host).workspace
}

@(private = "file")
rec_data_root :: proc(host: rawptr) -> string {
    return (cast(^Recorder) host).data_root
}

@(private = "file")
rec_write :: proc(host: rawptr, path, text: string) {
    r := cast(^Recorder) host
    append(&r.written, strings.clone(path))
    delete(r.text)
    r.text = strings.clone(text)
}

// Gives back the text of the last write, whatever the path.
@(private = "file")
rec_read :: proc(host: rawptr, path: string) -> string {
    return strings.clone((cast(^Recorder) host).text)
}

@(private = "file")
rec_panel :: proc(host: rawptr, id, title, dock: string) {
    r := cast(^Recorder) host
    append(&r.panels, strings.clone(id))
}

@(private = "file")
rec_panel_render :: proc(host: rawptr, id: string, nodes: []View_Node) {
    r := cast(^Recorder) host
    for node in nodes {
        append(&r.kinds, node.kind)
        append(&r.labels, strings.clone(node.text))
    }
    r.depth, r.count = tree_size(nodes)
}

// The depth and the node count of a panel tree.
@(private = "file")
tree_size :: proc(nodes: []View_Node) -> (depth, count: int) {
    if len(nodes) == 0 {
        return 0, 0
    }
    for node in nodes {
        below, inner := tree_size(node.children)
        depth = max(depth, below)
        count += inner + 1
    }
    return depth + 1, count
}

// A manager wired to `r`, ready to load plugin sources.
@(private = "file")
recording_manager :: proc(m: ^Manager, r: ^Recorder) {
    manager_init(m)
    manager_set_host(m, Host {
        data         = r,
        print        = rec_print,
        workspace    = rec_workspace,
        data_root    = rec_data_root,
        read         = rec_read,
        write        = rec_write,
        panel        = rec_panel,
        panel_render = rec_panel_render,
    })
}

@(private = "file")
printed :: proc(r: ^Recorder) -> string {
    return strings.to_string(r.output)
}

// Scanning reports what each plugin wants without running any of it, so the
// host can ask before a single line of plugin code executes.
@(test)
test_scan_reports_manifest_permissions :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    found := manager_scan(&m)
    testing.expect(t, len(found) > 0, "plugins found")
    testing.expect(t, len(m.plugins) == 0, "scanning runs nothing")

    seen_git, seen_language := false, false
    for p in found {
        switch p.id {
        case "git":
            seen_git = true
            testing.expectf(t, p.perms == {.Exec, .Ui}, "git asks for %v", p.perms)
        case "odin":
            seen_language = true
            testing.expectf(t, p.perms == {}, "a language plugin asks for %v", p.perms)
        }
    }
    testing.expect(t, seen_git, "the git plugin was scanned")
    testing.expect(t, seen_language, "the odin plugin was scanned")

    names := permission_names({.Exec, .Ui}, context.temp_allocator)
    testing.expectf(t, len(names) == 2 && names[0] == "exec" && names[1] == "ui", "permission names: %v", names)
    testing.expect(t, permissions_from_names({"write", "nope"}) == {.Write}, "unknown names are dropped")
}

// A plugin only sees the entry points its permissions grant; the rest are absent
// rather than present-and-refusing, so `thor.exec` is a plain nil value.
@(test)
test_sandbox_hides_ungranted_api :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `thor.print(type(thor.exec) .. " " .. type(thor.on_key) .. " " .. type(thor.panel) .. " " .. type(thor.on_tick) .. " " .. type(thor.print))`
    testing.expect(t, manager_load_source(&m, "plain", "plugins/plain", script, {}), "plugin runs")
    testing.expectf(t, strings.contains(printed(&r), "nil nil nil nil function"), "denied api present: %q", printed(&r))

    granted := `thor.print(type(thor.exec) .. " " .. type(thor.panel))`
    testing.expect(t, manager_load_source(&m, "trusted", "plugins/trusted", granted, {.Exec, .Ui}), "plugin runs")
    testing.expectf(t, strings.contains(printed(&r), "function function"), "granted api missing: %q", printed(&r))
}

// A NUL byte goes through thor.write and comes back from thor.read whole.
@(test)
test_read_write_keep_nul_bytes :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `thor.write("nul.txt", "a\0b"); local s = thor.read("nul.txt"); thor.print(#s .. " " .. (s == "a\0b" and "same" or "cut"))`
    testing.expect(t, manager_load_source(&m, "nul", "plugins/nul", script, {.Read, .Write}), "plugin runs")
    testing.expect_value(t, r.text, "a\x00b")
    testing.expectf(t, strings.contains(printed(&r), "3 same"), "read back: %q", printed(&r))
}

// thor.data_path names a folder outside the workspace, so plugin state survives
// a workspace switch. The sandbox accepts a write there and still refuses
// another plugin's folder under the same root.
@(test)
test_plugin_data_path_is_its_own_folder :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    // A workspace beside the data root, not over it, so only the data-folder
    // branch of resolve_path can accept the write.
    cwd := r.workspace
    r.workspace = strings.concatenate({cwd, "/thor_plugin_ws"})
    delete(cwd)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `thor.print("p=" .. tostring(thor.data_path("state.json")))
thor.write(thor.data_path("state.json"), "kept")
thor.write(thor.data_path("../other/steal.json"), "stolen")`
    testing.expect(t, manager_load_source(&m, "demo", "plugins/demo", script, {.Write}), "plugin runs")

    mine, join_err := filepath.join({r.data_root, "demo", "state.json"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "expected path joined")
    testing.expectf(t, strings.contains(printed(&r), "p="), "data_path returned nothing: %q", printed(&r))
    testing.expectf(t, len(r.written) == 1, "writes accepted: %v", r.written)
    if len(r.written) == 1 {
        testing.expect_value(t, r.written[0], mine)
    }
}

// Globals are per plugin, and the libraries that reach outside the sandbox were
// never loaded, so no plugin can find them.
@(test)
test_sandbox_isolates_globals :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    manager_load_source(&m, "first", "plugins/first", `shared = "leaked"`, {})
    manager_load_source(&m, "second", "plugins/second", `thor.print("shared=" .. tostring(shared))`, {})
    testing.expectf(t, strings.contains(printed(&r), "shared=nil"), "globals leak between plugins: %q", printed(&r))

    probe := `thor.print("libs=" .. tostring(io) .. tostring(package) .. tostring(debug) .. tostring(load) .. tostring(os.execute))`
    manager_load_source(&m, "probe", "plugins/probe", probe, {})
    testing.expectf(t, strings.contains(printed(&r), "libs=nilnilnilnilnil"), "unsafe library reachable: %q", printed(&r))
}

// Precompiled bytecode is refused on both chunk paths. Lua 5.4 does not verify
// bytecode, so a binary chunk would reach past the sandbox that dropping `load`
// and `loadfile` closes.
@(test)
test_sandbox_refuses_lua_bytecode :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    // Dumped on the raw state, so the blob is a chunk this Lua does accept.
    dumped := `blob = string.dump(function() escaped = true end)`
    testing.expect(t, lua.L_dostring(m.state, strings.clone_to_cstring(dumped, context.temp_allocator)) == 0, "dump runs")
    lua.getglobal(m.state, "blob")
    size: c.size_t
    ptr := lua.tolstring(m.state, -1, &size)
    bytes := cast([^]byte) ptr
    bytecode := strings.clone(string(bytes[:size]), context.temp_allocator)
    lua.pop(m.state, 1)
    testing.expect(t, len(bytecode) > 0 && bytecode[0] == 0x1b, "string.dump did not produce a binary chunk")

    testing.expect(t, !manager_load_source(&m, "binary", "plugins/binary", bytecode, {}), "a bytecode plugin loaded")

    dir := "bin/test/bytecode-plugin"
    os.make_directory(dir)
    path, join_err := filepath.join({dir, "mod.lua"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "module path joined")
    testing.expect(t, os.write_entire_file(path, transmute([]byte) bytecode) == nil, "module written")
    defer os.remove(path)

    script := `local ok = pcall(require, "mod")
thor.print("required=" .. tostring(ok))`
    manager_load_source(&m, "requirer", dir, script, {})
    testing.expectf(t, strings.contains(printed(&r), "required=false"), "require loaded bytecode: %q", printed(&r))
}

// Standard-library tables are cloned per plugin, so one plugin monkey-patching
// a stdlib function cannot corrupt it for another.
@(test)
test_sandbox_isolates_stdlib_tables :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    tamper := `string.format = function(...) return "pwned" end
table.insert = function(...) end`
    testing.expect(t, manager_load_source(&m, "tamper", "plugins/tamper", tamper, {}), "plugin runs")

    probe := `local list = {}
table.insert(list, "x")
thor.print("format=" .. string.format("%d", 7) .. " inserted=" .. tostring(#list))`
    testing.expect(t, manager_load_source(&m, "probe", "plugins/probe", probe, {}), "plugin runs")

    out := printed(&r)
    testing.expectf(t, strings.contains(out, "format=7"), "string.format leaked across plugins: %q", out)
    testing.expectf(t, strings.contains(out, "inserted=1"), "table.insert leaked across plugins: %q", out)
}

// A plugin that never returns is cut off instead of freezing the editor.
@(test)
test_sandbox_stops_runaway_plugin :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    start := time.tick_now()
    ok := manager_load_source(&m, "spin", "plugins/spin", "while true do end", {})
    elapsed := time.tick_since(start)
    testing.expect(t, !ok, "runaway plugin reported as failed")
    testing.expectf(t, elapsed >= CALL_BUDGET, "stopped too early: %v", elapsed)
    testing.expectf(t, elapsed < 4 * CALL_BUDGET, "stopped too late: %v", elapsed)
}

// A Lua hook is per thread, so a coroutine gets its own; a runaway loop inside
// one is cut off like any other. The plugin cannot catch the budget error: it
// ends the whole call.
@(test)
test_sandbox_stops_runaway_coroutine :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    wrapped := `local spin = coroutine.wrap(function() while true do end end)
local ok, err = pcall(spin)
thor.print("wrap ok=" .. tostring(ok) .. " err=" .. tostring(err))`
    start := time.tick_now()
    testing.expect(t, !manager_load_source(&m, "cowrap", "plugins/cowrap", wrapped, {}), "the budget error was caught")
    elapsed := time.tick_since(start)
    testing.expectf(t, elapsed >= CALL_BUDGET && elapsed < 4 * CALL_BUDGET, "stopped at %v", elapsed)

    created := `local co = coroutine.create(function() while true do end end)
local ok, err = coroutine.resume(co)
thor.print("resume ok=" .. tostring(ok) .. " err=" .. tostring(err) .. " status=" .. coroutine.status(co))`
    testing.expect(t, !manager_load_source(&m, "cocreate", "plugins/cocreate", created, {}), "the budget error was caught")
    out := printed(&r)
    testing.expectf(t, !strings.contains(out, "ok="), "the plugin ran on past its budget: %q", out)
}

// require runs the module on the thread that called it, so a coroutine gets the
// module value and the main stack stays intact.
@(test)
test_require_inside_coroutine :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    dir := "bin/test/require-coroutine-plugin"
    os.make_directory(dir)
    path, _ := filepath.join({dir, "mod.lua"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(path, transmute([]byte) string(`return { value = 42 }`)) == nil, "module written")
    defer os.remove(path)

    script := `local inner = coroutine.wrap(function() return require("mod") end)()
thor.print("inner=" .. tostring(inner and inner.value))
local co = coroutine.create(function() return require("mod").value end)
local ok, value = coroutine.resume(co)
thor.print("resume=" .. tostring(ok) .. " " .. tostring(value))
thor.print("outer=" .. tostring(require("mod") == inner))`
    testing.expect(t, manager_load_source(&m, "cor", dir, script, {}), "plugin runs")

    out := printed(&r)
    testing.expectf(t, strings.contains(out, "inner=42"), "require in coroutine.wrap: %q", out)
    testing.expectf(t, strings.contains(out, "resume=true 42"), "require in coroutine.resume: %q", out)
    testing.expectf(t, strings.contains(out, "outer=true"), "the module cache: %q", out)
    testing.expect_value(t, lua.gettop(m.state), 0)
}

// pcall in a loop cannot hold the frame: the budget error passes through every
// protected call.
@(test)
test_sandbox_budget_passes_through_pcall :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    script := `local function spin() while true do end end
while true do pcall(spin) end`
    start := time.tick_now()
    testing.expect(t, !manager_load_source(&m, "catch", "plugins/catch", script, {}), "the plugin outran its budget")
    elapsed := time.tick_since(start)
    testing.expectf(t, elapsed >= CALL_BUDGET && elapsed < 4 * CALL_BUDGET, "stopped at %v", elapsed)

    handled := `local function spin() while true do end end
while true do xpcall(spin, function(e) return e end) end`
    start = time.tick_now()
    testing.expect(t, !manager_load_source(&m, "xcatch", "plugins/xcatch", handled, {}), "the plugin outran its budget")
    testing.expectf(t, time.tick_since(start) < 4 * CALL_BUDGET, "xpcall held the frame")

    // The next call starts with a new budget.
    testing.expect(t, manager_load_source(&m, "after", "plugins/after", "local x = 1", {}), "a later plugin runs")
}

// The replaced pcall, xpcall and coroutine.resume keep the stock results for an
// ordinary error and for a yield across them.
@(test)
test_sandbox_protected_calls_keep_their_results :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `local ok, err = pcall(error, "boom")
thor.print("pcall " .. tostring(ok) .. " " .. tostring(err))
local a, b, c = pcall(function(x, y) return x + y, "two" end, 1, 2)
thor.print("values " .. tostring(a) .. " " .. tostring(b) .. " " .. tostring(c))
local xok, xerr = xpcall(function() error("inner") end, function(e) return "handled" end)
thor.print("xpcall " .. tostring(xok) .. " " .. tostring(xerr))
local xa, xb = xpcall(function(v) return v * 2 end, print, 21)
thor.print("xvalues " .. tostring(xa) .. " " .. tostring(xb))
local co = coroutine.create(function(v)
    local got = select(2, pcall(coroutine.yield, v + 1))
    error("done " .. tostring(got))
end)
local r1, v1 = coroutine.resume(co, 1)
thor.print("yield " .. tostring(r1) .. " " .. tostring(v1))
local r2, v2 = coroutine.resume(co, "back")
thor.print("resume " .. tostring(r2) .. " " .. tostring(v2))
local r3, v3 = coroutine.resume(co)
thor.print("dead " .. tostring(r3) .. " " .. tostring(v3))`
    testing.expect(t, manager_load_source(&m, "calls", "plugins/calls", script, {}), "plugin runs")
    out := printed(&r)
    testing.expectf(t, strings.contains(out, "pcall false boom"), "pcall: %q", out)
    testing.expectf(t, strings.contains(out, "values true 3 two"), "pcall results: %q", out)
    testing.expectf(t, strings.contains(out, "xpcall false handled"), "xpcall: %q", out)
    testing.expectf(t, strings.contains(out, "xvalues true 42"), "xpcall results: %q", out)
    testing.expectf(t, strings.contains(out, "yield true 2"), "yield across pcall: %q", out)
    testing.expectf(t, strings.contains(out, "resume false") && strings.contains(out, "done back"), "resume: %q", out)
    testing.expectf(t, strings.contains(out, "dead false cannot resume dead coroutine"), "dead coroutine: %q", out)
}

// A `__gc` finaliser runs with hooks off, so a plugin cannot set one.
@(test)
test_sandbox_refuses_a_finaliser :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `setmetatable({}, {__gc = function() while true do end end})`
    testing.expect(t, !manager_load_source(&m, "gc", "plugins/gc", script, {}), "a finaliser was accepted")
    placeholder := `setmetatable({}, {__gc = true})`
    testing.expect(t, !manager_load_source(&m, "gc2", "plugins/gc2", placeholder, {}), "a __gc placeholder was accepted")

    plain := `local t = setmetatable({}, {__index = function(_, k) return k .. "!" end})
thor.print("meta " .. t.hello .. " " .. tostring(getmetatable(t) ~= nil))`
    testing.expect(t, manager_load_source(&m, "meta", "plugins/meta", plain, {}), "plugin runs")
    testing.expectf(t, strings.contains(printed(&r), "meta hello! true"), "setmetatable: %q", printed(&r))
}

// The host measures a lexer result with no `__len` call: a metamethod there
// would run outside the budget and outside a protected call.
@(test)
test_lexer_result_length_runs_no_metamethod :: proc(t: ^testing.T) {
    m: Manager
    manager_init(&m)
    defer manager_destroy(&m)

    script := `thor.register_language { name = "Raise", extensions = { ".raise" },
    highlight = function() return setmetatable({}, {__len = function() error("x") end}) end }
thor.register_language { name = "Huge", extensions = { ".huge" },
    highlight = function() return setmetatable({ { 0, 1, "keywords" } }, {__len = function() return 1 << 60 end}) end }
thor.register_language { name = "Sparse", extensions = { ".sparse" },
    highlight = function()
        local t = { { 0, 1, "keywords" } }
        for i = 1, 62 do t[1 << i] = { 0, 1, "keywords" } end
        t[3] = nil
        return t
    end }`
    testing.expect(t, manager_load_source(&m, "len", "plugins/len", script, {}), "plugin runs")

    raised := highlight(&m, "", "abc", ".raise", context.allocator)
    testing.expect_value(t, len(raised), 0)
    delete(raised)

    start := time.tick_now()
    for ext in ([]string{".huge", ".sparse"}) {
        spans := highlight(&m, "", "abc", ext, context.allocator)
        testing.expect_value(t, len(spans), 1)
        for s in spans {
            delete(s.role)
        }
        delete(spans)
    }
    testing.expectf(t, time.tick_since(start) < time.Second, "the host loop ran for %v", time.tick_since(start))
}

// Paths resolve against the workspace, and a path climbing out of it never
// reaches the host.
@(test)
test_sandbox_confines_paths :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `thor.write(".thor/inside.txt", "x")
thor.write("../outside.txt", "x")`
    manager_load_source(&m, "writer", "plugins/writer", script, {.Write})

    testing.expectf(t, len(r.written) == 1, "expected one accepted write, got %d", len(r.written))
    if len(r.written) == 1 {
        testing.expect(t, strings.contains(r.written[0], "inside.txt"), "the workspace-relative write went through")
        testing.expect(t, strings.has_prefix(r.written[0], r.workspace), "resolved against the workspace")
    }
}

// A link inside the workspace can lead out of it, so a path through one never
// reaches the host. Needs the right to make a link, which Windows gives only in
// developer mode.
@(test)
test_sandbox_refuses_a_link :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    dir := "bin/test/link-plugin"
    if mkerr := os.make_directory_all(dir); mkerr != nil && mkerr != .Exist {
        testing.expectf(t, false, "test folder: %v", mkerr)
        return
    }
    target, _ := filepath.join({r.workspace, "bin"}, context.temp_allocator)
    link, _ := filepath.join({dir, "out"}, context.temp_allocator)
    os.remove(link)
    if os.symlink(target, link) != nil {
        return
    }
    defer os.remove(link)

    script := `thor.write("bin/test/link-plugin/out/escaped.txt", "x")
thor.write("bin/test/link-plugin/out", "x")
thor.write("bin/test/link-plugin/beside.txt", "x")`
    manager_load_source(&m, "linker", "plugins/linker", script, {.Write})

    testing.expectf(t, len(r.written) == 1, "writes accepted: %v", r.written)
    if len(r.written) == 1 {
        testing.expect(t, strings.contains(r.written[0], "beside.txt"), "the write beside the link went through")
    }
}

// A plugin parses with a compiled-in grammar, walks the tree and runs its own
// query, with capture names naming the matched nodes.
@(test)
test_ts_parse_query_and_walk :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `local tree, err = thor.ts.parse("package p\n\n// note\nmain :: proc() {}\n", "odin")
if not tree then thor.print("parse failed: " .. tostring(err)) return end
local root = tree:root()
thor.print("root=" .. root:type() .. " children=" .. tostring(root:child_count() > 0))
local matches = tree:query("(comment) @c")
thor.print("matches=" .. tostring(#matches))
thor.print("text=" .. matches[1].c:text())
thor.print("bytes=" .. tostring(matches[1].c.start_byte) .. ".." .. tostring(matches[1].c.end_byte))`
    testing.expect(t, manager_load_source(&m, "walker", "plugins/walker", script, {}), "plugin runs")

    out := printed(&r)
    testing.expectf(t, strings.contains(out, "children=true"), "root has no children: %q", out)
    testing.expectf(t, strings.contains(out, "matches=1"), "query found no comment: %q", out)
    testing.expectf(t, strings.contains(out, "text=// note"), "capture text wrong: %q", out)
    testing.expectf(t, strings.contains(out, "bytes=11..18"), "capture offsets wrong: %q", out)
}

// A node that outlives its tree answers nothing: a finaliser can free the tree
// while the node is still reachable.
@(test)
test_ts_node_on_freed_tree :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    // The sandbox cannot reach `__gc`, so the test hands the finaliser in.
    index := new_plugin(&m, "freed", "plugins/freed", {})
    lua.rawgeti(m.state, lua.REGISTRYINDEX, lua.Integer(m.plugins[index].env_ref))
    lua.pushcfunction(m.state, tree_gc)
    lua.setfield(m.state, -2, "free_tree")
    lua.pop(m.state, 1)

    script := `local tree = thor.ts.parse("package p\n\n// note\n", "odin")
local root = tree:root()
local other = tree:root()
free_tree(tree)
thor.print("type=" .. tostring(root:type()) .. " text=[" .. root:text() .. "]")
thor.print("end=" .. tostring(root.end_byte) .. " named=" .. tostring(root.named))
thor.print("child=" .. tostring(root:child(0)) .. " count=" .. tostring(root:child_count()))
thor.print("eq=" .. tostring(root == other) .. " str=" .. tostring(root))
thor.print("root=" .. tostring(tree:root()))`
    testing.expect(t, load_chunk(&m, index, "", transmute([]byte) script), "plugin runs")

    out := printed(&r)
    for want in ([]string {
        "type=nil text=[]",
        "end=nil named=nil",
        "child=nil",
        "eq=false str=<node>",
        "root=nil",
    }) {
        testing.expectf(t, strings.contains(out, want), "missing %q in %q", want, out)
    }
}

// A plugin that parses the same buffer again gets a tree seeded off the last
// one, so the answer must not depend on what it parsed before: an edited source,
// an unrelated one and a second grammar all read exactly as a cold parse would.
@(test)
test_ts_parse_reuses_its_tree :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `local function comments(src, grammar)
    local tree = thor.ts.parse(src, grammar)
    if not tree then return "no tree" end
    local out = {}
    for _, match in ipairs(tree:query("(comment) @c")) do out[#out + 1] = match.c:text() end
    return table.concat(out, "|")
end
thor.print("first=" .. comments("package p\n// one\n", "odin"))
thor.print("edited=" .. comments("package p\n// one\n// two\n", "odin"))
thor.print("shrunk=" .. comments("package p\n// two\n", "odin"))
thor.print("other=" .. comments("-- lua\nlocal x = 1\n", "lua"))
thor.print("back=" .. comments("package p\n// one\n", "odin"))`
    testing.expect(t, manager_load_source(&m, "reparse", "plugins/reparse", script, {}), "plugin runs")

    out := printed(&r)
    for want in ([]string {
        "first=// one",
        "edited=// one|// two",
        "shrunk=// two",
        "other=-- lua",
        "back=// one",
    }) {
        testing.expectf(t, strings.contains(out, want), "missing %q in %q", want, out)
    }
}

// A query naming a node the grammar does not have fails loudly: the plugin gets
// an error back, and the console says which query broke and where.
@(test)
test_ts_query_error_is_reported :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `local tree = thor.ts.parse("package p\n", "odin")
local matches, err = tree:query("(no_such_node) @x")
thor.print("result=" .. tostring(matches) .. " err=" .. tostring(err))`
    testing.expect(t, manager_load_source(&m, "bad", "plugins/bad", script, {}), "plugin runs")

    out := printed(&r)
    testing.expectf(t, strings.contains(out, "result=nil"), "a broken query returned matches: %q", out)
    testing.expectf(t, strings.contains(out, "unknown node type"), "the plugin got no reason: %q", out)
    testing.expectf(t, strings.contains(out, "[bad] query"), "the console was not told: %q", out)
}

// A plugin calling tree:query on the same .scm name twice must read the file
// from disk only once: query_source caches by resolved path, so a query run
// from a canvas draw callback does not re-read its file every visible frame.
@(test)
test_tree_query_reads_scm_file_once :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    dir := "bin/test/query-cache-plugin"
    os.make_directory(dir)
    path, _ := filepath.join({dir, "highlights.scm"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(path, transmute([]byte) string("(comment) @c")) == nil, "query file written")
    defer os.remove(path)

    script := `local tree = thor.ts.parse("package p\n\n// note\n", "odin")
tree:query("highlights.scm")
tree:query("highlights.scm")`
    testing.expect(t, manager_load_source(&m, "cacher", dir, script, {}), "plugin runs")

    testing.expect_value(t, len(m.query_files), 1)
}

// A plugin that builds its query text misses the cache every time, so the cache
// must stay bounded rather than hold one compiled query per string until the
// next plugin reload.
@(test)
test_tree_query_cache_is_bounded :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `local tree = thor.ts.parse("package p\n\nvalue := 1\n", "odin")
local last
for i = 1, 100 do
    last = tree:query("(identifier) @a" .. i)
end
thor.print("matches=" .. tostring(#last))`
    testing.expect(t, manager_load_source(&m, "querier", "plugins/querier", script, {}), "plugin runs")

    testing.expectf(
        t,
        len(m.ts_state.queries) <= TS_QUERY_MAX,
        "the query cache grew to %d entries",
        len(m.ts_state.queries),
    )
    out := printed(&r)
    testing.expectf(t, strings.contains(out, "matches=2"), "a query after the cache was dropped: %q", out)
}

// A line_based lexer is handed only the lines the window covers and its spans
// land at their absolute offsets. One without the flag reads the whole buffer
// and reports that, so a caller caching the spans never re-lexes on a scroll.
@(test)
test_line_based_lexer_is_windowed :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    // Tags every line it is given, so the spans show exactly what it saw.
    script := `
local function lex(src)
    local spans = {}
    local i = 1
    while i <= #src do
        local nl = src:find("\n", i, true)
        local stop = nl and (nl - 1) or #src
        if stop >= i then spans[#spans + 1] = { i - 1, stop, thor.theme.keywords } end
        i = (nl or #src) + 1
    end
    return spans
end
thor.register_language { name = "Windowed", extensions = { ".lb" }, highlight = lex, line_based = true }
thor.register_language { name = "Whole", extensions = { ".whole" }, highlight = lex }
`
    testing.expect(t, manager_load_source(&m, "lb", "plugins/lb", script, {}), "plugin runs")

    src := "aaa\nbbb\nccc\nddd\n" // lines start at 0, 4, 8, 12

    // A window opening mid-line widens to that line's start, so the first line
    // reaches the lexer whole.
    spans, lo, hi := highlight_range(&m, "", src, ".lb", 5, 7, context.temp_allocator)
    testing.expect_value(t, lo, 4)
    testing.expect_value(t, hi, 8)
    testing.expectf(t, len(spans) == 1, "expected one line of spans, got %d", len(spans))
    if len(spans) == 1 {
        testing.expect_value(t, spans[0].start, 4)
        testing.expect_value(t, spans[0].end, 7)
    }

    // The same language over the whole buffer colors every line.
    all, all_lo, all_hi := highlight_range(&m, "", src, ".lb", 0, max(int), context.temp_allocator)
    testing.expect_value(t, all_lo, 0)
    testing.expect_value(t, all_hi, len(src))
    testing.expect_value(t, len(all), 4)

    // Without the flag the window is ignored, and the reported coverage says so.
    whole, whole_lo, whole_hi := highlight_range(&m, "", src, ".whole", 5, 7, context.temp_allocator)
    testing.expect_value(t, whole_lo, 0)
    testing.expect_value(t, whole_hi, len(src))
    testing.expect_value(t, len(whole), 4)
}

// A plugin replaces the compiled-in highlights query with its own, given inline
// or as a .scm file beside plugin.lua. Both paths end at the same query.
@(test)
test_plugin_supplied_highlights_query :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    inline_query := `thor.register_language {
        name = "odin", grammar = "odin", extensions = { ".odin" },
        highlights = "(comment) @comment",
        colors = { comment = thor.theme.comments },
    }`
    testing.expect(t, manager_load_source(&m, "odin1", "plugins/odin1", inline_query, {}), "plugin runs")

    src := "package p\n\n// note\nmain :: proc() {}\n"
    spans := highlight(&m, "", src, ".odin", context.allocator)
    defer delete(spans)
    testing.expectf(t, len(spans) == 1, "expected only the comment, got %d spans", len(spans))
    if len(spans) == 1 {
        testing.expect(t, src[spans[0].start:spans[0].end] == "// note", "the plugin's query drove the spans")
    }

    dir := "bin/test/query-plugin"
    os.make_directory(dir)
    path, _ := filepath.join({dir, "highlights.scm"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(path, transmute([]byte) string("(package_declaration) @keyword")) == nil, "query file written")
    defer os.remove(path)

    from_file := `thor.register_language {
        name = "odin", grammar = "odin", extensions = { ".odin2" },
        highlights = "highlights.scm",
        colors = { keyword = thor.theme.keywords },
    }`
    testing.expect(t, manager_load_source(&m, "odin2", dir, from_file, {}), "plugin runs")

    spans2 := highlight(&m, "", src, ".odin2", context.allocator)
    defer delete(spans2)
    testing.expectf(t, len(spans2) == 1, "expected one span from the .scm file, got %d", len(spans2))
    if len(spans2) == 1 {
        testing.expect(t, spans2[0].role == "keywords", "the .scm file's capture drove the color role")
    }
}

// A highlights query that does not compile leaves the language alone and says so
// on the console, instead of silently uncoloring every file of that language.
@(test)
test_broken_highlights_query_is_reported :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `thor.register_language {
        name = "odin", grammar = "odin", extensions = { ".odin" },
        highlights = "(no_such_node) @keyword",
        colors = { keyword = thor.theme.keywords },
    }`
    testing.expect(t, manager_load_source(&m, "broken", "plugins/broken", script, {}), "plugin runs")

    out := printed(&r)
    testing.expectf(t, strings.contains(out, "[broken] query"), "the console was not told: %q", out)
    testing.expectf(t, strings.contains(out, "unknown node type"), "the reason was not given: %q", out)

    // The compiled-in query still runs, so the language keeps its colors.
    spans := highlight(&m, "", "package p\n\n// note\nmain :: proc() {}\n", ".odin", context.allocator)
    defer delete(spans)
    testing.expect(t, len(spans) > 1, "the default highlights query still applies")
}

// A panel reaches the host as plain nodes, and a click on a rendered button runs
// the Lua function that node carried.
@(test)
test_panel_render_and_click :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    script := `local p = thor.panel { id = "status", title = "Status", dock = "right" }
p:render {
    { kind = "label", text = "Hello" },
    { kind = "button", text = "Go", on_click = function() thor.print("clicked") end },
}`
    testing.expect(t, manager_load_source(&m, "demo", "plugins/demo", script, {.Ui}), "plugin runs")

    testing.expectf(t, len(r.panels) == 1 && r.panels[0] == "demo/status", "panel id: %v", r.panels)
    testing.expectf(t, len(r.kinds) == 2, "expected two nodes, got %d", len(r.kinds))
    if len(r.kinds) == 2 {
        testing.expect(t, r.kinds[0] == .Label && r.labels[0] == "Hello", "first node is the label")
        testing.expect(t, r.kinds[1] == .Button && r.labels[1] == "Go", "second node is the button")
    }

    manager_panel_click(&m, "demo/status", 0)
    testing.expectf(t, strings.contains(printed(&r), "clicked"), "the click did not reach Lua: %q", printed(&r))
}

// A node that holds itself stops at MAX_VIEW_DEPTH, and a child shared at each
// level stops at MAX_VIEW_NODES.
@(test)
test_panel_tree_is_bounded :: proc(t: ^testing.T) {
    r: Recorder
    recorder_init(&r)
    defer recorder_destroy(&r)
    m: Manager
    recording_manager(&m, &r)
    defer manager_destroy(&m)

    cycle := `local p = thor.panel { id = "cycle", title = "Cycle", dock = "right" }
local n = { kind = "column" }
n.children = { n }
p:render { n }`
    testing.expect(t, manager_load_source(&m, "cycle", "plugins/cycle", cycle, {.Ui}), "plugin runs")
    testing.expect_value(t, r.depth, MAX_VIEW_DEPTH)

    shared := `local p = thor.panel { id = "wide", title = "Wide", dock = "right" }
local n = { kind = "label" }
for i = 1, 24 do n = { kind = "column", children = { n, n } } end
p:render { n }`
    start := time.tick_now()
    testing.expect(t, manager_load_source(&m, "wide", "plugins/wide", shared, {.Ui}), "plugin runs")
    testing.expect_value(t, r.count, MAX_VIEW_NODES)
    testing.expectf(t, time.tick_since(start) < time.Second, "the parse ran for %v", time.tick_since(start))
    testing.expect_value(t, lua.gettop(m.state), 0)
}
