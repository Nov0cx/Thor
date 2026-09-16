// The console pane: a terminal emulator's screen. It draws the cell grid the
// `vt` package keeps, turns keys, pastes and mouse events into the bytes the
// shell expects, and tells its owner when the grid changed size. One per
// terminal tab.
package thor

import "core:strings"
import rl "vendor:raylib"

import "../font"
import ui "../vendor/loom/loom"
import "../vt"

// Sends bytes to the shell behind this console.
Console_Write_Proc :: #type proc(data: rawptr, bytes: string)

// Reports the grid the panel can hold, so the shell re-wraps and a full-screen
// program redraws.
Console_Resize_Proc :: #type proc(data: rawptr, cols, rows: int)

// Tests whether a scrollback line names a navigable source location. Reports the
// byte span of the clickable text and whether the line is a link. The owner does
// the parsing, so the console stays agnostic about path and error formats.
Console_Link_Proc :: #type proc(data: rawptr, line: string) -> (start: int, end: int, ok: bool)

// Opens the source location a clicked scrollback line names.
Console_Activate_Proc :: #type proc(data: rawptr, line: string)

CONSOLE_PAD_X :: f32(10)
CONSOLE_PAD_Y :: f32(6)
CONSOLE_SCROLLBACK :: 5000
// Lines one wheel notch moves, and the arrow keys an alternate-screen program
// gets instead when it reads no mouse.
CONSOLE_WHEEL_LINES :: 3

@(private = "file")
CURSOR_BLINK_PERIOD :: 1.0

Console :: struct {
    term:           ^vt.Term, // owned
    font_size:      i32,
    // Lines scrolled back from the newest output; 0 pins the view to the bottom.
    scroll:         int,
    // The grid the view last measured, which is what the shell was told.
    cols, rows:     int,
    // Cell selection over the scrollback-plus-screen sequence.
    sel_anchor:     vt.Position,
    sel_cursor:     vt.Position,
    has_selection:  bool,
    selecting:      bool,
    // A mouse button is down for a program that reads the mouse, so a move is
    // reported as a drag.
    mouse_button:   vt.Mouse_Button,
    mouse_held:     bool,
    // The cell the last reported move was in, so one move is not sent twice.
    mouse_cell:     vt.Position,
    // Set by an open, consumed by the view: the grid takes the keyboard on the
    // frame the terminal first shows.
    focus_pending:  bool,
    focused:        bool,
    // When the cursor last moved, so the blink starts solid after a keystroke.
    blink_base:     f64,
    on_write:       Console_Write_Proc,
    on_resize:      Console_Resize_Proc,
    write_data:     rawptr,
    on_link:        Console_Link_Proc,
    on_activate:    Console_Activate_Proc,
    link_data:      rawptr,
}

thor_console_init :: proc(console: ^Console) {
    console.font_size = 15
    console.cols, console.rows = 80, 24
    console.term = vt.term_make(console.cols, console.rows, CONSOLE_SCROLLBACK)
    console.focus_pending = true
}

thor_console_destroy :: proc(console: ^Console) {
    vt.term_destroy(console.term)
    console.term = nil
}

