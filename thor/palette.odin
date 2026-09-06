// The command palette: one overlay serving six modes (command list, quick-open,
// go-to-line, a text prompt, a yes/no confirmation and a fuzzy picker). State
// lives on `Thor`; `thor_palette_view` declares it from that state each frame.
package thor

import "core:slice"
import "core:strconv"
import "core:strings"

import ui "../vendor/loom/loom"

// Palette entry. Mode-switching entries (Go to File/Line) pass `thor` as `data`
// and flip the mode, which keeps the palette open (see thor_palette_activate).
Palette_Command :: struct {
    title:    string, // borrowed; owned by the registrar
    shortcut: string, // owned; "" when the command has no keybind
    run:      proc(data: rawptr),
    data:     rawptr,
}

// Single-line text prompt (New File/Folder name, ...): fires on Enter.
Palette_Prompt_Proc :: #type proc(data: rawptr, text: string)
// Yes/no confirmation (delete a file, ...): fires on Enter, cancels on Escape.
Palette_Confirm_Proc :: #type proc(data: rawptr)
// Fuzzy pick from a caller-supplied list (theme, font, branch, ...).
Palette_Pick_Proc :: #type proc(data: rawptr, choice: string)
// Rich fuzzy pick (symbol lists): fires with the chosen item's index into the
// caller's own slice, so the caller maps it back to its own data.
Palette_Pick_Index_Proc :: #type proc(data: rawptr, index: int)
// Rich Pick mode only: fires after user input changes the query, so a picker
// whose rows come from a server can re-dispatch instead of only re-filtering.
Palette_Query_Changed_Proc :: #type proc(data: rawptr, query: string)

