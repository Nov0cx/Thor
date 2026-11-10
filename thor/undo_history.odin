package thor

import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "../editview"
import "../textedit"
import ui "../vendor/loom/loom"

// The Undo History modal: the undo tree of one buffer as a graph, newest first, with a diff of the selected step.
// Moving the selection moves the buffer; Enter keeps that state, Escape goes back to the start.

UNDO_VIEW_WIDTH :: 980
UNDO_ROW_H :: f32(28)
UNDO_LANE_W :: f32(14)
UNDO_DIFF_ROW_H :: f32(20)
// Bytes of op text a label quotes.
UNDO_HISTORY_SNIPPET :: 40
// Context lines above and below each hunk of the diff.
UNDO_DIFF_CONTEXT :: 2
UNDO_DIFF_HUNKS :: 3
UNDO_DIFF_ROWS :: 60

// State of the Undo History modal.
Undo_View :: struct {
    path:           string,                    // owned
    rows:           [dynamic]Undo_Graph_Row,   // owned
    // The node the buffer held when the modal opened.
    origin:         int,
    selected:       int,
    // The buffer revision after the modal's last move; any other value means the buffer changed under it.
    revision:       u64,
    lanes:          int,
    branches:       int,
    return_focus:   string, // borrowed focus owner when it opened
    focus_pending:  bool,
    scroll_pending: bool,
}

// One row of the step diff.
@(private)
Undo_Diff_Row :: struct {
    kind: Git_Diff_Row_Kind,
    line: int, // 1-based; 0 for none
    text: string,
}

// Opens the Undo History modal over the focused buffer.
thor_cmd_undo_history :: proc(data: rawptr) {
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    state := &file.state
    if textedit.history_root(state) == textedit.NO_NODE {
        thor_flash_status(thor, "No undo history")
        return
    }
    v := &thor.undo_view
    if !thor.undo_open {
        v.return_focus = thor.focus_owner
    }
    thor_clear_undo_history(thor)
    v.path = strings.clone(file.path)
    v.origin = textedit.history_current(state)
    undo_view_rebuild(v, file)
    v.focus_pending = true
    v.scroll_pending = true
    thor.undo_open = true
}

// Frees what the Undo History modal holds.
thor_clear_undo_history :: proc(thor: ^Thor) {
    v := &thor.undo_view
    delete(v.path)
    v.path = ""
    clear(&v.rows)
}

thor_undo_history_destroy :: proc(thor: ^Thor) {
    thor_clear_undo_history(thor)
    delete(thor.undo_view.rows)
    thor.undo_view.rows = nil
}

// Closes the modal. Without `keep`, the buffer goes back to the state it held at open.
thor_undo_history_close :: proc(thor: ^Thor, keep: bool) {
    if !thor.undo_open {
        return
    }
    v := &thor.undo_view
    if file := undo_view_file(thor); !keep && file != nil && file.state.revision == v.revision {
        if textedit.history_current(&file.state) != v.origin && textedit.undo_goto(&file.state, v.origin) {
            undo_view_after_move(thor, file)
        }
    }
    thor.undo_open = false
    if v.return_focus != "" {
        thor.focus_request = v.return_focus
    }
    thor_clear_undo_history(thor)
}

// The open file the modal shows; nil when it was closed.
@(private = "file")
undo_view_file :: proc(thor: ^Thor) -> ^Open_File {
    file := thor_open_file_at(thor, thor.undo_view.path)
    if file == nil || !file.loaded || file.closed {
        return nil
    }
    return file
}

// Lays the rows out again and selects the current node.
@(private = "file")
undo_view_rebuild :: proc(v: ^Undo_View, file: ^Open_File) {
    state := &file.state
    delete(v.rows)
    v.rows = undo_graph_build(state)
    if textedit.history_node(state, v.origin) == nil {
        v.origin = textedit.history_current(state)
    }
    current := textedit.history_current(state)
    undo_graph_group(state, &v.rows, file.saved_content, v.origin, current)
    v.selected = max(undo_view_row_containing(state, v, current), 0)
    v.lanes = 1
    v.branches = 0
    for row in v.rows {
        v.lanes = max(v.lanes, row.lane + 1)
        for l in row.through {
            v.lanes = max(v.lanes, l + 1)
        }
        if !row.top {
            v.branches += 1
        }
    }
    v.revision = state.revision
}

