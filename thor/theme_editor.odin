// The Theme window, opened by the "Theme Colors" row of the Settings modal: one
// row per color role of the active palette under a foldable group, each opening
// the color picker, plus the rows that generate a whole palette from two seeds.
// It carries no theme knowledge — `thor/theme_ui.odin` fills the rows and answers
// a click.
package thor

import "core:strings"

import ui "../vendor/loom/loom"

THEME_EDITOR_WIDTH :: f32(560)
THEME_EDITOR_HEIGHT :: f32(560)
THEME_EDITOR_ROW_H :: f32(36)

Theme_Row_Kind :: enum {
    Group,  // chevron + label; clicking folds or unfolds the rows under it
    Color,  // label + hex + swatch; clicking opens the color picker
    Action, // label + value; clicking asks the host to act
}

Theme_Row :: struct {
    kind:  Theme_Row_Kind,
    id:    string, // owned; the color key, the action name, or the group id
    label: string, // owned
    value: string, // owned; the display hex, or an action's value text
    group: string, // owned; id of the Group row holding it, "" outside one
    color: ui.Color,
}

Theme_Editor :: struct {
    title:         string, // owned; the theme's display name
    rows:          [dynamic]Theme_Row,
    // Indices into `rows` currently shown: a folded group hides its rows.
    visible_rows:  [dynamic]int,
    current_group: string, // owned; cursor set by begin_group, "" outside one
    // Fold state per group id (keys owned). It outlives thor_theme_editor_clear,
    // so a repopulate after a change keeps the groups the user folded folded.
    collapsed:     map[string]bool,
    // Pane key the focus goes back to when the window closes.
    return_focus:  string,
}

thor_theme_editor_init :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    e.rows = make([dynamic]Theme_Row)
    e.visible_rows = make([dynamic]int)
    e.collapsed = make(map[string]bool)
}

thor_theme_editor_destroy :: proc(thor: ^Thor) {
    e := &thor.theme_editor
    thor_theme_editor_clear(e)
    delete(e.rows)
    delete(e.visible_rows)
    for key in e.collapsed {
        delete(key)
    }
    delete(e.collapsed)
    delete(e.title)
}

// Drops every row, keeping the fold state so a live repopulate (after a color is
// committed) does not move the list under the cursor.
thor_theme_editor_clear :: proc(e: ^Theme_Editor) {
    for row in e.rows {
        delete(row.id)
        delete(row.label)
        delete(row.value)
        delete(row.group)
    }
    clear(&e.rows)
    clear(&e.visible_rows)
    delete(e.current_group)
    e.current_group = ""
}

// Names the theme the rows came from; drawn in the header.
thor_theme_editor_set_title :: proc(e: ^Theme_Editor, title: string) {
    heading := strings.clone(title)
    delete(e.title)
    e.title = heading
}

thor_theme_editor_begin_group :: proc(e: ^Theme_Editor, id, label: string, collapsed := false) {
    if id not_in e.collapsed {
        e.collapsed[strings.clone(id)] = collapsed
    }
    append(
        &e.rows,
        Theme_Row {
            kind = .Group,
            id = strings.clone(id),
            label = strings.clone(label),
            value = strings.clone(""),
            group = strings.clone(""),
        },
    )
    delete(e.current_group)
    e.current_group = strings.clone(id)
}

thor_theme_editor_end_group :: proc(e: ^Theme_Editor) {
    delete(e.current_group)
    e.current_group = ""
}

// `hex` is the display text; the host formats it, so no color-format knowledge
// lives here.
thor_theme_editor_add_color :: proc(e: ^Theme_Editor, key, label, hex: string, color: ui.Color) {
    append(
        &e.rows,
        Theme_Row {
            kind = .Color,
            id = strings.clone(key),
            label = strings.clone(label),
            value = strings.clone(hex),
            group = strings.clone(e.current_group),
            color = color,
        },
    )
}

thor_theme_editor_add_action :: proc(e: ^Theme_Editor, action, label, value: string) {
    append(
        &e.rows,
        Theme_Row {
            kind = .Action,
            id = strings.clone(action),
            label = strings.clone(label),
            value = strings.clone(value),
            group = strings.clone(e.current_group),
        },
    )
}

thor_theme_editor_open :: proc(thor: ^Thor) {
    if !thor.theme_editor_open {
        thor.theme_editor.return_focus = thor.focus_owner
    }
    thor.theme_editor_open = true
}

thor_theme_editor_is_open :: proc(thor: ^Thor) -> bool {
    return thor.theme_editor_open
}

@(private = "file")
theme_editor_close :: proc(thor: ^Thor) {
    thor.theme_editor_open = false
    if thor.theme_editor.return_focus != "" {
        thor.focus_request = thor.theme_editor.return_focus
    }
}