// One row of a rich pick. `text` is drawn and fuzzy-matched whole; its leading
// `name_len` bytes take `color`, the remainder is dimmed. `detail` is a preview
// line under the list for the selected row; "" hides it.
Pick_Item :: struct {
    text:     string, // owned
    name_len: int,
    color:    ui.Color,
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
Palette_Match :: struct {
    index: int,
    score: int,
}

PALETTE_WIDTH :: f32(720)
PALETTE_ROW_H :: f32(30)
PALETTE_INPUT_H :: f32(44)
PALETTE_MAX_ROWS :: 10
PALETTE_TOP :: f32(90)

Palette :: struct {
    mode:                  Palette_Mode,
    commands:              [dynamic]Palette_Command,
    // Files and plain Pick mode: the candidate list. Owned.
    files:                 [dynamic]string,
    query:                 [dynamic]u8, // owned; ui.input edits it in place
    matches:               [dynamic]Palette_Match,
    selected:              int,
    scroll:                int,
    // Pane key the focus goes back to when the palette closes.
    return_focus:          string,
    // Set by an open, consumed by the view: the input takes the keyboard on the
    // frame it first appears.
    focus_pending:         bool,
    // Placeholder (Prompt/Pick) or message (Confirm). Borrowed from the opener.
    prompt_label:          string,
    prompt_run:            Palette_Prompt_Proc,
    prompt_data:           rawptr,
    confirm_run:           Palette_Confirm_Proc,
    confirm_cancel:        Palette_Confirm_Proc,
    confirm_data:          rawptr,
    pick_run:              Palette_Pick_Proc,
    pick_data:             rawptr,
    pick_items:            [dynamic]Pick_Item, // owned
    pick_rich:             bool,
    // True while a rich pick waits for rows computed off the main thread.
    pick_loading:          bool,
    // Shown instead of a bare empty list when a load lands with no rows. Owned.
    pick_hint:             string,
    pick_index_run:        Palette_Pick_Index_Proc,
    on_query_changed:      Palette_Query_Changed_Proc,
    on_query_changed_data: rawptr,
}

thor_palette_init :: proc(thor: ^Thor) {
    p := &thor.palette
    p.commands = make([dynamic]Palette_Command)
    p.files = make([dynamic]string)
    p.query = make([dynamic]u8)
    p.matches = make([dynamic]Palette_Match)
    p.pick_items = make([dynamic]Pick_Item)
}

thor_palette_destroy :: proc(thor: ^Thor) {
    p := &thor.palette
    palette_clear_files(p)
    delete(p.files)
    palette_clear_pick_items(p)
    delete(p.pick_items)
    thor_palette_clear_commands(thor)
    delete(p.commands)
    delete(p.query)
    delete(p.matches)
}

// Appends a command. `title` must outlive the palette; `shortcut` is copied.
thor_palette_add :: proc(
    thor: ^Thor,
    title: string,
    run: proc(data: rawptr),
    data: rawptr,
    shortcut := "",
) {
    sc := shortcut == "" ? "" : strings.clone(shortcut)
    append(
        &thor.palette.commands,
        Palette_Command{title = title, shortcut = sc, run = run, data = data},
    )
}

thor_palette_clear_commands :: proc(thor: ^Thor) {
    for command in thor.palette.commands {
        if len(command.shortcut) > 0 {
            delete(command.shortcut)
        }
    }
    clear(&thor.palette.commands)
}

thor_palette_is_open :: proc(thor: ^Thor) -> bool {
    return thor.palette_open
}

thor_palette_open :: proc(thor: ^Thor) {
    palette_show(thor, .Commands)
}

// Opens straight into Files mode (quick-open), so searching files to open is
// one chord.
thor_palette_open_files :: proc(thor: ^Thor) {
    palette_show(thor, .Files, reset = false)
    palette_enter_files(thor)
}

// Opens straight into Line mode (go-to-line).
thor_palette_open_line :: proc(thor: ^Thor) {
    palette_show(thor, .Line)
}

thor_palette_close :: proc(thor: ^Thor) {
    p := &thor.palette
    if !thor.palette_open {
        return
    }
    thor.palette_open = false
    // A confirmation dismissed unanswered reports itself, so its caller can drop
    // whatever it was asking about. Confirming clears the hook first.
    if p.mode == .Confirm && p.confirm_cancel != nil {
        cancel := p.confirm_cancel
        p.confirm_cancel = nil
        cancel(p.confirm_data)
    }
    if p.return_focus != "" {
        thor.focus_request = p.return_focus
    }
}

// Opens the palette as a single-line text prompt. `label` is the placeholder
// (borrowed); `run` fires with the typed text on Enter. `initial` prefills it.
thor_palette_prompt :: proc(
    thor: ^Thor,
    label: string,
    run: Palette_Prompt_Proc,
    data: rawptr,
    initial := "",
) {
    p := &thor.palette
    p.prompt_label = label
    p.prompt_run = run
    p.prompt_data = data
    palette_show(thor, .Prompt)
    if len(initial) > 0 {
        append(&p.query, initial)
        palette_refilter(thor)
    }
}

// Opens the palette as a yes/no confirmation. `run` fires on Enter; Escape or an
// outside click dismisses, firing `on_cancel` when one is given.
thor_palette_confirm :: proc(
    thor: ^Thor,
    message: string,
    run: Palette_Confirm_Proc,
    data: rawptr,
    on_cancel: Palette_Confirm_Proc = nil,
) {
    p := &thor.palette
    p.prompt_label = message
    p.confirm_run = run
    p.confirm_cancel = on_cancel
    p.confirm_data = data
    palette_show(thor, .Confirm)
}

// Opens a fuzzy picker over `items`; `run` fires with the chosen string. Items
// are copied, so the caller keeps ownership of its slice.
thor_palette_pick :: proc(
    thor: ^Thor,
    label: string,
    items: []string,
    run: Palette_Pick_Proc,
    data: rawptr,
) {
    p := &thor.palette
    palette_clear_files(p)
    for item in items {
        append(&p.files, strings.clone(item))
    }
    palette_clear_pick_items(p)
    p.prompt_label = label
    p.pick_run = run
    p.pick_data = data
    p.pick_rich = false
    p.pick_loading = false
    palette_show(thor, .Pick)
}

// Opens a rich fuzzy picker (symbol rows); `run` fires with the chosen item's
// index into `items`. Items are deep-copied.
thor_palette_pick_rich :: proc(
    thor: ^Thor,
    label: string,
    items: []Pick_Item,
    run: Palette_Pick_Index_Proc,
    data: rawptr,
) {
    p := &thor.palette
    palette_set_pick_items(p, items)
    p.prompt_label = label
    p.pick_index_run = run
    p.pick_data = data
    p.pick_rich = true
    p.pick_loading = false
    palette_show(thor, .Pick)
}

// Opens a rich pick whose rows are still being computed off-thread. The picker
// appears at once with a loading hint; thor_palette_pick_rich_set lands the
// rows. Enter on the empty list is a harmless no-op until then.
thor_palette_pick_rich_loading :: proc(
    thor: ^Thor,
    label: string,
    run: Palette_Pick_Index_Proc,
    data: rawptr,
    on_query_changed: Palette_Query_Changed_Proc = nil,
    on_query_changed_data: rawptr = nil,
) {
    p := &thor.palette
    palette_clear_pick_items(p)
    p.prompt_label = label
    p.pick_index_run = run
    p.pick_data = data
    p.pick_rich = true
    p.pick_loading = true
    palette_show(thor, .Pick)
    p.on_query_changed = on_query_changed
    p.on_query_changed_data = on_query_changed_data
}

// True while a rich pick is open and still waiting for its async rows. The owner
// checks this before applying a landing result, so a scan that finishes after
// the picker closed (or another one opened) is dropped.
thor_palette_pick_loading :: proc(thor: ^Thor) -> bool {
    p := &thor.palette
    return thor.palette_open && p.mode == .Pick && p.pick_rich && p.pick_loading
}

// Marks an open rich pick as waiting for a fresh set of rows again, without
// clearing the ones already showing, for an on_query_changed hook that
// re-dispatches. A no-op outside Rich Pick mode.
thor_palette_set_loading :: proc(thor: ^Thor) {
    p := &thor.palette
    if p.mode == .Pick && p.pick_rich {
        p.pick_loading = true
    }
}

// Fills an open loading rich pick with its rows, keeping the typed query and
// re-ranking against it. No-op unless a loading pick is open, so a stale result
// cannot clobber a picker the user has moved on from.
thor_palette_pick_rich_set :: proc(thor: ^Thor, items: []Pick_Item, hint: string = "") {
    if !thor_palette_pick_loading(thor) {
        return
    }
    p := &thor.palette
    palette_set_pick_items(p, items)
    p.pick_loading = false
    if len(items) == 0 && hint != "" {
        p.pick_hint = strings.clone(hint)
    }
    palette_refilter(thor)
}

// Command hooks (registered with data = the Thor) that switch modes in place.
thor_palette_goto_file_command :: proc(data: rawptr) {
    palette_enter_files(cast(^Thor)data)
}

thor_palette_goto_line_command :: proc(data: rawptr) {
    palette_reset(cast(^Thor)data, .Line)
}

// ---- internals ---------------------------------------------------------------

@(private = "file")
palette_show :: proc(thor: ^Thor, mode: Palette_Mode, reset := true) {
    p := &thor.palette
    // A command that opens a nested mode runs while the palette already has the
    // focus; capturing then would point return_focus at the palette itself.
    if !thor.palette_open {
        p.return_focus = thor.focus_owner
    }
    thor.palette_open = true
    p.focus_pending = true
    if reset {
        palette_reset(thor, mode)
    }
}

@(private = "file")
palette_reset :: proc(thor: ^Thor, mode: Palette_Mode) {
    p := &thor.palette
    p.mode = mode
    // Belongs to the picker that is closing; only an opener that wants one sets
    // it again, after this call.
    p.on_query_changed = nil
    p.on_query_changed_data = nil
    clear(&p.query)
    p.selected = 0
    p.scroll = 0
    palette_refilter(thor)
}

@(private = "file")
palette_enter_files :: proc(thor: ^Thor) {
    p := &thor.palette
    palette_clear_files(p)
    for path in thor_palette_list_files(thor) {
        append(&p.files, strings.clone(path))
    }
    palette_reset(thor, .Files)
}

@(private = "file")
palette_clear_files :: proc(p: ^Palette) {
    for path in p.files {
        delete(path)
    }
    clear(&p.files)
}

@(private = "file")
palette_set_pick_items :: proc(p: ^Palette, items: []Pick_Item) {
    palette_clear_pick_items(p)
    for item in items {
        append(
            &p.pick_items,
            Pick_Item {
                text = strings.clone(item.text),
                name_len = item.name_len,
                color = item.color,
                detail = item.detail == "" ? "" : strings.clone(item.detail),
            },
        )
    }
}

@(private = "file")
palette_clear_pick_items :: proc(p: ^Palette) {
    for item in p.pick_items {
        delete(item.text)
        if len(item.detail) > 0 {
            delete(item.detail)
        }
    }
    clear(&p.pick_items)
    if p.pick_hint != "" {
        delete(p.pick_hint)
        p.pick_hint = ""
    }
}

// Path shown and matched in Files mode: workspace-relative.
@(private = "file")
palette_display :: proc(thor: ^Thor, index: int) -> string {
    p := &thor.palette
    switch p.mode {
    case .Commands:
        return p.commands[index].title
    case .Files:
        return strings.trim_prefix(p.files[index], thor.workspace_prefix)
    case .Pick:
        return p.pick_rich ? p.pick_items[index].text : p.files[index]
    case .Line, .Prompt, .Confirm:
        return ""
    }
    return ""
}

@(private = "file")
palette_source_count :: proc(thor: ^Thor) -> int {
    p := &thor.palette
    switch p.mode {
    case .Commands:
        return len(p.commands)
    case .Files:
        return len(p.files)
    case .Pick:
        return p.pick_rich ? len(p.pick_items) : len(p.files)
    case .Line, .Prompt, .Confirm:
        return 0
    }
    return 0
}

// Rebuilds matches from the query: empty keeps source order, else fuzzy-ranked.
@(private = "file")
palette_refilter :: proc(thor: ^Thor) {
    p := &thor.palette
    clear(&p.matches)
    query := string(p.query[:])
    for i in 0 ..< palette_source_count(thor) {
        if score, ok := fuzzy_score(query, palette_display(thor, i)); ok {
            append(&p.matches, Palette_Match{index = i, score = score})
        }
    }
    if len(query) > 0 {
        slice.stable_sort_by(p.matches[:], proc(a, b: Palette_Match) -> bool {
            return a.score > b.score
        })
    }
    p.selected = 0
    p.scroll = 0
}

// Re-filters and, in Rich Pick mode with a hook installed, tells the owner the
// query changed. Never called from the reset a picker opens with.
@(private = "file")
palette_query_changed :: proc(thor: ^Thor) {
    p := &thor.palette
    palette_refilter(thor)
    if p.mode == .Pick && p.on_query_changed != nil {
        p.on_query_changed(p.on_query_changed_data, string(p.query[:]))
    }
}

@(private = "file")
palette_move :: proc(thor: ^Thor, delta: int) {
    p := &thor.palette
    count := len(p.matches)
    if count == 0 {
        return
    }
    p.selected = clamp(p.selected + delta, 0, count - 1)
    if p.selected < p.scroll {
        p.scroll = p.selected
    } else if p.selected >= p.scroll + PALETTE_MAX_ROWS {
        p.scroll = p.selected - PALETTE_MAX_ROWS + 1
    }
}

@(private = "file")
palette_activate :: proc(thor: ^Thor) {
    p := &thor.palette
    switch p.mode {
    case .Commands:
        if p.selected < 0 || p.selected >= len(p.matches) {
            return
        }
        command := p.commands[p.matches[p.selected].index]
        if command.run != nil {
            command.run(command.data)
        }
        // Mode-switching commands (Go to File / Line) keep the palette open;
        // anything else runs and dismisses it.
        if p.mode == .Commands {
            thor_palette_close(thor)
        }
    case .Files:
        if p.selected < 0 || p.selected >= len(p.matches) {
            return
        }
        // Copy: closing the palette may free the list.
        path := strings.clone(p.files[p.matches[p.selected].index], context.temp_allocator)
        thor_palette_close(thor)
        thor_palette_open_file(thor, path)
    case .Line:
        line, ok := strconv.parse_int(string(p.query[:]))
        thor_palette_close(thor)
        if ok && line > 0 {
            thor_palette_goto_line(thor, line)
        }
    case .Prompt:
        // Copy and close first: the callback may open the next prompt, which
        // resets the query the text points into.
        text := strings.clone(strings.trim_space(string(p.query[:])), context.temp_allocator)
        run := p.prompt_run
        data := p.prompt_data
        thor_palette_close(thor)
        if text != "" && run != nil {
            run(data, text)
        }
    case .Confirm:
        run := p.confirm_run
        data := p.confirm_data
        p.confirm_cancel = nil // answered: the dismissal hook must not fire
        thor_palette_close(thor)
        if run != nil {
            run(data)
        }
    case .Pick:
        if p.selected < 0 || p.selected >= len(p.matches) {
            return
        }
        index := p.matches[p.selected].index
        if p.pick_rich {
            run := p.pick_index_run
            data := p.pick_data
            thor_palette_close(thor)
            if run != nil {
                run(data, index)
            }
            return
        }
        choice := strings.clone(p.files[index], context.temp_allocator)
        run := p.pick_run
        data := p.pick_data
        thor_palette_close(thor)
        if run != nil {
            run(data, choice)
        }
    }
}

// ---- the view ----------------------------------------------------------------

@(private = "file")
palette_placeholder :: proc(p: ^Palette) -> string {
    switch p.mode {
    case .Commands:
        return "Type a command"
    case .Files:
        return "Go to file"
    case .Line:
        return "Go to line"
    case .Prompt, .Pick:
        return p.prompt_label
    case .Confirm:
        return ""
    }
    return ""
}

thor_palette_view :: proc(thor: ^Thor) {
    if !thor.palette_open {
        return
    }
    p := &thor.palette

    // The backdrop covers the window, so a click outside the box dismisses.
    ui.scope(
        {
            key = "palette-backdrop",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                align = .Center,
                z = 400,
                bg = ui.Color{0, 0, 0, 120},
            },
        },
    )

    palette_box(thor)

    palette_keys(thor)
    _ = p
}

