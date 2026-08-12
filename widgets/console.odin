package widgets

import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../ui"

// Called on Enter with a non-empty command; the command runs elsewhere and
// output arrives via console_append.
Console_Run_Proc :: #type proc(data: rawptr, command: string)

// Tests whether a scrollback line names a navigable source location. Returns the
// byte span [start, end) of the clickable text within the line (for the hover
// underline) and ok when the line is a link. The owner does the parsing so the
// console stays agnostic about path/error formats.
Console_Link_Proc :: #type proc(data: rawptr, line: string) -> (start: int, end: int, ok: bool)

// Opens the source location named by a clicked scrollback line.
Console_Activate_Proc :: #type proc(data: rawptr, line: string)

// Called on Ctrl+C while a command runs, to stop it.
Console_Interrupt_Proc :: #type proc(data: rawptr)

// Scrollback pane plus a prompt line. Echoes input to on_run and displays
// whatever text is fed back through console_append; it runs nothing itself.
Console :: struct {
    using widget: ui.Widget,
    output:           strings.Builder,
    input:            [dynamic]u8,
    // Byte offset into `input`, always on a rune boundary.
    input_caret:      int,
    scroll_y:         f32,
    // Sticks the view to the bottom until the user scrolls up.
    autoscroll:       bool,
    // A command is running. Typing stays open, since a running command may read
    // its own stdin; only the prompt is dimmed.
    running:          bool,
    // A CR ended the last chunk; its newline may still be coming.
    pending_cr:       bool,
    // Byte offset of every scrollback line, first entry 0. Grown incrementally
    // from `indexed_len` so a long log is never rescanned whole. owned
    line_starts:      [dynamic]int,
    // Bytes of `output` the index covers.
    indexed_len:      int,
    // Submitted commands, oldest first, walked with the arrow keys. owned
    history:          [dynamic]string,
    // Position in history while walking; len(history) is the live input line.
    history_index:    int,
    font_size:        i32,
    prompt:           string,
    on_run:           Console_Run_Proc,
    run_data:         rawptr,
    on_interrupt:     Console_Interrupt_Proc,
    interrupt_data:   rawptr,
    text_color:       rl.Color,
    prompt_color:     rl.Color,
    background_color: rl.Color,
    caret_color:      rl.Color,
    // Right-click opens a context menu supplied by the owner.
    on_context_menu:   Context_Menu_Proc,
    context_menu_data: rawptr,
    // Clickable error/location lines: on_link resolves a line to a navigable
    // span (hover affordance + hit test), on_activate opens it on click.
    on_link:           Console_Link_Proc,
    on_activate:       Console_Activate_Proc,
    link_data:         rawptr,
    link_color:        rl.Color,
    // Mouse text selection over the scrollback, as absolute byte offsets into
    // `output`. selecting is true only while a drag that started in the output
    // area (not the input row) is held.
    sel_anchor:    int,
    sel_cursor:    int,
    has_selection: bool,
    selecting:     bool,
}

console_set_on_link :: proc(console: ^Console, on_link: Console_Link_Proc, on_activate: Console_Activate_Proc, data: rawptr) {
    console.on_link = on_link
    console.on_activate = on_activate
    console.link_data = data
}

console_set_on_interrupt :: proc(console: ^Console, on_interrupt: Console_Interrupt_Proc, data: rawptr) {
    console.on_interrupt = on_interrupt
    console.interrupt_data = data
}

console_set_on_context_menu :: proc(console: ^Console, on_context_menu: Context_Menu_Proc, data: rawptr) {
    console.on_context_menu = on_context_menu
    console.context_menu_data = data
}

// Wipes the scrollback and re-pins the view to the bottom.
console_clear :: proc(console: ^Console) {
    strings.builder_reset(&console.output)
    clear(&console.line_starts)
    append(&console.line_starts, 0)
    console.indexed_len = 0
    console.scroll_y = 0
    console.autoscroll = true
    console.has_selection = false
}

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

// Line `index` without its newline (borrowed; valid until the next
// append/clear). The index must be in range and the line index current.
@(private = "file")
console_line_text :: proc(console: ^Console, index: int) -> string {
    buf := console.output.buf[:]
    end := len(buf)
    if index + 1 < len(console.line_starts) {
        end = console.line_starts[index + 1] - 1
    }
    return string(buf[console.line_starts[index]:end])
}

// The full scrollback text (borrowed; valid until the next append/clear).
console_text :: proc(console: ^Console) -> string {
    return strings.to_string(console.output)
}

