// The Settings modal: a sidebar of categories, a General/Workspace scope switch,
// a search box that filters across every category, and the row list itself. The
// rows are data — `thor/settings_ui.odin` fills them from the live config and
// persists each change, so this file keeps no settings knowledge.
package thor

import "core:strconv"
import "core:strings"

import ui "../vendor/loom/loom"

SETTINGS_WIDTH :: f32(940)
SETTINGS_HEIGHT :: f32(620)
SETTINGS_SIDEBAR_W :: f32(210)
SETTINGS_ROW_H :: f32(34)
SETTINGS_CATEGORY_H :: f32(32)

Settings_Row_Kind :: enum {
    Number,  // label + [-] value [+] stepper
    Choice,  // label + value; clicking asks the host to open a picker
    Keybind, // label + chord; clicking captures a new chord, a clear box unbinds
    Group,   // chevron + label; clicking folds or unfolds the rows under it
    Info,    // label + read-only value; nothing to click
    Action,  // label + a button at the right edge; clicking asks the host to act
}

// How a value reads. A row states what its value means and the view picks the
// color, so no host spells a theme color of its own.
Settings_Tone :: enum {
    Normal,
    Good,
    Warn,
    Bad,
}

Settings_Row :: struct {
    kind:           Settings_Row_Kind,
    id:             string, // owned; stable key handed back to the handlers
    label:          string, // owned
    value:          string, // owned; formatted display (number, choice, chord, button label)
    category:       string, // owned; id of the Settings_Category this row belongs to
    group:          string, // owned; id of the Group row holding it, "" outside a group
    tone:           Settings_Tone,
    number:         int,
    min, max, step: int,
}

// A sidebar entry. The host registers one with thor_settings_begin_category
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

Settings_State :: struct {
    categories:          [dynamic]Settings_Category,
    current_category:    string, // owned; cursor set by begin_category, stamped onto new rows
    current_group:       string, // owned; cursor set by begin_group, "" outside one
    // Fold state per group id (keys owned). It outlives thor_settings_clear, so
    // a repopulate after a change keeps the groups the user folded folded.
    collapsed:           map[string]bool,
    selected_category:   int,
    scope:               Settings_Scope,
    // False hides the row list and shows a "create workspace settings" prompt
    // instead, set by the host from thor.workspace_initialized.
    workspace_available: bool,
    rows:                [dynamic]Settings_Row,
    // Indices into `rows` currently shown: the selected category, or every match
    // when `search` is non-empty. Recomputed once per frame.
    visible_rows:        [dynamic]int,
    search:              [dynamic]u8, // owned; ui.input edits it in place
    // Row waiting for a chord (-1 = none), an absolute index into `rows`. While
    // set, the host suppresses its global shortcuts so the press lands here.
    capturing:           int,
    // Id of that row; owned, "" when not capturing. The chord commits against
    // this, never the index: a repopulate rebuilds every row, so the index can
    // come to name another action.
    capturing_id:        string,
    // Pane key the focus goes back to when the modal closes.
    return_focus:        string,
    // Set by an open, consumed by the view: the search box takes the keyboard on
    // the frame it first appears.
    focus_pending:       bool,
}

thor_settings_init :: proc(thor: ^Thor) {
    s := &thor.settings
    s.categories = make([dynamic]Settings_Category)
    s.rows = make([dynamic]Settings_Row)
    s.visible_rows = make([dynamic]int)
    s.search = make([dynamic]u8)
    s.collapsed = make(map[string]bool)
    s.capturing = -1
}

thor_settings_destroy :: proc(thor: ^Thor) {
    s := &thor.settings
    thor_settings_clear(s)
    delete(s.categories)
    delete(s.rows)
    delete(s.visible_rows)
    delete(s.search)
    for key in s.collapsed {
        delete(key)
    }
    delete(s.collapsed)
    delete(s.capturing_id)
}

thor_settings_scope :: proc(s: ^Settings_State) -> Settings_Scope {
    return s.scope
}

thor_settings_set_workspace_available :: proc(s: ^Settings_State, available: bool) {
    s.workspace_available = available
}

