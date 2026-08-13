package plugin

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The tutorial plugin (plugins/tutorial) driven headlessly: a fake host serves
// thor.read from an in-memory playground and records what thor.doc renders, so
// the repair checklist can be asserted without a window. Run from the repo root.

@(private = "file")
Tutor :: struct {
    workspace: string, // owned
    lab:       string, // owned; the playground buffer the plugin reads back
    doc:       string, // owned; the last tutorial.md rendered
    confirmed: bool,   // whether a reset was offered
}

@(private = "file")
tutor_destroy :: proc(t: ^Tutor) {
    delete(t.workspace)
    delete(t.lab)
    delete(t.doc)
}

@(private = "file")
tut_workspace :: proc(host: rawptr) -> string {
    return (cast(^Tutor) host).workspace
}

// Every action is bound, so no challenge is dropped for want of a chord.
@(private = "file")
tut_keybind :: proc(host: rawptr, action: string) -> (string, bool) {
    return strings.concatenate({"Key<", action, ">"}, context.temp_allocator), true
}

@(private = "file")
tut_doc :: proc(host: rawptr, path, text: string, focus: bool) {
    t := cast(^Tutor) host
    if strings.has_suffix(path, ".odin") {
        delete(t.lab)
        t.lab = strings.clone(text)
        return
    }
    delete(t.doc)
    t.doc = strings.clone(text)
}

@(private = "file")
tut_read :: proc(host: rawptr, path: string) -> string {
    t := cast(^Tutor) host
    if strings.has_suffix(path, ".odin") {
        return strings.clone(t.lab)
    }
    return strings.clone("")
}

@(private = "file")
tut_confirm :: proc(host: rawptr, message: string) {
    (cast(^Tutor) host).confirmed = true
}

// A manager running the real tutorial plugin against `t`.
@(private = "file")
tutorial_manager :: proc(m: ^Manager, t: ^Tutor) -> bool {
    cwd, _ := os.get_working_directory(context.allocator)
    t.workspace = cwd
    manager_init(m)
    manager_set_host(m, Host {
        data      = t,
        keybind   = tut_keybind,
        doc       = tut_doc,
        read      = tut_read,
        workspace = tut_workspace,
        confirm   = tut_confirm,
    })
    return manager_load_plugin(m, "tutorial", "plugins/tutorial", {.Read, .Write, .Ui, .Keys, .Tick})
}

// Runs the on_tick handlers now, without waiting out the interval the frame loop
// would.
@(private = "file")
force_tick :: proc(m: ^Manager) {
    m.tick_at._nsec -= i64(TICK_INTERVAL)
    manager_dispatch_tick(m)
}

// The playground with every planted defect repaired: imports fixed, `total`
// declared, the switch complete, the body indented, no trailing whitespace and
// the constants aligned. Every task must read this as cleared.
@(private = "file")
FIXED_LAB :: `package tutorial

import "core:fmt"

MAX_ITEMS     :: 32
DEFAULT_LABEL :: "item"
RETRY_LIMIT   :: 3

Shape :: enum {
    Circle,
    Square,
    Triangle,
}

Item :: struct {
    name:  string,
    count: int,
    shape: Shape,
}

sides :: proc(shape: Shape) -> int {
    switch shape {
    case .Circle:
        return 0
    case .Square:
        return 4
    case .Triangle:
        return 3
    }
    return -1
}

report :: proc(items: []Item) {
    total := 0
    for it in items {
        total += it.count
        fmt.printfln("%s x%d", it.name, it.count)
    }
    fmt.printfln("%s: %d items, %d total", DEFAULT_LABEL, len(items), total)
}
`

