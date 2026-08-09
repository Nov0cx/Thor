package widgets

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../ui"

// A centered modal that edits every setting in one place: a left sidebar of
// categories (icon + label), a General/Workspace scope switch in the header, a
// search box that filters across all categories, and the row list itself (the
// numeric editor preferences, the theme/font pickers, the full keybinding
// list). The host (thor) fills it with categories and rows and persists the
// callbacks' effects, so the widget stays free of any settings-format
// knowledge.

// Fired when a number stepper is nudged; `value` is the already-clamped result.
Settings_Number_Proc :: #type proc(data: rawptr, id: string, value: int)
// Fired when a choice row is clicked; the host opens its own picker for `id`.
Settings_Choice_Proc :: #type proc(data: rawptr, id: string)
// Fired when a keybinding is captured or cleared; key = .KEY_NULL means unbind.
Settings_Keybind_Proc :: #type proc(data: rawptr, id: string, key: rl.KeyboardKey, ctrl, shift, alt: bool)
// Fired when the General/Workspace tab is switched; the host repopulates rows
// for the new scope (view.scope already reflects it).
Settings_Scope_Proc :: #type proc(data: rawptr, scope: Settings_Scope)
// Fired when the "Create Workspace Settings" button is clicked in the empty
// Workspace tab.
Settings_Init_Workspace_Proc :: #type proc(data: rawptr)

Settings_Row_Kind :: enum {
    Number,  // label + [-] value [+] stepper
    Choice,  // label + value; clicking asks the host to open a picker
    Keybind, // label + chord; clicking captures a new chord, a clear box unbinds
}

Settings_Row :: struct {
    kind:     Settings_Row_Kind,
    id:       string, // owned; stable key handed back to the callbacks
    label:    string, // owned
    value:    string, // owned; formatted display (number, choice, chord)
    category: string, // owned; id of the Settings_Category this row belongs to
    number:            int,
    min, max, step:    int,
}

// A sidebar entry. The host registers one with settings_view_begin_category
// before adding the rows that belong to it.
Settings_Category :: struct {
    id:    string, // owned
    label: string, // owned
    icon:  string, // owned; a name from assets/icons/icons.json
}

Settings_Scope :: enum {
    General,
    Workspace,
}

Settings_View :: struct {
    using widget: ui.Widget,
    categories:        [dynamic]Settings_Category,
    current_category:  string, // owned; cursor set by begin_category, stamped onto new rows
    selected_category: int,
    scope:             Settings_Scope,
    // False hides the row list and shows a "create workspace settings" prompt
    // instead, set by the host from thor.workspace_initialized.
    workspace_available: bool,
    rows:         [dynamic]Settings_Row,
    // Indices into `rows` currently shown: the selected category, or every
    // match when `search` is non-empty. Recomputed once per layout.
    visible_rows: [dynamic]int,
    search:       [dynamic]u8,
    // Row currently capturing a chord (-1 = none), an absolute index into
    // `rows`. While set, the host suppresses its global shortcuts so the press
    // reaches this widget.
    capturing:    int,
    // Keyboard-highlighted row (-1 = none), an index into `visible_rows`.
    // Up/Down move it; Left/Right nudge a Number row; Enter activates a Choice
    // or Keybind row. Mouse clicks also move it, so the two stay in sync.
    selected:     int,
    scroll:       f32,
    box:          rl.Rectangle,
    sidebar:      rl.Rectangle,
    content:      rl.Rectangle,
    width:        f32,
    row_height:      f32,
    header_height:   f32,
    category_height: f32,
    search_height:   f32,
    sidebar_width:   f32,
    // Callbacks into the host.
    on_number:         Settings_Number_Proc,
    on_choice:         Settings_Choice_Proc,
    on_keybind:        Settings_Keybind_Proc,
    on_scope_change:   Settings_Scope_Proc,
    on_init_workspace: Settings_Init_Workspace_Proc,
    data:         rawptr,
    return_focus: ^ui.Widget,
    background_color: rl.Color,
    border_color:     rl.Color,
    header_color:     rl.Color,
    field_color:      rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    accent_color:     rl.Color,
    selected_color:   rl.Color,
}

settings_view_vtable := ui.Widget_VTable {
    layout = settings_view_layout,
    handle_event = settings_view_handle_event,
    draw = settings_view_draw,
    destroy = settings_view_destroy,
}