@(private = "file")
palette_box :: proc(thor: ^Thor) {
    p := &thor.palette

    ui.scope(
        {
            key = "palette-box",
            flags = {.Clickable},
            props = {
                w = ui.Px(PALETTE_WIDTH),
                max_w = ui.viewport().x - 80,
                h = ui.FIT,
                dir = .Column,
                margin = {t = PALETTE_TOP},
                pad = ui.all(6),
                gap = {0, 4},
                bg = thor.theme.second_background,
                radius = ui.rad(8),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 6}, blur = 24, color = thor.theme.contrast},
            },
        },
    )

    if p.mode == .Confirm {
        ui.label(
            p.prompt_label,
            {key = "msg", props = {pad = ui.xy(8, 10), color = thor.theme.foreground}},
        )
        ui.label(
            "Enter to confirm, Escape to cancel",
            {key = "hint", props = {pad = ui.xy(8, 2), color = thor.theme.muted_color}},
        )
    } else {
        it := ui.input(
            &p.query,
            {
                key = "query",
                props = {
                    h = ui.Px(PALETTE_INPUT_H - 12),
                    align = .Center,
                    bg = thor.theme.background,
                    color = thor.theme.foreground,
                },
            },
            palette_placeholder(p),
        )
        if p.focus_pending {
            ui.set_focus(it.id)
            p.focus_pending = false
        }
        if it.changed {
            // Line mode takes digits only, and ui.input has no filter of its own.
            if p.mode == .Line {
                palette_keep_digits(&p.query)
            }
            palette_query_changed(thor)
        }
    }

    palette_list(thor)
}

