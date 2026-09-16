// A VT220/xterm terminal emulator: the escape parser, the screen grid, the
// scrollback and the key and mouse encoders. No UI, no OS calls and no threads,
// so every part of it is testable on its own. The host reads bytes off a
// pseudo-terminal into `term_feed`, draws the grid, and writes whatever
// `term_take_reply` gives back.
package vt

import "base:runtime"

// A cell colour: the terminal default, one of the 256 palette entries, or a
// direct RGB triple. Indexed keeps the entry in v[0].
Color_Kind :: enum u8 {
    Default,
    Indexed,
    RGB,
}

Color :: struct {
    kind: Color_Kind,
    v:    [3]u8,
}

color_indexed :: proc(index: int) -> Color {
    return {kind = .Indexed, v = {u8(clamp(index, 0, 255)), 0, 0}}
}

color_rgb :: proc(r, g, b: u8) -> Color {
    return {kind = .RGB, v = {r, g, b}}
}

Attr :: enum u16 {
    Bold,
    Dim,
    Italic,
    Blink,
    Fast_Blink,
    Reverse,
    Hidden,
    Strike,
    Overline,
    Protected,
}

Attr_Set :: bit_set[Attr;u16]

Underline :: enum u8 {
    None,
    Single,
    Double,
    Curly,
    Dotted,
    Dashed,
}

Cell_Flag :: enum u8 {
    // The left half of a double-width character.
    Wide,
    // The column a double-width character covers but does not draw in.
    Spacer,
}

Cell_Flags :: bit_set[Cell_Flag;u8]

// One grid cell. `grapheme` is 0 for a lone rune and otherwise indexes the
// term's grapheme pool, which holds base plus combining marks.
Cell :: struct {
    ch:        rune,
    fg:        Color,
    bg:        Color,
    ul:        Color,
    link:      u32,
    grapheme:  u32,
    attrs:     Attr_Set,
    underline: Underline,
    flags:     Cell_Flags,
}

// Everything SGR sets, carried by every cell the cursor writes.
Pen :: struct {
    fg:        Color,
    bg:        Color,
    ul:        Color,
    link:      u32,
    attrs:     Attr_Set,
    underline: Underline,
}

// One grid row. `wrapped` says the row ran off its right edge and continues on
// the next, which is what selection and text extraction join on.
Line :: struct {
    cells:   [dynamic]Cell, // owned
    wrapped: bool,
}

Cursor :: struct {
    x, y: int,
    pen:  Pen,
    // The cursor sits past the last column: the next printable rune wraps
    // before it is written. Deferred so a write into the last column does not
    // scroll on its own.
    pending_wrap: bool,
}

Saved_Cursor :: struct {
    cur:      Cursor,
    charsets: [4]Charset,
    gl, gr:   int,
    origin:   bool,
    valid:    bool,
}

// A character set a Gn slot is designated to. Only the two that change what is
// drawn are distinguished; the rest behave as ASCII.
Charset :: enum u8 {
    Ascii,
    Dec_Graphics,
    Uk,
}

Cursor_Style :: enum u8 {
    Block,
    Underline,
    Bar,
}

// What the shell asked to be told about the mouse.
Mouse_Track :: enum u8 {
    Off,
    X10,     // press only
    Normal,  // press and release
    Button,  // press, release and drag
    Any,     // every move
}

// How a mouse report is spelled.
Mouse_Encoding :: enum u8 {
    X10,  // the original 32-offset bytes
    Utf8, // mode 1005
    Sgr,  // mode 1006
    Urxvt,// mode 1015
}

// The one shell-integration mark the editor acts on: a command finished, with
// the status it finished on.
Command_End :: struct {
    code:  int,
    known: bool,
}

DEFAULT_SCROLLBACK :: 5000
MAX_PARAMS :: 32
MAX_OSC :: 1 << 20
MAX_GRAPHEMES :: 1 << 14
MAX_LINKS :: 1 << 12