thor_console_set_on_write :: proc(
    console: ^Console,
    on_write: Console_Write_Proc,
    on_resize: Console_Resize_Proc,
    data: rawptr,
) {
    console.on_write = on_write
    console.on_resize = on_resize
    console.write_data = data
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

// Seeds the emulator's colours from the theme, so terminal output follows the
// editor. A program can still move any of them with OSC 4, 10, 11 or 12.
thor_console_apply_theme :: proc(thor: ^Thor, console: ^Console) {
    t := console.term
    if t == nil {
        return
    }
    base := [8][3]u8 {
        rgb_of(thor.theme.second_background),
        rgb_of(thor.theme.danger_color),
        rgb_of(thor.theme.success_color),
        rgb_of(thor.theme.warning_color),
        rgb_of(thor.theme.info_color),
        rgb_of(thor.theme.keywords_color),
        rgb_of(thor.theme.accent_color),
        rgb_of(thor.theme.foreground),
    }
    for color, i in base {
        t.default_palette[i] = color
        t.default_palette[i + 8] = brighten(color)
        t.palette[i] = t.default_palette[i]
        t.palette[i + 8] = t.default_palette[i + 8]
    }
    t.default_fg = rgb_of(thor.theme.foreground)
    t.default_bg = rgb_of(thor.theme.background)
    t.cursor_color = rgb_of(thor.theme.accent_color)
}

@(private = "file")
rgb_of :: proc(color: ui.Color) -> [3]u8 {
    return {color[0], color[1], color[2]}
}

// The bright half of the palette: the base colour lifted towards white.
@(private = "file")
brighten :: proc(color: [3]u8) -> [3]u8 {
    out: [3]u8
    for channel, i in color {
        out[i] = u8(min(int(channel) + (255 - int(channel)) / 3 + 24, 255))
    }
    return out
}

// Shell output, straight off the pseudo-terminal.
thor_console_feed :: proc(console: ^Console, bytes: []u8) {
    if console.term == nil || len(bytes) == 0 {
        return
    }
    before := console_history(console)
    vt.term_feed(console.term, bytes)
    // A view held back stays on the lines it was reading: the scroll counts from
    // the newest line, so every line the output added moves it one further back.
    // A view at the bottom stays at the bottom, which is what follows the output.
    if console.scroll > 0 {
        console.scroll = clamp(
            console.scroll + console_history(console) - before,
            0,
            console_history(console),
        )
    }
}

// Text the editor itself writes into the terminal — a plugin's print, or a note
// about the shell. A bare newline only moves down on a terminal, so each one
// gets the carriage return that starts the next line at the left.
thor_console_append :: proc(console: ^Console, text: string) {
    if console.term == nil || text == "" {
        return
    }
    start := 0
    for i in 0 ..< len(text) {
        if text[i] != '\n' {
            continue
        }
        if i > 0 && text[i - 1] == '\r' {
            continue
        }
        vt.term_feed_string(console.term, text[start:i])
        vt.term_feed_string(console.term, "\r\n")
        start = i + 1
    }
    vt.term_feed_string(console.term, text[start:])
}

// Writes to the shell. Everything the user types goes through here.
thor_console_write :: proc(console: ^Console, bytes: string) {
    if console.on_write == nil || bytes == "" {
        return
    }
    console.scroll = 0
    console.on_write(console.write_data, bytes)
}

// Wipes the screen and the history and puts the cursor home. The shell is not
// told: it draws its prompt again on its own.
thor_console_clear :: proc(console: ^Console) {
    if console.term == nil {
        return
    }
    vt.term_feed_string(console.term, "\x1b[H\x1b[2J\x1b[3J")
    console.scroll = 0
    console.has_selection = false
}

// The whole scrollback and screen as text, in the temp allocator.
thor_console_text :: proc(console: ^Console) -> string {
    if console.term == nil {
        return ""
    }
    return vt.term_text_all(console.term, context.temp_allocator)
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
    if !console.has_selection || console.term == nil {
        thor_console_copy_all(console)
        return
    }
    text := vt.term_text_range(
        console.term,
        console.sel_anchor,
        console.sel_cursor,
        context.temp_allocator,
    )
    if text == "" {
        return
    }
    rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
}

// Pastes the system clipboard into the shell, fenced when the program asked for
// bracketed paste.
thor_console_paste :: proc(console: ^Console) {
    clip := rl.GetClipboardText()
    if clip == nil || console.term == nil {
        return
    }
    thor_console_write(console, vt.encode_paste(console.term, string(clip), context.temp_allocator))
}

// Runs `command` as if it had been typed at the prompt, for a task or a code
// action. False when the terminal has no shell behind it.
thor_console_run_command :: proc(console: ^Console, command: string) -> bool {
    if console.on_write == nil || command == "" {
        return false
    }
    thor_console_write(console, command)
    thor_console_write(console, "\r")
    return true
}

// Lines of history above the screen, which is how far the view can scroll back.
@(private = "file")
console_history :: proc(console: ^Console) -> int {
    if console.term == nil {
        return 0
    }
    return max(vt.term_total_lines(console.term) - console.rows, 0)
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
    console_grid(thor, console)
}

@(private = "file")
console_grid :: proc(thor: ^Thor, console: ^Console) {
    cell_w := console_cell_width(console)
    row_h := f32(font.line_height(console.font_size))

    grid := ui.begin(
        {
            key = "grid",
            flags = {.Clip, .Clickable, .Focusable, .Wheel},
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                pad = ui.xy(CONSOLE_PAD_X, CONSOLE_PAD_Y),
                cursor = .Text,
            },
        },
    )

    console_sync_size(console, grid.rect, cell_w, row_h)
    first := console_first_line(console)
    lo, hi := console_selection_range(console)

    for row in 0 ..< console.rows {
        ui.push_id_int(i64(row))
        console_row(thor, console, first + row, cell_w, row_h, lo, hi)
        ui.pop_id()
    }
    ui.end()

    console_input(thor, console, grid, cell_w, row_h, first)
}