settings_view_create :: proc(id: string) -> ^Settings_View {
    view := new(Settings_View)
    ui.widget_init(&view.widget, id, settings_view_vtable)
    view.visible = false
    view.categories = make([dynamic]Settings_Category)
    view.rows = make([dynamic]Settings_Row)
    view.visible_rows = make([dynamic]int)
    view.search = make([dynamic]u8)
    view.capturing = -1
    view.selected = -1
    view.selected_category = 0
    view.scope = .General
    view.width = 860
    view.row_height = 34
    view.header_height = 46
    view.category_height = 38
    view.search_height = 48
    view.sidebar_width = 190
    view.background_color = rl.Color {24, 26, 31, 250}
    view.header_color = rl.Color {31, 34, 51, 255}
    view.field_color = rl.Color {18, 20, 24, 255}
    view.border_color = rl.Color {132, 255, 255, 255}
    view.text_color = rl.Color {238, 255, 255, 255}
    view.muted_color = rl.Color {120, 128, 160, 255}
    view.accent_color = rl.Color {132, 255, 255, 255}
    view.selected_color = rl.Color {132, 255, 255, 40}
    return view
}

settings_view_set_colors :: proc(
    view: ^Settings_View,
    background, border, header, field, text, muted, accent, selected: rl.Color,
) -> ^Settings_View {
    view.background_color = background
    view.border_color = border
    view.header_color = header
    view.field_color = field
    view.text_color = text
    view.muted_color = muted
    view.accent_color = accent
    view.selected_color = selected
    return view
}

settings_view_set_callbacks :: proc(
    view: ^Settings_View,
    on_number: Settings_Number_Proc,
    on_choice: Settings_Choice_Proc,
    on_keybind: Settings_Keybind_Proc,
    on_scope_change: Settings_Scope_Proc,
    on_init_workspace: Settings_Init_Workspace_Proc,
    data: rawptr,
) {
    view.on_number = on_number
    view.on_choice = on_choice
    view.on_keybind = on_keybind
    view.on_scope_change = on_scope_change
    view.on_init_workspace = on_init_workspace
    view.data = data
}

settings_view_scope :: proc(view: ^Settings_View) -> Settings_Scope {
    return view.scope
}

settings_view_set_workspace_available :: proc(view: ^Settings_View, available: bool) {
    view.workspace_available = available
}

// Drops every row and category, keeping scroll/scope/capture so a live
// repopulate (after a change persists and reloads) does not reset the view.
// settings_view_open resets those.
settings_view_clear :: proc(view: ^Settings_View) {
    for row in view.rows {
        delete(row.id)
        delete(row.label)
        delete(row.value)
        delete(row.category)
    }
    clear(&view.rows)
    for cat in view.categories {
        delete(cat.id)
        delete(cat.label)
        delete(cat.icon)
    }
    clear(&view.categories)
    delete(view.current_category)
    view.current_category = ""
    clear(&view.visible_rows)
}

// Registers a sidebar entry and points every row added after it at this
// category, until the next settings_view_begin_category call.
settings_view_begin_category :: proc(view: ^Settings_View, id, label, icon: string) {
    append(&view.categories, Settings_Category {
        id = strings.clone(id),
        label = strings.clone(label),
        icon = strings.clone(icon),
    })
    delete(view.current_category)
    view.current_category = strings.clone(id)
}

settings_view_add_number :: proc(view: ^Settings_View, id, label: string, value, min, max, step: int) {
    buf: [32]u8
    append(&view.rows, Settings_Row {
        kind = .Number,
        id = strings.clone(id),
        label = strings.clone(label),
        value = strings.clone(strconv.write_int(buf[:], cast(i64) value, 10)),
        category = strings.clone(view.current_category),
        number = value,
        min = min,
        max = max,
        step = step,
    })
}

settings_view_add_choice :: proc(view: ^Settings_View, id, label, value: string) {
    append(&view.rows, Settings_Row {
        kind = .Choice,
        id = strings.clone(id),
        label = strings.clone(label),
        value = strings.clone(value),
        category = strings.clone(view.current_category),
    })
}

// `chord` is the display string ("Ctrl+K"), or "" for an unbound action.
settings_view_add_keybind :: proc(view: ^Settings_View, id, label, chord: string) {
    append(&view.rows, Settings_Row {
        kind = .Keybind,
        id = strings.clone(id),
        label = strings.clone(label),
        value = strings.clone(chord),
        category = strings.clone(view.current_category),
    })
}

