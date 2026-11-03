package thor

import "core:fmt"
import "core:math"
import "core:strings"

import "../editview"
import "../setting"
import ui "../vendor/loom/loom"

MAX_PANES :: 6
LAYOUT_MAX_COLUMNS :: 3
LAYOUT_MAX_ROWS :: 2
// Smallest pane a layout change may leave.
PANE_MIN_W :: f32(240)
PANE_MIN_H :: f32(120)
PANE_HANDLE_WIDTH :: f32(3)
// Smallest share of its group a pane keeps while a handle is dragged.
PANE_MIN_WEIGHT :: f32(0.1)

// The editor area's arrangement. Panes number down each column, then across.
Pane_Layout :: enum u8 {
    Single,
    Columns2,
    Columns3,
    Rows2,
    Main_Stack,
    Grid4,
    Grid6,
}

// Row count of each column; 0 ends the list.
LAYOUT_ROWS := [Pane_Layout][LAYOUT_MAX_COLUMNS]int {
    .Single     = {1, 0, 0},
    .Columns2   = {1, 1, 0},
    .Columns3   = {1, 1, 1},
    .Rows2      = {2, 0, 0},
    .Main_Stack = {1, 2, 0},
    .Grid4      = {2, 2, 0},
    .Grid6      = {2, 2, 2},
}

// Session spelling of each layout.
LAYOUT_NAMES := [Pane_Layout]string {
    .Single     = "single",
    .Columns2   = "columns2",
    .Columns3   = "columns3",
    .Rows2      = "rows2",
    .Main_Stack = "main_stack",
    .Grid4      = "grid4",
    .Grid6      = "grid6",
}

LAYOUT_TITLES := [Pane_Layout]string {
    .Single     = "Single",
    .Columns2   = "2 Columns",
    .Columns3   = "3 Columns",
    .Rows2      = "2 Rows",
    .Main_Stack = "Main + Stack",
    .Grid4      = "2x2 Grid",
    .Grid6      = "3x2 Grid",
}

PANE_NUMBERS := [MAX_PANES]string{"1", "2", "3", "4", "5", "6"}

// Focus key of each pane.
PANE_KEYS := [MAX_PANES]string{"pane0", "pane1", "pane2", "pane3", "pane4", "pane5"}

// A file waiting for the pane picker. path "" means the active file.
Pane_Pick :: struct {
    open: bool,
    path: string, // owned
}

layout_columns :: proc(layout: Pane_Layout) -> int {
    n := 0
    for rows in LAYOUT_ROWS[layout] {
        if rows > 0 {
            n += 1
        }
    }
    return n
}

layout_pane_count :: proc(layout: Pane_Layout) -> int {
    n := 0
    for rows in LAYOUT_ROWS[layout] {
        n += rows
    }
    return n
}

// Pane index of the top pane of column `col`.
layout_first_pane :: proc(layout: Pane_Layout, col: int) -> int {
    n := 0
    for c in 0 ..< col {
        n += LAYOUT_ROWS[layout][c]
    }
    return n
}

layout_max_rows :: proc(layout: Pane_Layout) -> int {
    n := 0
    for rows in LAYOUT_ROWS[layout] {
        n = max(n, rows)
    }
    return n
}

// Smallest layout with at least `count` panes, side by side where it can be.
layout_for_count :: proc(count: int) -> Pane_Layout {
    switch {
    case count <= 1: return .Single
    case count == 2: return .Columns2
    case count == 3: return .Columns3
    case count == 4: return .Grid4
    }
    return .Grid6
}

layout_from_name :: proc(name: string) -> (Pane_Layout, bool) {
    for n, layout in LAYOUT_NAMES {
        if n == name {
            return layout, true
        }
    }
    return .Single, false
}

thor_pane_count :: proc(thor: ^Thor) -> int {
    return layout_pane_count(thor.layout)
}

thor_pane_key :: proc(pane: int) -> string {
    return PANE_KEYS[clamp(pane, 0, MAX_PANES - 1)]
}

// Pane a focus key names, or -1.
thor_pane_of_key :: proc(key: string) -> int {
    for k, pane in PANE_KEYS {
        if k == key {
            return pane
        }
    }
    return -1
}

// Visible pane under `pos` last frame, or -1.
thor_pane_at :: proc(thor: ^Thor, pos: ui.Vec2) -> int {
    for pane in 0 ..< thor_pane_count(thor) {
        r := thor.pane_rect[pane]
        if r.w > 0 && ui.rect_contains(r, pos) {
            return pane
        }
    }
    return -1
}

thor_pane_reset_weights :: proc(thor: ^Thor) {
    for &w in thor.col_weight {
        w = 1
    }
    for &column in thor.row_weight {
        for &w in column {
            w = 1
        }
    }
}

