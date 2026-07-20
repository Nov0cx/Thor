package widgets

import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../ui"

// Palette entry. Mode-switching entries (Go to File/Line) pass the palette as
// `data` and flip `mode`, which keeps it open (see command_palette_activate).
Command :: struct {
    title:    string, // borrowed; owned by the registrar (thor)
    shortcut: string, // owned; "" when the command has no keybind
    run:      proc(data: rawptr),
    data:     rawptr,
}

// Owner hooks so the palette can navigate files without knowing the workspace.
Palette_List_Files_Proc :: #type proc(data: rawptr) -> []string
Palette_Open_File_Proc :: #type proc(data: rawptr, path: string)
Palette_Goto_Line_Proc :: #type proc(data: rawptr, line: int)
// Single-line text prompt (New File/Folder name, etc.): fires on Enter.
Palette_Prompt_Proc :: #type proc(data: rawptr, text: string)
// Yes/no confirmation (delete a file, etc.): fires on Enter, cancels on Escape.
Palette_Confirm_Proc :: #type proc(data: rawptr)
// Fuzzy pick from a caller-supplied list (theme, font, branch, ...): fires with
// the chosen item on Enter/click.
Palette_Pick_Proc :: #type proc(data: rawptr, choice: string)
// Rich fuzzy pick (symbol lists): fires with the chosen item's index into the
// caller's original slice, so the caller maps it back to its own data.
Palette_Pick_Index_Proc :: #type proc(data: rawptr, index: int)

// One row of a rich pick (a symbol). `text` is drawn and fuzzy-matched whole;
// its leading `name_len` bytes are drawn in `color` (the identifier, tinted by
// kind), the remainder dimmed. `detail` is a dim preview line shown beneath the
// list for the selected row (e.g. "pkg/math.odin:42"); "" hides it.
Pick_Item :: struct {
    text:     string, // owned
    name_len: int,
    color:    rl.Color,
    detail:   string, // owned
}

Palette_Mode :: enum {
    Commands,
    Files,
    Line,
    Prompt,
    Confirm,
    Pick,
}

@(private = "file")
Match :: struct {
    index: int,
    score: int,
}

Command_Palette :: struct {
    using widget: ui.Widget,
    mode:         Palette_Mode,
    commands:     [dynamic]Command,
    // Files mode: full paths (owned), refreshed each time the mode is entered.
    files:        [dynamic]string,
    // Prefix trimmed from file paths for display/matching (workspace root).
    root_prefix:  string,
    query:        [dynamic]u8,
    matches:      [dynamic]Match,
    selected:     int,
    scroll:       int,
    // Focus handed back here when the palette closes (the editor).
    return_focus: ^ui.Widget,
    list_files:   Palette_List_Files_Proc,
    open_file:    Palette_Open_File_Proc,
    goto_line:    Palette_Goto_Line_Proc,
    cb_data:      rawptr,
    // Prompt mode: placeholder text and the callback fired with the typed
    // string on Enter. Set fresh each time the prompt is opened.
    prompt_label: string,
    prompt_run:   Palette_Prompt_Proc,
    prompt_data:  rawptr,
    // Confirm mode: the message shown and the callback fired on Enter.
    confirm_run:  Palette_Confirm_Proc,
    confirm_data: rawptr,
    // Pick mode: the callback fired with the chosen item (the list lives in
    // `files`, so it fuzzy-filters and scrolls like Files mode).
    pick_run:     Palette_Pick_Proc,
    pick_data:    rawptr,
    // Rich Pick mode: structured rows (colored name + dim signature + preview
    // footer). When pick_rich is set, the list draws from pick_items and Enter
    // fires pick_index_run with the source index instead of pick_run.
    pick_items:      [dynamic]Pick_Item,
    pick_rich:       bool,
    // True while a rich pick is open but its rows are still being computed off
    // the main thread (a workspace-symbol scan). Draws a "Loading…" hint until
    // command_palette_pick_rich_set lands the rows.
    pick_loading:    bool,
    pick_index_run:  Palette_Pick_Index_Proc,
    box:          rl.Rectangle,
    width:        f32,
    row_height:   f32,
    input_height: f32,
    max_rows:     int,
    top_offset:   f32,
    backdrop_color:   rl.Color,
    background_color: rl.Color,
    border_color:     rl.Color,
    input_color:      rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    selected_color:   rl.Color,
    accent_color:     rl.Color,
}