// The advance of one cell. A monospace face is what the console is drawn in, so
// one measurement stands for every column.
@(private = "file")
console_cell_width :: proc(console: ^Console) -> f32 {
    return f32(max(font.measure("M", console.font_size), 1))
}

// Fits the grid to the panel and tells the shell when it changed.
@(private = "file")
console_sync_size :: proc(console: ^Console, rect: ui.Rect, cell_w, row_h: f32) {
    if cell_w <= 0 || row_h <= 0 || rect.w <= 0 || rect.h <= 0 {
        return
    }
    cols := max(int((rect.w - CONSOLE_PAD_X * 2) / cell_w), 1)
    rows := max(int((rect.h - CONSOLE_PAD_Y * 2) / row_h), 1)
    if cols == console.cols && rows == console.rows {
        return
    }
    console.cols, console.rows = cols, rows
    if console.term != nil {
        console.term.cell_w = int(cell_w)
        console.term.cell_h = int(row_h)
        vt.term_resize(console.term, cols, rows)
    }
    console.scroll = min(console.scroll, console_history(console))
    if console.on_resize != nil {
        console.on_resize(console.write_data, cols, rows)
    }
}

// The scrollback-plus-screen index the top row of the view shows.
@(private = "file")
console_first_line :: proc(console: ^Console) -> int {
    if console.term == nil {
        return 0
    }
    total := vt.term_total_lines(console.term)
    return max(total - console.rows - console.scroll, 0)
}

@(private = "file")
console_selection_range :: proc(console: ^Console) -> (lo: vt.Position, hi: vt.Position) {
    if !console.has_selection {
        return {line = -1}, {line = -1}
    }
    lo, hi = console.sel_anchor, console.sel_cursor
    if hi.line < lo.line || (hi.line == lo.line && hi.col < lo.col) {
        lo, hi = hi, lo
    }
    return
}

@(private = "file")
console_selected :: proc(lo, hi: vt.Position, line, col: int) -> bool {
    if lo.line < 0 {
        return false
    }
    if line < lo.line || line > hi.line {
        return false
    }
    if line == lo.line && col < lo.col {
        return false
    }
    if line == hi.line && col >= hi.col {
        return false
    }
    return true
}

// Everything that decides how a cell is painted. Cells that agree on all of it
// are drawn as one node, which is what keeps a full screen to a few hundred.
@(private = "file")
Console_Style :: struct {
    fg, bg:    ui.Color,
    ul:        ui.Color,
    underline: vt.Underline,
    strike:    bool,
    overline:  bool,
    link:      bool,
}