settings_view_open :: proc(view: ^Settings_View, ctx: ^ui.Context) {
    view.scroll = 0
    view.capturing = -1
    view.scope = .General
    view.selected_category = 0
    clear(&view.search)
    view.selected = 0
    view.visible = true
    view.return_focus = ctx.focused
    ctx.focused = &view.widget
    ui.widget_bring_to_front(&view.widget)
}

settings_view_is_open :: proc(view: ^Settings_View) -> bool {
    return view != nil && view.visible
}

// True while a keybinding row is waiting for a chord; the host checks this to
// step aside so the next press reaches the widget instead of firing a shortcut.
settings_view_is_capturing :: proc(view: ^Settings_View) -> bool {
    return view != nil && view.visible && view.capturing >= 0
}

@(private = "file")
settings_view_close :: proc(view: ^Settings_View, ctx: ^ui.Context) {
    view.visible = false
    view.capturing = -1
    if ctx.focused == &view.widget {
        ctx.focused = view.return_focus
    }
}

// Switches scope, resetting the category/search/scroll state that no longer
// applies, then lets the host rebuild rows for the new scope.
@(private = "file")
settings_view_switch_scope :: proc(view: ^Settings_View, scope: Settings_Scope) {
    if view.scope == scope {
        return
    }
    view.scope = scope
    view.selected_category = 0
    view.scroll = 0
    clear(&view.search)
    if view.on_scope_change != nil {
        view.on_scope_change(view.data, scope)
    }
}

settings_view_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    view := cast(^Settings_View) widget
    // Cover the whole screen so clicks outside the box dismiss the dialog.
    view.bounds = bounds

    settings_view_recompute_visible(view)

    width := min(view.width, bounds.width - 80)
    max_height := bounds.height * 0.82
    content_rows_h := cast(f32) len(view.visible_rows) * view.row_height
    sidebar_needed := cast(f32) len(view.categories) * view.category_height + 16
    body := max(content_rows_h, sidebar_needed)
    chrome := view.header_height + view.search_height
    height := clamp(chrome + body + 16, chrome + 120, max_height)

    view.box = rl.Rectangle {
        x = bounds.x + (bounds.width - width) * 0.5,
        y = bounds.y + (bounds.height - height) * 0.5,
        width = width,
        height = height,
    }
    view.sidebar = rl.Rectangle {
        view.box.x, view.box.y + view.header_height, view.sidebar_width, view.box.height - view.header_height,
    }
    view.content = rl.Rectangle {
        view.box.x + view.sidebar_width,
        view.box.y + view.header_height,
        view.box.width - view.sidebar_width,
        view.box.height - view.header_height,
    }
    settings_view_clamp_scroll(view)

    // A live repopulate (settings_view_clear + re-adding rows) can shrink or
    // reorder the list; keep the keyboard selection in bounds.
    if len(view.visible_rows) == 0 {
        view.selected = -1
    } else {
        view.selected = clamp(view.selected, 0, len(view.visible_rows) - 1)
    }
}

// Rebuilds visible_rows from the selected category, or from every row whose
// label matches `search` when it is non-empty.
@(private = "file")
settings_view_recompute_visible :: proc(view: ^Settings_View) {
    clear(&view.visible_rows)
    if len(view.search) == 0 {
        if view.selected_category < 0 || view.selected_category >= len(view.categories) {
            return
        }
        cat_id := view.categories[view.selected_category].id
        for row, i in view.rows {
            if row.category == cat_id {
                append(&view.visible_rows, i)
            }
        }
        return
    }
    query := strings.to_lower(string(view.search[:]), context.temp_allocator)
    for row, i in view.rows {
        label := strings.to_lower(row.label, context.temp_allocator)
        if strings.contains(label, query) {
            append(&view.visible_rows, i)
        }
    }
}

@(private = "file")
settings_view_category_label :: proc(view: ^Settings_View, id: string) -> string {
    for cat in view.categories {
        if cat.id == id {
            return cat.label
        }
    }
    return ""
}

// Height of the scrollable list area below the search box.
@(private = "file")
settings_view_list_height :: proc(view: ^Settings_View) -> f32 {
    return view.content.height - view.search_height
}