// The row whose run holds `node`; -1 when none.
@(private = "file")
undo_view_row_containing :: proc(state: ^textedit.State, v: ^Undo_View, node: int) -> int {
    if node == textedit.NO_NODE {
        return -1
    }
    nodes := state.history.nodes[:]
    for row, i in v.rows {
        for n := row.node; n != textedit.NO_NODE; n = nodes[n].parent {
            if n == node {
                return i
            }
            if n == row.first {
                break
            }
        }
    }
    return -1
}

// Selects row `index` and moves the buffer to its state.
@(private)
undo_view_select :: proc(thor: ^Thor, file: ^Open_File, index: int) {
    v := &thor.undo_view
    if len(v.rows) == 0 {
        return
    }
    row := clamp(index, 0, len(v.rows) - 1)
    v.selected = row
    v.scroll_pending = true
    node := v.rows[row].node
    if textedit.history_current(&file.state) == node {
        return
    }
    if textedit.undo_goto(&file.state, node) {
        undo_view_after_move(thor, file)
    }
}

@(private = "file")
undo_view_after_move :: proc(thor: ^Thor, file: ^Open_File) {
    thor.undo_view.revision = file.state.revision
    thor_sync_saved(file)
    for pane in 0 ..< thor_pane_count(thor) {
        if editor := thor_pane_editor(thor, pane); editor.state == &file.state {
            editview.editor_scroll_to_caret(editor)
        }
    }
}

// Moves the buffer one step: to the parent (`dir` < 0) or to a child (`dir` > 0), inside a row's run first.
@(private)
undo_view_step :: proc(thor: ^Thor, file: ^Open_File, dir: int) {
    v := &thor.undo_view
    state := &file.state
    current := textedit.history_current(state)
    node := textedit.history_node(state, current)
    if node == nil {
        return
    }
    target := textedit.NO_NODE
    if dir < 0 {
        target = node.parent
    } else if row := undo_view_row_containing(state, v, current); row >= 0 && v.rows[row].node != current {
        for n := v.rows[row].node; n != textedit.NO_NODE; n = state.history.nodes[n].parent {
            if state.history.nodes[n].parent == current {
                target = n
                break
            }
        }
    } else if n := len(node.children); n > 0 {
        target = node.children[n - 1]
    }
    row := undo_view_row_containing(state, v, target)
    if row < 0 || !textedit.undo_goto(state, target) {
        return
    }
    v.selected = row
    v.scroll_pending = true
    undo_view_after_move(thor, file)
}

@(private = "file")
undo_view_keys :: proc(thor: ^Thor, file: ^Open_File) {
    v := &thor.undo_view
    if ui.take_key(.Escape) {
        thor_undo_history_close(thor, false)
        return
    }
    if ui.take_key(.Enter) || ui.take_key(.Pad_Enter) {
        thor_undo_history_close(thor, true)
        return
    }
    page := 10
    switch {
    case ui.take_key(.Up):
        undo_view_select(thor, file, v.selected - 1)
    case ui.take_key(.Down):
        undo_view_select(thor, file, v.selected + 1)
    case ui.take_key(.Page_Up):
        undo_view_select(thor, file, v.selected - page)
    case ui.take_key(.Page_Down):
        undo_view_select(thor, file, v.selected + page)
    case ui.take_key(.Home):
        undo_view_select(thor, file, 0)
    case ui.take_key(.End):
        undo_view_select(thor, file, len(v.rows) - 1)
    case ui.take_key(.Left):
        undo_view_step(thor, file, -1)
    case ui.take_key(.Right):
        undo_view_step(thor, file, 1)
    }
}

