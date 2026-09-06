// The console pane: a scrollback buffer plus a prompt line. It echoes what is
// typed to its runner and shows whatever text is fed back through
// thor_console_append; it runs nothing itself. One per terminal tab.
package thor

import "core:strings"
import rl "vendor:raylib"

import "../font"
import ui "../vendor/loom/loom"

// Called on Enter with a command; the command runs elsewhere and its output
// arrives through thor_console_append.
Console_Run_Proc :: #type proc(data: rawptr, command: string)

// Tests whether a scrollback line names a navigable source location. Reports the
// byte span of the clickable text and whether the line is a link. The owner does
// the parsing, so the console stays agnostic about path and error formats.
Console_Link_Proc :: #type proc(data: rawptr, line: string) -> (start: int, end: int, ok: bool)

// Opens the source location a clicked scrollback line names.
Console_Activate_Proc :: #type proc(data: rawptr, line: string)

// Called on Ctrl+C while a command runs, to stop it.
Console_Interrupt_Proc :: #type proc(data: rawptr)

CONSOLE_PAD_X :: f32(12)
CONSOLE_PAD_Y :: f32(8)

Console :: struct {
    output:         strings.Builder, // owned
    input:          [dynamic]u8, // owned; ui.input edits it in place
    // Sticks the view to the bottom until the user scrolls up.
    autoscroll:     bool,
    // A command is running. Typing stays open, since a running command may read
    // its own stdin; only the prompt is dimmed.
    running:        bool,
    // A CR ended the last chunk; its newline may still be coming.
    pending_cr:     bool,
    // Byte offset of every scrollback line, first entry 0. Grown incrementally
    // from `indexed_len`, so a long log is never rescanned whole. owned
    line_starts:    [dynamic]int,
    // Bytes of `output` the index covers.
    indexed_len:    int,
    // Submitted commands, oldest first, walked with the arrow keys. owned
    history:        [dynamic]string,
    // Position in history while walking; len(history) is the live input line.
    history_index:  int,
    font_size:      i32,
    prompt:         string, // borrowed literal
    on_run:         Console_Run_Proc,
    run_data:       rawptr,
    on_interrupt:   Console_Interrupt_Proc,
    interrupt_data: rawptr,
    on_link:        Console_Link_Proc,
    on_activate:    Console_Activate_Proc,
    link_data:      rawptr,
    // Mouse text selection over the scrollback, as absolute byte offsets into
    // `output`. `selecting` holds only while a drag started in the output area.
    sel_anchor:     int,
    sel_cursor:     int,
    has_selection:  bool,
    selecting:      bool,
    // Set by an open, consumed by the view: the prompt takes the keyboard on the
    // frame the terminal first shows.
    focus_pending:  bool,
}

thor_console_init :: proc(console: ^Console) {
    console.output = strings.builder_make()
    console.line_starts = make([dynamic]int)
    append(&console.line_starts, 0)
    console.input = make([dynamic]u8)
    console.history = make([dynamic]string)
    console.autoscroll = true
    console.font_size = 15
    console.prompt = "> "
    console.focus_pending = true
    strings.write_string(&console.output, "Thor console: type a command and press Enter.\n")
}

thor_console_destroy :: proc(console: ^Console) {
    strings.builder_destroy(&console.output)
    delete(console.input)
    delete(console.line_starts)
    for entry in console.history {
        delete(entry)
    }
    delete(console.history)
}

thor_console_set_on_run :: proc(console: ^Console, on_run: Console_Run_Proc, data: rawptr) {
    console.on_run = on_run
    console.run_data = data
}

thor_console_set_on_interrupt :: proc(
    console: ^Console,
    on_interrupt: Console_Interrupt_Proc,
    data: rawptr,
) {
    console.on_interrupt = on_interrupt
    console.interrupt_data = data
}

thor_console_set_on_link :: proc(
    console: ^Console,
    on_link: Console_Link_Proc,
    on_activate: Console_Activate_Proc,
    data: rawptr,
) {
    console.on_link = on_link
    console.on_activate = on_activate
    console.link_data = data
}

// Wipes the scrollback and re-pins the view to the bottom.
thor_console_clear :: proc(console: ^Console) {
    strings.builder_reset(&console.output)
    clear(&console.line_starts)
    append(&console.line_starts, 0)
    console.indexed_len = 0
    console.autoscroll = true
    console.has_selection = false
}