// Inserts UTF-8 text at the caret (used by the paste action). Newlines are
// dropped since the prompt is single-line.
console_input_append :: proc(console: ^Console, text: string) {
    filtered := make([dynamic]u8, 0, len(text), context.temp_allocator)
    for b in transmute([]u8) text {
        if b == '\n' || b == '\r' {
            continue
        }
        append(&filtered, b)
    }
    if len(filtered) == 0 {
        return
    }
    console.input_caret = clamp(console.input_caret, 0, len(console.input))
    inject_at(&console.input, console.input_caret, ..filtered[:])
    console.input_caret += len(filtered)
}

// Copies the whole scrollback to the system clipboard, selection or not.
console_copy_all :: proc(console: ^Console) {
    text := console_text(console)
    if text != "" {
        rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
    }
}

// Copies the selected text, or the whole scrollback when nothing is selected.
console_copy :: proc(console: ^Console) {
    if console.has_selection {
        lo := clamp(min(console.sel_anchor, console.sel_cursor), 0, len(console.output.buf))
        hi := clamp(max(console.sel_anchor, console.sel_cursor), 0, len(console.output.buf))
        if hi > lo {
            rl.SetClipboardText(strings.clone_to_cstring(string(console.output.buf[lo:hi]), context.temp_allocator))
            return
        }
    }
    console_copy_all(console)
}

console_has_selection :: proc(console: ^Console) -> bool {
    return console.has_selection
}

// Pastes the system clipboard into the input line.
console_paste :: proc(console: ^Console) {
    if clip := rl.GetClipboardText(); clip != nil {
        console_input_append(console, string(clip))
    }
}

console_vtable := ui.Widget_VTable {
    layout = nil,
    handle_event = console_handle_event,
    draw = console_draw,
    destroy = console_destroy,
}

console_create :: proc(id: string) -> ^Console {
    console := new(Console)
    ui.widget_init(&console.widget, id, console_vtable)
    console.output = strings.builder_make()
    console.line_starts = make([dynamic]int)
    append(&console.line_starts, 0)
    console.input = make([dynamic]u8)
    console.history = make([dynamic]string)
    console.autoscroll = true
    console.font_size = 15
    console.prompt = "> "
    console.text_color = rl.Color {200, 205, 215, 255}
    console.prompt_color = rl.Color {132, 255, 255, 255}
    console.background_color = rl.Color {18, 20, 30, 255}
    console.caret_color = rl.Color {132, 255, 255, 255}
    console.link_color = rl.Color {120, 180, 255, 255}
    console.min_size = rl.Vector2 {0, 110}
    strings.write_string(&console.output, "Thor console — type a command and press Enter.\n")
    return console
}

console_set_colors :: proc(console: ^Console, text, prompt, background, caret: rl.Color) -> ^Console {
    console.text_color = text
    console.prompt_color = prompt
    console.background_color = background
    console.caret_color = caret
    return console
}

console_set_on_run :: proc(console: ^Console, on_run: Console_Run_Proc, data: rawptr) {
    console.on_run = on_run
    console.run_data = data
}

console_set_link_color :: proc(console: ^Console, color: rl.Color) {
    console.link_color = color
}

// Maps a point to a scrollback line index, or -1 when it falls outside the
// output area (the prompt line, or off the widget). Mirrors console_draw's
// geometry so hover and click hit-test exactly what is drawn.
@(private = "file")
console_line_index_at :: proc(console: ^Console, pos: rl.Vector2) -> int {
    line_height := console_line_height(console)
    pad: f32 = CONSOLE_PAD_Y
    output_bottom := console.bounds.y + console.bounds.height - console_input_height(console)
    if pos.x < console.bounds.x || pos.x >= console.bounds.x + console.bounds.width {
        return -1
    }
    if pos.y < console.bounds.y || pos.y >= output_bottom {
        return -1
    }
    rel := pos.y - (console.bounds.y + pad) + console.scroll_y
    if rel < 0 {
        return -1
    }
    return cast(int) (rel / line_height)
}