@(private = "file")
console_row :: proc(
    thor: ^Thor,
    console: ^Console,
    index: int,
    cell_w, row_h: f32,
    lo, hi: vt.Position,
) {
    term := console.term
    line := term == nil ? nil : vt.term_line(term, index)

    ui.begin({key = "row", props = {w = ui.Grow(1), h = ui.Px(row_h), dir = .Row, gap = {0, 0}}})
    defer ui.end()
    if line == nil {
        return
    }

    console_row_cursor(thor, console, index, cell_w, row_h)

    link_start, link_end := console_link_columns(console, line, index)
    end := console_row_end(line)

    x := 0
    for x < end {
        style := console_style(thor, console, line, index, x, lo, hi, link_start, link_end)
        run_end := x + 1
        for run_end < end {
            next := console_style(thor, console, line, index, run_end, lo, hi, link_start, link_end)
            if next != style {
                break
            }
            run_end += 1
        }

        builder := strings.builder_make(context.temp_allocator)
        vt.line_write(term, line, &builder, x, run_end)
        width := f32(run_end - x) * cell_w

        ui.push_id_int(i64(x))
        ui.begin(
            {
                key = "run",
                text = strings.to_string(builder),
                props = {
                    w = ui.Px(width),
                    h = ui.Px(row_h),
                    bg = style.bg,
                    color = style.fg,
                    font = thor.font_mono,
                    font_size = f32(console.font_size),
                    text_align_v = .Center,
                    text_wrap = .None,
                },
            },
        )
        console_decorations(style, width, row_h)
        ui.end()
        ui.pop_id()

        x = run_end
    }
}

// The underline, strike-through and overline a run wears. Each is a rectangle
// under the text of its own node.
@(private = "file")
console_decorations :: proc(style: Console_Style, width, row_h: f32) {
    if style.underline != .None {
        y := row_h - 2
        color := style.ul[3] == 0 ? style.fg : style.ul
        switch style.underline {
        case .None:
        case .Single, .Curly, .Dotted, .Dashed:
            ui.paint_rect({0, y, width, 1}, color, over = true)
        case .Double:
            ui.paint_rect({0, y - 2, width, 1}, color, over = true)
            ui.paint_rect({0, y, width, 1}, color, over = true)
        }
    }
    if style.strike {
        ui.paint_rect({0, row_h * 0.5, width, 1}, style.fg, over = true)
    }
    if style.overline {
        ui.paint_rect({0, 1, width, 1}, style.fg, over = true)
    }
}

// Where a row stops being worth drawing: the last cell that shows anything.
@(private = "file")
console_row_end :: proc(line: ^vt.Line) -> int {
    end := len(line.cells)
    for end > 0 {
        cell := line.cells[end - 1]
        if cell.ch != ' ' && cell.ch != 0 {
            break
        }
        if cell.bg.kind != .Default || .Reverse in cell.attrs {
            break
        }
        end -= 1
    }
    return end
}

@(private = "file")
console_style :: proc(
    thor: ^Thor,
    console: ^Console,
    line: ^vt.Line,
    index, col: int,
    lo, hi: vt.Position,
    link_start, link_end: int,
) -> Console_Style {
    term := console.term
    cell := line.cells[col]

    fg := console_color(console, cell.fg, term.default_fg)
    bg_solid := console_color(console, cell.bg, term.default_bg)
    // A default background is left to the panel, so the terminal is as
    // transparent as the rest of the editor's chrome.
    bg := cell.bg.kind == .Default ? ui.Color{0, 0, 0, 0} : bg_solid

    if .Bold in cell.attrs && cell.fg.kind == .Indexed && cell.fg.v[0] < 8 {
        fg = console_color(console, vt.color_indexed(int(cell.fg.v[0]) + 8), term.default_fg)
    }
    if .Dim in cell.attrs {
        fg = blend(fg, bg_solid, 0.45)
    }
    if (.Reverse in cell.attrs) != term.reverse_video {
        fg, bg = bg_solid, fg
    }
    if .Hidden in cell.attrs {
        fg = bg_solid
    }

    style := Console_Style {
        fg        = fg,
        bg        = bg,
        underline = cell.underline,
        strike    = .Strike in cell.attrs,
        overline  = .Overline in cell.attrs,
    }
    if cell.ul.kind != .Default {
        style.ul = console_color(console, cell.ul, term.default_fg)
    }
    // A hyperlink the program declared, and a file path the owner recognised,
    // are both drawn as links.
    if cell.link != 0 || (col >= link_start && col < link_end) {
        style.link = true
        style.fg = thor.theme.info_color
        if style.underline == .None {
            style.underline = .Single
        }
    }
    if console_selected(lo, hi, index, col) {
        style.bg = thor.theme.selection_background
    }
    return style
}

