package thor

// The guided tutorial: chapters of steps, each step done when an action runs
// (by key, palette, menu or button), when a check on the editor state passes,
// or when the reader presses Next. Progress goes to sessions/tutorial.json.

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"

import "../atomicfile"
import ui "../vendor/loom/loom"

@(private = "file")
TUTORIAL_FILE :: "sessions/tutorial.json"

// A part of the window a step points at.
Tutorial_Region :: enum u8 {
    None,
    Titlebar,
    Menu_Bar,
    Explorer,
    Tabbar,
    Editor,
    Console,
    Statusbar,
}

// Done when one of the actions runs.
Check_Action :: struct {
    actions: []string,
}

// Done when the proc returns true. Polled once a frame while the step is up.
Check_Proc :: #type proc(thor: ^Thor) -> bool

// Done when the reader presses Next.
Check_Next :: struct {}

// Done when the lab task of this index passes.
Check_Lab :: distinct int

Step_Check :: union {
    Check_Action,
    Check_Proc,
    Check_Next,
    Check_Lab,
}

// One step. `body` is markdown; `{key:action}` becomes the live chord.
Tutorial_Step :: struct {
    title:  string,
    body:   string,
    region: Tutorial_Region,
    check:  Step_Check,
}

Tutorial_Chapter :: struct {
    id:       string,
    title:    string,
    steps:    []Tutorial_Step,
    on_start: proc(thor: ^Thor),
}

// Saved progress of one chapter.
Tutorial_Mark :: struct {
    step: int,
    done: bool,
}

@(private = "file")
Tutorial_Record :: struct {
    chapters: map[string]Tutorial_Mark,
}

Tutorial :: struct {
    running:      bool,
    chooser_open: bool,
    chapter:      int,
    step:         int, // len(steps) is the chapter-done card
    marks:        [len(TUTORIAL_CHAPTERS)]Tutorial_Mark,
    loaded:       bool,
    card:         Markdown_View, // owned
    card_h:       f32, // last frame's card height, for the placement
    // A rect the "Show me" button points at, in place of the step's region.
    focus:        ui.Rect,
    focus_set:    bool,
    lab:          Lab,
}

// Help -> Tutorial: the chapter list.
thor_cmd_tutorial :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_tutorial_load(thor)
    thor.tutorial.chooser_open = true
}

// Starts a chapter at its saved step, or at the start when it is done.
thor_tutorial_start :: proc(thor: ^Thor, chapter: int) {
    t := &thor.tutorial
    if chapter < 0 || chapter >= len(TUTORIAL_CHAPTERS) {
        return
    }
    thor_tutorial_load(thor)
    c := TUTORIAL_CHAPTERS[chapter]
    mark := t.marks[chapter]
    t.running = true
    t.chooser_open = false
    t.chapter = chapter
    t.step = mark.done ? 0 : clamp(mark.step, 0, len(c.steps))
    t.focus_set = false
    if c.on_start != nil {
        c.on_start(thor)
    }
}

thor_tutorial_stop :: proc(thor: ^Thor) {
    thor.tutorial.running = false
    thor.tutorial.focus_set = false
}

thor_tutorial_destroy :: proc(thor: ^Thor) {
    thor_markdown_view_destroy(thor, &thor.tutorial.card)
    thor_lab_destroy(&thor.tutorial.lab)
}

// The current step, or false on the chapter-done card.
thor_tutorial_current :: proc(thor: ^Thor) -> (Tutorial_Step, bool) {
    t := &thor.tutorial
    if !t.running {
        return {}, false
    }
    steps := TUTORIAL_CHAPTERS[t.chapter].steps
    if t.step < 0 || t.step >= len(steps) {
        return {}, false
    }
    return steps[t.step], true
}

// Moves `delta` steps. Past the last step the chapter is done.
thor_tutorial_move :: proc(thor: ^Thor, delta: int) {
    t := &thor.tutorial
    if !t.running {
        return
    }
    n := len(TUTORIAL_CHAPTERS[t.chapter].steps)
    t.step = clamp(t.step + delta, 0, n)
    t.focus_set = false
    mark := &t.marks[t.chapter]
    if t.step == n {
        mark.done = true
        mark.step = 0
    } else if !mark.done {
        mark.step = t.step
    }
    // Only progress that was read first is written, so no file is overwritten blind.
    if t.loaded {
        thor_tutorial_save(thor)
    }
}