@(private = "file")
settings_view_max_scroll :: proc(view: ^Settings_View) -> f32 {
    content := cast(f32) len(view.visible_rows) * view.row_height
    return max(0, content - settings_view_list_height(view))
}

@(private = "file")
settings_view_clamp_scroll :: proc(view: ^Settings_View) {
    view.scroll = clamp(view.scroll, 0, settings_view_max_scroll(view))
}

// Screen rect of the row at position `pos` in visible_rows, accounting for
// scroll; may fall outside the list area.
@(private = "file")
settings_view_row_rect :: proc(view: ^Settings_View, pos: int) -> rl.Rectangle {
    top := view.content.y + view.search_height + cast(f32) pos * view.row_height - view.scroll
    return rl.Rectangle {view.content.x, top, view.content.width, view.row_height}
}

// Position in visible_rows under `point`, or -1 when outside the list area.
@(private = "file")
settings_view_row_at :: proc(view: ^Settings_View, point: rl.Vector2) -> int {
    list_top := view.content.y + view.search_height
    list := rl.Rectangle {view.content.x, list_top, view.content.width, settings_view_list_height(view)}
    if !rl.CheckCollisionPointRec(point, list) {
        return -1
    }
    pos := cast(int) ((point.y - list_top + view.scroll) / view.row_height)
    if pos < 0 || pos >= len(view.visible_rows) {
        return -1
    }
    return pos
}

// The three hit rects on a Number row: minus button, value box, plus button.
@(private = "file")
settings_view_number_rects :: proc(view: ^Settings_View, row: rl.Rectangle) -> (minus, value, plus: rl.Rectangle) {
    btn: f32 = 28
    val_w: f32 = 58
    pad: f32 = 14
    cy := row.y + (row.height - btn) * 0.5
    plus = rl.Rectangle {row.x + row.width - pad - btn, cy, btn, btn}
    value = rl.Rectangle {plus.x - val_w, cy, val_w, btn}
    minus = rl.Rectangle {value.x - btn, cy, btn, btn}
    return
}

// The clear ("unbind") box on a Keybind row, at its right edge.
@(private = "file")
settings_view_clear_rect :: proc(view: ^Settings_View, row: rl.Rectangle) -> rl.Rectangle {
    btn: f32 = 28
    pad: f32 = 14
    cy := row.y + (row.height - btn) * 0.5
    return rl.Rectangle {row.x + row.width - pad - btn, cy, btn, btn}
}

// The header's two scope-tab pills, right-aligned.
@(private = "file")
settings_view_scope_tab_rects :: proc(view: ^Settings_View) -> (general, workspace: rl.Rectangle) {
    tab_h: f32 = 28
    tab_w: f32 = 96
    gap: f32 = 8
    pad: f32 = 16
    y := view.box.y + (view.header_height - tab_h) * 0.5
    workspace = rl.Rectangle {view.box.x + view.box.width - pad - tab_w, y, tab_w, tab_h}
    general = rl.Rectangle {workspace.x - gap - tab_w, y, tab_w, tab_h}
    return
}

@(private = "file")
settings_view_workspace_cta_rect :: proc(view: ^Settings_View) -> rl.Rectangle {
    w: f32 = 220
    h: f32 = 40
    return rl.Rectangle {
        view.content.x + (view.content.width - w) * 0.5,
        view.content.y + view.content.height * 0.5,
        w, h,
    }
}

settings_view_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    view := cast(^Settings_View) widget
    if !view.visible {
        return false
    }

    #partial switch event.kind {
    case .Key_Press:
        if view.capturing >= 0 {
            settings_view_capture_key(view, event)
        } else {
            #partial switch event.key {
            case .ESCAPE:
                if len(view.search) > 0 {
                    clear(&view.search)
                } else {
                    settings_view_close(view, ctx)
                }
            case .UP:
                settings_view_move_selection(view, -1)
            case .DOWN:
                settings_view_move_selection(view, 1)
            case .LEFT:
                settings_view_nudge_selected(view, -1)
            case .RIGHT:
                settings_view_nudge_selected(view, 1)
            case .ENTER, .KP_ENTER:
                settings_view_activate_selected(view)
            case .BACKSPACE:
                settings_view_search_backspace(view)
            }
        }
        return true

    case .Text_Input:
        settings_view_search_input(view, event)
        return true

    case .Scroll:
        view.scroll -= event.wheel_delta * view.row_height
        settings_view_clamp_scroll(view)
        return true

    case .Mouse_Down:
        settings_view_mouse_down(view, ctx, event.mouse_position)
        return true
    }

    return true // block everything underneath while open
}