command_palette_vtable := ui.Widget_VTable {
    layout = command_palette_layout,
    handle_event = command_palette_handle_event,
    draw = command_palette_draw,
    destroy = command_palette_destroy,
}

command_palette_create :: proc(id: string) -> ^Command_Palette {
    palette := new(Command_Palette)
    ui.widget_init(&palette.widget, id, command_palette_vtable)
    palette.visible = false
    palette.commands = make([dynamic]Command)
    palette.files = make([dynamic]string)
    palette.query = make([dynamic]u8)
    palette.matches = make([dynamic]Match)
    palette.pick_items = make([dynamic]Pick_Item)
    palette.width = 720
    palette.row_height = 30
    palette.input_height = 44
    palette.max_rows = 10
    palette.top_offset = 90
    palette.backdrop_color = rl.Color {0, 0, 0, 120}
    palette.background_color = rl.Color {24, 26, 31, 250}
    palette.border_color = rl.Color {132, 255, 255, 255}
    palette.input_color = rl.Color {15, 17, 26, 255}
    palette.text_color = rl.Color {238, 255, 255, 255}
    palette.muted_color = rl.Color {120, 128, 160, 255}
    palette.selected_color = rl.Color {132, 255, 255, 40}
    palette.accent_color = rl.Color {132, 255, 255, 255}
    return palette
}

command_palette_set_colors :: proc(
    palette: ^Command_Palette,
    background, border, input, text, muted, selected, accent: rl.Color,
) -> ^Command_Palette {
    palette.background_color = background
    palette.border_color = border
    palette.input_color = input
    palette.text_color = text
    palette.muted_color = muted
    palette.selected_color = selected
    palette.accent_color = accent
    return palette
}

command_palette_set_navigation :: proc(
    palette: ^Command_Palette,
    list_files: Palette_List_Files_Proc,
    open_file: Palette_Open_File_Proc,
    goto_line: Palette_Goto_Line_Proc,
    root_prefix: string,
    data: rawptr,
) {
    palette.list_files = list_files
    palette.open_file = open_file
    palette.goto_line = goto_line
    palette.root_prefix = root_prefix
    palette.cb_data = data
}

// Appends a command. `title` must outlive the palette; `shortcut` is copied
// (shown right-aligned in the list, "" to hide it).
command_palette_add :: proc(palette: ^Command_Palette, title: string, run: proc(data: rawptr), data: rawptr, shortcut := "") {
    sc := shortcut == "" ? "" : strings.clone(shortcut)
    append(&palette.commands, Command {title = title, shortcut = sc, run = run, data = data})
}

command_palette_open :: proc(palette: ^Command_Palette, ctx: ^ui.Context) {
    palette.visible = true
    command_palette_reset(palette, .Commands)
    ctx.focused = &palette.widget
    ui.widget_bring_to_front(&palette.widget)
}

// Opens the palette straight into Files mode (quick-open), skipping the command
// list. Used by the quick_open keybind so searching files to open is one chord.
command_palette_open_files :: proc(palette: ^Command_Palette, ctx: ^ui.Context) {
    palette.visible = true
    command_palette_enter_files(palette)
    ctx.focused = &palette.widget
    ui.widget_bring_to_front(&palette.widget)
}

// Opens the palette straight into Line mode (go-to-line), used by the ctrl+g
// keybind so jumping to a line is a single chord.
command_palette_open_line :: proc(palette: ^Command_Palette, ctx: ^ui.Context) {
    palette.visible = true
    command_palette_reset(palette, .Line)
    ctx.focused = &palette.widget
    ui.widget_bring_to_front(&palette.widget)
}