// Byte offset in `output` nearest a screen position, for text selection. The
// line index is clamped to the scrollback range so a drag that leaves the
// output area (above the first line, or past the last) still extends sensibly.
@(private = "file")
console_pos_at :: proc(console: ^Console, position: rl.Vector2) -> int {
    line_count := console_line_count(console)
    if line_count == 0 {
        return 0
    }
    line_height := console_line_height(console)
    rel := position.y - (console.bounds.y + CONSOLE_PAD_Y) + console.scroll_y
    index := clamp(cast(int) (rel / line_height), 0, line_count - 1)
    line := console_line_text(console, index)
    target_x := position.x - (console.bounds.x + CONSOLE_PAD_X)

    // Rune-boundary byte offsets in the line, so the hit test below can binary
    // search instead of re-measuring the growing prefix at every byte — this
    // was O(line length squared) with a long unwrapped line.
    rune_count := utf8.rune_count_in_string(line)
    boundaries := make([]int, rune_count + 1, context.temp_allocator)
    p := 0
    for i := 1; i <= rune_count; i += 1 {
        _, width := utf8.decode_rune_in_string(line[p:])
        p += width
        boundaries[i] = p
    }

    lo, hi := 0, rune_count
    for lo < hi {
        mid := (lo + hi) / 2
        before := cast(f32) ui.measure_text(line[:boundaries[mid]], console.font_size)
        after := cast(f32) ui.measure_text(line[:boundaries[mid + 1]], console.font_size)
        if target_x < (before + after) / 2 {
            hi = mid
        } else {
            lo = mid + 1
        }
    }
    return console.line_starts[index] + boundaries[lo]
}

// The scrollback line at `index` (borrowed; valid until the next append/clear),
// or ok=false when the index is out of range.
@(private)
console_line_at :: proc(console: ^Console, index: int) -> (string, bool) {
    if index < 0 || index >= console_line_count(console) {
        return "", false
    }
    return console_line_text(console, index), true
}

// Fires the owner's activate callback if the line under `pos` resolves to a link.
@(private = "file")
console_try_activate :: proc(console: ^Console, pos: rl.Vector2) -> bool {
    if console.on_link == nil || console.on_activate == nil {
        return false
    }
    line, ok := console_line_at(console, console_line_index_at(console, pos))
    if !ok {
        return false
    }
    if _, _, is_link := console.on_link(console.link_data, line); is_link {
        console.on_activate(console.link_data, line)
        return true
    }
    return false
}

// Appends text to the scrollback and re-pins the view to the bottom. Control
// bytes are resolved here, since output that comes straight off a shell carries
// them: a CR before a newline is dropped, a bare CR rewinds to the start of the
// line the way a progress bar expects, and an escape sequence is removed because
// the console draws plain text.
console_append :: proc(console: ^Console, text: string) {
    data := transmute([]u8) text
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
    console.autoscroll = true
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
    console_history_add(console, command)
    if console.on_run != nil {
        console.running = true
        console.on_run(console.run_data, command)
    }
}

// Runs `command` as if it had been typed at the prompt. False when a command is
// already running or `command` is empty, so a task cannot land in the middle of
// another one's output.
console_run_command :: proc(console: ^Console, command: string) -> bool {
    if console.running || command == "" {
        return false
    }
    console_submit(console, command)
    return true
}

// Called by the owner when a command finishes so the prompt returns to normal.
console_command_finished :: proc(console: ^Console) {
    console.running = false
    console.autoscroll = true
}

// Records a command for the arrow keys, dropping an empty line and a repeat of
// the newest entry.
console_history_add :: proc(console: ^Console, command: string) {
    if command != "" && (len(console.history) == 0 || console.history[len(console.history) - 1] != command) {
        append(&console.history, strings.clone(command))
    }
    console.history_index = len(console.history)
}

// Replaces the input line with the history entry at `index`, where len(history)
// means the empty live line.
console_history_show :: proc(console: ^Console, index: int) {
    console.history_index = clamp(index, 0, len(console.history))
    clear(&console.input)
    if console.history_index < len(console.history) {
        append(&console.input, ..transmute([]u8) console.history[console.history_index])
    }
    console.input_caret = len(console.input)
}

@(private = "file")
console_line_height :: proc(console: ^Console) -> f32 {
    return cast(f32) ui.text_line_height(console.font_size)
}

@(private = "file")
CONSOLE_PAD_X :: 12
@(private = "file")
CONSOLE_PAD_Y :: 8

// Height of the input row pinned to the bottom, separator included.
@(private = "file")
console_input_height :: proc(console: ^Console) -> f32 {
    return console_line_height(console) + 14
}

// Left edge of the input text, past the prompt. Shared by the draw and the
// click hit test so the two cannot drift.
@(private = "file")
console_input_origin :: proc(console: ^Console) -> f32 {
    return console.bounds.x + CONSOLE_PAD_X + cast(f32) ui.measure_text(console.prompt, console.font_size)
}