thor_undo_history_view :: proc(thor: ^Thor) {
    if !thor.undo_open {
        return
    }
    v := &thor.undo_view
    file := undo_view_file(thor)
    if file == nil {
        v.revision = 0
        thor_undo_history_close(thor, true)
        return
    }
    if file.state.revision != v.revision {
        if textedit.history_root(&file.state) == textedit.NO_NODE {
            thor_undo_history_close(thor, true)
            return
        }
        undo_view_rebuild(v, file)
        v.scroll_pending = true
    }

    backdrop := ui.scope(
        {
            key = "undo-backdrop",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Row,
                justify = .End,
                align = .Center,
                pad = ui.all(24),
                z = 410,
                bg = ui.Color{0, 0, 0, 60},
            },
        },
    )

    undo_view_box(thor, file)
    if !thor.undo_open {
        return
    }
    if backdrop.clicked {
        thor_undo_history_close(thor, false)
        return
    }
    undo_view_keys(thor, file)
}

@(private = "file")
undo_view_box :: proc(thor: ^Thor, file: ^Open_File) {
    v := &thor.undo_view
    box := ui.scope(
        {
            key = "undo-box",
            flags = {.Clickable, .Focusable},
            props = {
                w = ui.Px(min(UNDO_VIEW_WIDTH, ui.viewport().x * 0.62)),
                max_w = ui.viewport().x - 48,
                h = ui.Px(ui.viewport().y - 80),
                dir = .Column,
                bg = thor.theme.background,
                radius = ui.rad(10),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 8}, blur = 32, color = thor.theme.contrast},
            },
        },
    )
    if v.focus_pending {
        ui.set_focus(box.id)
        v.focus_pending = false
    }

    undo_view_header(thor, file)
    if !thor.undo_open {
        return
    }
    {
        ui.scope({key = "body", props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Row}})
        undo_view_list(thor, file)
        ui.leaf({key = "split", props = {w = ui.Px(1), h = ui.Grow(1), bg = thor.theme.border}})
        undo_view_diff(thor, file)
    }
    ui.label(
        "↑↓ rows   ←→ single steps   Enter keep   Esc go back",
        {
            key = "hint",
            props = {
                w = ui.Grow(1),
                pad = ui.xy(14, 6),
                color = thor.theme.muted_color,
                bg = thor.theme.second_background,
                text_wrap = .Ellipsis,
            },
        },
    )
}

@(private = "file")
undo_view_header :: proc(thor: ^Thor, file: ^Open_File) {
    v := &thor.undo_view
    ui.scope(
        {
            key = "header",
            props = {
                w = ui.Grow(1),
                h = ui.FIT,
                dir = .Row,
                align = .Center,
                gap = {10, 0},
                pad = ui.xy(14, 12),
                bg = thor.theme.second_background,
            },
        },
    )
    thor_icon_label(thor, "history", thor.theme.accent_color)
    ui.label("Undo history", {key = "title", props = {color = thor.theme.foreground, text_wrap = .None}})
    ui.label(
        thor_file_base(file.path),
        {key = "file", props = {color = thor.theme.foreground, text_wrap = .Ellipsis}},
    )
    ui.label(
        fmt.tprintf(
            "%d states · %d %s",
            len(v.rows),
            v.branches,
            v.branches == 1 ? "branch" : "branches",
        ),
        {key = "counts", props = {color = thor.theme.muted_color, text_wrap = .None}},
    )
    ui.leaf({key = "gap", props = {w = ui.Grow(1)}})
    close := ui.scope(
        {
            key = "close",
            flags = {.Clickable},
            props = {w = ui.Px(26), h = ui.Px(26), dir = .Row, justify = .Center, align = .Center, radius = ui.rad(4), cursor = .Pointer},
            hover = {bg = thor.theme.buttons},
        },
    )
    thor_icon_label(thor, "x", thor.theme.muted_color)
    thor_tip(thor, close.id, "Close and go back", "Escape")
    if close.clicked {
        thor_undo_history_close(thor, false)
    }
}