// Whether every pane of `layout` keeps its minimum size in last frame's area.
// An area not laid out yet fits anything.
thor_layout_fits :: proc(thor: ^Thor, layout: Pane_Layout) -> bool {
    area := thor.panes_area
    if area.w <= 0 || area.h <= 0 {
        return true
    }
    cols := f32(layout_columns(layout))
    rows := f32(layout_max_rows(layout))
    return area.w >= cols * PANE_MIN_W + (cols - 1) * PANE_HANDLE_WIDTH &&
        area.h >= rows * PANE_MIN_H + (rows - 1) * PANE_HANDLE_WIDTH
}

// Whether open file `index` shows in one of the first `count` panes.
@(private = "file")
thor_file_shown :: proc(thor: ^Thor, index, count: int) -> bool {
    for pane in 0 ..< count {
        if thor.pane_file[pane] == index {
            return true
        }
    }
    return false
}

// File a new pane opens on: the ctrl+e target, else the first tab no pane shows,
// else what pane 1 shows.
thor_unshown_file :: proc(thor: ^Thor, count: int) -> int {
    if thor.last_active_file != nil {
        for file, index in thor.open_files {
            if file == thor.last_active_file && !thor_file_shown(thor, index, count) {
                return index
            }
        }
    }
    for _, index in thor.open_files {
        if !thor_file_shown(thor, index, count) {
            return index
        }
    }
    return thor.pane_file[0]
}

// Switches the arrangement. Panes it cuts drop their file (the tab stays open);
// panes it adds open on a file no pane shows. False when the panes would not fit.
thor_set_layout :: proc(thor: ^Thor, layout: Pane_Layout) -> bool {
    if layout == thor.layout {
        return true
    }
    if !thor_layout_fits(thor, layout) {
        thor_flash_status(thor, fmt.tprintf("No space for the %s layout", LAYOUT_TITLES[layout]), is_error = true)
        return false
    }
    old := thor_pane_count(thor)
    count := layout_pane_count(layout)
    thor.layout = layout
    if layout != .Single {
        thor.last_multi_layout = layout
    }
    thor_pane_reset_weights(thor)

    for pane in count ..< MAX_PANES {
        if thor.pane_file[pane] >= 0 {
            thor.pane_file[pane] = -1
            thor_bind_pane(thor, pane)
        }
    }
    for pane in old ..< count {
        if thor.pane_file[pane] < 0 || thor.pane_file[pane] >= len(thor.open_files) {
            thor.pane_file[pane] = thor_unshown_file(thor, pane)
        }
        // A new pane starts at pane 1's zoom; afterwards each pane zooms alone.
        editview.editor_set_font_size(&thor.editors[pane], thor.editors[0].font_size)
        thor_bind_pane(thor, pane)
    }
    if thor.active_pane >= count {
        thor_focus_pane(thor, count - 1)
    }
    return true
}

// Grows the layout until pane `pane` exists. False when it cannot.
thor_ensure_pane :: proc(thor: ^Thor, pane: int) -> bool {
    if pane < 0 || pane >= MAX_PANES {
        return false
    }
    if pane < thor_pane_count(thor) {
        return true
    }
    // The remembered arrangement first, when it is big enough.
    if pane < layout_pane_count(thor.last_multi_layout) && thor.layout == .Single {
        return thor_set_layout(thor, thor.last_multi_layout)
    }
    return thor_set_layout(thor, layout_for_count(pane + 1))
}

// Single pane, or back to the last multi-pane layout with the focus in pane 2.
thor_toggle_split :: proc(thor: ^Thor) {
    if thor.layout != .Single {
        thor_set_layout(thor, .Single)
        thor_focus_pane(thor, 0)
        return
    }
    if thor_set_layout(thor, thor.last_multi_layout) {
        thor_focus_pane(thor, 1)
    }
}

// Steps through the layouts in declaration order.
thor_cycle_layout :: proc(thor: ^Thor, step: int) {
    n := len(Pane_Layout)
    layout := thor.layout
    // A layout that does not fit is skipped, not stopped at.
    for _ in 0 ..< n {
        layout = Pane_Layout((int(layout) + step + n) % n)
        if thor_layout_fits(thor, layout) {
            thor_set_layout(thor, layout)
            thor_flash_status(thor, fmt.tprintf("Layout: %s", LAYOUT_TITLES[layout]))
            return
        }
    }
}

thor_focus_pane :: proc(thor: ^Thor, pane: int) {
    if pane < 0 || pane >= thor_pane_count(thor) {
        thor_flash_status(thor, fmt.tprintf("There is no pane %d", pane + 1), is_error = true)
        return
    }
    thor.active_pane = pane
    thor.focus_request = thor_pane_key(pane)
    thor_sync_active_signal(thor)
}

