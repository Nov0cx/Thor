package widgets

import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../ui"

// Called on Enter with a non-empty command; the command runs elsewhere and
// output arrives via console_append.
Console_Run_Proc :: #type proc(data: rawptr, command: string)

// Scrollback pane plus a prompt line. Echoes input to on_run and displays
// whatever text is fed back through console_append; it runs nothing itself.
Console :: struct {
    using widget: ui.Widget,
    output:           strings.Builder,
    input:            [dynamic]u8,
    scroll_y:         f32,
    // Sticks the view to the bottom until the user scrolls up.
    autoscroll:       bool,
    // A command is running; the prompt shows a busy hint and input is ignored.
    running:          bool,
    font_size:        i32,
    prompt:           string,
    on_run:           Console_Run_Proc,
    run_data:         rawptr,
    text_color:       rl.Color,
    prompt_color:     rl.Color,
    background_color: rl.Color,
    caret_color:      rl.Color,
    // Right-click opens a context menu supplied by the owner.
    on_context_menu:   Context_Menu_Proc,
    context_menu_data: rawptr,
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
// are dropped since the prompt is single-line; ignored while a command runs.
console_input_append :: proc(console: ^Console, text: string) {
    if console.running {
        return
    }
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
    console.autoscroll = true
    console.font_size = 15
    console.prompt = "> "
    console.text_color = rl.Color {200, 205, 215, 255}
    console.prompt_color = rl.Color {132, 255, 255, 255}
    console.background_color = rl.Color {18, 20, 30, 255}
    console.caret_color = rl.Color {132, 255, 255, 255}
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

// Appends text to the scrollback and re-pins the view to the bottom.
console_append :: proc(console: ^Console, text: string) {
    strings.write_string(&console.output, text)
    console.autoscroll = true
}

// Called by the owner when a command finishes so the prompt returns to normal.
console_command_finished :: proc(console: ^Console) {
    console.running = false
    console.autoscroll = true
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
    case .Scroll:
        console.scroll_y -= event.wheel_delta * console_line_height(console) * 2
        console.autoscroll = false
        if console.scroll_y < 0 {
            console.scroll_y = 0
        }
        return true
    case .Text_Input:
        if console.running || (event.ctrl && !event.alt) {
            return true
        }
        if event.codepoint >= 32 && event.codepoint != 127 {
            buffer, width := utf8.encode_rune(event.codepoint)
            append(&console.input, ..buffer[:width])
        }
        return true
    case .Key_Press:
        #partial switch event.key {
        case .ENTER, .KP_ENTER:
            if console.running {
                return true
            }
            command := string(console.input[:])
            strings.write_string(&console.output, console.prompt)
            strings.write_string(&console.output, command)
            strings.write_byte(&console.output, '\n')
            console.autoscroll = true
            if command != "" && console.on_run != nil {
                console.running = true
                console.on_run(console.run_data, command)
            }
            clear(&console.input)
            return true
        case .BACKSPACE:
            console_pop_rune(console)
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

    ui.begin_clip(output_rect)
    for line, index in lines {
        y := output_rect.y + pad + cast(f32) index * line_height - console.scroll_y
        if y + line_height < output_rect.y || y > output_rect.y + output_rect.height {
            continue
        }
        ui.draw_text(line, cast(i32) (console.bounds.x + pad), cast(i32) y, console.font_size, console.text_color)
    }
    ui.end_clip()

    // Prompt line pinned to the bottom.
    input_y := console.bounds.y + console.bounds.height - input_height + 4
    prompt := console.running ? "... running" : console.prompt
    prompt_color := console.running ? console.text_color : console.prompt_color
    ui.draw_text(prompt, cast(i32) (console.bounds.x + pad), cast(i32) input_y, console.font_size, prompt_color)

    if !console.running {
        prompt_width := ui.measure_text(console.prompt, console.font_size)
        input_x := cast(i32) (console.bounds.x + pad) + prompt_width
        input := string(console.input[:])
        ui.draw_text(input, input_x, cast(i32) input_y, console.font_size, console.text_color)
        caret_x := input_x + ui.measure_text(input, console.font_size) + 1
        if ctx.focused == widget {
            rl.DrawRectangle(caret_x, cast(i32) input_y, 2, console.font_size, console.caret_color)
        }
    }
}

console_destroy :: proc(widget: ^ui.Widget) {
    console := cast(^Console) widget
    strings.builder_destroy(&console.output)
    delete(console.input)
    free(console)
}
