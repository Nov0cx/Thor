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

// Corner roundness of the box, as raylib's DrawRectangleRounded takes it.
@(private)
SETTINGS_ROUNDNESS :: f32(0.04)
// Space over, and under, the search field.
@(private)
SETTINGS_SEARCH_PAD_TOP :: f32(16)
@(private)
SETTINGS_SEARCH_PAD_BOTTOM :: f32(14)
@(private)
SETTINGS_SEARCH_FIELD_HEIGHT :: f32(34)
// Space over the first category entry.
@(private)
SETTINGS_SIDEBAR_PAD_TOP :: f32(10)
// Side margin of a category entry and of a row band.
@(private)
SETTINGS_ITEM_INSET :: f32(8)
// Space between a row's edge and its controls; keeps them clear of the scrollbar.
@(private)
SETTINGS_ROW_PAD :: f32(22)
// Extra left offset of a row inside a foldable group.
@(private)
SETTINGS_GROUP_INDENT :: f32(20)

Settings_Row_Kind :: enum {
    Number,  // label + [-] value [+] stepper
    Choice,  // label + value; clicking asks the host to open a picker
    Keybind, // label + chord; clicking captures a new chord, a clear box unbinds
    Group,   // chevron + label; clicking folds or unfolds the rows under it
}

Settings_Row :: struct {
    kind:     Settings_Row_Kind,
    id:       string, // owned; stable key handed back to the callbacks
    label:    string, // owned
    value:    string, // owned; formatted display (number, choice, chord)
    category: string, // owned; id of the Settings_Category this row belongs to
    group:    string, // owned; id of the Group row holding it, "" outside a group
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
    current_group:     string, // owned; cursor set by begin_group, "" outside one
    // Fold state per group id (keys owned). It outlives settings_view_clear, so
    // a repopulate after a change keeps the groups the user folded folded.
    collapsed:         map[string]bool,
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
    // The box keeps this size whatever it holds, so a scope or category switch
    // never resizes the modal under the cursor.
    width:        f32,
    height:       f32,
    row_height:      f32,
    header_height:   f32,
    category_height: f32,
    search_height:   f32,
    footer_height:   f32,
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
    view.collapsed = make(map[string]bool)
    view.capturing = -1
    view.selected = -1
    view.selected_category = 0
    view.scope = .General
    view.width = 880
    view.height = 560
    view.row_height = 40
    view.header_height = 56
    view.category_height = 36
    view.search_height = SETTINGS_SEARCH_PAD_TOP + SETTINGS_SEARCH_FIELD_HEIGHT + SETTINGS_SEARCH_PAD_BOTTOM
    view.footer_height = 34
    view.sidebar_width = 200
    view.background_color = rl.Color {24, 26, 31, 250}
    view.header_color = rl.Color {31, 34, 51, 255}
    view.field_color = rl.Color {18, 20, 24, 255}
    view.border_color = rl.Color {51, 56, 70, 255}
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
        delete(row.group)
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
    delete(view.current_group)
    view.current_group = ""
    clear(&view.visible_rows)
}

// Registers a sidebar entry and points every row added after it at this
// category, until the next settings_view_begin_category call. It also ends an
// open group: a group never spans two categories.
settings_view_begin_category :: proc(view: ^Settings_View, id, label, icon: string) {
    append(&view.categories, Settings_Category {
        id = strings.clone(id),
        label = strings.clone(label),
        icon = strings.clone(icon),
    })
    delete(view.current_category)
    view.current_category = strings.clone(id)
    settings_view_end_group(view)
}

// Adds a foldable header and puts every row added after it inside the group,
// until settings_view_end_group. `collapsed` is the state the group starts in;
// once the user folds it, that answer wins over the default.
settings_view_begin_group :: proc(view: ^Settings_View, id, label: string, collapsed := false) {
    if id not_in view.collapsed {
        view.collapsed[strings.clone(id)] = collapsed
    }
    append(&view.rows, Settings_Row {
        kind = .Group,
        id = strings.clone(id),
        label = strings.clone(label),
        value = strings.clone(""),
        category = strings.clone(view.current_category),
        group = strings.clone(""),
    })
    delete(view.current_group)
    view.current_group = strings.clone(id)
}

settings_view_end_group :: proc(view: ^Settings_View) {
    delete(view.current_group)
    view.current_group = ""
}