command_palette_close :: proc(palette: ^Command_Palette, ctx: ^ui.Context) {
    palette.visible = false
    if ctx.focused == &palette.widget {
        ctx.focused = palette.return_focus
    }
}

command_palette_is_open :: proc(palette: ^Command_Palette) -> bool {
    return palette.visible
}

// Opens the palette as a single-line text prompt. `label` is the placeholder
// (borrowed); `run` fires with the typed text on Enter. `initial` prefills the
// input (used by rename to seed the current name), with the caret at its end.
command_palette_prompt :: proc(
    palette: ^Command_Palette,
    ctx: ^ui.Context,
    label: string,
    run: Palette_Prompt_Proc,
    data: rawptr,
    initial := "",
) {
    palette.prompt_label = label
    palette.prompt_run = run
    palette.prompt_data = data
    palette.visible = true
    command_palette_reset(palette, .Prompt)
    if len(initial) > 0 {
        append(&palette.query, ..transmute([]u8) initial)
        command_palette_refilter(palette)
    }
    ctx.focused = &palette.widget
    ui.widget_bring_to_front(&palette.widget)
}

// Opens the palette as a yes/no confirmation. `message` is shown (borrowed);
// `run` fires on Enter; Escape or an outside click dismisses.
command_palette_confirm :: proc(
    palette: ^Command_Palette,
    ctx: ^ui.Context,
    message: string,
    run: Palette_Confirm_Proc,
    data: rawptr,
) {
    palette.prompt_label = message
    palette.confirm_run = run
    palette.confirm_data = data
    palette.visible = true
    command_palette_reset(palette, .Confirm)
    ctx.focused = &palette.widget
    ui.widget_bring_to_front(&palette.widget)
}

// Opens the palette as a fuzzy picker over `items`. `label` is the placeholder
// (borrowed); `run` fires with the chosen string on Enter/click. Items are
// copied, so the caller keeps ownership of its slice.
command_palette_pick :: proc(
    palette: ^Command_Palette,
    ctx: ^ui.Context,
    label: string,
    items: []string,
    run: Palette_Pick_Proc,
    data: rawptr,
) {
    for path in palette.files {
        delete(path)
    }
    clear(&palette.files)
    for item in items {
        append(&palette.files, strings.clone(item))
    }
    palette.prompt_label = label
    palette.pick_run = run
    palette.pick_data = data
    palette.pick_rich = false
    palette.pick_loading = false
    palette.visible = true
    command_palette_reset(palette, .Pick)
    ctx.focused = &palette.widget
    ui.widget_bring_to_front(&palette.widget)
}

// Opens the palette as a rich fuzzy picker over `items` (symbol rows). `label`
// is the placeholder; `run` fires with the chosen item's index into `items` on
// Enter/click. Items are deep-copied, so the caller keeps ownership of its slice.
command_palette_pick_rich :: proc(
    palette: ^Command_Palette,
    ctx: ^ui.Context,
    label: string,
    items: []Pick_Item,
    run: Palette_Pick_Index_Proc,
    data: rawptr,
) {
    command_palette_set_pick_items(palette, items)
    palette.prompt_label = label
    palette.pick_index_run = run
    palette.pick_data = data
    palette.pick_rich = true
    palette.pick_loading = false
    palette.visible = true
    command_palette_reset(palette, .Pick)
    ctx.focused = &palette.widget
    ui.widget_bring_to_front(&palette.widget)
}

// Opens a rich pick whose rows are still being computed off-thread (a workspace
// symbol scan). The picker appears immediately with a "Loading…" hint so the
// chord stays responsive; call command_palette_pick_rich_set with the rows when
// the scan lands. Enter on the empty list is a harmless no-op until then.
command_palette_pick_rich_loading :: proc(
    palette: ^Command_Palette,
    ctx: ^ui.Context,
    label: string,
    run: Palette_Pick_Index_Proc,
    data: rawptr,
) {
    command_palette_clear_pick_items(palette)
    palette.prompt_label = label
    palette.pick_index_run = run
    palette.pick_data = data
    palette.pick_rich = true
    palette.pick_loading = true
    palette.visible = true
    command_palette_reset(palette, .Pick)
    ctx.focused = &palette.widget
    ui.widget_bring_to_front(&palette.widget)
}