@(private = "file")
undo_view_list :: proc(thor: ^Thor, file: ^Open_File) {
    v := &thor.undo_view
    list := ui.scope(
        {
            key = "list",
            flags = {.Clip, .Scroll_Y},
            props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column, pad = ui.xy(6, 6)},
        },
    )
    if v.scroll_pending && list.node != nil && list.rect.h > 0 {
        top := f32(v.selected) * UNDO_ROW_H
        view := list.rect.h - 12
        scroll := list.node.scroll.y
        if top < scroll {
            ui.set_scroll(list.node, .Y, top)
        } else if top + UNDO_ROW_H > scroll + view {
            ui.set_scroll(list.node, .Y, top + UNDO_ROW_H - view)
        }
        v.scroll_pending = false
    }

    now := time.now()
    first, last := ui.virtual(len(v.rows), UNDO_ROW_H)
    defer ui.end_virtual()
    for i in first ..< last {
        ui.push_id_int(i64(i))
        clicked, double := undo_view_row(thor, file, i, now)
        ui.pop_id()
        if double {
            undo_view_select(thor, file, i)
            thor_undo_history_close(thor, true)
            return
        }
        if clicked {
            undo_view_select(thor, file, i)
        }
    }
}

// One graph row. Reports a click and a double click.
@(private = "file")
undo_view_row :: proc(thor: ^Thor, file: ^Open_File, index: int, now: time.Time) -> (clicked, double: bool) {
    v := &thor.undo_view
    row := v.rows[index]
    state := &file.state
    node := textedit.history_node(state, row.node)
    if node == nil {
        return
    }
    on: bool = index == v.selected
    it := ui.scope(
        {
            key = "row",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(UNDO_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {8, 0},
                pad = {r = 8},
                radius = ui.rad(4),
                cursor = .Pointer,
                bg = on ? thor.theme.selection_background : ui.Color{0, 0, 0, 0},
            },
            hover = {bg = on ? thor.theme.selection_background : thor.theme.buttons},
        },
    )
    undo_view_graph(thor, v, row, on)

    root := node.parent == textedit.NO_NODE
    ui.label(
        undo_row_label(state, row),
        {
            key = "label",
            props = {
                w = ui.Grow(1),
                color = root ? thor.theme.muted_color : thor.theme.foreground,
                text_wrap = .Ellipsis,
            },
        },
    )
    content := textedit.node_content_id(state, row.node)
    if content == file.saved_content {
        undo_view_badge(thor, "saved", thor.theme.success_color)
    }
    if row.node == v.origin && !on {
        undo_view_badge(thor, "start", thor.theme.accent_color)
    }
    if !root {
        ui.label(
            fmt.tprintf("L%d", node.line + 1),
            {key = "line", props = {color = thor.theme.muted_color, text_wrap = .None, min_w = 44}},
        )
    }
    ui.label(
        undo_history_age(time.diff(node.stamp, now)),
        {key = "age", props = {color = thor.theme.muted_color, text_wrap = .None, min_w = 56}},
    )
    return it.clicked, it.double_clicked
}

@(private = "file")
undo_view_badge :: proc(thor: ^Thor, text: string, color: ui.Color) {
    ui.label(
        text,
        {
            key = text,
            props = {
                pad = ui.xy(6, 1),
                radius = ui.rad(4),
                color = color,
                border = {width = ui.all(1), color = color},
                text_wrap = .None,
            },
        },
    )
}