// The full scrollback text, borrowed until the next append or clear.
thor_console_text :: proc(console: ^Console) -> string {
    return strings.to_string(console.output)
}

thor_console_has_selection :: proc(console: ^Console) -> bool {
    return console.has_selection
}

// Copies the whole scrollback to the system clipboard, selection or not.
thor_console_copy_all :: proc(console: ^Console) {
    text := thor_console_text(console)
    if text != "" {
        rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
    }
}

// Copies the selected text, or the whole scrollback when nothing is selected.
thor_console_copy :: proc(console: ^Console) {
    if console.has_selection {
        n := len(console.output.buf)
        lo := clamp(min(console.sel_anchor, console.sel_cursor), 0, n)
        hi := clamp(max(console.sel_anchor, console.sel_cursor), 0, n)
        if hi > lo {
            rl.SetClipboardText(
                strings.clone_to_cstring(
                    string(console.output.buf[lo:hi]),
                    context.temp_allocator,
                ),
            )
            return
        }
    }
    thor_console_copy_all(console)
}

// Pastes the system clipboard into the input line. Newlines are dropped since
// the prompt is single-line.
thor_console_paste :: proc(console: ^Console) {
    clip := rl.GetClipboardText()
    if clip == nil {
        return
    }
    for b in transmute([]u8)string(clip) {
        if b == '\n' || b == '\r' {
            continue
        }
        append(&console.input, b)
    }
}

// Appends text to the scrollback. The view follows only while `autoscroll`
// holds, so output cannot pull the user out of the scrollback being read.
// Control bytes are resolved here, since output straight off a shell carries
// them: a CR before a newline is dropped, a bare CR rewinds to the start of the
// line the way a progress bar expects, and an escape sequence is removed because
// the console draws plain text.
thor_console_append :: proc(console: ^Console, text: string) {
    data := transmute([]u8)text
    // A CRLF split across two chunks: the CR was held back last time.
    if console.pending_cr && len(data) > 0 {
        console.pending_cr = false
        if data[0] == '\n' {
            strings.write_byte(&console.output, '\n')
            data = data[1:]
        } else {
            console_rewind_line(console)
        }
    }

    for i := 0; i < len(data); {
        b := data[i]
        switch {
        case b == '\r':
            if i + 1 >= len(data) {
                console.pending_cr = true
            } else if data[i + 1] == '\n' {
                strings.write_byte(&console.output, '\n')
                i += 1
            } else {
                console_rewind_line(console)
            }
            i += 1
        case b == 0x1b:
            i += console_escape_length(data[i:])
        case b < 32 && b != '\n' && b != '\t':
            i += 1
        case:
            strings.write_byte(&console.output, b)
            i += 1
        }
    }
}

// Runs `command` as if it had been typed at the prompt. False when a command is
// already running or `command` is empty, so a task cannot land in the middle of
// another one's output.
thor_console_run_command :: proc(console: ^Console, command: string) -> bool {
    if console.running || command == "" {
        return false
    }
    console_submit(console, command)
    return true
}

// Called by the owner when a command finishes so the prompt returns to normal.
// The view stays where it is: the user may be reading what the command wrote,
// and the end of it is no reason to move.
thor_console_command_finished :: proc(console: ^Console) {
    console.running = false
}

// Records a command for the arrow keys, dropping an empty line and a repeat of
// the newest entry.
thor_console_history_add :: proc(console: ^Console, command: string) {
    if command != "" &&
       (len(console.history) == 0 || console.history[len(console.history) - 1] != command) {
        append(&console.history, strings.clone(command))
    }
    console.history_index = len(console.history)
}

// ---- the scrollback index ---------------------------------------------------------

// Indexes the bytes appended since the last call. Every reader of a line calls
// it first; the writers only call it before they shorten the buffer, which is
// the one case the incremental scan cannot see.
@(private = "file")
console_index_lines :: proc(console: ^Console) {
    buf := console.output.buf[:]
    for i := console.indexed_len; i < len(buf); i += 1 {
        if buf[i] == '\n' {
            append(&console.line_starts, i + 1)
        }
    }
    console.indexed_len = len(buf)
}

// Number of scrollback lines; a trailing newline ends an empty last line.
@(private = "file")
console_line_count :: proc(console: ^Console) -> int {
    console_index_lines(console)
    return len(console.line_starts)
}

