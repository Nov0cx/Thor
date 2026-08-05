package plugin

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// Host stub: records what a plugin asked the editor to do.
@(private = "file")
Recorder :: struct {
    workspace: string,
    output:    strings.Builder,
    written:   [dynamic]string,
    panels:    [dynamic]string,
    kinds:     [dynamic]View_Kind,
    labels:    [dynamic]string,
}

@(private = "file")
recorder_init :: proc(r: ^Recorder) {
    r.workspace, _ = os.get_working_directory(context.allocator)
    r.output = strings.builder_make()
    r.written = make([dynamic]string)
    r.panels = make([dynamic]string)
    r.kinds = make([dynamic]View_Kind)
    r.labels = make([dynamic]string)
}

@(private = "file")
recorder_destroy :: proc(r: ^Recorder) {
    delete(r.workspace)
    strings.builder_destroy(&r.output)
    for path in r.written {
        delete(path)
    }
    delete(r.written)
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
rec_write :: proc(host: rawptr, path, text: string) {
    r := cast(^Recorder) host
    append(&r.written, strings.clone(path))
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
}

// A manager wired to `r`, ready to load plugin sources.
@(private = "file")
recording_manager :: proc(m: ^Manager, r: ^Recorder) {
    manager_init(m)
    manager_set_host(m, Host {
        data         = r,
        print        = rec_print,
        workspace    = rec_workspace,
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
            testing.expectf(t, p.perms == {.Exec, .Write, .Ui}, "git asks for %v", p.perms)
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

    script := `thor.print(type(thor.exec) .. " " .. type(thor.on_key) .. " " .. type(thor.panel) .. " " .. type(thor.print))`
    testing.expect(t, manager_load_source(&m, "plain", "plugins/plain", script, {}), "plugin runs")
    testing.expectf(t, strings.contains(printed(&r), "nil nil nil function"), "denied api present: %q", printed(&r))

    granted := `thor.print(type(thor.exec) .. " " .. type(thor.panel))`
    testing.expect(t, manager_load_source(&m, "trusted", "plugins/trusted", granted, {.Exec, .Ui}), "plugin runs")
    testing.expectf(t, strings.contains(printed(&r), "function function"), "granted api missing: %q", printed(&r))
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
// one is cut off like any other, and the error reaches the plugin.
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
    testing.expect(t, manager_load_source(&m, "cowrap", "plugins/cowrap", wrapped, {}), "plugin runs")
    elapsed := time.tick_since(start)
    out := printed(&r)
    testing.expectf(t, strings.contains(out, "wrap ok=false"), "wrapped coroutine never stopped: %q", out)
    testing.expectf(t, strings.contains(out, "time budget"), "stopped for another reason: %q", out)
    testing.expectf(t, elapsed >= CALL_BUDGET && elapsed < 4 * CALL_BUDGET, "stopped at %v", elapsed)

    created := `local co = coroutine.create(function() while true do end end)
local ok, err = coroutine.resume(co)
thor.print("resume ok=" .. tostring(ok) .. " err=" .. tostring(err) .. " status=" .. coroutine.status(co))`
    testing.expect(t, manager_load_source(&m, "cocreate", "plugins/cocreate", created, {}), "plugin runs")
    out = printed(&r)
    testing.expectf(t, strings.contains(out, "resume ok=false"), "created coroutine never stopped: %q", out)
    testing.expectf(t, strings.contains(out, "status=dead"), "the coroutine survived its budget: %q", out)
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