// Appends a typed rune to the search query; swallows control chords and
// non-printable codepoints so a bound shortcut never leaks into the box.
@(private = "file")
settings_view_search_input :: proc(view: ^Settings_View, event: ^ui.Event) {
    if view.capturing >= 0 {
        return
    }
    if event.ctrl && !event.alt {
        return
    }
    if event.codepoint < 32 || event.codepoint == 127 {
        return
    }
    buffer, width := utf8.encode_rune(event.codepoint)
    append(&view.search, ..buffer[:width])
    view.scroll = 0
    view.selected = 0
}

@(private = "file")
settings_view_search_backspace :: proc(view: ^Settings_View) {
    if len(view.search) == 0 {
        return
    }
    text := string(view.search[:])
    start := input_prev_rune(text, len(text))
    resize(&view.search, start)
    view.scroll = 0
    view.selected = 0
}

@(private = "file")
settings_view_mouse_down :: proc(view: ^Settings_View, ctx: ^ui.Context, point: rl.Vector2) {
    if !rl.CheckCollisionPointRec(point, view.box) {
        settings_view_close(view, ctx)
        return
    }
    // A press anywhere else cancels an in-progress capture.
    if view.capturing >= 0 {
        view.capturing = -1
        return
    }
    if settings_view_click_scope_tabs(view, point) {
        return
    }
    if view.scope == .Workspace && !view.workspace_available {
        if rl.CheckCollisionPointRec(point, settings_view_workspace_cta_rect(view)) && view.on_init_workspace != nil {
            view.on_init_workspace(view.data)
        }
        return
    }
    if settings_view_click_sidebar(view, point) {
        return
    }
    settings_view_click(view, point)
}

@(private = "file")
settings_view_click_scope_tabs :: proc(view: ^Settings_View, point: rl.Vector2) -> bool {
    general, workspace := settings_view_scope_tab_rects(view)
    if rl.CheckCollisionPointRec(point, general) {
        settings_view_switch_scope(view, .General)
        return true
    }
    if rl.CheckCollisionPointRec(point, workspace) {
        settings_view_switch_scope(view, .Workspace)
        return true
    }
    return false
}

@(private = "file")
settings_view_click_sidebar :: proc(view: ^Settings_View, point: rl.Vector2) -> bool {
    if !rl.CheckCollisionPointRec(point, view.sidebar) {
        return false
    }
    i := cast(int) ((point.y - view.sidebar.y) / view.category_height)
    if i >= 0 && i < len(view.categories) && i != view.selected_category {
        view.selected_category = i
        clear(&view.search)
        view.scroll = 0
        view.selected = 0
    }
    return true
}

// Commits or cancels a chord capture. Modifier-only presses are ignored so the
// widget waits for the real key; Escape cancels without changing the binding.
@(private = "file")
settings_view_capture_key :: proc(view: ^Settings_View, event: ^ui.Event) {
    #partial switch event.key {
    case .LEFT_CONTROL, .RIGHT_CONTROL, .LEFT_SHIFT, .RIGHT_SHIFT, .LEFT_ALT, .RIGHT_ALT:
        return
    case .ESCAPE:
        view.capturing = -1
        return
    }
    row := view.capturing
    view.capturing = -1
    if row >= 0 && row < len(view.rows) && view.on_keybind != nil {
        view.on_keybind(view.data, view.rows[row].id, event.key, event.ctrl, event.shift, event.alt)
    }
}

// Moves keyboard selection one row in `dir` within visible_rows.
@(private = "file")
settings_view_move_selection :: proc(view: ^Settings_View, dir: int) {
    if len(view.visible_rows) == 0 {
        return
    }
    view.selected = clamp(view.selected + dir, 0, len(view.visible_rows) - 1)
    settings_view_scroll_selected_into_view(view)
}

@(private = "file")
settings_view_scroll_selected_into_view :: proc(view: ^Settings_View) {
    if view.selected < 0 {
        return
    }
    top := cast(f32) view.selected * view.row_height
    bottom := top + view.row_height
    list_height := settings_view_list_height(view)
    if top < view.scroll {
        view.scroll = top
    } else if bottom > view.scroll + list_height {
        view.scroll = bottom - list_height
    }
    settings_view_clamp_scroll(view)
}