// Drops every row and category, keeping scope and capture so a live repopulate
// (after a change persists and reloads) does not reset the view. The capture
// keeps its id only: thor_settings_add_keybind re-points the index when the row
// comes back.
thor_settings_clear :: proc(s: ^Settings_State) {
    s.capturing = -1
    for row in s.rows {
        delete(row.id)
        delete(row.label)
        delete(row.value)
        delete(row.category)
        delete(row.group)
    }
    clear(&s.rows)
    for cat in s.categories {
        delete(cat.id)
        delete(cat.label)
        delete(cat.icon)
    }
    clear(&s.categories)
    delete(s.current_category)
    s.current_category = ""
    delete(s.current_group)
    s.current_group = ""
    clear(&s.visible_rows)
}

// Registers a sidebar entry and points every row added after it at this
// category, until the next call. It also ends an open group: a group never spans
// two categories.
thor_settings_begin_category :: proc(s: ^Settings_State, id, label, icon: string) {
    append(
        &s.categories,
        Settings_Category {
            id = strings.clone(id),
            label = strings.clone(label),
            icon = strings.clone(icon),
        },
    )
    delete(s.current_category)
    s.current_category = strings.clone(id)
    thor_settings_end_group(s)
}

// Adds a foldable header and puts every row added after it inside the group,
// until thor_settings_end_group. `collapsed` is the state the group starts in;
// once the user folds it, that answer wins over the default. `value` is a
// summary at the header's right edge, so a folded group still says what is in it.
thor_settings_begin_group :: proc(
    s: ^Settings_State,
    id, label: string,
    collapsed := false,
    value := "",
    tone := Settings_Tone.Normal,
) {
    if id not_in s.collapsed {
        s.collapsed[strings.clone(id)] = collapsed
    }
    append(
        &s.rows,
        Settings_Row {
            kind = .Group,
            id = strings.clone(id),
            label = strings.clone(label),
            value = strings.clone(value),
            category = strings.clone(s.current_category),
            group = strings.clone(""),
            tone = tone,
        },
    )
    delete(s.current_group)
    s.current_group = strings.clone(id)
}

thor_settings_end_group :: proc(s: ^Settings_State) {
    delete(s.current_group)
    s.current_group = ""
}

thor_settings_add_number :: proc(s: ^Settings_State, id, label: string, value, min, max, step: int) {
    buf: [32]u8
    append(
        &s.rows,
        Settings_Row {
            kind = .Number,
            id = strings.clone(id),
            label = strings.clone(label),
            value = strings.clone(strconv.write_int(buf[:], cast(i64)value, 10)),
            category = strings.clone(s.current_category),
            group = strings.clone(s.current_group),
            number = value,
            min = min,
            max = max,
            step = step,
        },
    )
}

thor_settings_add_choice :: proc(s: ^Settings_State, id, label, value: string) {
    append(
        &s.rows,
        Settings_Row {
            kind = .Choice,
            id = strings.clone(id),
            label = strings.clone(label),
            value = strings.clone(value),
            category = strings.clone(s.current_category),
            group = strings.clone(s.current_group),
        },
    )
}

// A read-only row: a label and what it is. Nothing clicks it and the keyboard
// steps over it, so it never reads as a control that does nothing.
thor_settings_add_info :: proc(
    s: ^Settings_State,
    id, label, value: string,
    tone := Settings_Tone.Normal,
) {
    append(
        &s.rows,
        Settings_Row {
            kind = .Info,
            id = strings.clone(id),
            label = strings.clone(label),
            value = strings.clone(value),
            category = strings.clone(s.current_category),
            group = strings.clone(s.current_group),
            tone = tone,
        },
    )
}

// A row with one button at its right edge. `button` is the text on it.
thor_settings_add_action :: proc(
    s: ^Settings_State,
    id, label, button: string,
    tone := Settings_Tone.Normal,
) {
    append(
        &s.rows,
        Settings_Row {
            kind = .Action,
            id = strings.clone(id),
            label = strings.clone(label),
            value = strings.clone(button),
            category = strings.clone(s.current_category),
            group = strings.clone(s.current_group),
            tone = tone,
        },
    )
}

// `chord` is the display string ("Ctrl+K"), or "" for an unbound action.
thor_settings_add_keybind :: proc(s: ^Settings_State, id, label, chord: string) {
    append(
        &s.rows,
        Settings_Row {
            kind = .Keybind,
            id = strings.clone(id),
            label = strings.clone(label),
            value = strings.clone(chord),
            category = strings.clone(s.current_category),
            group = strings.clone(s.current_group),
        },
    )
    // The row a repopulate dropped mid-capture: point the capture back at it.
    if s.capturing < 0 && s.capturing_id != "" && s.capturing_id == id {
        s.capturing = len(s.rows) - 1
    }
}