Term :: struct {
    allocator:        runtime.Allocator,
    cols, rows:       int,
    primary:          [dynamic]Line, // owned
    alt:              [dynamic]Line, // owned
    alt_active:       bool,
    scrollback:       [dynamic]Line, // owned, oldest first
    scrollback_limit: int,
    cur:              Cursor,
    saved:            Saved_Cursor,
    saved_alt:        Saved_Cursor,
    // Scroll region, 0-based rows, both ends inside it.
    top, bottom:      int,
    tabs:             [dynamic]bool, // owned
    charsets:         [4]Charset,
    gl, gr:           int,
    single_shift:     int, // 0 when none is armed, else the Gn slot for one rune
    // Modes.
    app_cursor:       bool,
    app_keypad:       bool,
    origin:           bool,
    autowrap:         bool,
    reverse_wrap:     bool,
    insert:           bool,
    newline_mode:     bool,
    reverse_video:    bool,
    cursor_visible:   bool,
    cursor_blink:     bool,
    cursor_style:     Cursor_Style,
    bracketed_paste:  bool,
    focus_events:     bool,
    sync_output:      bool,
    mouse_track:      Mouse_Track,
    mouse_encoding:   Mouse_Encoding,
    // Colours. The palette starts as the xterm 256 and OSC 4 can move it.
    palette:          [256][3]u8,
    default_palette:  [256][3]u8,
    // Titles, owned. `title_stack` is what XTWINOPS 22/23 pushes and pops.
    title:            string,
    icon_title:       string,
    title_stack:      [dynamic]string, // owned
    // The working directory OSC 7 reported, owned and "" until one arrives.
    cwd:              string,
    // OSC 8 targets, index 0 unused so a cell's 0 means "no link". owned
    links:            [dynamic]string,
    // Base plus combining marks for the cells that need more than one rune,
    // index 0 unused. owned
    graphemes:        [dynamic]string,
    // What the host sets so the pixel and cell reports can answer.
    cell_w, cell_h:   int,
    // The two colours a Default cell resolves to and the cursor's, seeded from
    // the theme and moved by OSC 10, 11 and 12.
    default_fg:       [3]u8,
    default_bg:       [3]u8,
    cursor_color:     [3]u8,
    // OSC 52 asked for this text to go on the clipboard. owned
    clipboard:        string,
    clipboard_ready:  bool,
    // Counters the host reads and clears.
    bell:             int,
    command_end:      Command_End,
    command_end_ready: bool,
    // Bytes owed to the shell: device reports and clipboard answers.
    reply:            [dynamic]u8, // owned
    // Parser state.
    state:            Parser_State,
    params:           Params,
    private:          u8,
    inter:            [2]u8,
    inter_n:          int,
    osc:              [dynamic]u8, // owned
    dcs_final:        u8,
    utf8:             [4]u8,
    utf8_len:         int,
    utf8_need:        int,
    // The last rune printed, which REP repeats.
    last_rune:        rune,
}

// Makes a terminal of `cols` x `rows`, with `scrollback` lines of history on the
// primary screen.
term_make :: proc(
    cols, rows: int,
    scrollback := DEFAULT_SCROLLBACK,
    allocator := context.allocator,
) -> ^Term {
    context.allocator = allocator
    t := new(Term)
    t.allocator = allocator
    t.cols = max(cols, 1)
    t.rows = max(rows, 1)
    t.scrollback_limit = max(scrollback, 0)
    t.primary = make([dynamic]Line)
    t.alt = make([dynamic]Line)
    t.scrollback = make([dynamic]Line)
    t.tabs = make([dynamic]bool)
    t.title_stack = make([dynamic]string)
    t.links = make([dynamic]string)
    t.graphemes = make([dynamic]string)
    t.reply = make([dynamic]u8)
    t.osc = make([dynamic]u8)
    // Index 0 of both pools means "none".
    append(&t.links, "")
    append(&t.graphemes, "")

    grid_resize(t, &t.primary, t.cols, t.rows)
    grid_resize(t, &t.alt, t.cols, t.rows)
    t.default_palette = palette_default()
    t.palette = t.default_palette
    term_soft_reset(t)
    tabs_reset(t)
    return t
}

term_destroy :: proc(t: ^Term) {
    if t == nil {
        return
    }
    context.allocator = t.allocator
    grid_destroy(&t.primary)
    grid_destroy(&t.alt)
    grid_destroy(&t.scrollback)
    delete(t.tabs)
    for entry in t.title_stack {
        delete(entry)
    }
    delete(t.title_stack)
    for link in t.links[1:] {
        delete(link)
    }
    delete(t.links)
    for g in t.graphemes[1:] {
        delete(g)
    }
    delete(t.graphemes)
    delete(t.title)
    delete(t.icon_title)
    delete(t.cwd)
    delete(t.clipboard)
    delete(t.reply)
    delete(t.osc)
    free(t)
}