// True while a rich pick is open and still waiting for its async rows. The owner
// checks this before applying a landing result, so a scan that finishes after the
// user closed the picker (or opened a different one) is dropped, not applied.
command_palette_pick_loading :: proc(palette: ^Command_Palette) -> bool {
    return palette.visible && palette.mode == .Pick && palette.pick_rich && palette.pick_loading
}

// Fills an open loading rich pick with its rows, preserving the query the user
// has already typed and re-ranking against it. No-op unless a loading pick is
// open (see command_palette_pick_loading), so a stale result can't clobber a
// picker the user has moved on from.
command_palette_pick_rich_set :: proc(palette: ^Command_Palette, items: []Pick_Item) {
    if !command_palette_pick_loading(palette) {
        return
    }
    command_palette_set_pick_items(palette, items)
    palette.pick_loading = false
    command_palette_refilter(palette)
}

// Deep-copies `items` into pick_items, replacing whatever was there.
@(private = "file")
command_palette_set_pick_items :: proc(palette: ^Command_Palette, items: []Pick_Item) {
    command_palette_clear_pick_items(palette)
    for it in items {
        append(&palette.pick_items, Pick_Item {
            text     = strings.clone(it.text),
            name_len = it.name_len,
            color    = it.color,
            detail   = it.detail == "" ? "" : strings.clone(it.detail),
        })
    }
}

@(private = "file")
command_palette_clear_pick_items :: proc(palette: ^Command_Palette) {
    for it in palette.pick_items {
        delete(it.text)
        if len(it.detail) > 0 {
            delete(it.detail)
        }
    }
    clear(&palette.pick_items)
}

@(private = "file")
command_palette_reset :: proc(palette: ^Command_Palette, mode: Palette_Mode) {
    palette.mode = mode
    clear(&palette.query)
    palette.selected = 0
    palette.scroll = 0
    command_palette_refilter(palette)
}

@(private = "file")
command_palette_enter_files :: proc(palette: ^Command_Palette) {
    for path in palette.files {
        delete(path)
    }
    clear(&palette.files)
    if palette.list_files != nil {
        for path in palette.list_files(palette.cb_data) {
            append(&palette.files, strings.clone(path))
        }
    }
    command_palette_reset(palette, .Files)
}

// Path shown/matched in Files mode: workspace-relative, forward slashes.
@(private = "file")
command_palette_display :: proc(palette: ^Command_Palette, index: int) -> string {
    switch palette.mode {
    case .Commands:
        return palette.commands[index].title
    case .Files:
        return strings.trim_prefix(palette.files[index], palette.root_prefix)
    case .Pick:
        return palette.pick_rich ? palette.pick_items[index].text : palette.files[index]
    case .Line, .Prompt, .Confirm:
        return ""
    }
    return ""
}

@(private = "file")
command_palette_source_count :: proc(palette: ^Command_Palette) -> int {
    switch palette.mode {
    case .Commands:               return len(palette.commands)
    case .Files:                  return len(palette.files)
    case .Pick:                   return palette.pick_rich ? len(palette.pick_items) : len(palette.files)
    case .Line, .Prompt, .Confirm: return 0
    }
    return 0
}

// Rebuilds matches from the query: empty keeps source order, else fuzzy-ranked.
@(private = "file")
command_palette_refilter :: proc(palette: ^Command_Palette) {
    clear(&palette.matches)
    query := string(palette.query[:])
    for i in 0 ..< command_palette_source_count(palette) {
        if score, ok := fuzzy_score(query, command_palette_display(palette, i)); ok {
            append(&palette.matches, Match {index = i, score = score})
        }
    }
    if len(query) > 0 {
        slice.stable_sort_by(palette.matches[:], proc(a, b: Match) -> bool {
            return a.score > b.score
        })
    }
    palette.selected = 0
    palette.scroll = 0
}