// Applies a stepper delta to a Number row, clamped to its range; shared by the
// mouse +/- buttons and the keyboard Left/Right nudge.
@(private = "file")
settings_view_apply_number_delta :: proc(view: ^Settings_View, item: ^Settings_Row, delta: int) {
    next := clamp(item.number + delta, item.min, item.max)
    if next != item.number && view.on_number != nil {
        view.on_number(view.data, item.id, next)
    }
}

// Left/Right on the selected row: nudges a Number row by one step; no-op for
// any other kind.
@(private = "file")
settings_view_nudge_selected :: proc(view: ^Settings_View, dir: int) {
    if view.selected < 0 || view.selected >= len(view.visible_rows) {
        return
    }
    item := &view.rows[view.visible_rows[view.selected]]
    if item.kind != .Number {
        return
    }
    settings_view_apply_number_delta(view, item, dir * item.step)
}

// Enter on the selected row: opens a Choice row's picker, or starts capturing
// a Keybind row's next chord. No-op for a Number row.
@(private = "file")
settings_view_activate_selected :: proc(view: ^Settings_View) {
    if view.selected < 0 || view.selected >= len(view.visible_rows) {
        return
    }
    vi := view.visible_rows[view.selected]
    item := &view.rows[vi]
    #partial switch item.kind {
    case .Choice:
        if view.on_choice != nil {
            view.on_choice(view.data, item.id)
        }
    case .Keybind:
        view.capturing = vi
    }
}

// Routes a click inside the list to the row control under it. May trigger a
// callback that repopulates the rows, so it reads nothing from the row afterward.
@(private = "file")
settings_view_click :: proc(view: ^Settings_View, point: rl.Vector2) {
    pos := settings_view_row_at(view, point)
    if pos < 0 {
        return
    }
    view.selected = pos
    rect := settings_view_row_rect(view, pos)
    vi := view.visible_rows[pos]
    item := &view.rows[vi]

    switch item.kind {
    case .Number:
        minus, _, plus := settings_view_number_rects(view, rect)
        delta := 0
        if rl.CheckCollisionPointRec(point, minus) {
            delta = -item.step
        } else if rl.CheckCollisionPointRec(point, plus) {
            delta = item.step
        }
        if delta != 0 {
            settings_view_apply_number_delta(view, item, delta)
        }
    case .Choice:
        if view.on_choice != nil {
            view.on_choice(view.data, item.id)
        }
    case .Keybind:
        if rl.CheckCollisionPointRec(point, settings_view_clear_rect(view, rect)) {
            if view.on_keybind != nil {
                view.on_keybind(view.data, item.id, .KEY_NULL, false, false, false)
            }
        } else {
            view.capturing = vi
        }
    }
}

settings_view_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    view := cast(^Settings_View) widget
    if !view.visible {
        return
    }

    rl.DrawRectangleRec(view.bounds, rl.Color {0, 0, 0, 120})
    rl.DrawRectangleRounded(view.box, 0.04, 8, view.background_color)
    rl.DrawRectangleRoundedLinesEx(view.box, 0.04, 8, 1, view.border_color)

    ui.draw_text(
        "Settings",
        cast(i32) (view.box.x + 20),
        cast(i32) (view.box.y + (view.header_height - 20) * 0.5),
        20,
        view.text_color,
    )
    settings_view_draw_scope_tabs(view)
    rl.DrawRectangleRec(
        rl.Rectangle {view.box.x + 12, view.box.y + view.header_height, view.box.width - 24, 1},
        view.muted_color,
    )

    settings_view_draw_sidebar(view)

    if view.scope == .Workspace && !view.workspace_available {
        settings_view_draw_workspace_empty_state(view)
        return
    }

    settings_view_draw_search(view)

    list := rl.Rectangle {
        view.content.x, view.content.y + view.search_height, view.content.width, settings_view_list_height(view),
    }
    ui.begin_clip(list)
    show_category := len(view.search) > 0
    for pos in 0 ..< len(view.visible_rows) {
        vi := view.visible_rows[pos]
        rect := settings_view_row_rect(view, pos)
        if rect.y + rect.height < list.y || rect.y > list.y + list.height {
            continue // fully scrolled out
        }
        if pos == view.selected {
            rl.DrawRectangleRounded(rect, 0.2, 6, view.selected_color)
        }
        settings_view_draw_row(view, &view.rows[vi], rect, vi, show_category)
    }
    ui.end_clip()

    settings_view_draw_scrollbar(view, list)
}