// Tells the tutorial an action ran. The current step advances when it waits for it.
thor_note_action :: proc(thor: ^Thor, action: string) {
    step, ok := thor_tutorial_current(thor)
    if !ok || action == "" {
        return
    }
    want, is_action := step.check.(Check_Action)
    if !is_action {
        return
    }
    for a in want.actions {
        if a == action {
            thor_tutorial_move(thor, 1)
            return
        }
    }
}

// editview.Action_Proc: an editor keymap action ran.
thor_editor_action_note :: proc(data: rawptr, name: string) {
    thor_note_action(cast(^Thor) data, name)
}

// Polls the state checks of the current step. Called once a frame.
thor_tutorial_poll :: proc(thor: ^Thor) {
    step, ok := thor_tutorial_current(thor)
    if !ok {
        return
    }
    #partial switch check in step.check {
    case Check_Proc:
        if check(thor) {
            thor_tutorial_move(thor, 1)
        }
    case Check_Lab:
        if thor_lab_passes(thor, int(check)) {
            thor_tutorial_move(thor, 1)
        }
    }
}

// The step body with each `{key:action}` replaced by the live chord, or by the
// palette command that runs the action when it has no chord. In the temp allocator.
thor_tutorial_expand :: proc(thor: ^Thor, body: string) -> string {
    b := strings.builder_make(context.temp_allocator)
    rest := body
    for {
        at := strings.index(rest, "{key:")
        if at < 0 {
            break
        }
        end := strings.index_byte(rest[at:], '}')
        if end < 0 {
            break
        }
        strings.write_string(&b, rest[:at])
        strings.write_string(&b, thor_tutorial_chord_text(thor, rest[at + len("{key:"):at + end]))
        rest = rest[at + end + 1:]
    }
    strings.write_string(&b, rest)
    return strings.to_string(b)
}

// How a step names the way to run `action`. In the temp allocator.
thor_tutorial_chord_text :: proc(thor: ^Thor, action: string) -> string {
    if chord := thor_action_shortcut(thor, action); chord != "" {
        return strings.concatenate({"`", chord, "`"}, context.temp_allocator)
    }
    for command in thor.palette.commands {
        if command.action == action {
            return strings.concatenate({"**", command.title, "** in the command palette"}, context.temp_allocator)
        }
    }
    return strings.concatenate({"`", action, "`"}, context.temp_allocator)
}

// Reads the saved progress once.
thor_tutorial_load :: proc(thor: ^Thor) {
    t := &thor.tutorial
    if t.loaded {
        return
    }
    t.loaded = true
    data, err := os.read_entire_file(TUTORIAL_FILE, context.temp_allocator)
    if err != nil {
        return
    }
    t.marks = thor_tutorial_parse(data)
}

// The marks of a progress file, by chapter id. An unknown id is dropped.
thor_tutorial_parse :: proc(data: []byte) -> (marks: [len(TUTORIAL_CHAPTERS)]Tutorial_Mark) {
    record: Tutorial_Record
    if err := json.unmarshal(data, &record, allocator = context.temp_allocator); err != nil {
        log.warnf("Could not read %q: %v", TUTORIAL_FILE, err)
        return
    }
    for c, i in TUTORIAL_CHAPTERS {
        if mark, ok := record.chapters[c.id]; ok {
            marks[i] = mark
        }
    }
    return
}

// The progress file for `marks`. In the temp allocator.
thor_tutorial_marshal :: proc(marks: []Tutorial_Mark) -> ([]byte, json.Marshal_Error) {
    record := Tutorial_Record {
        chapters = make(map[string]Tutorial_Mark, len(marks), context.temp_allocator),
    }
    for mark, i in marks {
        if i < len(TUTORIAL_CHAPTERS) && (mark.done || mark.step > 0) {
            record.chapters[TUTORIAL_CHAPTERS[i].id] = mark
        }
    }
    return json.marshal(record, {pretty = true}, context.temp_allocator)
}

thor_tutorial_save :: proc(thor: ^Thor) {
    if !os.is_dir("sessions") {
        if err := os.make_directory("sessions"); err != nil {
            log.errorf("Could not create sessions dir: %v", err)
            return
        }
    }
    data, err := thor_tutorial_marshal(thor.tutorial.marks[:])
    if err != nil {
        log.errorf("Could not marshal the tutorial progress: %v", err)
        return
    }
    if werr := atomicfile.write(TUTORIAL_FILE, data); werr != nil {
        log.errorf("Could not write %q: %v", TUTORIAL_FILE, werr)
    }
}