@(private = "file")
theme_editor_group_collapsed :: proc(e: ^Theme_Editor, id: string) -> bool {
    return e.collapsed[id] or_else false
}

@(private = "file")
theme_editor_toggle_group :: proc(e: ^Theme_Editor, id: string) {
    if id not_in e.collapsed {
        return
    }
    e.collapsed[id] = !e.collapsed[id]
}

@(private = "file")
theme_editor_recompute_visible :: proc(e: ^Theme_Editor) {
    clear(&e.visible_rows)
    for row, i in e.rows {
        if row.kind != .Group && row.group != "" && theme_editor_group_collapsed(e, row.group) {
            continue
        }
        append(&e.visible_rows, i)
    }
}

// ---- the view ---------------------------------------------------------------------

thor_theme_editor_view :: proc(thor: ^Thor) {
    if !thor.theme_editor_open {
        return
    }
    e := &thor.theme_editor
    theme_editor_recompute_visible(e)

    backdrop := ui.scope(
        {
            key = "theme-backdrop",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                justify = .Center,
                align = .Center,
                z = 440,
                bg = ui.Color{0, 0, 0, 140},
            },
        },
    )

    theme_editor_box(thor)

    // The picker sits over this window, so it takes the click and the key first.
    if thor.color_picker_open {
        return
    }
    if backdrop.clicked || ui.take_key(.Escape) {
        theme_editor_close(thor)
    }
}

@(private = "file")
theme_editor_box :: proc(thor: ^Thor) {
    e := &thor.theme_editor

    ui.scope(
        {
            key = "theme-box",
            flags = {.Clickable},
            props = {
                w = ui.Px(THEME_EDITOR_WIDTH),
                max_w = ui.viewport().x - 60,
                h = ui.Px(THEME_EDITOR_HEIGHT),
                max_h = ui.viewport().y - 60,
                dir = .Column,
                bg = thor.theme.background,
                radius = ui.rad(10),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 8}, blur = 32, color = thor.theme.contrast},
            },
        },
    )

    theme_editor_header(thor)

    {
        ui.scope(
            {
                key = "list",
                flags = {.Clip, .Scroll_Y},
                props = {
                    w = ui.Grow(1),
                    h = ui.Grow(1),
                    dir = .Column,
                    pad = ui.xy(10, 8),
                    gap = {0, 2},
                },
            },
        )
        for row_index, position in e.visible_rows {
            ui.push_id_int(i64(position))
            theme_editor_row(thor, &e.rows[row_index])
            ui.pop_id()
        }
    }
}

@(private = "file")
theme_editor_header :: proc(thor: ^Thor) {
    e := &thor.theme_editor

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
        "Theme Colors",
        {key = "title", props = {color = thor.theme.foreground, text_wrap = .None}},
    )
    ui.label(
        e.title,
        {key = "name", props = {w = ui.Grow(1), color = thor.theme.muted_color, text_wrap = .Ellipsis}},
    )

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
        theme_editor_close(thor)
    }
}

@(private = "file")
theme_editor_row :: proc(thor: ^Thor, row: ^Theme_Row) {
    e := &thor.theme_editor

    if row.kind == .Group {
        open := !theme_editor_group_collapsed(e, row.id)
        it := ui.scope(
            {
                key = "group",
                flags = {.Clickable},
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(THEME_EDITOR_ROW_H),
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
            {key = "label", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis}},
        )
        if it.clicked {
            theme_editor_toggle_group(e, row.id)
        }
        return
    }

    indent := row.group != "" ? f32(20) : f32(0)
    it := ui.scope(
        {
            key = "row",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(THEME_EDITOR_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {10, 0},
                pad = {l = 8 + indent, r = 10},
                radius = ui.rad(6),
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.second_background},
        },
    )
    ui.label(
        row.label,
        {key = "label", props = {w = ui.Grow(1), color = thor.theme.foreground, text_wrap = .Ellipsis}},
    )
    ui.label(
        row.value,
        {key = "value", props = {color = thor.theme.muted_color, text_wrap = .None}},
    )
    if row.kind == .Color {
        ui.leaf(
            {
                key = "swatch",
                props = {
                    w = ui.Px(34),
                    h = ui.Px(18),
                    radius = ui.rad(4),
                    bg = row.color,
                    border = {width = ui.all(1), color = thor.theme.border},
                },
            },
        )
    }

    if it.clicked {
        if row.kind == .Color {
            thor_on_theme_editor_color(thor, row.id)
        } else {
            thor_on_theme_editor_action(thor, row.id)
        }
    }
}