// The lanes beside a row: a bar for each line that passes, the node's dot, and a
// connector from each branch that ends at the node.
@(private = "file")
undo_view_graph :: proc(thor: ^Thor, v: ^Undo_View, row: Undo_Graph_Row, on: bool) {
    line := thor.theme.border
    dot := on ? thor.theme.accent_color : thor.theme.muted_color
    ui.scope(
        {
            key = "graph",
            props = {
                position = .Relative,
                w = ui.Px(f32(v.lanes) * UNDO_LANE_W + 6),
                h = ui.Px(UNDO_ROW_H),
            },
        },
    )
    x_of :: proc(lane: int) -> f32 {
        return 6 + f32(lane) * UNDO_LANE_W + UNDO_LANE_W / 2
    }
    mid := UNDO_ROW_H / 2
    bar :: proc(key: string, x, y, w, h: f32, color: ui.Color) {
        ui.leaf({key = key, props = {position = .Absolute, inset = {l = x, t = y}, w = ui.Px(w), h = ui.Px(h), bg = color}})
    }
    for l in row.through {
        ui.push_id_int(i64(l))
        bar("through", x_of(l) - 1, 0, 2, UNDO_ROW_H, line)
        ui.pop_id()
    }
    for l in row.joins {
        ui.push_id_int(i64(l))
        bar("join-up", x_of(l) - 1, 0, 2, mid, line)
        lo, hi := min(x_of(l), x_of(row.lane)), max(x_of(l), x_of(row.lane))
        bar("join", lo - 1, mid - 1, hi - lo + 2, 2, line)
        ui.pop_id()
    }
    x := x_of(row.lane)
    if row.top {
        bar("top", x - 1, 0, 2, mid, line)
    }
    if row.bottom {
        bar("bottom", x - 1, mid, 2, UNDO_ROW_H - mid, line)
    }
    size := f32(10)
    ui.leaf(
        {
            key = "dot",
            props = {
                position = .Absolute,
                inset = {l = x - size / 2, t = mid - size / 2},
                w = ui.Px(size),
                h = ui.Px(size),
                radius = ui.rad(size / 2),
                bg = on ? dot : thor.theme.background,
                border = {width = ui.all(2), color = dot},
            },
        },
    )
}

// A short description of what a step did.
@(private)
undo_step_label :: proc(node: ^textedit.Undo_Node) -> string {
    if node.parent == textedit.NO_NODE {
        return node.seq == 0 ? "Opened file" : "Oldest kept state"
    }
    hunks := textedit.node_hunks(node, context.temp_allocator)
    switch len(hunks) {
    case 0:
        return "Edit"
    case 1:
    case:
        return fmt.tprintf("Edited %d places", len(hunks))
    }
    removed := hunks[0].removed
    inserted := ""
    for op in node.ops {
        if op.kind == .Insert {
            inserted = op.text
            break
        }
    }
    switch {
    case removed != "" && inserted != "":
        if strings.contains_rune(removed, '\n') || strings.contains_rune(inserted, '\n') {
            return undo_describe("Replaced", removed)
        }
        return fmt.tprintf("Replaced \"%s\" → \"%s\"", undo_history_snippet(removed), undo_history_snippet(inserted))
    case inserted != "":
        typed := node.coalesce == .Typing && !strings.contains_rune(inserted, '\n')
        return undo_describe(typed ? "Typed" : "Inserted", inserted)
    }
    return undo_describe("Deleted", removed)
}

// `verb` and what `text` is: a quote of one line, a count of lines or a kind of whitespace.
@(private = "file")
undo_describe :: proc(verb, text: string) -> string {
    breaks := strings.count(text, "\n")
    if breaks == 0 {
        if snippet := undo_history_snippet(text); snippet != "" {
            return fmt.tprintf("%s \"%s\"", verb, snippet)
        }
        return fmt.tprintf("%s whitespace", verb)
    }
    if strings.trim_space(text) == "" {
        return breaks == 1 ? fmt.tprintf("%s line break", verb) : fmt.tprintf("%s %d blank lines", verb, breaks)
    }
    lines := breaks + (strings.has_suffix(text, "\n") ? 0 : 1)
    return lines == 1 ? fmt.tprintf("%s 1 line", verb) : fmt.tprintf("%s %d lines", verb, lines)
}

// The first non-blank line of `text`, cut on a rune boundary.
@(private = "file")
undo_history_snippet :: proc(text: string) -> string {
    rest := text
    for line in strings.split_lines_iterator(&rest) {
        trimmed := strings.trim_space(line)
        if trimmed == "" {
            continue
        }
        if len(trimmed) <= UNDO_HISTORY_SNIPPET {
            return trimmed
        }
        cut := UNDO_HISTORY_SNIPPET
        for cut > 0 && !utf8.rune_start(trimmed[cut]) {
            cut -= 1
        }
        return strings.concatenate({trimmed[:cut], "…"}, context.temp_allocator)
    }
    return ""
}