// Line `index` without its newline, borrowed until the next append or clear.
// The index must be in range and the line index current.
@(private = "file")
console_line_text :: proc(console: ^Console, index: int) -> string {
    buf := console.output.buf[:]
    end := len(buf)
    if index + 1 < len(console.line_starts) {
        end = console.line_starts[index + 1] - 1
    }
    return string(buf[console.line_starts[index]:end])
}

// Drops the last line back to its start, for a carriage return that rewrites it.
@(private = "file")
console_rewind_line :: proc(console: ^Console) {
    console_index_lines(console)
    buf := &console.output.buf
    n := len(buf)
    for n > 0 && buf[n - 1] != '\n' {
        n -= 1
    }
    resize(buf, n)
    for len(console.line_starts) > 1 && console.line_starts[len(console.line_starts) - 1] > n {
        pop(&console.line_starts)
    }
    console.indexed_len = n
}

// Length of the escape sequence at the front of `data`. A sequence cut off by
// the end of the chunk takes the rest of it.
@(private = "file")
console_escape_length :: proc(data: []u8) -> int {
    if len(data) < 2 {
        return len(data)
    }
    switch data[1] {
    case '[': // CSI: parameters, then a final byte in 0x40..0x7E
        for i := 2; i < len(data); i += 1 {
            if data[i] >= 0x40 && data[i] <= 0x7e {
                return i + 1
            }
        }
        return len(data)
    case ']': // OSC: a string ended by BEL or ESC backslash
        for i := 2; i < len(data); i += 1 {
            if data[i] == 0x07 {
                return i + 1
            }
            if data[i] == 0x1b && i + 1 < len(data) && data[i + 1] == '\\' {
                return i + 2
            }
        }
        return len(data)
    }
    return 2
}

// Echoes `command` on a prompt line and hands it to the owner's runner. An empty
// line is echoed too: a running command may be waiting on one.
@(private = "file")
console_submit :: proc(console: ^Console, command: string) {
    strings.write_string(&console.output, console.prompt)
    strings.write_string(&console.output, command)
    strings.write_byte(&console.output, '\n')
    console.autoscroll = true
    thor_console_history_add(console, command)
    if console.on_run != nil {
        console.running = true
        console.on_run(console.run_data, command)
    }
}

// Replaces the input line with the history entry at `index`, where len(history)
// means the empty live line.
@(private = "file")
console_history_show :: proc(console: ^Console, index: int) {
    console.history_index = clamp(index, 0, len(console.history))
    clear(&console.input)
    if console.history_index < len(console.history) {
        append(&console.input, console.history[console.history_index])
    }
}

// ---- the view ------------------------------------------------------------------------

thor_console_view :: proc(thor: ^Thor, console: ^Console) {
    ui.scope(
        {
            key = "console",
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                bg = thor.theme.background,
            },
        },
    )

    console_scrollback(thor, console)
    console_prompt(thor, console)
}

@(private = "file")
console_row_props :: proc(thor: ^Thor, console: ^Console) -> ui.Props {
    return ui.Props {
        w = ui.Grow(1),
        h = ui.Px(f32(font.line_height(console.font_size))),
        font = thor.font_mono,
        font_size = f32(console.font_size),
        color = thor.theme.primary_text_color,
        text_wrap = .None,
    }
}

@(private = "file")
console_scrollback :: proc(thor: ^Thor, console: ^Console) {
    count := console_line_count(console)
    row_h := f32(font.line_height(console.font_size))

    view := ui.scope(
        {
            key = "scrollback",
            flags = {.Clip, .Scroll_Y, .Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                pad = ui.xy(CONSOLE_PAD_X, CONSOLE_PAD_Y),
            },
        },
    )

    // A wheel is the user taking over: output stops pulling the view down until
    // the scroll returns to the bottom.
    if view.wheel.y != 0 {
        console.autoscroll = false
    }
    if console.autoscroll && view.node != nil {
        ui.set_scroll(view.node, .Y, max(f32(count) * row_h - view.rect.h, 0))
    }

    if view.right_clicked {
        thor_console_context_menu(thor, ui.mouse_pos())
    }

    lo, hi := 0, 0
    if console.has_selection {
        lo = min(console.sel_anchor, console.sel_cursor)
        hi = max(console.sel_anchor, console.sel_cursor)
    }

    first, last := ui.virtual(count, row_h)
    defer ui.end_virtual()

    for index in first ..< last {
        line := console_line_text(console, index)
        start := console.line_starts[index]

        props := console_row_props(thor, console)
        spans: []ui.Text_Span
        if link_start, link_end, ok := console_link_span(console, line); ok {
            runs := make([]ui.Text_Span, 1, context.temp_allocator)
            runs[0] = {start = link_start, end = link_end, color = thor.theme.info_color}
            spans = runs
            props.cursor = .Pointer
        }

        ui.push_id_int(i64(index))
        row := ui.begin(
            {key = "line", text = line, spans = spans, flags = {.Clickable}, props = props},
        )
        // The selection band sits under the text, in row-local coordinates.
        if hi > lo && hi > start && lo < start + len(line) {
            a := clamp(lo - start, 0, len(line))
            b := clamp(hi - start, 0, len(line))
            if b > a {
                x0 := ui.caret_x(line, a, props)
                x1 := ui.caret_x(line, b, props)
                ui.paint_rect({x0, 0, max(x1 - x0, 2), row_h}, thor.theme.selection_background)
            }
        }
        ui.end()
        ui.pop_id()

        console_row_input(console, row, index, line, start, props)
    }
}