thor_focus_next_pane :: proc(thor: ^Thor, step: int) {
    count := thor_pane_count(thor)
    thor_focus_pane(thor, ((thor.active_pane + step) % count + count) % count)
}

// Pane beside the focused one: the next pane, opening a split when there is one pane.
thor_side_pane :: proc(thor: ^Thor) -> int {
    if thor_pane_count(thor) == 1 && !thor_ensure_pane(thor, 1) {
        return thor.active_pane
    }
    return (thor.active_pane + 1) % thor_pane_count(thor)
}

// Shows open file `index` in `pane`, growing the layout first, and focuses it.
thor_show_file_in_pane :: proc(thor: ^Thor, index, pane: int) {
    if !thor_ensure_pane(thor, pane) {
        return
    }
    thor_focus_pane(thor, pane)
    thor_set_active_file(thor, index)
}

// Opens `path` in `pane`, growing the layout first, and focuses it.
thor_open_file_in_pane :: proc(thor: ^Thor, path: string, pane: int) {
    if !thor_ensure_pane(thor, pane) {
        return
    }
    thor_focus_pane(thor, pane)
    thor_open_file(thor, path)
}

// Shows the active file in `pane` too. The pane it came from keeps it.
thor_file_to_pane :: proc(thor: ^Thor, pane: int) {
    index := thor.pane_file[thor.active_pane]
    if index < 0 || index >= len(thor.open_files) {
        thor_flash_status(thor, "No file is open", is_error = true)
        return
    }
    thor_show_file_in_pane(thor, index, pane)
}

// Opens the pane picker for `path`, or for the active file when path is "".
// With one pane the file goes to the side at once.
thor_pane_pick_begin :: proc(thor: ^Thor, path: string) {
    if thor_pane_count(thor) == 1 {
        pane := thor_side_pane(thor)
        if path == "" {
            thor_file_to_pane(thor, pane)
        } else {
            thor_open_file_in_pane(thor, path, pane)
        }
        return
    }
    thor_pane_pick_cancel(thor)
    thor.pane_pick.open = true
    if path != "" {
        thor.pane_pick.path = strings.clone(path)
    }
}

thor_pane_pick_finish :: proc(thor: ^Thor, pane: int) {
    if !thor.pane_pick.open {
        return
    }
    path := thor.pane_pick.path
    thor.pane_pick = {}
    defer delete(path)
    if path == "" {
        thor_file_to_pane(thor, pane)
    } else {
        thor_open_file_in_pane(thor, path, pane)
    }
}

thor_pane_pick_cancel :: proc(thor: ^Thor) {
    delete(thor.pane_pick.path)
    thor.pane_pick = {}
}

// Digit 1..9 of a number-row or keypad key.
thor_key_digit :: proc(key: ui.Key) -> (int, bool) {
    return editview.editor_key_digit(key)
}

// Like keybind_matches, but a number-row digit also matches its keypad twin.
thor_digit_bind_matches :: proc(bind: setting.Keybind, event: ui.Key_Event) -> bool {
    if setting.keybind_matches(bind, event.key, event.mods) {
        return true
    }
    want, want_ok := thor_key_digit(bind.key)
    got, got_ok := thor_key_digit(event.key)
    return want_ok && got_ok && want == got && setting.keybind_matches(bind, bind.key, event.mods)
}

// Moves the boundary after entry `i` of `weights` by `moved` pixels of `avail`.
// grab holds the two weights at the press.
thor_pane_drag_weights :: proc(weights: []f32, i: int, grab: [2]f32, moved, avail: f32) {
    if i + 1 >= len(weights) || avail <= 0 {
        return
    }
    total: f32
    for w in weights {
        total += w
    }
    pair := grab[0] + grab[1]
    least := PANE_MIN_WEIGHT * total
    if pair <= 2 * least {
        return
    }
    a := clamp(grab[0] + moved / avail * total, least, pair - least)
    weights[i] = a
    weights[i + 1] = pair - a
}

// Pixel sizes of `n` slots sharing `avail` by `weights`. The last slot takes the rest.
thor_pane_sizes :: proc(weights: []f32, n: int, avail: f32) -> (sizes: [LAYOUT_MAX_COLUMNS]f32) {
    total: f32
    for i in 0 ..< n {
        total += weights[i]
    }
    if total <= 0 {
        return
    }
    used: f32
    for i in 0 ..< n - 1 {
        sizes[i] = math.round(avail * weights[i] / total)
        used += sizes[i]
    }
    sizes[n - 1] = avail - used
    return
}