@(private = "file")
settings_view_draw_sidebar :: proc(view: ^Settings_View) {
    rl.DrawRectangleRec(view.sidebar, view.header_color)
    mouse := rl.GetMousePosition()
    for cat, i in view.categories {
        rect := rl.Rectangle {
            view.sidebar.x, view.sidebar.y + cast(f32) i * view.category_height, view.sidebar.width, view.category_height,
        }
        selected := i == view.selected_category && len(view.search) == 0
        if selected {
            rl.DrawRectangleRec(rect, rl.Color {255, 255, 255, 26})
        } else if rl.CheckCollisionPointRec(mouse, rect) {
            rl.DrawRectangleRec(rect, rl.Color {255, 255, 255, 14})
        }
        icon_color := selected ? view.accent_color : view.muted_color
        text_color := selected ? view.text_color : view.muted_color
        ui.draw_icon(cat.icon, cast(i32) (rect.x + 14), cast(i32) (rect.y + (rect.height - 16) * 0.5), 16, icon_color)
        ui.draw_text(cat.label, cast(i32) (rect.x + 40), cast(i32) (rect.y + (rect.height - 15) * 0.5), 15, text_color)
    }
    rl.DrawRectangleRec(
        rl.Rectangle {view.sidebar.x + view.sidebar.width - 1, view.sidebar.y, 1, view.sidebar.height},
        view.muted_color,
    )
}

@(private = "file")
settings_view_draw_scope_tabs :: proc(view: ^Settings_View) {
    general, workspace := settings_view_scope_tab_rects(view)
    settings_view_draw_scope_tab(view, general, "General", view.scope == .General)
    settings_view_draw_scope_tab(view, workspace, "Workspace", view.scope == .Workspace)
}

@(private = "file")
settings_view_draw_scope_tab :: proc(view: ^Settings_View, rect: rl.Rectangle, label: string, active: bool) {
    fill := active ? view.accent_color : view.field_color
    text_color := active ? view.background_color : view.muted_color
    rl.DrawRectangleRounded(rect, 0.5, 6, fill)
    tw := ui.measure_text(label, 14)
    ui.draw_text(
        label,
        cast(i32) (rect.x + (rect.width - cast(f32) tw) * 0.5),
        cast(i32) (rect.y + (rect.height - 14) * 0.5),
        14,
        text_color,
    )
}

@(private = "file")
settings_view_draw_search :: proc(view: ^Settings_View) {
    pad: f32 = 12
    rect := rl.Rectangle {view.content.x + pad, view.content.y + pad, view.content.width - pad * 2, view.search_height - pad}
    rl.DrawRectangleRounded(rect, 0.3, 6, view.field_color)

    icon_size: i32 = 16
    ui.draw_icon(
        "search",
        cast(i32) (rect.x + 10),
        cast(i32) (rect.y + (rect.height - cast(f32) icon_size) * 0.5),
        icon_size,
        view.muted_color,
    )
    text_x := cast(i32) (rect.x + 34)
    text_y := cast(i32) (rect.y + (rect.height - 16) * 0.5)
    if len(view.search) == 0 {
        ui.draw_text("Search settings...", text_x, text_y, 16, view.muted_color)
        return
    }
    query := string(view.search[:])
    ui.draw_text(query, text_x, text_y, 16, view.text_color)
    caret_x := text_x + cast(i32) ui.measure_text(query, 16) + 2
    rl.DrawRectangle(caret_x, text_y, 2, 16, view.accent_color)
}

@(private = "file")
settings_view_draw_workspace_empty_state :: proc(view: ^Settings_View) {
    msg := "This folder isn't a workspace yet."
    mw := ui.measure_text(msg, 16)
    my := view.content.y + view.content.height * 0.5 - 44
    ui.draw_text(msg, cast(i32) (view.content.x + (view.content.width - cast(f32) mw) * 0.5), cast(i32) my, 16, view.muted_color)

    rect := settings_view_workspace_cta_rect(view)
    hover := rl.CheckCollisionPointRec(rl.GetMousePosition(), rect)
    rl.DrawRectangleRounded(rect, 0.3, 6, hover ? view.accent_color : view.field_color)
    label := "Create Workspace Settings"
    lw := ui.measure_text(label, 15)
    ui.draw_text(
        label,
        cast(i32) (rect.x + (rect.width - cast(f32) lw) * 0.5),
        cast(i32) (rect.y + (rect.height - 15) * 0.5),
        15,
        hover ? view.background_color : view.text_color,
    )
}