@(private = "file")
palette_keep_digits :: proc(buf: ^[dynamic]u8) {
    keep := 0
    for i in 0 ..< len(buf) {
        if buf[i] >= '0' && buf[i] <= '9' {
            buf[keep] = buf[i]
            keep += 1
        }
    }
    resize(buf, keep)
}

@(private = "file")
palette_keys :: proc(thor: ^Thor) {
    if ui.take_key(.Escape) {
        thor_palette_close(thor)
        return
    }
    if ui.take_key(.Enter) || ui.take_key(.Pad_Enter) {
        palette_activate(thor)
        return
    }
    if ui.take_key(.Up) {
        palette_move(thor, -1)
    }
    if ui.take_key(.Down) {
        palette_move(thor, 1)
    }
    if ui.take_key(.Page_Up) {
        palette_move(thor, -PALETTE_MAX_ROWS)
    }
    if ui.take_key(.Page_Down) {
        palette_move(thor, PALETTE_MAX_ROWS)
    }
}

@(private = "file")
palette_list :: proc(thor: ^Thor) {
    p := &thor.palette
    if p.mode == .Line || p.mode == .Prompt || p.mode == .Confirm {
        return
    }

    if len(p.matches) == 0 {
        if p.pick_rich && (p.pick_loading || p.pick_hint != "") {
            ui.label(
                p.pick_loading ? "Loading" : p.pick_hint,
                {key = "loading", props = {pad = ui.xy(10, 6), color = thor.theme.muted_color}},
            )
        }
        return
    }

    activate := false
    {
        list := ui.scope(
            {
                key = "list",
                flags = {.Clickable},
                props = {w = ui.Grow(1), h = ui.FIT, dir = .Column},
            },
        )
        if list.wheel.y != 0 {
            palette_move(thor, list.wheel.y > 0 ? 1 : -1)
        }

        p.scroll = clamp(p.scroll, 0, max(len(p.matches) - PALETTE_MAX_ROWS, 0))
        last := min(p.scroll + PALETTE_MAX_ROWS, len(p.matches))
        for i in p.scroll ..< last {
            ui.push_id_int(i64(i))
            if palette_row(thor, i) {
                p.selected = i
                activate = true
            }
            ui.pop_id()
        }
    }

    // The selected row's preview line, under the list.
    if p.mode == .Pick && p.pick_rich && p.selected < len(p.matches) {
        item := p.pick_items[p.matches[p.selected].index]
        if item.detail != "" {
            ui.label(
                item.detail,
                {
                    key = "detail",
                    props = {
                        pad = ui.xy(10, 4),
                        color = thor.theme.muted_color,
                        text_wrap = .Ellipsis,
                    },
                },
            )
        }
    }

    if activate {
        palette_activate(thor)
    }
}