@(private = "file")
command_palette_move_selection :: proc(palette: ^Command_Palette, delta: int) {
    count := len(palette.matches)
    if count == 0 {
        return
    }
    palette.selected = clamp(palette.selected + delta, 0, count - 1)
    if palette.selected < palette.scroll {
        palette.scroll = palette.selected
    } else if palette.selected >= palette.scroll + palette.max_rows {
        palette.scroll = palette.selected - palette.max_rows + 1
    }
}

@(private = "file")
command_palette_activate :: proc(palette: ^Command_Palette, ctx: ^ui.Context) {
    switch palette.mode {
    case .Commands:
        if palette.selected < 0 || palette.selected >= len(palette.matches) {
            return
        }
        command := palette.commands[palette.matches[palette.selected].index]
        if command.run != nil {
            command.run(command.data)
        }
        // Mode-switching commands (Go to File / Line) keep the palette open;
        // anything else runs and dismisses it.
        if palette.mode == .Commands {
            command_palette_close(palette, ctx)
        }
    case .Files:
        if palette.selected < 0 || palette.selected >= len(palette.matches) {
            return
        }
        path := palette.files[palette.matches[palette.selected].index]
        if palette.open_file != nil {
            palette.open_file(palette.cb_data, path)
        }
        command_palette_close(palette, ctx)
    case .Line:
        if line, ok := strconv.parse_int(string(palette.query[:])); ok && line > 0 && palette.goto_line != nil {
            palette.goto_line(palette.cb_data, line)
        }
        command_palette_close(palette, ctx)
    case .Prompt:
        text := strings.trim_space(string(palette.query[:]))
        if text != "" && palette.prompt_run != nil {
            palette.prompt_run(palette.prompt_data, text)
        }
        command_palette_close(palette, ctx)
    case .Confirm:
        run := palette.confirm_run
        data := palette.confirm_data
        command_palette_close(palette, ctx)
        if run != nil {
            run(data)
        }
    case .Pick:
        if palette.selected < 0 || palette.selected >= len(palette.matches) {
            return
        }
        index := palette.matches[palette.selected].index
        if palette.pick_rich {
            run := palette.pick_index_run
            data := palette.pick_data
            command_palette_close(palette, ctx)
            if run != nil {
                run(data, index)
            }
            return
        }
        choice := palette.files[index]
        run := palette.pick_run
        data := palette.pick_data
        // Copy: closing the palette (or the callback) may free the list.
        choice = strings.clone(choice, context.temp_allocator)
        command_palette_close(palette, ctx)
        if run != nil {
            run(data, choice)
        }
    }
}

// Command hooks (registered with data = the palette) that switch modes.
command_palette_goto_file_command :: proc(data: rawptr) {
    command_palette_enter_files(cast(^Command_Palette) data)
}

command_palette_goto_line_command :: proc(data: rawptr) {
    command_palette_reset(cast(^Command_Palette) data, .Line)
}

command_palette_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    palette := cast(^Command_Palette) widget
    // Capture the whole screen so clicks outside the box dismiss the palette.
    palette.bounds = bounds

    visible_rows := min(len(palette.matches), palette.max_rows)
    if palette.mode == .Line || palette.mode == .Prompt || palette.mode == .Confirm {
        visible_rows = 0
    }
    // Rich pick reserves one extra row beneath the list for the preview footer.
    footer_rows := (palette.mode == .Pick && palette.pick_rich && visible_rows > 0) ? 1 : 0
    // A loading rich pick with no rows yet reserves one row for the "Loading…" hint.
    loading_rows := (palette.mode == .Pick && palette.pick_rich && palette.pick_loading && visible_rows == 0) ? 1 : 0
    width := min(palette.width, bounds.width - 80)
    height := palette.input_height + cast(f32) (visible_rows + footer_rows + loading_rows) * palette.row_height + 10

    palette.box = rl.Rectangle {
        x = bounds.x + (bounds.width - width) * 0.5,
        y = bounds.y + palette.top_offset,
        width = width,
        height = height,
    }
}