// The pane chords of the global keymap: focus pane N, file to pane N, next and
// previous pane, next layout.
thor_pane_global_key :: proc(thor: ^Thor, event: ui.Key_Event) -> bool {
    for bind, pane in thor.focus_pane_keys {
        if thor_digit_bind_matches(bind, event) {
            thor_focus_pane(thor, pane)
            return true
        }
    }
    for bind, pane in thor.file_to_pane_keys {
        if thor_digit_bind_matches(bind, event) {
            thor_file_to_pane(thor, pane)
            return true
        }
    }
    switch {
    case thor_app_key_hit(thor, thor.focus_next_pane_key, "focus_next_pane", event):
        thor_focus_next_pane(thor, 1)
    case thor_app_key_hit(thor, thor.focus_previous_pane_key, "focus_previous_pane", event):
        thor_focus_next_pane(thor, -1)
    case thor_app_key_hit(thor, thor.next_layout_key, "next_layout", event):
        thor_cycle_layout(thor, 1)
    case:
        return false
    }
    return true
}

// Binds every pane past the first after a session restore, and fills the ones
// the session left empty.
thor_bind_extra_panes :: proc(thor: ^Thor) {
    for pane in 1 ..< thor_pane_count(thor) {
        if thor.pane_file[pane] < 0 || thor.pane_file[pane] >= len(thor.open_files) {
            thor.pane_file[pane] = thor_unshown_file(thor, pane)
        }
        editview.editor_set_font_size(&thor.editors[pane], thor.editors[0].font_size)
        thor_bind_pane(thor, pane)
    }
}

// Layout the pane_layout setting names, or false for "remember".
thor_configured_layout :: proc(thor: ^Thor) -> (Pane_Layout, bool) {
    name := setting.pane_layout(&thor.config)
    if name == "" {
        return .Single, false
    }
    return layout_from_name(name)
}

// Takes saved weights, keeping the defaults for any group with a weight that is
// not positive.
thor_restore_weights :: proc(thor: ^Thor, cols: [LAYOUT_MAX_COLUMNS]f32, rows: [LAYOUT_MAX_COLUMNS][LAYOUT_MAX_ROWS]f32) {
    cols, rows := cols, rows
    if valid_weights(cols[:]) {
        thor.col_weight = cols
    }
    for &column, c in rows {
        if valid_weights(column[:]) {
            thor.row_weight[c] = column
        }
    }

    valid_weights :: proc(weights: []f32) -> bool {
        for w in weights {
            if !(w > 0 && w < 1000) {
                return false
            }
        }
        return true
    }
}

thor_cmd_next_layout :: proc(data: rawptr) {thor_cycle_layout(cast(^Thor) data, 1)}
thor_cmd_focus_next_pane :: proc(data: rawptr) {thor_focus_next_pane(cast(^Thor) data, 1)}
thor_cmd_focus_previous_pane :: proc(data: rawptr) {thor_focus_next_pane(cast(^Thor) data, -1)}
thor_cmd_pick_pane :: proc(data: rawptr) {thor_pane_pick_begin(cast(^Thor) data, "")}

thor_cmd_open_to_side :: proc(data: rawptr) {
    thor := cast(^Thor) data
    thor_file_to_pane(thor, thor_side_pane(thor))
}

// Lists the layouts. No live preview: a layout passed over would drop the
// files of the panes it cuts.
thor_cmd_pick_layout :: proc(data: rawptr) {
    thor := cast(^Thor) data
    titles: [len(Pane_Layout)]string
    for title, layout in LAYOUT_TITLES {
        titles[int(layout)] = title
    }
    thor_select_open(
        thor,
        "Pane Layout",
        titles[:],
        LAYOUT_TITLES[thor.layout],
        thor_pick_layout_preview,
        thor_pick_layout_commit,
        thor,
    )
}

@(private = "file")
thor_layout_of_title :: proc(title: string) -> (Pane_Layout, bool) {
    for t, layout in LAYOUT_TITLES {
        if t == title {
            return layout, true
        }
    }
    return .Single, false
}

@(private = "file")
thor_pick_layout_preview :: proc(_: rawptr, _: string) {}

@(private = "file")
thor_pick_layout_commit :: proc(data: rawptr, choice: string) {
    thor := cast(^Thor) data
    if layout, ok := thor_layout_of_title(choice); ok {
        thor_set_layout(thor, layout)
    }
}

// A key while the pane picker is up: a pane number picks, Escape cancels, and
// every other key is dropped.
thor_pane_pick_key :: proc(thor: ^Thor, event: ui.Key_Event) {
    if event.action != .Press {
        return
    }
    if event.key == .Escape {
        thor_pane_pick_cancel(thor)
        return
    }
    if digit, ok := thor_key_digit(event.key); ok && event.mods == {} && digit >= 1 && digit <= thor_pane_count(thor) {
        thor_pane_pick_finish(thor, digit - 1)
    }
}