// Scroll offset that puts the last line at the bottom of the output area. The
// view stops there, so the scrollback never scrolls into blank space.
@(private = "file")
console_max_scroll :: proc(console: ^Console) -> f32 {
    content_height := cast(f32) console_line_count(console) * console_line_height(console)
    return max(0, content_height - (console.bounds.height - console_input_height(console)))
}

console_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    console := cast(^Console) widget

    #partial switch event.kind {
    case .Mouse_Down:
        if event.mouse_button == .RIGHT {
            if console.on_context_menu != nil {
                console.on_context_menu(console.context_menu_data, event.mouse_position)
            }
            return true
        }
        // A drag that starts in the scrollback selects text; the input row
        // ignores it, so clicking there just moves focus and clears any selection.
        output_bottom := console.bounds.y + console.bounds.height - console_input_height(console)
        console.selecting = event.mouse_position.y < output_bottom
        console.has_selection = false
        if console.selecting {
            console.sel_anchor = console_pos_at(console, event.mouse_position)
            console.sel_cursor = console.sel_anchor
        } else {
            console.input_caret = input_caret_at_x(
                string(console.input[:]),
                console_input_origin(console),
                event.mouse_position.x,
                console.font_size,
            )
        }
        return true // take focus so typing goes here
    case .Mouse_Move:
        // Only dispatched here while the button is held (drag), so extend.
        if console.selecting {
            console.sel_cursor = console_pos_at(console, event.mouse_position)
            console.has_selection = console.sel_cursor != console.sel_anchor
            return true
        }
    case .Click:
        // A drag that produced a selection is not a link click.
        if event.mouse_button == .LEFT && !console.has_selection {
            console_try_activate(console, event.mouse_position)
        }
        return true
    case .Scroll:
        max_scroll := console_max_scroll(console)
        console.scroll_y = clamp(console.scroll_y - event.wheel_delta * console_line_height(console) * 2, 0, max_scroll)
        // Following new output resumes once the view is back at the last line.
        console.autoscroll = console.scroll_y >= max_scroll
        return true
    case .Text_Input:
        if event.ctrl && !event.alt {
            return true
        }
        if event.codepoint >= 32 && event.codepoint != 127 {
            buffer, width := utf8.encode_rune(event.codepoint)
            console.input_caret = clamp(console.input_caret, 0, len(console.input))
            inject_at(&console.input, console.input_caret, ..buffer[:width])
            console.input_caret += width
        }
        return true
    case .Key_Press:
        // Ctrl+C stops the command instead of copying, the way a terminal does.
        // Copy is Ctrl+Shift+C instead, so it works whether or not one is running.
        if event.ctrl && event.key == .C {
            if event.shift {
                console_copy(console)
                return true
            }
            if console.running && console.on_interrupt != nil {
                console.on_interrupt(console.interrupt_data)
                return true
            }
            return false
        }
        if event.ctrl && event.key == .V {
            console_paste(console)
            return true
        }
        console.input_caret = clamp(console.input_caret, 0, len(console.input))
        input := string(console.input[:])
        #partial switch event.key {
        case .ENTER, .KP_ENTER:
            console_submit(console, input)
            clear(&console.input)
            console.input_caret = 0
            return true
        case .BACKSPACE:
            console_pop_rune(console)
            return true
        case .DELETE:
            if end := input_next_rune(input, console.input_caret); end > console.input_caret {
                remove_range(&console.input, console.input_caret, end)
            }
            return true
        case .LEFT:
            console.input_caret = input_prev_rune(input, console.input_caret)
            return true
        case .RIGHT:
            console.input_caret = input_next_rune(input, console.input_caret)
            return true
        case .HOME:
            console.input_caret = 0
            return true
        case .END:
            console.input_caret = len(console.input)
            return true
        case .UP:
            console_history_show(console, console.history_index - 1)
            return true
        case .DOWN:
            console_history_show(console, console.history_index + 1)
            return true
        }
    }
    return false
}

// Backspace: removes the rune before the caret.
@(private = "file")
console_pop_rune :: proc(console: ^Console) {
    input := string(console.input[:])
    if start := input_prev_rune(input, console.input_caret); start < console.input_caret {
        remove_range(&console.input, start, console.input_caret)
        console.input_caret = start
    }
}