@(private = "file")
console_color :: proc(console: ^Console, color: vt.Color, fallback: [3]u8) -> ui.Color {
    rgb := vt.term_color(console.term, color, fallback)
    return {rgb[0], rgb[1], rgb[2], 255}
}

@(private = "file")
blend :: proc(a, b: ui.Color, t: f32) -> ui.Color {
    out: ui.Color
    for i in 0 ..< 3 {
        out[i] = u8(f32(a[i]) * (1 - t) + f32(b[i]) * t)
    }
    out[3] = 255
    return out
}

// The block, bar or underline the cursor is drawn as, on the row it sits in.
@(private = "file")
console_row_cursor :: proc(thor: ^Thor, console: ^Console, index: int, cell_w, row_h: f32) {
    term := console.term
    if !term.cursor_visible || index != vt.term_cursor_line(term) {
        return
    }
    if term.cursor_blink && console.focused {
        phase := rl.GetTime() - console.blink_base
        if phase - f64(int(phase / CURSOR_BLINK_PERIOD)) * CURSOR_BLINK_PERIOD >
           CURSOR_BLINK_PERIOD * 0.5 {
            return
        }
    }

    color := ui.Color {
        term.cursor_color[0],
        term.cursor_color[1],
        term.cursor_color[2],
        console.focused ? 255 : 110,
    }
    x := f32(term.cur.x) * cell_w
    switch term.cursor_style {
    case .Block:
        ui.paint_rect({x, 0, cell_w, row_h}, color)
    case .Underline:
        ui.paint_rect({x, row_h - 2, cell_w, 2}, color, over = true)
    case .Bar:
        ui.paint_rect({x, 0, 2, row_h}, color, over = true)
    }
}

// The columns of a row the owner would open as a source location.
@(private = "file")
console_link_columns :: proc(console: ^Console, line: ^vt.Line, index: int) -> (int, int) {
    if console.on_link == nil {
        return 0, 0
    }
    text := vt.line_text(console.term, line, context.temp_allocator)
    if text == "" {
        return 0, 0
    }
    start, end, ok := console.on_link(console.link_data, text)
    if !ok {
        return 0, 0
    }
    return vt.column_of_offset(console.term, line, start),
        vt.column_of_offset(console.term, line, end)
}

// ---- input ---------------------------------------------------------------------------

@(private = "file")
console_input :: proc(
    thor: ^Thor,
    console: ^Console,
    grid: ui.Interaction,
    cell_w, row_h: f32,
    first: int,
) {
    if console.term == nil {
        return
    }
    if console.focus_pending || thor.focus_request == "console" {
        ui.set_focus(grid.id)
        console.focus_pending = false
    }
    if grid.pressed {
        ui.set_focus(grid.id)
    }

    was_focused := console.focused
    console.focused = ui.focus_within(grid.node)
    thor.console_focused = console.focused
    if console.focused != was_focused {
        console.blink_base = rl.GetTime()
        if report, ok := vt.encode_focus(console.term, console.focused); ok {
            thor_console_write(console, report)
        }
    }

    console_mouse(thor, console, grid, cell_w, row_h, first)
    if !console.focused {
        return
    }
    console_keys(thor, console)
    console_text(console)
}

