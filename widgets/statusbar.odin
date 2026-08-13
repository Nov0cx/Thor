package widgets

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

import "../ui"

// Radians per second of the busy segment's alpha pulse.
BUSY_PULSE_RATE :: 4.0

Status_Info :: struct {
    branch:        string,
    file_name:     string,
    language:      string,
    line:          int,
    column:        int,
    // Spaces per indent level; when indent_spaces is true the segment reads
    // "Spaces: N", otherwise "Tab Size: N". A width of 0 hides the segment.
    indent_width:  int,
    indent_spaces: bool,
    // Editor zoom as a percentage of the configured font size; 0 hides it.
    zoom:          int,
    // On-disk line terminator, "LF" or "CRLF"; empty hides the segment.
    line_ending:   string,
    file_open:     bool,
    modified:      bool,
    saving:        bool,
    // Language-analyzer work in flight, and the label for it ("Analyzing...").
    // The owner delays the flag, so a request that finishes within a few frames
    // never flashes the segment.
    busy:          bool,
    busy_message:  string,
    // Transient notice (e.g. "No definition found"); empty hides it. Drawn in the
    // error color when is_error is set, otherwise the accent color. The owner
    // clears it after a timeout.
    message:       string,
    is_error:      bool,
    // Relative-line jump count the user is typing; jump_active hides the segment
    // when unset, so a pending 0 still shows.
    jump_active:   bool,
    jump_count:    int,
    jump_up:       bool,
}

Status_Proc :: #type proc(data: rawptr) -> Status_Info

Status_Click_Proc :: #type proc(data: rawptr)

// Bottom status bar. Pulls its content from a callback every frame, so it
// never holds stale state.
Statusbar :: struct {
    using widget: ui.Widget,
    info_proc:        Status_Proc,
    data:             rawptr,
    // Clicking the line-ending segment; nil leaves the segment inert.
    on_line_ending:   Status_Click_Proc,
    click_data:       rawptr,
    // Screen rect of the line-ending segment from the last draw, for hit
    // testing. Zeroed on any frame that does not draw it.
    line_ending_bounds: rl.Rectangle,
    font_size:        i32,
    icon_size:        i32,
    text_color:       rl.Color,
    dim_color:        rl.Color,
    background_color: rl.Color,
    accent_color:     rl.Color,
    error_color:      rl.Color,
}

statusbar_vtable := ui.Widget_VTable {
    layout = nil,
    handle_event = statusbar_handle_event,
    draw = statusbar_draw,
    destroy = statusbar_destroy,
}

statusbar_create :: proc(id: string) -> ^Statusbar {
    statusbar := new(Statusbar)
    ui.widget_init(&statusbar.widget, id, statusbar_vtable)
    statusbar.font_size = 15
    statusbar.icon_size = 16
    statusbar.text_color = rl.Color {200, 205, 215, 255}
    statusbar.dim_color = rl.Color {140, 148, 170, 255}
    statusbar.background_color = rl.Color {20, 22, 32, 255}
    statusbar.accent_color = rl.Color {132, 255, 255, 255}
    statusbar.error_color = rl.Color {255, 83, 112, 255}
    statusbar.min_size = rl.Vector2 {0, 28}
    return statusbar
}

statusbar_bind :: proc(statusbar: ^Statusbar, info_proc: Status_Proc, data: rawptr) -> ^Statusbar {
    statusbar.info_proc = info_proc
    statusbar.data = data
    return statusbar
}

statusbar_set_on_line_ending :: proc(statusbar: ^Statusbar, on_click: Status_Click_Proc, data: rawptr) -> ^Statusbar {
    statusbar.on_line_ending = on_click
    statusbar.click_data = data
    return statusbar
}

statusbar_set_colors :: proc(statusbar: ^Statusbar, text, dim, background, accent, error: rl.Color) -> ^Statusbar {
    statusbar.text_color = text
    statusbar.dim_color = dim
    statusbar.background_color = background
    statusbar.accent_color = accent
    statusbar.error_color = error
    return statusbar
}

@(private = "file")
statusbar_draw_segment :: proc(statusbar: ^Statusbar, x: f32, icon: string, text: string, color: rl.Color) -> f32 {
    cursor := x
    icon_y := cast(i32) (statusbar.bounds.y + (statusbar.bounds.height - cast(f32) statusbar.icon_size) * 0.5)
    text_y := cast(i32) (statusbar.bounds.y + (statusbar.bounds.height - cast(f32) statusbar.font_size) * 0.5)

    if icon != "" {
        ui.draw_icon(icon, cast(i32) cursor, icon_y, statusbar.icon_size, color)
        cursor += cast(f32) statusbar.icon_size + 4
    }
    if text != "" {
        ui.draw_text(text, cast(i32) cursor, text_y, statusbar.font_size, color)
        cursor += cast(f32) ui.measure_text(text, statusbar.font_size)
    }
    return cursor + 18
}