// Press, drag and click on one scrollback row: character-level selection, and a
// click on a link line that carries no selection opens it.
@(private = "file")
console_row_input :: proc(
    console: ^Console,
    row: ui.Interaction,
    index: int,
    line: string,
    start: int,
    props: ui.Props,
) {
    if row.pressed {
        at := start + ui.offset_at(line, ui.mouse_pos().x - row.rect.x, props)
        console.sel_anchor = at
        console.sel_cursor = at
        console.has_selection = false
        console.selecting = true
    }
    if console.selecting && row.dragging {
        console.sel_cursor = start + ui.offset_at(line, ui.mouse_pos().x - row.rect.x, props)
        console.has_selection = console.sel_cursor != console.sel_anchor
    }
    if row.released {
        console.selecting = false
    }
    if row.clicked && !console.has_selection {
        console_activate_link(console, line)
    }
    _ = index
}

@(private = "file")
console_link_span :: proc(console: ^Console, line: string) -> (start, end: int, ok: bool) {
    if console.on_link == nil {
        return 0, 0, false
    }
    return console.on_link(console.link_data, line)
}

@(private = "file")
console_activate_link :: proc(console: ^Console, line: string) {
    if console.on_activate == nil {
        return
    }
    if _, _, ok := console_link_span(console, line); ok {
        console.on_activate(console.link_data, line)
    }
}

@(private = "file")
console_prompt :: proc(thor: ^Thor, console: ^Console) {
    ui.scope(
        {
            key = "prompt",
            props = {
                w = ui.Grow(1),
                h = ui.FIT,
                dir = .Row,
                align = .Center,
                gap = {0, 0},
                pad = ui.xy(CONSOLE_PAD_X, 6),
                border = {width = {t = 1}, color = thor.theme.border},
            },
        },
    )

    ui.label(
        console.prompt,
        {
            key = "sigil",
            props = {
                color = console.running ? thor.theme.disabled : thor.theme.accent_color,
                font = thor.font_mono,
                font_size = f32(console.font_size),
                text_wrap = .None,
            },
        },
    )

    it := ui.input(
        &console.input,
        {
            key = "line",
            props = {
                bg = ui.Color{0, 0, 0, 0},
                border = {},
                pad = {},
                font = thor.font_mono,
                font_size = f32(console.font_size),
                color = thor.theme.foreground,
            },
        },
    )
    if console.focus_pending {
        ui.set_focus(it.id)
        console.focus_pending = false
    }
    if !it.focused {
        return
    }

    if ui.take_key(.Enter) || ui.take_key(.Pad_Enter) {
        command := strings.clone(string(console.input[:]), context.temp_allocator)
        clear(&console.input)
        console_submit(console, command)
    }
    if ui.take_key(.Up) {
        console_history_show(console, console.history_index - 1)
    }
    if ui.take_key(.Down) {
        console_history_show(console, console.history_index + 1)
    }
    // Ctrl+C stops a running command; with nothing running it copies, which is
    // what the same chord does everywhere else.
    if ui.take_key(.C, {.Ctrl}) {
        if console.running && console.on_interrupt != nil {
            console.on_interrupt(console.interrupt_data)
        } else {
            thor_console_copy(console)
        }
    }
    if ui.take_key(.V, {.Ctrl}) {
        thor_console_paste(console)
    }
}