@(private = "file")
undo_history_age :: proc(age: time.Duration) -> string {
    seconds := int(time.duration_seconds(age))
    switch {
    case seconds < 5:
        return "just now"
    case seconds < 60:
        return fmt.tprintf("%ds ago", seconds)
    case seconds < 3600:
        return fmt.tprintf("%dm ago", seconds / 60)
    case seconds < 86400:
        return fmt.tprintf("%dh ago", seconds / 3600)
    }
    return fmt.tprintf("%dd ago", seconds / 86400)
}

@(private = "file")
undo_view_diff :: proc(thor: ^Thor, file: ^Open_File) {
    v := &thor.undo_view
    ui.scope({key = "diff", props = {w = ui.Px(min(UNDO_VIEW_WIDTH, ui.viewport().x * 0.62) * 0.4), h = ui.Grow(1), dir = .Column}})
    state := &file.state
    node: ^textedit.Undo_Node
    title := "Change"
    hunks: []textedit.Node_Hunk
    if v.selected >= 0 && v.selected < len(v.rows) {
        title, hunks, node = undo_row_change(state, v.rows[v.selected])
    }
    ui.label(
        title,
        {
            key = "title",
            props = {
                w = ui.Grow(1),
                h = ui.Px(UNDO_ROW_H),
                pad = ui.xy(12, 0),
                bg = thor.theme.second_background,
                color = thor.theme.muted_color,
                text_wrap = .Ellipsis,
            },
        },
    )

    ui.scope({key = "rows", flags = {.Clip, .Scroll_Y, .Scroll_X}, props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Column, pad = {t = 4}}})
    if node == nil || node.parent == textedit.NO_NODE {
        text := node != nil && node.seq != 0 ? "The oldest state the history still holds." : "The file as it was when the history began."
        ui.label(text, {key = "root", props = {pad = ui.xy(12, 8), color = thor.theme.muted_color}})
        return
    }
    rows := undo_diff_rows(state, hunks)
    for row, i in rows {
        ui.push_id_int(i64(i))
        sign := " "
        #partial switch row.kind {
        case .Added:
            sign = "+"
        case .Removed:
            sign = "-"
        }
        number := row.line > 0 ? fmt.tprintf("%4d", row.line) : "    "
        text := row.kind == .Hunk || row.kind == .Meta ? row.text : fmt.tprintf("%s %s %s", number, sign, row.text)
        ui.label(
            text,
            {
                key = "line",
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(UNDO_DIFF_ROW_H),
                    pad = ui.xy(12, 0),
                    bg = git_diff_row_bg(thor, row.kind),
                    color = git_diff_row_color(thor, row.kind),
                    font = thor.font_mono,
                    text_wrap = .None,
                },
            },
        )
        ui.pop_id()
    }
}

// What a row did: its label, its hunks and its newest node. When the buffer is at a step
// inside the row's run, that one step instead.
@(private)
undo_row_change :: proc(state: ^textedit.State, row: Undo_Graph_Row) -> (label: string, hunks: []textedit.Node_Hunk, node: ^textedit.Undo_Node) {
    current := textedit.history_current(state)
    if row.count > 1 && current != row.node {
        step := 1
        for n := current; n != row.first && n != textedit.NO_NODE; n = state.history.nodes[n].parent {
            step += 1
        }
        if node = textedit.history_node(state, current); node != nil {
            label = fmt.tprintf("Step %d of %d: %s", step, row.count, undo_step_label(node))
            return label, textedit.node_hunks(node, context.temp_allocator), node
        }
    }
    node = textedit.history_node(state, row.node)
    if node == nil {
        return "Change", nil, nil
    }
    return undo_row_label(state, row), undo_row_hunks(state, row), node
}

// The label of a row: of its whole run when it joins several steps.
@(private)
undo_row_label :: proc(state: ^textedit.State, row: Undo_Graph_Row) -> string {
    node := textedit.history_node(state, row.node)
    if node == nil {
        return ""
    }
    if hunk, ok := undo_graph_run_hunk(state, row); ok {
        if node.coalesce == .Typing {
            return undo_describe("Typed", undo_graph_run_text(state, row))
        }
        return undo_describe("Deleted", hunk.removed)
    }
    return undo_step_label(node)
}