@(private = "file")
settings_view_group_collapsed :: proc(view: ^Settings_View, id: string) -> bool {
    return view.collapsed[id] or_else false
}

// Folds an unfolded group, and the reverse.
@(private = "file")
settings_view_toggle_group :: proc(view: ^Settings_View, id: string) {
    if id not_in view.collapsed {
        return
    }
    view.collapsed[id] = !view.collapsed[id]
    view.scroll = 0
}

settings_view_add_number :: proc(view: ^Settings_View, id, label: string, value, min, max, step: int) {
    buf: [32]u8
    append(&view.rows, Settings_Row {
        kind = .Number,
        id = strings.clone(id),
        label = strings.clone(label),
        value = strings.clone(strconv.write_int(buf[:], cast(i64) value, 10)),
        category = strings.clone(view.current_category),
        group = strings.clone(view.current_group),
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
        group = strings.clone(view.current_group),
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
        group = strings.clone(view.current_group),
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
    height := min(view.height, max(bounds.height - 80, 240))

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

// Rebuilds visible_rows from the selected category, less the rows in a folded
// group, or from every row whose label matches `search` when it is non-empty.
// A search reaches into a folded group and drops the group headers: the query
// answers what is shown, not the fold state.
@(private = "file")
settings_view_recompute_visible :: proc(view: ^Settings_View) {
    clear(&view.visible_rows)
    if len(view.search) == 0 {
        if view.selected_category < 0 || view.selected_category >= len(view.categories) {
            return
        }
        cat_id := view.categories[view.selected_category].id
        for row, i in view.rows {
            if row.category != cat_id {
                continue
            }
            if row.group != "" && settings_view_group_collapsed(view, row.group) {
                continue
            }
            append(&view.visible_rows, i)
        }
        return
    }
    query := strings.to_lower(string(view.search[:]), context.temp_allocator)
    for row, i in view.rows {
        if row.kind == .Group {
            continue
        }
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

// Corner radius raylib gives the box for SETTINGS_ROUNDNESS. The sidebar fill
// and the shadow follow it.
@(private = "file")
settings_view_corner_radius :: proc(view: ^Settings_View) -> f32 {
    return SETTINGS_ROUNDNESS * min(view.box.width, view.box.height) * 0.5
}

// `base` at `alpha`: the hover and separator washes are derived from a theme
// color, never from a fixed grey.
@(private = "file")
settings_view_tint :: proc(base: rl.Color, alpha: u8) -> rl.Color {
    return rl.Color {base.r, base.g, base.b, alpha}
}

// Height of the scrollable list area, between the search box and the footer.
@(private = "file")
settings_view_list_height :: proc(view: ^Settings_View) -> f32 {
    return view.content.height - view.search_height - view.footer_height
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
@(private)
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

// Screen rect of the category entry at `index`, inset from the sidebar edges.
@(private)
settings_view_category_rect :: proc(view: ^Settings_View, index: int) -> rl.Rectangle {
    return rl.Rectangle {
        view.sidebar.x + SETTINGS_ITEM_INSET,
        view.sidebar.y + SETTINGS_SIDEBAR_PAD_TOP + cast(f32) index * view.category_height,
        view.sidebar.width - SETTINGS_ITEM_INSET * 2,
        view.category_height,
    }
}

// The three hit rects on a Number row: minus button, value box, plus button.
// They are spaced apart, so the stepper does not read as one box.
@(private)
settings_view_number_rects :: proc(view: ^Settings_View, row: rl.Rectangle) -> (minus, value, plus: rl.Rectangle) {
    btn: f32 = 28
    val_w: f32 = 56
    gap: f32 = 6
    cy := row.y + (row.height - btn) * 0.5
    plus = rl.Rectangle {row.x + row.width - SETTINGS_ROW_PAD - btn, cy, btn, btn}
    value = rl.Rectangle {plus.x - gap - val_w, cy, val_w, btn}
    minus = rl.Rectangle {value.x - gap - btn, cy, btn, btn}
    return
}

// The clear ("unbind") box on a Keybind row, at its right edge.
@(private = "file")
settings_view_clear_rect :: proc(view: ^Settings_View, row: rl.Rectangle) -> rl.Rectangle {
    btn: f32 = 24
    cy := row.y + (row.height - btn) * 0.5
    return rl.Rectangle {row.x + row.width - SETTINGS_ROW_PAD - btn, cy, btn, btn}
}

// The close box at the right end of the header.
@(private)
settings_view_close_rect :: proc(view: ^Settings_View) -> rl.Rectangle {
    size: f32 = 28
    return rl.Rectangle {
        view.box.x + view.box.width - 14 - size,
        view.box.y + (view.header_height - size) * 0.5,
        size, size,
    }
}

// The two segments of the scope switch, left of the close box. Both are a fixed
// width: the hit test must not depend on a measured label.
@(private = "file")
settings_view_scope_tab_rects :: proc(view: ^Settings_View) -> (general, workspace: rl.Rectangle) {
    tab_h: f32 = 30
    tab_w: f32 = 86
    y := view.box.y + (view.header_height - tab_h) * 0.5
    right := settings_view_close_rect(view).x - 12
    workspace = rl.Rectangle {right - tab_w, y, tab_w, tab_h}
    general = rl.Rectangle {workspace.x - tab_w, y, tab_w, tab_h}
    return
}

@(private)
settings_view_search_rect :: proc(view: ^Settings_View) -> rl.Rectangle {
    pad: f32 = 16
    return rl.Rectangle {
        view.content.x + pad,
        view.content.y + SETTINGS_SEARCH_PAD_TOP,
        view.content.width - pad * 2,
        SETTINGS_SEARCH_FIELD_HEIGHT,
    }
}

// The box that empties the query, at the right edge of the search field.
@(private = "file")
settings_view_search_clear_rect :: proc(view: ^Settings_View) -> rl.Rectangle {
    field := settings_view_search_rect(view)
    size: f32 = 20
    return rl.Rectangle {
        field.x + field.width - 8 - size,
        field.y + (field.height - size) * 0.5,
        size, size,
    }
}

// The hint bar under the list. It spans the content column only, so the sidebar
// stays a full-height rail.
@(private = "file")
settings_view_footer_rect :: proc(view: ^Settings_View) -> rl.Rectangle {
    return rl.Rectangle {
        view.content.x,
        view.content.y + view.content.height - view.footer_height,
        view.content.width,
        view.footer_height,
    }
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
    if rl.CheckCollisionPointRec(point, settings_view_close_rect(view)) {
        settings_view_close(view, ctx)
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
    if len(view.search) > 0 && rl.CheckCollisionPointRec(point, settings_view_search_clear_rect(view)) {
        clear(&view.search)
        view.scroll = 0
        view.selected = 0
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
    top := view.sidebar.y + SETTINGS_SIDEBAR_PAD_TOP
    if point.y < top {
        return true // the pad over the first entry
    }
    i := cast(int) ((point.y - top) / view.category_height)
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

// Left/Right on the selected row: nudges a Number row by one step, or folds
// (Left) and unfolds (Right) a Group row. No-op for any other kind.
@(private = "file")
settings_view_nudge_selected :: proc(view: ^Settings_View, dir: int) {
    if view.selected < 0 || view.selected >= len(view.visible_rows) {
        return
    }
    item := &view.rows[view.visible_rows[view.selected]]
    if item.kind == .Group {
        if settings_view_group_collapsed(view, item.id) == (dir < 0) {
            return
        }
        settings_view_toggle_group(view, item.id)
        return
    }
    if item.kind != .Number {
        return
    }
    settings_view_apply_number_delta(view, item, dir * item.step)
}

// Enter on the selected row: opens a Choice row's picker, starts capturing a
// Keybind row's next chord, or folds a Group row. No-op for a Number row.
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
    case .Group:
        settings_view_toggle_group(view, item.id)
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
    case .Group:
        settings_view_toggle_group(view, item.id)
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
        if item.value != "" && rl.CheckCollisionPointRec(point, settings_view_clear_rect(view, rect)) {
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
    mouse := rl.GetMousePosition()

    rl.DrawRectangleRec(view.bounds, rl.Color {0, 0, 0, 150})
    settings_view_draw_shadow(view)
    rl.DrawRectangleRounded(view.box, SETTINGS_ROUNDNESS, 8, view.background_color)
    rl.DrawRectangleRoundedLinesEx(view.box, SETTINGS_ROUNDNESS, 8, 1, view.border_color)

    // The sidebar comes first: the header divider lies on its top edge.
    settings_view_draw_sidebar(view, mouse)
    settings_view_draw_header(view, mouse)

    if view.scope == .Workspace && !view.workspace_available {
        settings_view_draw_workspace_empty_state(view, mouse)
        return
    }

    settings_view_draw_search(view, mouse)
    settings_view_draw_rows(view, mouse)
    settings_view_draw_footer(view)
}

// Three fading outlines under the box. There is no blur, so the steps stand in
// for one.
@(private = "file")
settings_view_draw_shadow :: proc(view: ^Settings_View) {
    for step := 3; step >= 1; step -= 1 {
        grow := cast(f32) step * 3
        rect := rl.Rectangle {
            view.box.x - grow,
            view.box.y - grow + 2,
            view.box.width + grow * 2,
            view.box.height + grow * 2,
        }
        rl.DrawRectangleRounded(rect, SETTINGS_ROUNDNESS, 8, rl.Color {0, 0, 0, 30})
    }
}

@(private = "file")
settings_view_draw_header :: proc(view: ^Settings_View, mouse: rl.Vector2) {
    ui.draw_text(
        "Settings",
        cast(i32) (view.box.x + 20),
        cast(i32) (view.box.y + (view.header_height - 18) * 0.5),
        18,
        view.text_color,
    )
    settings_view_draw_scope_tabs(view)
    settings_view_draw_icon_button(view, settings_view_close_rect(view), "x", 16, mouse)
    rl.DrawRectangleRec(
        rl.Rectangle {view.box.x + 1, view.box.y + view.header_height, view.box.width - 2, 1},
        settings_view_tint(view.muted_color, 45),
    )
}

@(private = "file")
settings_view_draw_sidebar :: proc(view: ^Settings_View, mouse: rl.Vector2) {
    // An oversized rounded rect clipped to the sidebar: only the bottom-left
    // corner keeps its rounding, so the fill follows the box's corner instead
    // of poking out of it.
    radius := settings_view_corner_radius(view)
    fill := rl.Rectangle {
        view.sidebar.x,
        view.sidebar.y - radius,
        view.sidebar.width + radius,
        view.sidebar.height + radius,
    }
    ui.begin_clip(view.sidebar)
    rl.DrawRectangleRounded(fill, 2 * radius / min(fill.width, fill.height), 8, view.header_color)
    ui.end_clip()

    for cat, i in view.categories {
        rect := settings_view_category_rect(view, i)
        selected := i == view.selected_category && len(view.search) == 0
        if selected {
            rl.DrawRectangleRounded(rect, 0.35, 6, settings_view_tint(view.accent_color, 32))
        } else if rl.CheckCollisionPointRec(mouse, rect) {
            rl.DrawRectangleRounded(rect, 0.35, 6, settings_view_tint(view.text_color, 12))
        }
        icon_color := selected ? view.accent_color : view.muted_color
        text_color := selected ? view.text_color : view.muted_color
        ui.draw_icon(cat.icon, cast(i32) (rect.x + 12), cast(i32) (rect.y + (rect.height - 16) * 0.5), 16, icon_color)
        ui.draw_text(cat.label, cast(i32) (rect.x + 38), cast(i32) (rect.y + (rect.height - 15) * 0.5), 15, text_color)
    }

    rl.DrawRectangleRec(
        rl.Rectangle {view.sidebar.x + view.sidebar.width - 1, view.sidebar.y, 1, view.sidebar.height},
        settings_view_tint(view.muted_color, 45),
    )
}

// One segmented control: a track holding the two scope segments.
@(private = "file")
settings_view_draw_scope_tabs :: proc(view: ^Settings_View) {
    general, workspace := settings_view_scope_tab_rects(view)
    track := rl.Rectangle {general.x, general.y, workspace.x + workspace.width - general.x, general.height}
    rl.DrawRectangleRounded(track, 0.5, 8, view.field_color)
    settings_view_draw_scope_tab(view, general, "General", view.scope == .General)
    settings_view_draw_scope_tab(view, workspace, "Workspace", view.scope == .Workspace)
}

@(private = "file")
settings_view_draw_scope_tab :: proc(view: ^Settings_View, rect: rl.Rectangle, label: string, active: bool) {
    color := view.muted_color
    if active {
        pill := rl.Rectangle {rect.x + 3, rect.y + 3, rect.width - 6, rect.height - 6}
        rl.DrawRectangleRounded(pill, 0.5, 8, settings_view_tint(view.accent_color, 40))
        color = view.accent_color
    }
    tw := ui.measure_text(label, 14)
    ui.draw_text(
        label,
        cast(i32) (rect.x + (rect.width - cast(f32) tw) * 0.5),
        cast(i32) (rect.y + (rect.height - 14) * 0.5),
        14,
        color,
    )
}

@(private = "file")
settings_view_draw_search :: proc(view: ^Settings_View, mouse: rl.Vector2) {
    rect := settings_view_search_rect(view)
    typing := len(view.search) > 0
    rl.DrawRectangleRounded(rect, 0.4, 8, view.field_color)
    border := typing ? settings_view_tint(view.accent_color, 70) : settings_view_tint(view.muted_color, 45)
    rl.DrawRectangleRoundedLinesEx(rect, 0.4, 8, 1, border)

    ui.draw_icon("search", cast(i32) (rect.x + 10), cast(i32) (rect.y + (rect.height - 16) * 0.5), 16, view.muted_color)
    text_x := cast(i32) (rect.x + 34)
    text_y := cast(i32) (rect.y + (rect.height - 15) * 0.5)
    if !typing {
        ui.draw_text("Search settings...", text_x, text_y, 15, view.muted_color)
        return
    }
    query := string(view.search[:])
    ui.draw_text(query, text_x, text_y, 15, view.text_color)
    caret_x := text_x + cast(i32) ui.measure_text(query, 15) + 2
    rl.DrawRectangle(caret_x, text_y, 2, 15, view.accent_color)
    settings_view_draw_icon_button(view, settings_view_search_clear_rect(view), "x", 14, mouse)
}

@(private = "file")
settings_view_draw_rows :: proc(view: ^Settings_View, mouse: rl.Vector2) {
    list := rl.Rectangle {
        view.content.x, view.content.y + view.search_height, view.content.width, settings_view_list_height(view),
    }
    if len(view.visible_rows) == 0 {
        message := len(view.search) > 0 ? "No matching settings" : "Nothing to configure here"
        tw := ui.measure_text(message, 15)
        ui.draw_text(
            message,
            cast(i32) (list.x + (list.width - cast(f32) tw) * 0.5),
            cast(i32) (list.y + list.height * 0.4),
            15,
            view.muted_color,
        )
        return
    }

    hovered := settings_view_row_at(view, mouse)
    ui.begin_clip(list)
    show_category := len(view.search) > 0
    for pos in 0 ..< len(view.visible_rows) {
        vi := view.visible_rows[pos]
        rect := settings_view_row_rect(view, pos)
        if rect.y + rect.height < list.y || rect.y > list.y + list.height {
            continue // fully scrolled out
        }
        band := rl.Rectangle {
            rect.x + SETTINGS_ITEM_INSET, rect.y + 2, rect.width - SETTINGS_ITEM_INSET * 2, rect.height - 4,
        }
        if pos == view.selected {
            rl.DrawRectangleRounded(band, 0.35, 6, view.selected_color)
        } else if pos == hovered {
            rl.DrawRectangleRounded(band, 0.35, 6, settings_view_tint(view.text_color, 10))
        }
        settings_view_draw_row(view, &view.rows[vi], rect, vi, show_category, mouse)
    }
    ui.end_clip()

    settings_view_draw_scrollbar(view, list)
}

@(private = "file")
settings_view_draw_footer :: proc(view: ^Settings_View) {
    rect := settings_view_footer_rect(view)
    rl.DrawRectangleRec(
        rl.Rectangle {rect.x, rect.y, rect.width, 1}, settings_view_tint(view.muted_color, 45),
    )
    // The UI font carries no arrow glyphs, so the hint names the keys.
    hint := "Up/Down navigate  ·  Enter change  ·  Esc close"
    tw := ui.measure_text(hint, 12)
    ui.draw_text(
        hint,
        cast(i32) (rect.x + (rect.width - cast(f32) tw) * 0.5),
        cast(i32) (rect.y + (rect.height - 12) * 0.5),
        12,
        settings_view_tint(view.muted_color, 200),
    )
}

@(private = "file")
settings_view_draw_workspace_empty_state :: proc(view: ^Settings_View, mouse: rl.Vector2) {
    msg := "This folder isn't a workspace yet."
    mw := ui.measure_text(msg, 16)
    my := view.content.y + view.content.height * 0.5 - 44
    ui.draw_text(msg, cast(i32) (view.content.x + (view.content.width - cast(f32) mw) * 0.5), cast(i32) my, 16, view.muted_color)

    rect := settings_view_workspace_cta_rect(view)
    hover := rl.CheckCollisionPointRec(mouse, rect)
    rl.DrawRectangleRounded(rect, 0.35, 6, hover ? settings_view_tint(view.accent_color, 45) : view.field_color)
    rl.DrawRectangleRoundedLinesEx(
        rect, 0.35, 6, 1, hover ? view.accent_color : settings_view_tint(view.muted_color, 60),
    )
    label := "Create Workspace Settings"
    lw := ui.measure_text(label, 15)
    ui.draw_text(
        label,
        cast(i32) (rect.x + (rect.width - cast(f32) lw) * 0.5),
        cast(i32) (rect.y + (rect.height - 15) * 0.5),
        15,
        hover ? view.accent_color : view.text_color,
    )
}

@(private = "file")
settings_view_draw_row :: proc(
    view: ^Settings_View,
    item: ^Settings_Row,
    rect: rl.Rectangle,
    row_index: int,
    show_category: bool,
    mouse: rl.Vector2,
) {
    label_y := cast(i32) (rect.y + (rect.height - 16) * 0.5)
    label_x := rect.x + SETTINGS_ITEM_INSET + 12

    if item.kind == .Group {
        collapsed := settings_view_group_collapsed(view, item.id)
        ui.draw_icon(
            collapsed ? "chevron-right" : "chevron-down",
            cast(i32) label_x,
            cast(i32) (rect.y + (rect.height - 16) * 0.5),
            16,
            view.accent_color,
        )
        ui.draw_text(item.label, cast(i32) (label_x + 22), label_y, 16, view.text_color)
        return
    }

    // Grouped rows sit inset under their header, except under a search, which
    // shows the flat list.
    if item.group != "" && !show_category {
        label_x += SETTINGS_GROUP_INDENT
    }

    if show_category {
        cat_label := settings_view_category_label(view, item.category)
        if cat_label != "" {
            prefix := strings.concatenate({cat_label, " · "}, context.temp_allocator)
            ui.draw_text(prefix, cast(i32) label_x, label_y, 16, view.muted_color)
            label_x += cast(f32) ui.measure_text(prefix, 16)
        }
    }
    ui.draw_text(item.label, cast(i32) label_x, label_y, 16, view.text_color)

    #partial switch item.kind {
    case .Number:
        minus, value, plus := settings_view_number_rects(view, rect)
        settings_view_draw_stepper_button(view, minus, "minus", mouse, item.number > item.min)
        settings_view_draw_stepper_button(view, plus, "plus", mouse, item.number < item.max)
        rl.DrawRectangleRounded(value, 0.35, 6, view.field_color)
        rl.DrawRectangleRoundedLinesEx(value, 0.35, 6, 1, settings_view_tint(view.muted_color, 60))
        tw := ui.measure_text(item.value, 16)
        ui.draw_text(
            item.value,
            cast(i32) (value.x + (value.width - cast(f32) tw) * 0.5),
            cast(i32) (value.y + (value.height - 16) * 0.5),
            16,
            view.text_color,
        )
    case .Choice:
        icon_size: f32 = 16
        icon_x := rect.x + rect.width - SETTINGS_ROW_PAD - icon_size
        ui.draw_icon(
            "chevron-right",
            cast(i32) icon_x,
            cast(i32) (rect.y + (rect.height - icon_size) * 0.5),
            cast(i32) icon_size,
            view.muted_color,
        )
        tw := ui.measure_text(item.value, 16)
        ui.draw_text(item.value, cast(i32) (icon_x - 8 - cast(f32) tw), label_y, 16, view.accent_color)
    case .Keybind:
        clear_rect := settings_view_clear_rect(view, rect)
        capturing := view.capturing == row_index
        bound := item.value != ""
        if bound && !capturing {
            settings_view_draw_icon_button(view, clear_rect, "x", 14, mouse)
        }
        if !bound && !capturing {
            tw := ui.measure_text("unbound", 14)
            ui.draw_text(
                "unbound",
                cast(i32) (clear_rect.x - 8 - cast(f32) tw),
                cast(i32) (rect.y + (rect.height - 14) * 0.5),
                14,
                view.muted_color,
            )
            return
        }
        // A keycap chip, so a chord reads as a key and not as a value.
        chord := capturing ? "Press shortcut..." : item.value
        tw := cast(f32) ui.measure_text(chord, 14)
        chip := rl.Rectangle {clear_rect.x - 8 - tw - 16, rect.y + (rect.height - 24) * 0.5, tw + 16, 24}
        fill := capturing ? settings_view_tint(view.accent_color, 25) : view.field_color
        border := capturing ? view.accent_color : settings_view_tint(view.muted_color, 60)
        rl.DrawRectangleRounded(chip, 0.35, 6, fill)
        rl.DrawRectangleRoundedLinesEx(chip, 0.35, 6, 1, border)
        ui.draw_text(
            chord,
            cast(i32) (chip.x + 8),
            cast(i32) (chip.y + (chip.height - 14) * 0.5),
            14,
            capturing ? view.accent_color : view.text_color,
        )
    }
}

// A borderless icon box for the chrome (close, clear).
@(private = "file")
settings_view_draw_icon_button :: proc(
    view: ^Settings_View, rect: rl.Rectangle, icon: string, size: i32, mouse: rl.Vector2,
) {
    hover := rl.CheckCollisionPointRec(mouse, rect)
    if hover {
        rl.DrawRectangleRounded(rect, 0.35, 6, settings_view_tint(view.accent_color, 25))
    }
    ui.draw_icon(
        icon,
        cast(i32) (rect.x + (rect.width - cast(f32) size) * 0.5),
        cast(i32) (rect.y + (rect.height - cast(f32) size) * 0.5),
        size,
        hover ? view.accent_color : view.muted_color,
    )
}

// A framed stepper button. `enabled` is false at the end of the row's range,
// which dims the glyph.
@(private = "file")
settings_view_draw_stepper_button :: proc(
    view: ^Settings_View, rect: rl.Rectangle, icon: string, mouse: rl.Vector2, enabled: bool,
) {
    hover := enabled && rl.CheckCollisionPointRec(mouse, rect)
    rl.DrawRectangleRounded(rect, 0.35, 6, hover ? settings_view_tint(view.accent_color, 25) : view.field_color)
    rl.DrawRectangleRoundedLinesEx(
        rect, 0.35, 6, 1, hover ? view.accent_color : settings_view_tint(view.muted_color, 60),
    )
    color := view.text_color
    if !enabled {
        color = settings_view_tint(view.muted_color, 90)
    } else if hover {
        color = view.accent_color
    }
    size: f32 = 16
    ui.draw_icon(
        icon,
        cast(i32) (rect.x + (rect.width - size) * 0.5),
        cast(i32) (rect.y + (rect.height - size) * 0.5),
        cast(i32) size,
        color,
    )
}

@(private = "file")
settings_view_draw_scrollbar :: proc(view: ^Settings_View, list: rl.Rectangle) {
    max_scroll := settings_view_max_scroll(view)
    if max_scroll <= 0 {
        return
    }
    width: f32 = 6
    x := list.x + list.width - width - 4
    rl.DrawRectangleRounded(
        rl.Rectangle {x, list.y, width, list.height}, 0.5, 4, settings_view_tint(view.muted_color, 15),
    )

    content := cast(f32) len(view.visible_rows) * view.row_height
    thumb_h := max(list.height * list.height / content, 24)
    t := view.scroll / max_scroll
    thumb_y := list.y + (list.height - thumb_h) * t
    rl.DrawRectangleRounded(
        rl.Rectangle {x, thumb_y, width, thumb_h}, 0.5, 4, settings_view_tint(view.muted_color, 120),
    )
}

settings_view_destroy :: proc(widget: ^ui.Widget) {
    view := cast(^Settings_View) widget
    settings_view_clear(view)
    delete(view.rows)
    delete(view.categories)
    delete(view.visible_rows)
    delete(view.search)
    for id in view.collapsed {
        delete(id)
    }
    delete(view.collapsed)
    free(view)
}
