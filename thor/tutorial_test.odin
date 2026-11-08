package thor

import "core:strings"
import "core:testing"

import "../setting"
import ui "../vendor/loom/loom"

// The playground with every defect repaired. Every lab task must pass on it.
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

@(private = "file")
chapter_index :: proc(id: string) -> int {
    for c, i in TUTORIAL_CHAPTERS {
        if c.id == id {
            return i
        }
    }
    return -1
}

// A step waits for its own actions: another action leaves it, one of its own
// moves it on, and the last step ends the chapter.
@(test)
test_tutorial_note_action_advances :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    chapter := chapter_index("multi_cursor")
    if !testing.expect(t, chapter >= 0, "the multi_cursor chapter exists") {
        return
    }
    thor.tutorial.running = true
    thor.tutorial.chapter = chapter

    thor_note_action(thor, "undo")
    testing.expect_value(t, thor.tutorial.step, 0)
    thor_note_action(thor, "select_word")
    testing.expect_value(t, thor.tutorial.step, 1)
    thor_note_action(thor, "select_word")
    testing.expect_value(t, thor.tutorial.step, 2)

    thor_tutorial_move(thor, -1)
    testing.expect_value(t, thor.tutorial.step, 1)
    thor_tutorial_move(thor, 1)
    thor_note_action(thor, "add_cursor_below")
    thor_note_action(thor, "collapse_cursors")
    _, has_step := thor_tutorial_current(thor)
    testing.expect(t, !has_step, "the chapter is done after its last step")
    testing.expect(t, thor.tutorial.marks[chapter].done, "the chapter is marked done")

    thor_tutorial_stop(thor)
    thor_note_action(thor, "select_word")
    testing.expect(t, !thor.tutorial.running, "a stopped tutorial stays stopped")
}

// A bound action shows its chord, an unbound one the palette command that runs it.
@(test)
test_tutorial_expand_placeholders :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.config = setting.load(setting.GLOBAL_DIR)
    defer setting.destroy(&thor.config)
    thor_palette_init(thor)
    defer {
        thor_palette_clear_commands(thor)
        thor_palette_destroy(thor)
        delete(thor.app_binds)
    }
    thor_register_commands(thor)

    chord := thor_action_shortcut(thor, "save")
    testing.expect(t, chord != "", "save has a shipped chord")
    got := thor_tutorial_expand(thor, "Press {key:save} now.")
    testing.expect_value(t, got, strings.concatenate({"Press `", chord, "` now."}, context.temp_allocator))

    testing.expect_value(
        t,
        thor_tutorial_expand(thor, "{key:toggle_word_wrap}"),
        "**View: Toggle Word Wrap** in the command palette",
    )
    testing.expect_value(t, thor_tutorial_expand(thor, "{key:no_such_action}"), "`no_such_action`")
    testing.expect_value(t, thor_tutorial_expand(thor, "open {key:save"), "open {key:save")
}

// Every lab task fails on the broken playground, names where the defect is and
// explains it, and passes on the repaired one.
@(test)
test_tutorial_lab_checks :: proc(t: ^testing.T) {
    broken := lab_state_of(thor_lab_source())
    fixed := lab_state_of(FIXED_LAB)
    testing.expect(t, !broken.parse_ok, "the playground does not parse")
    for task in 0 ..< LAB_TASKS {
        testing.expectf(t, !lab_check(&broken, task), "task %d passes on the broken playground", task)
        testing.expectf(t, lab_check(&fixed, task), "task %d fails on the repaired playground", task)
        _, _, ok := lab_target(&broken, task)
        testing.expectf(t, ok, "task %d names no defect", task)
        testing.expectf(t, lab_detail(&broken, task) != "", "task %d has no explanation", task)
        testing.expectf(t, !strings.contains(lab_detail(&broken, task), "%!"), "task %d: the explanation has a format error", task)
    }
}

// The trailing spaces of the playground are part of task 6.
@(test)
test_tutorial_lab_keeps_trailing_spaces :: proc(t: ^testing.T) {
    st := lab_state_of(thor_lab_source())
    lo, hi, ok := lab_target(&st, 6)
    testing.expect(t, ok && hi > lo, "the trailing whitespace is found")
    if ok {
        testing.expect_value(t, strings.trim_space(st.src[lo:hi]), "")
    }
}

// Progress written and read back is the same, and an empty chapter is left out.
@(test)
test_tutorial_progress_round_trip :: proc(t: ^testing.T) {
    marks: [len(TUTORIAL_CHAPTERS)]Tutorial_Mark
    marks[0] = {done = true}
    marks[2] = {step = 3}
    data, err := thor_tutorial_marshal(marks[:])
    if !testing.expect(t, err == nil, "the progress marshals") {
        return
    }
    testing.expect(t, !strings.contains(string(data), TUTORIAL_CHAPTERS[1].id), "an untouched chapter is not written")
    got := thor_tutorial_parse(data)
    testing.expect_value(t, got, marks)
    testing.expect_value(t, thor_tutorial_parse(transmute([]byte)string("not json")), [len(TUTORIAL_CHAPTERS)]Tutorial_Mark{})
}

// Every action a chapter waits for or names is a shipped keybinds.lua action,
// and the chapter ids are unique.
@(test)
test_tutorial_chapters_name_real_actions :: proc(t: ^testing.T) {
    shipped := setting.load(setting.GLOBAL_DIR)
    defer setting.destroy(&shipped)

    for c, i in TUTORIAL_CHAPTERS {
        testing.expectf(t, len(c.steps) > 0, "chapter %q has no steps", c.id)
        for other in TUTORIAL_CHAPTERS[i + 1:] {
            testing.expectf(t, other.id != c.id, "chapter id %q is used twice", c.id)
        }
        for step in c.steps {
            if want, ok := step.check.(Check_Action); ok {
                testing.expectf(t, len(want.actions) > 0, "%q waits for no action", step.title)
                for a in want.actions {
                    testing.expectf(t, a in shipped.keybinds, "%q waits for %q, which is no action", step.title, a)
                }
            }
            rest := step.body
            for {
                at := strings.index(rest, "{key:")
                if at < 0 {
                    break
                }
                end := strings.index_byte(rest[at:], '}')
                if !testing.expectf(t, end > 0, "%q has an unclosed placeholder", step.title) {
                    break
                }
                name := rest[at + len("{key:"):at + end]
                testing.expectf(t, name in shipped.keybinds, "%q names %q, which is no action", step.title, name)
                rest = rest[at + end:]
            }
        }
    }
}

// The chapter list declares balanced nodes and ids. Loom panics at the end of a
// node whose push_id was not popped inside it.
@(test)
test_tutorial_chooser_declares_cleanly :: proc(t: ^testing.T) {
    ctx := new(ui.Context)
    defer free(ctx)
    ui.init(ctx, ui.Config{backend = ui.noop_backend()})
    defer ui.destroy(ctx)
    thor := new(Thor)
    defer free(thor)
    thor.tutorial.loaded = true
    thor.tutorial.marks[0] = {done = true}
    thor.tutorial.marks[1] = {step = 2}
    thor.tutorial.chooser_open = true
    for ui.frame(ui.Input{dt = 0.016, viewport = {1200, 800}}) {
        thor_tutorial_view(thor)
    }
    testing.expect(t, thor.tutorial.chooser_open, "the chapter list stays open with no input")
}