// Wheel, selection drag and the mouse reports a program asked for.
@(private = "file")
console_mouse :: proc(
    thor: ^Thor,
    console: ^Console,
    grid: ui.Interaction,
    cell_w, row_h: f32,
    first: int,
) {
    term := console.term
    mods := console_mods()
    // Shift is the escape hatch: it always means "select", even while a program
    // is reading the mouse.
    reporting := term.mouse_track != .Off && .Shift not_in mods

    if grid.wheel.y != 0 {
        console_wheel(console, grid, int(grid.wheel.y), cell_w, row_h, first, reporting, mods)
    }
    if grid.right_clicked {
        thor_console_context_menu(thor, ui.mouse_pos())
        return
    }

    line, col := console_cell_at(console, grid, cell_w, row_h, first)
    screen_row := line - (vt.term_total_lines(term) - console.rows)

    if reporting {
        console_mouse_report(console, grid, col, screen_row, mods)
        return
    }

    if grid.pressed {
        console.sel_anchor = {line = line, col = col}
        console.sel_cursor = console.sel_anchor
        console.has_selection = false
        console.selecting = true
    }
    if console.selecting && grid.dragging {
        console.sel_cursor = {line = line, col = col}
        console.has_selection = console.sel_cursor != console.sel_anchor
    }
    if grid.released {
        console.selecting = false
    }
    if grid.clicked && !console.has_selection {
        console_activate(console, line, col)
    }
}

// A wheel over the alternate screen moves the program, not a history it has
// none of: without mouse reporting it reads arrow keys, which is what a pager
// scrolls on.
@(private = "file")
console_wheel :: proc(
    console: ^Console,
    grid: ui.Interaction,
    notches: int,
    cell_w, row_h: f32,
    first: int,
    reporting: bool,
    mods: vt.Mods,
) {
    term := console.term
    if reporting {
        line, col := console_cell_at(console, grid, cell_w, row_h, first)
        button: vt.Mouse_Button = notches > 0 ? .Wheel_Up : .Wheel_Down
        screen_row := line - (vt.term_total_lines(term) - console.rows)
        for _ in 0 ..< abs(notches) {
            if report, ok := vt.encode_mouse(term, button, .Press, col, screen_row, mods); ok {
                thor_console_write(console, report)
            }
        }
        return
    }
    if term.alt_active {
        key: vt.Key = notches > 0 ? .Up : .Down
        for _ in 0 ..< abs(notches) * CONSOLE_WHEEL_LINES {
            if bytes, ok := vt.encode_key(term, key); ok {
                thor_console_write(console, bytes)
            }
        }
        return
    }
    console.scroll = clamp(
        console.scroll + notches * CONSOLE_WHEEL_LINES,
        0,
        console_history(console),
    )
}

@(private = "file")
console_mouse_report :: proc(
    console: ^Console,
    grid: ui.Interaction,
    col, row: int,
    mods: vt.Mods,
) {
    term := console.term
    if grid.pressed {
        console.mouse_button = .Left
        console.mouse_held = true
        console.mouse_cell = {line = row, col = col}
        if report, ok := vt.encode_mouse(term, .Left, .Press, col, row, mods); ok {
            thor_console_write(console, report)
        }
        return
    }
    if grid.released && console.mouse_held {
        console.mouse_held = false
        if report, ok := vt.encode_mouse(term, console.mouse_button, .Release, col, row, mods);
           ok {
            thor_console_write(console, report)
        }
        return
    }
    if grid.hovered && console.mouse_cell != (vt.Position{line = row, col = col}) {
        console.mouse_cell = {line = row, col = col}
        button: vt.Mouse_Button = console.mouse_held ? console.mouse_button : .None
        if report, ok := vt.encode_mouse(term, button, .Move, col, row, mods); ok {
            thor_console_write(console, report)
        }
    }
}