// One list row. Reports whether it was clicked.
@(private = "file")
palette_row :: proc(thor: ^Thor, index: int) -> bool {
    p := &thor.palette
    source := p.matches[index].index
    on := index == p.selected

    it := ui.scope(
        {
            key = "row",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(PALETTE_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {8, 0},
                pad = ui.xy(10, 0),
                radius = ui.rad(4),
                bg = on ? thor.theme.selection_background : ui.Color{0, 0, 0, 0},
            },
            hover = {bg = thor.theme.buttons},
        },
    )

    if p.mode == .Pick && p.pick_rich {
        item := p.pick_items[source]
        spans: []ui.Text_Span
        if item.name_len > 0 && item.name_len <= len(item.text) {
            runs := make([]ui.Text_Span, 1, context.temp_allocator)
            runs[0] = {start = 0, end = item.name_len, color = item.color}
            spans = runs
        }
        ui.leaf(
            {
                key = "text",
                text = item.text,
                spans = spans,
                props = {
                    w = ui.Grow(1),
                    color = thor.theme.muted_color,
                    text_wrap = .Ellipsis,
                },
            },
        )
        return it.clicked
    }

    ui.label(
        palette_display(thor, source),
        {
            key = "text",
            props = {
                w = ui.Grow(1),
                color = on ? thor.theme.foreground : thor.theme.muted_color,
                text_wrap = .Ellipsis,
            },
        },
    )
    if p.mode == .Commands {
        if shortcut := p.commands[source].shortcut; shortcut != "" {
            ui.label(
                shortcut,
                {key = "sc", props = {color = thor.theme.disabled, text_wrap = .None}},
            )
        }
    }
    return it.clicked
}

// ---- fuzzy matching ------------------------------------------------------------

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