console_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    console := cast(^Console) widget

    rl.DrawRectangleRec(console.bounds, console.background_color)

    line_height := console_line_height(console)
    pad: f32 = CONSOLE_PAD_Y
    input_height := console_input_height(console)
    output_rect := rl.Rectangle {
        x = console.bounds.x,
        y = console.bounds.y,
        width = console.bounds.width,
        height = console.bounds.height - input_height,
    }

    line_count := console_line_count(console)
    content_height := cast(f32) line_count * line_height
    // Output that shrinks (a rewound line, a clear) can leave a stale offset past
    // the end, so the clamp runs whether or not the view is following.
    max_scroll := max(0, content_height - output_rect.height)
    console.scroll_y = console.autoscroll ? max_scroll : clamp(console.scroll_y, 0, max_scroll)

    // The scrollback line under the cursor, tested for a navigable link so it can
    // be highlighted and underlined.
    hover_index := -1
    if console.on_link != nil && ctx.hot == widget {
        hover_index = console_line_index_at(console, ctx.mouse_pos)
    }

    // Only the lines the output area shows are drawn, so scrollback length costs
    // nothing per frame.
    first := max(0, cast(int) (max(0, console.scroll_y - pad) / line_height) - 1)
    last := min(line_count - 1, cast(int) ((console.scroll_y - pad + output_rect.height) / line_height) + 1)

    sel_lo, sel_hi := 0, 0
    if console.has_selection {
        sel_lo = min(console.sel_anchor, console.sel_cursor)
        sel_hi = max(console.sel_anchor, console.sel_cursor)
    }
    selection_color := rl.Color {console.caret_color.r, console.caret_color.g, console.caret_color.b, 60}

    ui.begin_clip(output_rect)
    for index := first; index <= last; index += 1 {
        y := output_rect.y + pad + cast(f32) index * line_height - console.scroll_y
        if y + line_height < output_rect.y || y > output_rect.y + output_rect.height {
            continue
        }
        line := console_line_text(console, index)
        if console.has_selection {
            line_start := console.line_starts[index]
            lo := clamp(sel_lo - line_start, 0, len(line))
            hi := clamp(sel_hi - line_start, 0, len(line))
            if lo < hi {
                prefix_w := ui.measure_text(line[:lo], console.font_size)
                span_w := ui.measure_text(line[lo:hi], console.font_size)
                sx := cast(i32) (console.bounds.x + CONSOLE_PAD_X) + prefix_w
                rl.DrawRectangle(sx, cast(i32) y, span_w, cast(i32) line_height, selection_color)
            }
        }
        color := console.text_color
        if index == hover_index {
            if s, e, ok := console.on_link(console.link_data, line); ok {
                color = console.link_color
                s = clamp(s, 0, len(line))
                e = clamp(e, s, len(line))
                prefix_w := ui.measure_text(line[:s], console.font_size)
                span_w := ui.measure_text(line[s:e], console.font_size)
                ux := cast(i32) (console.bounds.x + CONSOLE_PAD_X) + prefix_w
                rl.DrawRectangle(ux, cast(i32) y + console.font_size, span_w, 1, console.link_color)
            }
        }
        ui.draw_text(line, cast(i32) (console.bounds.x + CONSOLE_PAD_X), cast(i32) y, console.font_size, color)
    }
    ui.end_clip()

    // Input row pinned to the bottom, marked off from the scrollback by a hairline.
    // It stays editable while a command runs, with the prompt dimmed, since the
    // command may be reading stdin.
    input_top := console.bounds.y + console.bounds.height - input_height
    rule := console.text_color
    rule.a = 36
    rl.DrawRectangle(cast(i32) console.bounds.x, cast(i32) input_top, cast(i32) console.bounds.width, 1, rule)

    input_y := input_top + (input_height - cast(f32) console.font_size) * 0.5
    prompt_color := console.running ? console.text_color : console.prompt_color
    ui.draw_text(console.prompt, cast(i32) (console.bounds.x + CONSOLE_PAD_X), cast(i32) input_y, console.font_size, prompt_color)

    input_x := cast(i32) console_input_origin(console)
    input := string(console.input[:])
    ui.draw_text(input, input_x, cast(i32) input_y, console.font_size, console.text_color)
    caret := clamp(console.input_caret, 0, len(input))
    caret_x := input_x + ui.measure_text(input[:caret], console.font_size) + 1
    if ctx.focused == widget {
        rl.DrawRectangle(caret_x, cast(i32) input_y, 2, console.font_size, console.caret_color)
    }
}

console_destroy :: proc(widget: ^ui.Widget) {
    console := cast(^Console) widget
    strings.builder_destroy(&console.output)
    delete(console.line_starts)
    delete(console.input)
    for command in console.history {
        delete(command)
    }
    delete(console.history)
    free(console)
}
