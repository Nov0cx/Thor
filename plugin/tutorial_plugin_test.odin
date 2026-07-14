package plugin

import "base:runtime"
import "core:strings"
import "core:testing"

// Holds the latest document the tutorial rendered via thor.doc, so the test can
// assert on it. The host callbacks are plain procs (no captures), so the sink
// lives at file scope.
@(private = "file")
g_doc: strings.Builder

// The allocator the manager was created under, and whether thor.doc ran under
// it. The Lua callback resets to the default context, so api_doc must restore
// the app allocator before calling the host; otherwise app allocations made
// here are freed by the wrong allocator later (a bad free).
@(private = "file")
g_host_allocator: runtime.Allocator
@(private = "file")
g_doc_allocator_ok: bool

@(private = "file")
tut_doc :: proc(host: rawptr, path: string, text: string, focus: bool) {
    g_doc_allocator_ok = context.allocator == g_host_allocator
    strings.builder_reset(&g_doc)
    strings.write_string(&g_doc, text)
}

// Deterministic, unique chord per action; the plugin compares the pressed chord
// against this same value, so dispatching tut_chord(action) clears that step.
@(private = "file")
tut_chord :: proc(action: string) -> string {
    return strings.concatenate({"KB:", action}, context.temp_allocator)
}

@(private = "file")
tut_keybind :: proc(host: rawptr, action: string) -> (string, bool) {
    return tut_chord(action), true
}

// Exercises the interactive-tutorial plugin end to end through the public API:
// it stays idle until the host runs the "tutorial" command, which renders the
// document (explaining every action, listing the challenges) via thor.doc; the
// matching key ticks a challenge off and the wrong key does nothing, and
// observing never consumes the key. Run from the repository root: odin test plugin
@(test)
test_tutorial_plugin_progresses :: proc(t: ^testing.T) {
    g_host_allocator = context.allocator
    g_doc_allocator_ok = false

    m: Manager
    manager_init(&m)
    g_doc = strings.builder_make()
    defer {
        manager_destroy(&m)
        strings.builder_destroy(&g_doc)
    }

    manager_set_host(&m, nil, nil, tut_keybind, tut_doc)
    manager_load(&m) // loads plugins/tutorial/plugin.lua (CWD = repo root)

    // The tutorial is command-driven (Help -> Tutorial): loading and even a key
    // press must render nothing until it is started.
    testing.expect(t, len(strings.to_string(g_doc)) == 0, "tutorial rendered before it was started")
    manager_dispatch_key(&m, tut_chord("command_palette"), true, false, false)
    testing.expect(t, len(strings.to_string(g_doc)) == 0, "tutorial advanced before it was started")

    // Start it the way the Help menu does.
    testing.expect(t, manager_run_command(&m, "tutorial"), "tutorial command not registered")
    testing.expect(t, g_doc_allocator_ok, "thor.doc did not run under the app allocator (api_doc must restore it)")
    doc := strings.to_string(g_doc)
    testing.expect(t, strings.contains(doc, "Thor - Interactive Tutorial"), "title not rendered")
    testing.expect(t, strings.contains(doc, "Every action explained"), "full reference not rendered")
    testing.expect(t, strings.contains(doc, ">> Open the command palette"), "first challenge not highlighted")

    // Clear the first challenge by "pressing" its bound chord.
    consumed := manager_dispatch_key(&m, tut_chord("command_palette"), true, false, false)
    testing.expect(t, !consumed, "the tutorial must observe without consuming the key")
    doc = strings.to_string(g_doc)
    testing.expect(t, strings.contains(doc, "[x] Open the command palette"), "challenge not ticked off")
    testing.expect(t, strings.contains(doc, ">> Quick-open the file finder"), "next challenge not highlighted")

    // A non-matching key must not advance the tutorial.
    before := strings.clone(strings.to_string(g_doc), context.temp_allocator)
    manager_dispatch_key(&m, "Ctrl+DoesNotExist", true, false, false)
    testing.expect(t, strings.to_string(g_doc) == before, "a wrong key advanced the tutorial")
}