// The cell the pointer is over, as a scrollback-plus-screen position.
@(private = "file")
console_cell_at :: proc(
    console: ^Console,
    grid: ui.Interaction,
    cell_w, row_h: f32,
    first: int,
) -> (line: int, col: int) {
    mouse := ui.mouse_pos()
    x := mouse.x - (grid.rect.x + CONSOLE_PAD_X)
    y := mouse.y - (grid.rect.y + CONSOLE_PAD_Y)
    col = clamp(int(x / max(cell_w, 1)), 0, max(console.cols - 1, 0))
    row := clamp(int(y / max(row_h, 1)), 0, max(console.rows - 1, 0))
    line = clamp(first + row, 0, max(vt.term_total_lines(console.term) - 1, 0))
    return
}

// A click that is not a selection: an OSC 8 hyperlink first, then whatever the
// owner recognises in the line's text.
@(private = "file")
console_activate :: proc(console: ^Console, line, col: int) {
    row := vt.term_line(console.term, line)
    if row == nil {
        return
    }
    if col < len(row.cells) {
        if uri := vt.term_link(console.term, row.cells[col].link); uri != "" {
            thor_open_in_browser(uri)
            return
        }
    }
    if console.on_activate == nil {
        return
    }
    text := vt.line_text(console.term, row, context.temp_allocator)
    if _, _, ok := console.on_link(console.link_data, text); ok {
        console.on_activate(console.link_data, text)
    }
}

@(private = "file")
console_mods :: proc() -> vt.Mods {
    out: vt.Mods
    held := ui.mods()
    if .Shift in held {
        out += {.Shift}
    }
    if .Alt in held {
        out += {.Alt}
    }
    if .Ctrl in held {
        out += {.Ctrl}
    }
    return out
}

// Typed characters. A modifier chord never arrives here — the platform sends no
// character for one — so this is plain text.
@(private = "file")
console_text :: proc(console: ^Console) {
    text := ui.typed_text()
    if text == "" {
        return
    }
    console.blink_base = rl.GetTime()
    thor_console_write(console, text)
}

@(private = "file")
console_keys :: proc(thor: ^Thor, console: ^Console) {
    for &event in ui.keys() {
        if event.consumed || event.action == .Release {
            continue
        }
        if console_handle_key(thor, console, event) {
            event.consumed = true
            console.blink_base = rl.GetTime()
        }
    }
}

@(private = "file")
console_handle_key :: proc(thor: ^Thor, console: ^Console, event: ui.Key_Event) -> bool {
    term := console.term
    mods := console_key_mods(event.mods)

    // The editor's own chords over the terminal, before anything reaches the
    // shell. Copy only takes ctrl+c while there is something to copy, so an
    // interrupt is never swallowed.
    if event.mods == {.Ctrl, .Shift} {
        #partial switch event.key {
        case .C:
            thor_console_copy(console)
            return true
        case .V:
            thor_console_paste(console)
            return true
        }
    }
    if event.mods == {.Ctrl} && event.key == .C && console.has_selection {
        thor_console_copy(console)
        console.has_selection = false
        return true
    }
    if event.mods == {.Ctrl} && event.key == .V {
        thor_console_paste(console)
        return true
    }
    if event.mods == {.Shift} {
        #partial switch event.key {
        case .Page_Up:
            console.scroll = min(console.scroll + console.rows, console_history(console))
            return true
        case .Page_Down:
            console.scroll = max(console.scroll - console.rows, 0)
            return true
        }
    }

    if key, ok := console_vt_key(event.key); ok {
        if bytes, sent := vt.encode_key(term, key, mods); sent {
            thor_console_write(console, bytes)
            return true
        }
        return false
    }

    // A chord over a character key: the character itself never arrives as text,
    // so it is encoded here.
    if .Ctrl in event.mods || .Alt in event.mods {
        if r, ok := console_key_rune(event.key); ok {
            if bytes, sent := vt.encode_rune(term, r, mods); sent {
                thor_console_write(console, bytes)
                return true
            }
        }
    }
    return false
}