thor_settings_open :: proc(thor: ^Thor) {
    s := &thor.settings
    settings_end_capture(s)
    s.scope = .General
    s.selected_category = 0
    clear(&s.search)
    s.focus_pending = true
    if !thor.settings_open {
        s.return_focus = thor.focus_owner
    }
    thor.settings_open = true
}

// Opens on a named category instead of the first one, for a command that goes
// straight to one page. An id no category answers to opens the first, so a
// renamed category is never a dead command.
thor_settings_open_at :: proc(thor: ^Thor, category: string) {
    thor_settings_open(thor)
    for entry, index in thor.settings.categories {
        if entry.id == category {
            thor.settings.selected_category = index
            return
        }
    }
}

thor_settings_is_open :: proc(thor: ^Thor) -> bool {
    return thor.settings_open
}

// True while a keybinding row waits for a chord; the host checks this to step
// aside so the next press reaches the modal instead of firing a shortcut.
thor_settings_is_capturing :: proc(thor: ^Thor) -> bool {
    return thor.settings_open && thor.settings.capturing >= 0
}

@(private = "file")
settings_close :: proc(thor: ^Thor) {
    thor.settings_open = false
    settings_end_capture(&thor.settings)
    if thor.settings.return_focus != "" {
        thor.focus_request = thor.settings.return_focus
    }
}

// Waits for a chord on the row at `index`, keeping its id as the commit target.
@(private = "file")
settings_begin_capture :: proc(s: ^Settings_State, index: int) {
    delete(s.capturing_id)
    s.capturing_id = strings.clone(s.rows[index].id)
    s.capturing = index
}

@(private = "file")
settings_end_capture :: proc(s: ^Settings_State) {
    delete(s.capturing_id)
    s.capturing_id = ""
    s.capturing = -1
}

// Switches scope, resetting the category and search state that no longer
// applies, then lets the host rebuild rows for the new scope.
@(private = "file")
settings_switch_scope :: proc(thor: ^Thor, scope: Settings_Scope) {
    s := &thor.settings
    if s.scope == scope {
        return
    }
    s.scope = scope
    s.selected_category = 0
    clear(&s.search)
    thor_populate_settings_view(thor)
}

@(private = "file")
settings_group_collapsed :: proc(s: ^Settings_State, id: string) -> bool {
    return s.collapsed[id] or_else false
}

@(private = "file")
settings_toggle_group :: proc(s: ^Settings_State, id: string) {
    if id not_in s.collapsed {
        return
    }
    s.collapsed[id] = !s.collapsed[id]
}

// The rows the list shows: the selected category with its folded groups hidden,
// or every label match when the search box is not empty.
@(private = "file")
settings_recompute_visible :: proc(s: ^Settings_State) {
    clear(&s.visible_rows)
    if len(s.search) == 0 {
        if s.selected_category < 0 || s.selected_category >= len(s.categories) {
            return
        }
        cat_id := s.categories[s.selected_category].id
        for row, i in s.rows {
            if row.category != cat_id {
                continue
            }
            if row.group != "" && settings_group_collapsed(s, row.group) {
                continue
            }
            append(&s.visible_rows, i)
        }
        return
    }
    query := strings.to_lower(string(s.search[:]), context.temp_allocator)
    for row, i in s.rows {
        if row.kind == .Group {
            continue
        }
        label := strings.to_lower(row.label, context.temp_allocator)
        if strings.contains(label, query) {
            append(&s.visible_rows, i)
        }
    }
}

@(private = "file")
settings_tone_color :: proc(thor: ^Thor, tone: Settings_Tone) -> ui.Color {
    switch tone {
    case .Good:
        return thor.theme.success_color
    case .Warn:
        return thor.theme.warning_color
    case .Bad:
        return thor.theme.danger_color
    case .Normal:
    }
    return thor.theme.muted_color
}

// ---- the view ---------------------------------------------------------------------

thor_settings_view :: proc(thor: ^Thor) {
    if !thor.settings_open {
        return
    }
    s := &thor.settings
    settings_recompute_visible(s)

    backdrop := ui.scope(
        {
            key = "settings-backdrop",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                justify = .Center,
                align = .Center,
                z = 420,
                bg = ui.Color{0, 0, 0, 140},
            },
        },
    )

    settings_box(thor)

    // A press anywhere else cancels a capture first, and only then dismisses.
    if backdrop.clicked {
        if s.capturing >= 0 {
            settings_end_capture(s)
        } else {
            settings_close(thor)
        }
        return
    }
    if s.capturing >= 0 {
        settings_capture_key(thor)
        return
    }
    if ui.take_key(.Escape) {
        settings_close(thor)
    }
}