// The rows on screen now, top first. Borrowed until the next feed or resize.
term_screen :: proc(t: ^Term) -> []Line {
    return grid(t)[:]
}

// Lines the view can show: the scrollback followed by the screen. A history line
// is only kept for the primary screen, so the alt screen reports its rows alone.
term_total_lines :: proc(t: ^Term) -> int {
    return len(t.scrollback) + t.rows
}

// Line `index` of the scrollback-plus-screen sequence, or nil when out of range.
term_line :: proc(t: ^Term, index: int) -> ^Line {
    if index < 0 {
        return nil
    }
    if index < len(t.scrollback) {
        return &t.scrollback[index]
    }
    row := index - len(t.scrollback)
    g := grid(t)
    if row >= len(g) {
        return nil
    }
    return &g[row]
}

// Where the cursor sits in the scrollback-plus-screen sequence.
term_cursor_line :: proc(t: ^Term) -> int {
    return len(t.scrollback) + t.cur.y
}

// The URI of OSC 8 link `id`, or "" when the id names none.
term_link :: proc(t: ^Term, id: u32) -> string {
    if id == 0 || int(id) >= len(t.links) {
        return ""
    }
    return t.links[id]
}

// The base plus combining marks of a cell that needs more than one rune, or ""
// when `id` is 0.
term_grapheme :: proc(t: ^Term, id: u32) -> string {
    if id == 0 || int(id) >= len(t.graphemes) {
        return ""
    }
    return t.graphemes[id]
}

// The RGB a cell colour resolves to. `fg` picks which default answers a Default
// colour, since the terminal's own two defaults live in the host's theme.
term_color :: proc(t: ^Term, c: Color, default_rgb: [3]u8) -> [3]u8 {
    switch c.kind {
    case .Default:
        return default_rgb
    case .Indexed:
        return t.palette[c.v[0]]
    case .RGB:
        return c.v
    }
    return default_rgb
}

// Takes the bytes owed to the shell. The slice is the term's own buffer, valid
// until the next feed; the caller writes it out at once.
term_take_reply :: proc(t: ^Term) -> []u8 {
    if len(t.reply) == 0 {
        return nil
    }
    out := t.reply[:]
    return out
}

// Drops the reply the caller just wrote.
term_clear_reply :: proc(t: ^Term) {
    clear(&t.reply)
}

// Reads and clears the bell counter.
term_take_bell :: proc(t: ^Term) -> int {
    n := t.bell
    t.bell = 0
    return n
}

// Reads and clears the last shell-integration command end (OSC 133;D).
term_take_command_end :: proc(t: ^Term) -> (Command_End, bool) {
    if !t.command_end_ready {
        return {}, false
    }
    end := t.command_end
    t.command_end = {}
    t.command_end_ready = false
    return end, true
}

// Reads and clears the text OSC 52 asked to put on the clipboard. The string is
// the term's own, valid until the next feed.
term_take_clipboard :: proc(t: ^Term) -> (string, bool) {
    if !t.clipboard_ready {
        return "", false
    }
    t.clipboard_ready = false
    return t.clipboard, true
}

// Resizes the grid. Content keeps its place from the top left; rows that fall
// off the bottom of the primary screen move into the scrollback, and the cursor
// is clamped. Lines are not reflowed: a wrapped line stays split where it was.
term_resize :: proc(t: ^Term, cols, rows: int) {
    cols, rows := max(cols, 1), max(rows, 1)
    if cols == t.cols && rows == t.rows {
        return
    }
    context.allocator = t.allocator

    // Shrinking the primary screen pushes the rows above the cursor into the
    // history instead of dropping them, which is what a shell redrawing its
    // prompt after a resize expects to find.
    if rows < t.rows && !t.alt_active {
        excess := t.rows - rows
        keep := max(t.cur.y - (rows - 1), 0)
        move := min(excess, keep)
        for _ in 0 ..< move {
            line := t.primary[0]
            ordered_remove(&t.primary, 0)
            scrollback_push(t, line)
            t.cur.y -= 1
        }
    }

    grid_resize(t, &t.primary, cols, rows)
    grid_resize(t, &t.alt, cols, rows)
    t.cols, t.rows = cols, rows

    tabs_reset(t)
    t.top = 0
    t.bottom = rows - 1
    t.cur.x = clamp(t.cur.x, 0, cols - 1)
    t.cur.y = clamp(t.cur.y, 0, rows - 1)
    t.cur.pending_wrap = false
    t.saved.valid = false
    t.saved_alt.valid = false
}