@(private = "file")
undo_row_hunks :: proc(state: ^textedit.State, row: Undo_Graph_Row) -> []textedit.Node_Hunk {
    if hunk, ok := undo_graph_run_hunk(state, row); ok {
        out := make([]textedit.Node_Hunk, 1, context.temp_allocator)
        out[0] = hunk
        return out
    }
    node := textedit.history_node(state, row.node)
    if node == nil {
        return nil
    }
    return textedit.node_hunks(node, context.temp_allocator)
}

// The diff rows of `hunks`, which must be places in the buffer's current content.
@(private)
undo_diff_rows :: proc(state: ^textedit.State, hunks: []textedit.Node_Hunk) -> []Undo_Diff_Row {
    rows := make([dynamic]Undo_Diff_Row, context.temp_allocator)
    txt := textedit.text(state)
    line_count := textedit.state_line_count(state)
    line_text :: proc(state: ^textedit.State, txt: string, line: int) -> string {
        start := textedit.state_line_start(state, line)
        end := line + 1 < textedit.state_line_count(state) ? textedit.state_line_start(state, line + 1) - 1 : len(txt)
        return undo_display(txt[start:max(start, end)])
    }

    for h, hi in hunks {
        if hi >= UNDO_DIFF_HUNKS {
            append(&rows, Undo_Diff_Row{kind = .Meta, text = fmt.tprintf("… %d more places", len(hunks) - hi)})
            break
        }
        a := clamp(h.pos, 0, len(txt))
        b := clamp(h.pos + h.inserted, a, len(txt))
        first := textedit.state_line_index(state, a)
        last := b > a ? textedit.state_line_index(state, b - 1) : first
        start := textedit.state_line_start(state, first)
        end := last + 1 < line_count ? textedit.state_line_start(state, last + 1) - 1 : len(txt)
        prefix := txt[start:a]

        if hi > 0 || first > UNDO_DIFF_CONTEXT {
            append(&rows, Undo_Diff_Row{kind = .Hunk, text = fmt.tprintf("line %d", first + 1)})
        }
        for l in max(first - UNDO_DIFF_CONTEXT, 0) ..< first {
            append(&rows, Undo_Diff_Row{kind = .Context, line = l + 1, text = line_text(state, txt, l)})
        }

        // A change of whole lines shows only those lines; one inside a line shows the line before and after.
        whole := prefix == "" && (b == a || txt[b - 1] == '\n') && (h.removed == "" || strings.has_suffix(h.removed, "\n"))
        old: string
        new_first, new_last, after := first, last, last + 1
        if whole {
            old = h.removed
            if b == a {
                new_last = first - 1
                after = first
            }
        } else {
            suffix := b <= end ? txt[b:end] : ""
            old = strings.concatenate({prefix, h.removed, suffix}, context.temp_allocator)
        }
        rest := strings.trim_suffix(old, "\n")
        if old != "" {
            n := 0
            for l in strings.split_lines_iterator(&rest) {
                append(&rows, Undo_Diff_Row{kind = .Removed, line = first + 1 + n, text = undo_display(l)})
                n += 1
            }
        }
        for l in new_first ..= new_last {
            append(&rows, Undo_Diff_Row{kind = .Added, line = l + 1, text = line_text(state, txt, l)})
        }
        for l in after ..< min(after + UNDO_DIFF_CONTEXT, line_count) {
            append(&rows, Undo_Diff_Row{kind = .Context, line = l + 1, text = line_text(state, txt, l)})
        }
        if len(rows) >= UNDO_DIFF_ROWS {
            more := len(rows) - UNDO_DIFF_ROWS
            resize(&rows, UNDO_DIFF_ROWS)
            if more > 0 || hi + 1 < len(hunks) {
                append(&rows, Undo_Diff_Row{kind = .Meta, text = "… more"})
            }
            break
        }
    }
    return rows[:]
}

// A line as the diff shows it: tabs as spaces, a CR dropped.
@(private = "file")
undo_display :: proc(line: string) -> string {
    s := strings.trim_suffix(line, "\r")
    if strings.contains_rune(s, '\t') {
        s, _ = strings.replace_all(s, "\t", "    ", context.temp_allocator)
    }
    return s
}