command_palette_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    palette := cast(^Command_Palette) widget
    if !palette.visible {
        return false
    }

    #partial switch event.kind {
    case .Text_Input:
        if palette.mode == .Confirm {
            return true // confirmation takes no text, only Enter/Escape
        }
        if event.ctrl && !event.alt {
            return true // swallow control chords, don't type them
        }
        if event.codepoint >= 32 && event.codepoint != 127 {
            // Line mode only accepts digits.
            if palette.mode == .Line && (event.codepoint < '0' || event.codepoint > '9') {
                return true
            }
            buffer, width := utf8.encode_rune(event.codepoint)
            append(&palette.query, ..buffer[:width])
            command_palette_refilter(palette)
        }
        return true

    case .Key_Press:
        #partial switch event.key {
        case .ESCAPE:
            command_palette_close(palette, ctx)
        case .ENTER, .KP_ENTER:
            command_palette_activate(palette, ctx)
        case .BACKSPACE:
            command_palette_pop_rune(palette)
            command_palette_refilter(palette)
        case .UP:
            command_palette_move_selection(palette, -1)
        case .DOWN:
            command_palette_move_selection(palette, 1)
        case .PAGE_UP:
            command_palette_move_selection(palette, -palette.max_rows)
        case .PAGE_DOWN:
            command_palette_move_selection(palette, palette.max_rows)
        }
        return true

    case .Mouse_Down:
        if !rl.CheckCollisionPointRec(event.mouse_position, palette.box) {
            command_palette_close(palette, ctx)
            return true
        }
        row := command_palette_row_at(palette, event.mouse_position)
        if row >= 0 {
            palette.selected = row
            command_palette_activate(palette, ctx)
        }
        return true

    case .Scroll:
        command_palette_move_selection(palette, event.wheel_delta > 0 ? -1 : 1)
        return true
    }

    return true // block everything else from reaching widgets underneath
}

@(private = "file")
command_palette_pop_rune :: proc(palette: ^Command_Palette) {
    n := len(palette.query)
    if n == 0 {
        return
    }
    // Trim continuation bytes (0b10xxxxxx) then the lead byte.
    i := n - 1
    for i > 0 && (palette.query[i] & 0xC0) == 0x80 {
        i -= 1
    }
    resize(&palette.query, i)
}

@(private = "file")
command_palette_row_at :: proc(palette: ^Command_Palette, point: rl.Vector2) -> int {
    list_top := palette.box.y + palette.input_height
    if point.y < list_top {
        return -1
    }
    row := palette.scroll + cast(int) ((point.y - list_top) / palette.row_height)
    if row < 0 || row >= len(palette.matches) {
        return -1
    }
    return row
}