// Commits or cancels a chord capture. A modifier alone is ignored so the modal
// waits for the real key; Escape cancels without changing the binding.
@(private = "file")
settings_capture_key :: proc(thor: ^Thor) {
    s := &thor.settings
    for &event in ui.keys() {
        if event.consumed || event.action == .Release || event.key == .None {
            continue
        }
        #partial switch event.key {
        case .Left_Ctrl, .Right_Ctrl, .Left_Shift, .Right_Shift, .Left_Alt, .Right_Alt,
             .Left_Super, .Right_Super:
            continue
        }
        event.consumed = true
        if event.key == .Escape {
            settings_end_capture(s)
            return
        }
        // The handler repopulates the rows, so the capture ends first and the id
        // outlives the row it came from.
        id := strings.clone(s.capturing_id, context.temp_allocator)
        settings_end_capture(s)
        if id != "" {
            thor_on_setting_keybind(thor, id, event.key, event.mods)
        }
        return
    }
}

@(private = "file")
settings_box :: proc(thor: ^Thor) {
    ui.scope(
        {
            key = "settings-box",
            flags = {.Clickable},
            props = {
                w = ui.Px(SETTINGS_WIDTH),
                max_w = ui.viewport().x - 80,
                h = ui.Px(SETTINGS_HEIGHT),
                max_h = ui.viewport().y - 80,
                dir = .Column,
                bg = thor.theme.background,
                radius = ui.rad(10),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 8}, blur = 32, color = thor.theme.contrast},
            },
        },
    )

    settings_header(thor)

    body := ui.scope(
        {
            key = "body",
            props = {w = ui.Grow(1), h = ui.Grow(1), dir = .Row},
        },
    )
    _ = body

    settings_sidebar(thor)
    settings_content(thor)
}

@(private = "file")
settings_header :: proc(thor: ^Thor) {
    s := &thor.settings

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

    ui.label(
        "Settings",
        {key = "title", props = {color = thor.theme.foreground, text_wrap = .None}},
    )

    settings_scope_tab(thor, .General, "General")
    settings_scope_tab(thor, .Workspace, "Workspace")

    it := ui.input(
        &s.search,
        {
            key = "search",
            props = {
                w = ui.Grow(1),
                bg = thor.theme.background,
                color = thor.theme.foreground,
                radius = ui.rad(6),
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
        "Search settings",
    )
    if s.focus_pending {
        ui.set_focus(it.id)
        s.focus_pending = false
    }

    close := ui.scope(
        {
            key = "close",
            flags = {.Clickable},
            props = {
                w = ui.Px(26),
                h = ui.Px(26),
                dir = .Row,
                justify = .Center,
                align = .Center,
                radius = ui.rad(4),
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.buttons},
        },
    )
    thor_icon_label(thor, "x", thor.theme.muted_color)
    if close.clicked {
        settings_close(thor)
    }
}

@(private = "file")
settings_scope_tab :: proc(thor: ^Thor, scope: Settings_Scope, label: string) {
    s := &thor.settings
    on := s.scope == scope

    it := ui.scope(
        {
            key = label,
            flags = {.Clickable},
            props = {
                h = ui.Px(24),
                dir = .Row,
                align = .Center,
                pad = ui.xy(12, 0),
                radius = ui.rad(12),
                bg = on ? thor.theme.accent_color : thor.theme.buttons,
                cursor = .Pointer,
            },
        },
    )
    ui.label(
        label,
        {
            key = "text",
            props = {
                color = on ? thor.theme.background : thor.theme.muted_color,
                text_wrap = .None,
            },
        },
    )
    if it.clicked {
        settings_switch_scope(thor, scope)
    }
}

@(private = "file")
settings_sidebar :: proc(thor: ^Thor) {
    s := &thor.settings

    ui.scope(
        {
            key = "sidebar",
            flags = {.Clip, .Scroll_Y},
            props = {
                w = ui.Px(SETTINGS_SIDEBAR_W),
                h = ui.Grow(1),
                dir = .Column,
                pad = {l = 8, r = 8, t = 10, b = 8},
                gap = {0, 2},
                bg = thor.theme.second_background,
            },
        },
    )

    for entry, index in s.categories {
        ui.push_id_int(i64(index))
        on := index == s.selected_category && len(s.search) == 0

        it := ui.scope(
            {
                key = "cat",
                flags = {.Clickable},
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(SETTINGS_CATEGORY_H),
                    dir = .Row,
                    align = .Center,
                    gap = {8, 0},
                    pad = ui.xy(8, 0),
                    radius = ui.rad(6),
                    bg = on ? thor.theme.selection_background : nil,
                    cursor = .Pointer,
                },
                hover = {bg = on ? thor.theme.selection_background : thor.theme.buttons},
            },
        )
        thor_icon_label(thor, entry.icon, on ? thor.theme.foreground : thor.theme.muted_color)
        ui.label(
            entry.label,
            {
                key = "label",
                props = {
                    w = ui.Grow(1),
                    color = on ? thor.theme.foreground : thor.theme.muted_color,
                    text_wrap = .Ellipsis,
                },
            },
        )
        ui.pop_id()

        if it.clicked && (index != s.selected_category || len(s.search) > 0) {
            s.selected_category = index
            clear(&s.search)
        }
    }
}

@(private = "file")
settings_content :: proc(thor: ^Thor) {
    s := &thor.settings

    ui.scope(
        {
            key = "content",
            flags = {.Clip, .Scroll_Y},
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                pad = ui.xy(14, 10),
                gap = {0, 2},
            },
        },
    )

    if s.scope == .Workspace && !s.workspace_available {
        settings_workspace_prompt(thor)
        return
    }
    if len(s.visible_rows) == 0 {
        ui.label(
            "Nothing here",
            {key = "empty", props = {pad = ui.xy(4, 8), color = thor.theme.disabled}},
        )
        return
    }

    for row_index, position in s.visible_rows {
        ui.push_id_int(i64(position))
        settings_row(thor, row_index)
        ui.pop_id()
    }
}