// Drops the history. The screen itself is untouched.
term_clear_scrollback :: proc(t: ^Term) {
    context.allocator = t.allocator
    grid_destroy(&t.scrollback)
    t.scrollback = make([dynamic]Line)
}

// RIS: back to the state a fresh terminal starts in, history included.
term_reset :: proc(t: ^Term) {
    context.allocator = t.allocator
    term_clear_scrollback(t)
    grid_blank(t, &t.primary)
    grid_blank(t, &t.alt)
    t.alt_active = false
    t.palette = t.default_palette
    for link in t.links[1:] {
        delete(link)
    }
    clear(&t.links)
    append(&t.links, "")
    for g in t.graphemes[1:] {
        delete(g)
    }
    clear(&t.graphemes)
    append(&t.graphemes, "")
    delete(t.title)
    delete(t.icon_title)
    t.title, t.icon_title = "", ""
    term_soft_reset(t)
    tabs_reset(t)
}

// DECSTR: the modes and the pen go back to their defaults; the screen content,
// the scrollback and the titles stay.
term_soft_reset :: proc(t: ^Term) {
    t.cur = {}
    t.saved = {}
    t.saved_alt = {}
    t.top = 0
    t.bottom = t.rows - 1
    t.charsets = {}
    t.gl, t.gr = 0, 1
    t.single_shift = 0
    t.app_cursor = false
    t.app_keypad = false
    t.origin = false
    t.autowrap = true
    t.reverse_wrap = false
    t.insert = false
    t.newline_mode = false
    t.reverse_video = false
    t.cursor_visible = true
    t.cursor_blink = true
    t.cursor_style = .Block
    t.bracketed_paste = false
    t.focus_events = false
    t.sync_output = false
    t.mouse_track = .Off
    t.mouse_encoding = .X10
    t.state = .Ground
    t.utf8_len, t.utf8_need = 0, 0
}

// ---- the grid ------------------------------------------------------------------

@(private)
grid :: proc(t: ^Term) -> ^[dynamic]Line {
    return t.alt_active ? &t.alt : &t.primary
}

@(private)
blank_cell :: proc(pen: Pen) -> Cell {
    // Only the background travels with an erase: an erased cell has no glyph,
    // so the foreground and the attributes that decorate one are not kept.
    return {ch = ' ', bg = pen.bg}
}

@(private)
line_make :: proc(cols: int) -> Line {
    line := Line {
        cells = make([dynamic]Cell, cols),
    }
    for i in 0 ..< cols {
        line.cells[i] = {ch = ' '}
    }
    return line
}

@(private)
line_clear :: proc(line: ^Line, pen: Pen) {
    blank := blank_cell(pen)
    for &cell in line.cells {
        cell = blank
    }
    line.wrapped = false
}

@(private)
grid_resize :: proc(t: ^Term, g: ^[dynamic]Line, cols, rows: int) {
    for len(g) > rows {
        line := pop(g)
        delete(line.cells)
    }
    for &line in g {
        old := len(line.cells)
        resize(&line.cells, cols)
        for i in old ..< cols {
            line.cells[i] = {ch = ' '}
        }
        if cols < old {
            line.wrapped = false
        }
    }
    for len(g) < rows {
        append(g, line_make(cols))
    }
}

@(private)
grid_blank :: proc(t: ^Term, g: ^[dynamic]Line) {
    for &line in g {
        line_clear(&line, {})
    }
}

@(private)
grid_destroy :: proc(g: ^[dynamic]Line) {
    for line in g {
        delete(line.cells)
    }
    delete(g^)
}

// Moves one line into the history, dropping the oldest once the limit is met.
// Trailing blanks are cut: a history line is only ever read, and most of a row
// is empty.
@(private)
scrollback_push :: proc(t: ^Term, line: Line) {
    line := line
    if t.scrollback_limit <= 0 {
        delete(line.cells)
        return
    }
    end := len(line.cells)
    for end > 0 {
        cell := line.cells[end - 1]
        if cell.ch != ' ' || cell.bg.kind != .Default || cell.attrs != {} {
            break
        }
        end -= 1
    }
    resize(&line.cells, end)
    shrink(&line.cells)

    if len(t.scrollback) >= t.scrollback_limit {
        oldest := t.scrollback[0]
        delete(oldest.cells)
        ordered_remove(&t.scrollback, 0)
    }
    append(&t.scrollback, line)
}