command_palette_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    palette := cast(^Command_Palette) widget
    if !palette.visible {
        return
    }

    rl.DrawRectangleRec(palette.bounds, palette.backdrop_color)
    rl.DrawRectangleRec(palette.box, palette.background_color)
    rl.DrawRectangleLinesEx(palette.box, 1, palette.border_color)

    if palette.mode == .Confirm {
        message_x := cast(i32) (palette.box.x + 16)
        message_y := cast(i32) (palette.box.y + 12)
        ui.draw_text(palette.prompt_label, message_x, message_y, 18, palette.text_color)
        ui.draw_text("Enter to confirm  ·  Esc to cancel", message_x, message_y + 24, 15, palette.muted_color)
        return
    }

    // Input row.
    pad: f32 = 12
    input_rect := rl.Rectangle {palette.box.x + 6, palette.box.y + 6, palette.box.width - 12, palette.input_height - 12}
    rl.DrawRectangleRec(input_rect, palette.input_color)

    text_y := cast(i32) (input_rect.y + (input_rect.height - 18) * 0.5)
    text_x := cast(i32) (input_rect.x + pad)
    query := string(palette.query[:])
    if len(query) == 0 {
        rl.DrawRectangleRec(input_rect, palette.input_color)
        ui.draw_text(command_palette_placeholder(palette), text_x, text_y, 18, palette.muted_color)
    } else {
        ui.draw_text(query, text_x, text_y, 18, palette.text_color)
    }
    // Caret after the query text.
    caret_x := text_x + ui.measure_text(query, 18) + 2
    rl.DrawRectangle(caret_x, text_y, 2, 18, palette.accent_color)

    if palette.mode == .Line || palette.mode == .Prompt {
        return
    }

    ui.begin_clip(palette.box)
    defer ui.end_clip()

    list_top := palette.box.y + palette.input_height
    visible := min(len(palette.matches), palette.max_rows)
    for i in 0 ..< visible {
        row := palette.scroll + i
        if row >= len(palette.matches) {
            break
        }
        row_y := list_top + cast(f32) i * palette.row_height
        row_rect := rl.Rectangle {palette.box.x, row_y, palette.box.width, palette.row_height}
        if row == palette.selected {
            rl.DrawRectangleRec(row_rect, palette.selected_color)
        }

        index := palette.matches[row].index
        row_text_y := cast(i32) (row_y + (palette.row_height - 17) * 0.5)
        if palette.mode == .Files {
            command_palette_draw_file_row(palette, index, cast(i32) (palette.box.x + pad), row_text_y)
        } else if palette.mode == .Pick {
            if palette.pick_rich {
                command_palette_draw_symbol_row(palette, index, cast(i32) (palette.box.x + pad), row_text_y)
            } else {
                ui.draw_text(palette.files[index], cast(i32) (palette.box.x + pad), row_text_y, 17, palette.text_color)
            }
        } else {
            command := palette.commands[index]
            ui.draw_text(command.title, cast(i32) (palette.box.x + pad), row_text_y, 17, palette.text_color)
            if len(command.shortcut) > 0 {
                shortcut_width := ui.measure_text(command.shortcut, 15)
                shortcut_x := cast(i32) (palette.box.x + palette.box.width - pad) - shortcut_width - 6
                ui.draw_text(command.shortcut, shortcut_x, row_text_y, 15, palette.muted_color)
            }
        }
    }

    // Loading rich pick with no rows yet: a dim hint where the list will appear.
    if palette.mode == .Pick && palette.pick_rich && palette.pick_loading && len(palette.matches) == 0 {
        row_text_y := cast(i32) (list_top + (palette.row_height - 17) * 0.5)
        ui.draw_text("Loading workspace symbols...", cast(i32) (palette.box.x + pad), row_text_y, 17, palette.muted_color)
    }

    // Rich pick: a dim preview line under the list for the selected symbol,
    // showing where it lives (e.g. "pkg/math.odin:42").
    if palette.mode == .Pick && palette.pick_rich && len(palette.matches) > 0 {
        sel := palette.matches[palette.selected].index
        detail := palette.pick_items[sel].detail
        if len(detail) > 0 {
            footer_y := cast(i32) (list_top + cast(f32) visible * palette.row_height + 7)
            ui.draw_text(detail, cast(i32) (palette.box.x + pad), footer_y, 15, palette.muted_color)
        }
    }

    command_palette_draw_scrollbar(palette, list_top)
}

// Draws a rich pick row: the identifier in its kind color, then the rest of the
// signature (":: proc(...)") dimmed.
@(private = "file")
command_palette_draw_symbol_row :: proc(palette: ^Command_Palette, index: int, x, y: i32) {
    item := palette.pick_items[index]
    name_len := clamp(item.name_len, 0, len(item.text))
    name := item.text[:name_len]
    ui.draw_text(name, x, y, 17, item.color)
    rest := item.text[name_len:]
    if len(rest) > 0 {
        ui.draw_text(rest, x + ui.measure_text(name, 17), y, 17, palette.muted_color)
    }
}