@(private = "file")
statusbar_segment_width :: proc(statusbar: ^Statusbar, icon: string, text: string) -> f32 {
    width: f32 = 0
    if icon != "" {
        width += cast(f32) statusbar.icon_size + 4
    }
    if text != "" {
        width += cast(f32) ui.measure_text(text, statusbar.font_size)
    }
    return width + 18
}

// Click on the line-ending segment: the only interactive part of the bar.
statusbar_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    statusbar := cast(^Statusbar) widget

    if event.kind == .Click && statusbar.on_line_ending != nil &&
       rl.CheckCollisionPointRec(event.mouse_position, statusbar.line_ending_bounds) {
        statusbar.on_line_ending(statusbar.click_data)
        return true
    }
    return false
}

statusbar_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    statusbar := cast(^Statusbar) widget

    rl.DrawRectangleRec(statusbar.bounds, statusbar.background_color)
    statusbar.line_ending_bounds = {}

    if statusbar.info_proc == nil {
        return
    }
    info := statusbar.info_proc(statusbar.data)

    ui.begin_clip(statusbar.bounds)
    defer ui.end_clip()

    // Left side: branch, file, save state.
    x := statusbar.bounds.x + 12
    if info.branch != "" {
        x = statusbar_draw_segment(statusbar, x, "git-branch", info.branch, statusbar.text_color)
    }
    if info.file_open {
        x = statusbar_draw_segment(statusbar, x, "file", info.file_name, statusbar.text_color)

        if info.saving {
            x = statusbar_draw_segment(statusbar, x, "device-floppy", "Saving...", statusbar.dim_color)
        } else if info.modified {
            x = statusbar_draw_segment(statusbar, x, "point", "Unsaved", statusbar.dim_color)
        } else {
            x = statusbar_draw_segment(statusbar, x, "circle-check", "Saved", statusbar.dim_color)
        }
    }

    // Analyzer work in flight. The icon pulses, so it reads as ongoing without
    // a rotating spinner.
    if info.busy {
        color := statusbar.dim_color
        pulse := 0.5 + 0.5 * math.sin(rl.GetTime() * BUSY_PULSE_RATE)
        color.a = cast(u8) (140 + 115 * pulse)
        x = statusbar_draw_segment(statusbar, x, "loader-2", info.busy_message, color)
    }

    // Relative-line jump being typed, so the count reads back before it runs.
    if info.jump_active {
        jump := fmt.tprintf("Jump %d %s", info.jump_count, info.jump_up ? "up" : "down")
        x = statusbar_draw_segment(statusbar, x, "", jump, statusbar.accent_color)
    }

    // Transient notice; errors in red, everything else accented, so it stands
    // out against the segments.
    if info.message != "" {
        color := info.is_error ? statusbar.error_color : statusbar.accent_color
        x = statusbar_draw_segment(statusbar, x, "", info.message, color)
    }

    // Right side: cursor position, encoding, language.
    if info.file_open {
        position := fmt.tprintf("Ln %d, Col %d", info.line, info.column)

        right := statusbar.bounds.x + statusbar.bounds.width - 12
        if info.language != "" {
            right -= statusbar_segment_width(statusbar, "", info.language)
            statusbar_draw_segment(statusbar, right, "", info.language, statusbar.text_color)
        }
        if info.indent_width > 0 {
            label := info.indent_spaces ? "Spaces" : "Tab Size"
            indent := fmt.tprintf("%s: %d", label, info.indent_width)
            right -= statusbar_segment_width(statusbar, "", indent)
            statusbar_draw_segment(statusbar, right, "", indent, statusbar.dim_color)
        }
        right -= statusbar_segment_width(statusbar, "", "UTF-8")
        statusbar_draw_segment(statusbar, right, "", "UTF-8", statusbar.dim_color)
        // Clickable, so it lights up under the cursor to say so.
        if info.line_ending != "" {
            width := statusbar_segment_width(statusbar, "", info.line_ending)
            right -= width
            statusbar.line_ending_bounds = rl.Rectangle {
                right, statusbar.bounds.y, width, statusbar.bounds.height,
            }
            color := statusbar.dim_color
            if statusbar.on_line_ending != nil &&
               rl.CheckCollisionPointRec(ctx.mouse_pos, statusbar.line_ending_bounds) {
                color = statusbar.accent_color
            }
            statusbar_draw_segment(statusbar, right, "", info.line_ending, color)
        }
        if info.zoom > 0 {
            zoom := fmt.tprintf("%d%%", info.zoom)
            right -= statusbar_segment_width(statusbar, "", zoom)
            statusbar_draw_segment(statusbar, right, "", zoom, statusbar.dim_color)
        }
        right -= statusbar_segment_width(statusbar, "", position)
        statusbar_draw_segment(statusbar, right, "", position, statusbar.text_color)
    }
}

statusbar_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Statusbar) widget)
}