// The Workspace tab with no .thor/ folder yet: one button that makes it.
@(private = "file")
settings_workspace_prompt :: proc(thor: ^Thor) {
    ui.label(
        "This folder has no workspace settings yet.",
        {key = "msg", props = {pad = ui.xy(4, 10), color = thor.theme.foreground}},
    )
    ui.label(
        "Workspace settings live in .thor/ and override the general ones.",
        {key = "hint", props = {pad = ui.xy(4, 2), color = thor.theme.muted_color}},
    )
    if settings_button(thor, "cta", "Create Workspace Settings", thor.theme.accent_color) {
        thor_cmd_init_workspace(thor)
    }
}

@(private = "file")
settings_row :: proc(thor: ^Thor, row_index: int) {
    s := &thor.settings
    row := &s.rows[row_index]

    if row.kind == .Group {
        settings_group_row(thor, row)
        return
    }

    indent := row.group != "" && len(s.search) == 0 ? f32(20) : f32(0)

    ui.scope(
        {
            key = "row",
            props = {
                w = ui.Grow(1),
                h = ui.Px(SETTINGS_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {12, 0},
                pad = {l = 8 + indent, r = 8},
                radius = ui.rad(6),
            },
            hover = {bg = thor.theme.second_background},
        },
    )

    ui.label(
        row.label,
        {
            key = "label",
            props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis},
        },
    )

    switch row.kind {
    case .Number:
        settings_number_control(thor, row)
    case .Choice:
        settings_choice_control(thor, row)
    case .Keybind:
        settings_keybind_control(thor, row, row_index)
    case .Action:
        if settings_button(thor, "act", row.value, settings_tone_color(thor, row.tone)) {
            thor_on_setting_action(thor, row.id)
        }
    case .Info:
        ui.label(
            row.value,
            {
                key = "value",
                props = {color = settings_tone_color(thor, row.tone), text_wrap = .Ellipsis},
            },
        )
    case .Group:
    }
}

@(private = "file")
settings_group_row :: proc(thor: ^Thor, row: ^Settings_Row) {
    s := &thor.settings
    open := !settings_group_collapsed(s, row.id)

    it := ui.scope(
        {
            key = "group",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(SETTINGS_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {8, 0},
                pad = ui.xy(6, 0),
                margin = {t = 6},
                radius = ui.rad(6),
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.second_background},
        },
    )
    thor_icon_label(thor, open ? "chevron-down" : "chevron-right", thor.theme.muted_color)
    ui.label(
        row.label,
        {
            key = "label",
            props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis},
        },
    )
    if row.value != "" {
        ui.label(
            row.value,
            {
                key = "summary",
                props = {color = settings_tone_color(thor, row.tone), text_wrap = .None},
            },
        )
    }
    if it.clicked {
        settings_toggle_group(s, row.id)
    }
}

