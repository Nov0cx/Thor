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
    scroll_y:         f32,
    // Sticks the view to the bottom until the user scrolls up.
    autoscroll:       bool,
    // A command is running. Typing stays open, since a running command may read
    // its own stdin; only the prompt is dimmed.
    running:          bool,
    // A CR ended the last chunk; its newline may still be coming.
    pending_cr:       bool,
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
    console.scroll_y = 0
    console.autoscroll = true
}

// The full scrollback text (borrowed; valid until the next append/clear).
console_text :: proc(console: ^Console) -> string {
    return strings.to_string(console.output)
}

// Appends UTF-8 text to the input line (used by the paste action). Newlines
// are dropped since the prompt is single-line.
console_input_append :: proc(console: ^Console, text: string) {
    for b in transmute([]u8) text {
        if b == '\n' || b == '\r' {
            continue
        }
        append(&console.input, b)
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
    pad: f32 = 8
    input_height := line_height + 8
    output_bottom := console.bounds.y + console.bounds.height - input_height
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

// The scrollback line at `index` (borrowed, temp-allocated split), or ok=false
// when the index is out of range.
@(private = "file")
console_line_at :: proc(console: ^Console, index: int) -> (string, bool) {
    if index < 0 {
        return "", false
    }
    lines := strings.split(strings.to_string(console.output), "\n", context.temp_allocator)
    if index >= len(lines) {
        return "", false
    }
    return lines[index], true
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
    buf := &console.output.buf
    n := len(buf)
    for n > 0 && buf[n - 1] != '\n' {
        n -= 1
    }
    resize(buf, n)
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
}

@(private = "file")
console_line_height :: proc(console: ^Console) -> f32 {
    return cast(f32) ui.text_line_height(console.font_size)
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
        return true // take focus so typing goes here
    case .Click:
        if event.mouse_button == .LEFT {
            console_try_activate(console, event.mouse_position)
        }
        return true
    case .Scroll:
        console.scroll_y -= event.wheel_delta * console_line_height(console) * 2
        console.autoscroll = false
        if console.scroll_y < 0 {
            console.scroll_y = 0
        }
        return true
    case .Text_Input:
        if event.ctrl && !event.alt {
            return true
        }
        if event.codepoint >= 32 && event.codepoint != 127 {
            buffer, width := utf8.encode_rune(event.codepoint)
            append(&console.input, ..buffer[:width])
        }
        return true
    case .Key_Press:
        // Ctrl+C stops the command instead of copying, the way a terminal does.
        if event.ctrl && event.key == .C {
            if console.running && console.on_interrupt != nil {
                console.on_interrupt(console.interrupt_data)
                return true
            }
            return false
        }
        #partial switch event.key {
        case .ENTER, .KP_ENTER:
            console_submit(console, string(console.input[:]))
            clear(&console.input)
            return true
        case .BACKSPACE:
            console_pop_rune(console)
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

@(private = "file")
console_pop_rune :: proc(console: ^Console) {
    n := len(console.input)
    if n == 0 {
        return
    }
    i := n - 1
    for i > 0 && (console.input[i] & 0xC0) == 0x80 {
        i -= 1
    }
    resize(&console.input, i)
}

console_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    console := cast(^Console) widget

    rl.DrawRectangleRec(console.bounds, console.background_color)

    line_height := console_line_height(console)
    pad: f32 = 8
    input_height := line_height + 8
    output_rect := rl.Rectangle {
        x = console.bounds.x,
        y = console.bounds.y,
        width = console.bounds.width,
        height = console.bounds.height - input_height,
    }

    lines := strings.split(strings.to_string(console.output), "\n", context.temp_allocator)
    content_height := cast(f32) len(lines) * line_height
    if console.autoscroll {
        console.scroll_y = max(0, content_height - output_rect.height)
    }

    // The scrollback line under the cursor, tested for a navigable link so it can
    // be highlighted and underlined.
    hover_index := -1
    if console.on_link != nil && ctx.hot == widget {
        hover_index = console_line_index_at(console, ctx.mouse_pos)
    }

    ui.begin_clip(output_rect)
    for line, index in lines {
        y := output_rect.y + pad + cast(f32) index * line_height - console.scroll_y
        if y + line_height < output_rect.y || y > output_rect.y + output_rect.height {
            continue
        }
        color := console.text_color
        if index == hover_index {
            if s, e, ok := console.on_link(console.link_data, line); ok {
                color = console.link_color
                s = clamp(s, 0, len(line))
                e = clamp(e, s, len(line))
                prefix_w := ui.measure_text(line[:s], console.font_size)
                span_w := ui.measure_text(line[s:e], console.font_size)
                ux := cast(i32) (console.bounds.x + pad) + prefix_w
                rl.DrawRectangle(ux, cast(i32) y + console.font_size, span_w, 1, console.link_color)
            }
        }
        ui.draw_text(line, cast(i32) (console.bounds.x + pad), cast(i32) y, console.font_size, color)
    }
    ui.end_clip()

    // Prompt line pinned to the bottom. It stays editable while a command runs,
    // dimmed, since the command may be reading stdin.
    input_y := console.bounds.y + console.bounds.height - input_height + 4
    prompt_color := console.running ? console.text_color : console.prompt_color
    ui.draw_text(console.prompt, cast(i32) (console.bounds.x + pad), cast(i32) input_y, console.font_size, prompt_color)

    prompt_width := ui.measure_text(console.prompt, console.font_size)
    input_x := cast(i32) (console.bounds.x + pad) + prompt_width
    input := string(console.input[:])
    ui.draw_text(input, input_x, cast(i32) input_y, console.font_size, console.text_color)
    caret_x := input_x + ui.measure_text(input, console.font_size) + 1
    if ctx.focused == widget {
        rl.DrawRectangle(caret_x, cast(i32) input_y, 2, console.font_size, console.caret_color)
    }
}

console_destroy :: proc(widget: ^ui.Widget) {
    console := cast(^Console) widget
    strings.builder_destroy(&console.output)
    delete(console.input)
    for command in console.history {
        delete(command)
    }
    delete(console.history)
    free(console)
}