@(private = "file")
console_key_mods :: proc(mods: ui.Mod_Set) -> vt.Mods {
    out: vt.Mods
    if .Shift in mods {
        out += {.Shift}
    }
    if .Alt in mods {
        out += {.Alt}
    }
    if .Ctrl in mods {
        out += {.Ctrl}
    }
    return out
}

// The keys that send a sequence of their own rather than a character.
@(private = "file")
console_vt_key :: proc(key: ui.Key) -> (vt.Key, bool) {
    #partial switch key {
    case .Enter:
        return .Enter, true
    case .Tab:
        return .Tab, true
    case .Backspace:
        return .Backspace, true
    case .Escape:
        return .Escape, true
    case .Up:
        return .Up, true
    case .Down:
        return .Down, true
    case .Left:
        return .Left, true
    case .Right:
        return .Right, true
    case .Home:
        return .Home, true
    case .End:
        return .End, true
    case .Page_Up:
        return .Page_Up, true
    case .Page_Down:
        return .Page_Down, true
    case .Insert:
        return .Insert, true
    case .Delete:
        return .Delete, true
    case .F1:
        return .F1, true
    case .F2:
        return .F2, true
    case .F3:
        return .F3, true
    case .F4:
        return .F4, true
    case .F5:
        return .F5, true
    case .F6:
        return .F6, true
    case .F7:
        return .F7, true
    case .F8:
        return .F8, true
    case .F9:
        return .F9, true
    case .F10:
        return .F10, true
    case .F11:
        return .F11, true
    case .F12:
        return .F12, true
    case .Pad_Enter:
        return .Pad_Enter, true
    case .Pad_0:
        return .Pad_0, true
    case .Pad_1:
        return .Pad_1, true
    case .Pad_2:
        return .Pad_2, true
    case .Pad_3:
        return .Pad_3, true
    case .Pad_4:
        return .Pad_4, true
    case .Pad_5:
        return .Pad_5, true
    case .Pad_6:
        return .Pad_6, true
    case .Pad_7:
        return .Pad_7, true
    case .Pad_8:
        return .Pad_8, true
    case .Pad_9:
        return .Pad_9, true
    case .Pad_Decimal:
        return .Pad_Decimal, true
    case .Pad_Divide:
        return .Pad_Divide, true
    case .Pad_Multiply:
        return .Pad_Multiply, true
    case .Pad_Subtract:
        return .Pad_Subtract, true
    case .Pad_Add:
        return .Pad_Add, true
    case .Pad_Equal:
        return .Pad_Equal, true
    case .Space:
        // Only a chord reaches the terminal as a key; a plain space is text.
        if .Ctrl in ui.mods() {
            return .Space, true
        }
    }
    return .None, false
}

// The character a key stands for, for a Ctrl or Alt chord over it.
@(private = "file")
console_key_rune :: proc(key: ui.Key) -> (rune, bool) {
    #partial switch key {
    case .A ..= .Z:
        return rune('a') + rune(key) - rune(ui.Key.A), true
    case .Num_0 ..= .Num_9:
        return rune('0') + rune(key) - rune(ui.Key.Num_0), true
    case .Minus:
        return '-', true
    case .Equal:
        return '=', true
    case .Left_Bracket:
        return '[', true
    case .Right_Bracket:
        return ']', true
    case .Backslash:
        return '\\', true
    case .Semicolon:
        return ';', true
    case .Apostrophe:
        return '\'', true
    case .Grave:
        return '`', true
    case .Comma:
        return ',', true
    case .Period:
        return '.', true
    case .Slash:
        return '/', true
    }
    return 0, false
}