// Draws a scrollbar on the right of the list when the matches overflow the
// visible rows; the thumb tracks palette.scroll.
@(private = "file")
command_palette_draw_scrollbar :: proc(palette: ^Command_Palette, list_top: f32) {
    total := len(palette.matches)
    if total <= palette.max_rows {
        return
    }

    track_height := cast(f32) palette.max_rows * palette.row_height
    width: f32 = 5
    x := palette.box.x + palette.box.width - width - 2
    rl.DrawRectangleRec(rl.Rectangle {x, list_top, width, track_height}, palette.input_color)

    thumb_height := max(track_height * cast(f32) palette.max_rows / cast(f32) total, 24)
    max_scroll := total - palette.max_rows
    t := max_scroll > 0 ? cast(f32) palette.scroll / cast(f32) max_scroll : 0
    thumb_y := list_top + (track_height - thumb_height) * t
    rl.DrawRectangleRec(rl.Rectangle {x, thumb_y, width, thumb_height}, palette.muted_color)
}

// Draws a file row as "name  dir/" with the directory dimmed.
@(private = "file")
command_palette_draw_file_row :: proc(palette: ^Command_Palette, index: int, x, y: i32) {
    rel := strings.trim_prefix(palette.files[index], palette.root_prefix)
    slash := max(strings.last_index_byte(rel, '/'), strings.last_index_byte(rel, '\\'))
    name := slash < 0 ? rel : rel[slash + 1:]
    ui.draw_text(name, x, y, 17, palette.text_color)
    if slash > 0 {
        dir := rel[:slash]
        ui.draw_text(dir, x + ui.measure_text(name, 17) + 12, y, 17, palette.muted_color)
    }
}

@(private = "file")
command_palette_placeholder :: proc(palette: ^Command_Palette) -> string {
    switch palette.mode {
    case .Commands: return "Type a command..."
    case .Files:    return "Go to file..."
    case .Line:     return "Go to line number..."
    case .Prompt:   return palette.prompt_label
    case .Confirm:  return palette.prompt_label
    case .Pick:     return palette.prompt_label
    }
    return ""
}

command_palette_destroy :: proc(widget: ^ui.Widget) {
    palette := cast(^Command_Palette) widget
    for path in palette.files {
        delete(path)
    }
    delete(palette.files)
    command_palette_clear_pick_items(palette)
    delete(palette.pick_items)
    for command in palette.commands {
        if len(command.shortcut) > 0 {
            delete(command.shortcut)
        }
    }
    delete(palette.commands)
    delete(palette.query)
    delete(palette.matches)
    free(palette)
}

// Case-insensitive subsequence match, scoring consecutive runs and word starts.
// Empty query matches all (score 0); ok=false when a query char is missing.
fuzzy_score :: proc(query, text: string) -> (score: int, ok: bool) {
    if len(query) == 0 {
        return 0, true
    }

    qi := 0
    streak := 0
    prev_sep := true
    for i in 0 ..< len(text) {
        if qi >= len(query) {
            break
        }
        if ascii_lower(text[i]) == ascii_lower(query[qi]) {
            score += 1
            if streak > 0 {
                score += 5
            }
            if prev_sep {
                score += 10
            }
            if i == 0 {
                score += 5
            }
            streak += 1
            qi += 1
        } else {
            streak = 0
        }
        prev_sep = is_separator(text[i])
    }
    if qi < len(query) {
        return 0, false
    }
    // Prefer tighter matches (less trailing text).
    score -= (len(text) - len(query)) / 8
    return score, true
}

@(private = "file")
ascii_lower :: proc(b: u8) -> u8 {
    return b >= 'A' && b <= 'Z' ? b + 32 : b
}

@(private = "file")
is_separator :: proc(b: u8) -> bool {
    switch b {
    case ' ', '\t', '/', '\\', '_', '-', '.', ':':
        return true
    }
    return false
}