@(private = "file")
settings_view_draw_row :: proc(view: ^Settings_View, item: ^Settings_Row, rect: rl.Rectangle, row_index: int, show_category: bool) {
    pad: f32 = 16
    label_y := cast(i32) (rect.y + (rect.height - 17) * 0.5)
    label_x := rect.x + pad

    if show_category {
        cat_label := settings_view_category_label(view, item.category)
        if cat_label != "" {
            prefix := strings.concatenate({cat_label, " · "}, context.temp_allocator)
            ui.draw_text(prefix, cast(i32) label_x, label_y, 17, view.muted_color)
            label_x += cast(f32) ui.measure_text(prefix, 17)
        }
    }
    ui.draw_text(item.label, cast(i32) label_x, label_y, 17, view.text_color)

    switch item.kind {
    case .Number:
        minus, value, plus := settings_view_number_rects(view, rect)
        settings_view_draw_button(view, minus, "-")
        settings_view_draw_button(view, plus, "+")
        rl.DrawRectangleRounded(value, 0.2, 6, view.field_color)
        tw := ui.measure_text(item.value, 17)
        ui.draw_text(
            item.value,
            cast(i32) (value.x + (value.width - cast(f32) tw) * 0.5),
            cast(i32) (value.y + (value.height - 17) * 0.5),
            17,
            view.text_color,
        )
    case .Choice:
        tw := ui.measure_text(item.value, 17)
        ui.draw_text(
            item.value,
            cast(i32) (rect.x + rect.width - pad - cast(f32) tw),
            label_y,
            17,
            view.accent_color,
        )
    case .Keybind:
        clear_rect := settings_view_clear_rect(view, rect)
        if item.value != "" {
            settings_view_draw_button(view, clear_rect, "x")
        }
        chord := item.value != "" ? item.value : "unbound"
        color := item.value != "" ? view.text_color : view.muted_color
        if view.capturing == row_index {
            chord = "Press shortcut..."
            color = view.accent_color
        }
        tw := ui.measure_text(chord, 16)
        right := clear_rect.x - 10
        ui.draw_text(
            chord,
            cast(i32) (right - cast(f32) tw),
            cast(i32) (rect.y + (rect.height - 16) * 0.5),
            16,
            color,
        )
    }
}

@(private = "file")
settings_view_draw_button :: proc(view: ^Settings_View, rect: rl.Rectangle, glyph: string) {
    hover := rl.CheckCollisionPointRec(rl.GetMousePosition(), rect)
    rl.DrawRectangleRounded(rect, 0.3, 6, hover ? view.header_color : view.field_color)
    rl.DrawRectangleRoundedLinesEx(rect, 0.3, 6, 1, view.muted_color)
    tw := ui.measure_text(glyph, 18)
    ui.draw_text(
        glyph,
        cast(i32) (rect.x + (rect.width - cast(f32) tw) * 0.5),
        cast(i32) (rect.y + (rect.height - 18) * 0.5),
        18,
        hover ? view.accent_color : view.text_color,
    )
}

@(private = "file")
settings_view_draw_scrollbar :: proc(view: ^Settings_View, list: rl.Rectangle) {
    max_scroll := settings_view_max_scroll(view)
    if max_scroll <= 0 {
        return
    }
    width: f32 = 5
    x := list.x + list.width - width - 2
    rl.DrawRectangleRec(rl.Rectangle {x, list.y, width, list.height}, view.header_color)

    content := cast(f32) len(view.visible_rows) * view.row_height
    thumb_h := max(list.height * list.height / content, 24)
    t := view.scroll / max_scroll
    thumb_y := list.y + (list.height - thumb_h) * t
    rl.DrawRectangleRec(rl.Rectangle {x, thumb_y, width, thumb_h}, view.muted_color)
}

settings_view_destroy :: proc(widget: ^ui.Widget) {
    view := cast(^Settings_View) widget
    settings_view_clear(view)
    delete(view.rows)
    delete(view.categories)
    delete(view.visible_rows)
    delete(view.search)
    free(view)
}