// Help -> Tutorial writes the broken playground and renders a document whose
// repair list is entirely unticked: the file it just wrote fails every check.
@(test)
test_tutorial_starts_with_a_broken_playground :: proc(t: ^testing.T) {
    tutor: Tutor
    defer tutor_destroy(&tutor)
    m: Manager
    defer manager_destroy(&m)
    if !testing.expect(t, tutorial_manager(&m, &tutor), "the tutorial plugin loads") {
        return
    }

    testing.expect(t, manager_run_command(&m, "tutorial"), "Help -> Tutorial runs")
    testing.expect(t, strings.contains(tutor.lab, "package tutorial"), "the playground was written")
    testing.expect(t, !tutor.confirmed, "a fresh playground is reset without asking")

    testing.expect(t, strings.contains(tutor.doc, "Part 2 - Repair"), "the document has the repair part")
    testing.expect(t, strings.contains(tutor.doc, "0/8"), "no repair task starts cleared")
    testing.expect(t, !strings.contains(tutor.doc, "[x]"), "nothing is ticked at the start")
    // The first task is the parse error, and its explanation is written from the
    // file rather than canned: it names the line the call is never closed on.
    testing.expect(t, strings.contains(tutor.doc, "Now: Close the call"), "the parse task comes first")
    testing.expect(t, strings.contains(tutor.doc, "the `(` after `printfln` is never closed"), "the parse task explains the cause")
    testing.expect(t, strings.contains(tutor.doc, "Key<code_actions>"), "explanations quote the live keybinds")
}

// A repaired buffer clears every task. The checks run off the tick and read the
// live buffer, so the document follows a fix that no key press announced -- a
// code action, say -- and needs no save.
@(test)
test_tutorial_clears_when_the_file_is_repaired :: proc(t: ^testing.T) {
    tutor: Tutor
    defer tutor_destroy(&tutor)
    m: Manager
    defer manager_destroy(&m)
    if !testing.expect(t, tutorial_manager(&m, &tutor), "the tutorial plugin loads") {
        return
    }
    testing.expect(t, manager_run_command(&m, "tutorial"), "Help -> Tutorial runs")

    // Fix only the missing bracket: the parse task clears and the next one, the
    // missing import, becomes the explained step.
    fixed_paren, _ := strings.replace(tutor.lab, "it.name, it.count\n", "it.name, it.count)\n", 1, context.allocator)
    delete(tutor.lab)
    tutor.lab = fixed_paren
    force_tick(&m)
    testing.expect(t, strings.contains(tutor.doc, "1/8"), "the parse task cleared")
    testing.expect(t, strings.contains(tutor.doc, "Now: Import the package"), "the import task is next")

    // The whole repair clears the part.
    delete(tutor.lab)
    tutor.lab = strings.clone(FIXED_LAB)
    force_tick(&m)
    testing.expect(t, strings.contains(tutor.doc, "8/8"), "every repair task cleared")
    testing.expect(t, strings.contains(tutor.doc, "Part 2 complete!"), "the part reports completion")
    testing.expect(t, strings.contains(tutor.doc, "1. [x]"), "the first repair task is ticked")
    testing.expect(t, strings.contains(tutor.doc, "8. [x]"), "the last repair task is ticked")
}

// A key press clears the challenge bound to it, and an edited playground is only
// reset after the reader confirms it.
@(test)
test_tutorial_challenges_and_reset_prompt :: proc(t: ^testing.T) {
    tutor: Tutor
    defer tutor_destroy(&tutor)
    m: Manager
    defer manager_destroy(&m)
    if !testing.expect(t, tutorial_manager(&m, &tutor), "the tutorial plugin loads") {
        return
    }
    testing.expect(t, manager_run_command(&m, "tutorial"), "Help -> Tutorial runs")
    testing.expect(t, strings.contains(tutor.doc, "Part 1 - Shortcuts"), "the drill is rendered")
    testing.expect(t, strings.contains(tutor.doc, "0/10"), "the drill starts empty")

    // The first challenge is the command palette; its chord clears it, and the
    // handler never consumes the key, so the real action still runs.
    consumed := manager_dispatch_key(&m, "Key<command_palette>", {.Ctrl})
    testing.expect(t, !consumed, "the tutorial observes keys without eating them")
    testing.expect(t, strings.contains(tutor.doc, "1/10"), "the pressed chord cleared its challenge")

    // Re-running the tutorial over an edited playground asks before replacing it.
    delete(tutor.lab)
    tutor.lab = strings.clone("package tutorial\n")
    testing.expect(t, manager_run_command(&m, "tutorial"), "Help -> Tutorial runs again")
    testing.expect(t, tutor.confirmed, "an edited playground is only reset on confirmation")
    testing.expect(t, tutor.lab == "package tutorial\n", "the edit survives until then")
}