@(private = "file")
settings_number_control :: proc(thor: ^Thor, row: ^Settings_Row) {
    step := 0
    if settings_step_button(thor, "dec", "minus", row.number > row.min) {
        step = -row.step
    }
    ui.label(
        row.value,
        {
            key = "value",
            props = {
                w = ui.Px(56),
                text_align = .Center,
                color = thor.theme.foreground,
                text_wrap = .None,
            },
        },
    )
    if settings_step_button(thor, "inc", "plus", row.number < row.max) {
        step = row.step
    }
    if step != 0 {
        thor_on_setting_number(thor, row.id, clamp(row.number + step, row.min, row.max))
    }
}

@(private = "file")
settings_step_button :: proc(thor: ^Thor, key, icon: string, enabled: bool) -> bool {
    it := ui.scope(
        {
            key = key,
            flags = enabled ? {.Clickable} : {},
            props = {
                w = ui.Px(24),
                h = ui.Px(24),
                dir = .Row,
                justify = .Center,
                align = .Center,
                radius = ui.rad(4),
                bg = thor.theme.buttons,
                cursor = enabled ? .Pointer : .Not_Allowed,
            },
            hover = {bg = enabled ? thor.theme.active : nil},
        },
    )
    thor_icon_label(thor, icon, enabled ? thor.theme.foreground : thor.theme.disabled, 14)
    return enabled && it.clicked
}

@(private = "file")
settings_choice_control :: proc(thor: ^Thor, row: ^Settings_Row) {
    it := ui.scope(
        {
            key = "choice",
            flags = {.Clickable},
            props = {
                h = ui.Px(26),
                dir = .Row,
                align = .Center,
                gap = {8, 0},
                pad = ui.xy(10, 0),
                radius = ui.rad(6),
                bg = thor.theme.buttons,
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.active},
        },
    )
    ui.label(
        row.value,
        {key = "value", props = {color = thor.theme.foreground, text_wrap = .None}},
    )
    thor_icon_label(thor, "chevron-down", thor.theme.muted_color, 14)
    if it.clicked {
        thor_on_setting_choice(thor, row.id)
    }
}

@(private = "file")
settings_keybind_control :: proc(thor: ^Thor, row: ^Settings_Row, row_index: int) {
    s := &thor.settings
    capturing := s.capturing == row_index
    bound := row.value != ""

    it := ui.scope(
        {
            key = "chord",
            flags = {.Clickable},
            props = {
                h = ui.Px(26),
                min_w = 120,
                dir = .Row,
                justify = .Center,
                align = .Center,
                pad = ui.xy(10, 0),
                radius = ui.rad(6),
                bg = capturing ? thor.theme.selection_background : thor.theme.buttons,
                border = {
                    width = ui.all(1),
                    color = capturing ? thor.theme.accent_color : thor.theme.border,
                },
                cursor = .Pointer,
            },
            hover = {bg = capturing ? thor.theme.selection_background : thor.theme.active},
        },
    )
    text := capturing ? "Press shortcut..." : (bound ? row.value : "Unbound")
    ui.label(
        text,
        {
            key = "text",
            props = {
                color = capturing \
                ? thor.theme.accent_color \
                : (bound ? thor.theme.foreground : thor.theme.disabled),
                text_wrap = .None,
            },
        },
    )
    if it.clicked && !capturing {
        settings_begin_capture(s, row_index)
    }

    // Clearing a binding is the same commit with no key.
    if bound && !capturing {
        if settings_step_button(thor, "clear", "x", true) {
            thor_on_setting_keybind(thor, row.id, .None, {})
        }
    }
}

@(private = "file")
settings_button :: proc(thor: ^Thor, key, label: string, color: ui.Color) -> bool {
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {
                h = ui.Px(26),
                dir = .Row,
                align = .Center,
                pad = ui.xy(12, 0),
                margin = {t = 8},
                radius = ui.rad(6),
                bg = thor.theme.buttons,
                border = {width = ui.all(1), color = color},
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.active},
        },
    )
    ui.label(label, {key = "text", props = {color = color, text_wrap = .None}})
    return it.clicked
}
