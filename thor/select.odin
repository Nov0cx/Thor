// The select dialog: a centered modal that picks one string from a list (theme,
// font, an enum setting). The selection previews live as it moves; Escape or a
// click outside reverts to the option that was active when it opened.
package thor

import "core:strings"

import ui "../vendor/loom/loom"

// Fired with the option under the cursor. `preview` applies a choice live as the
// selection moves; `commit` applies and persists it on confirm.
Select_Choice_Proc :: #type proc(data: rawptr, choice: string)

SELECT_WIDTH :: f32(420)
SELECT_ROW_H :: f32(30)
SELECT_MAX_ROWS :: 12

Select_Dialog :: struct {
    title:        string, // owned
    // Row labels shown in the list, and the value handed to the callbacks for
    // each row. They differ when the display name is not the persisted id (a
    // theme's name against its file base); values == options otherwise.
    options:      [dynamic]string, // owned
    values:       [dynamic]string, // owned, parallel to options
    selected:     int,
    scroll:       int,
    // Option active when the dialog opened; re-previewed on cancel.
    original:     int,
    preview:      Select_Choice_Proc,
    commit:       Select_Choice_Proc,
    data:         rawptr,
    // Pane key the focus goes back to when the dialog closes.
    return_focus: string,
}

thor_select_init :: proc(thor: ^Thor) {
    thor.select.options = make([dynamic]string)
    thor.select.values = make([dynamic]string)
}

thor_select_destroy :: proc(thor: ^Thor) {
    s := &thor.select
    select_clear(s)
    delete(s.options)
    delete(s.values)
    delete(s.title)
}

// Opens the picker over `labels`. `values` is what the callbacks get for each
// label (the labels themselves by default); `current` is matched against it to
// pick the starting row. The title and the items are copied, so a caller can
// pass temporary strings.
thor_select_open :: proc(
    thor: ^Thor,
    title: string,
    labels: []string,
    current: string,
    preview, commit: Select_Choice_Proc,
    data: rawptr,
    values: []string = nil,
) {
    s := &thor.select
    select_clear(s)
    for item, i in labels {
        append(&s.options, strings.clone(item))
        value := (values != nil && i < len(values)) ? values[i] : item
        append(&s.values, strings.clone(value))
    }

    // Cloned before the old one is freed: the caller can pass s.title back.
    heading := strings.clone(title)
    delete(s.title)
    s.title = heading

    s.preview = preview
    s.commit = commit
    s.data = data
    s.selected = 0
    for value, i in s.values {
        if value == current {
            s.selected = i
            break
        }
    }
    s.original = s.selected
    s.scroll = 0
    select_scroll_into_view(s)

    // A second open while already up must not clobber the real target.
    if !thor.select_open {
        s.return_focus = thor.focus_owner
    }
    thor.select_open = true
}

thor_select_is_open :: proc(thor: ^Thor) -> bool {
    return thor.select_open
}

@(private = "file")
select_clear :: proc(s: ^Select_Dialog) {
    for item in s.options {
        delete(item)
    }
    for item in s.values {
        delete(item)
    }
    clear(&s.options)
    clear(&s.values)
}

@(private = "file")
select_close :: proc(thor: ^Thor) {
    thor.select_open = false
    if thor.select.return_focus != "" {
        thor.focus_request = thor.select.return_focus
    }
}

// Cancels: restores the option active at open, then closes.
@(private = "file")
select_cancel :: proc(thor: ^Thor) {
    s := &thor.select
    if s.original != s.selected &&
       s.preview != nil &&
       s.original >= 0 &&
       s.original < len(s.values) {
        s.preview(s.data, s.values[s.original])
    }
    select_close(thor)
}

// Confirms the current selection: applies and persists it, then closes.
@(private = "file")
select_confirm :: proc(thor: ^Thor) {
    s := &thor.select
    if s.selected < 0 || s.selected >= len(s.values) {
        select_close(thor)
        return
    }
    choice := strings.clone(s.values[s.selected], context.temp_allocator)
    commit := s.commit
    data := s.data
    select_close(thor)
    if commit != nil {
        commit(data, choice)
    }
}

// Moves the selection by `delta`, keeps it on screen, and previews it live.
@(private = "file")
select_move :: proc(thor: ^Thor, delta: int) {
    s := &thor.select
    count := len(s.options)
    if count == 0 {
        return
    }
    next := clamp(s.selected + delta, 0, count - 1)
    if next == s.selected {
        return
    }
    s.selected = next
    select_scroll_into_view(s)
    if s.preview != nil {
        s.preview(s.data, s.values[s.selected])
    }
}

@(private = "file")
select_scroll_into_view :: proc(s: ^Select_Dialog) {
    if s.selected < s.scroll {
        s.scroll = s.selected
    } else if s.selected >= s.scroll + SELECT_MAX_ROWS {
        s.scroll = s.selected - SELECT_MAX_ROWS + 1
    }
}

// ---- the view ------------------------------------------------------------------

thor_select_view :: proc(thor: ^Thor) {
    if !thor.select_open {
        return
    }
    s := &thor.select

    {
        ui.scope(
            {
                key = "select-backdrop",
                flags = {.Floating, .Clickable},
                props = {
                    position = .Fixed,
                    inset = {0, 0, 0, 0},
                    w = ui.Grow(1),
                    h = ui.Grow(1),
                    dir = .Column,
                    justify = .Center,
                    align = .Center,
                    z = 450,
                    bg = ui.Color{0, 0, 0, 120},
                },
            },
        )
        select_box(thor)
    }

    if ui.take_key(.Escape) {
        select_cancel(thor)
        return
    }
    if ui.take_key(.Enter) || ui.take_key(.Pad_Enter) {
        select_confirm(thor)
        return
    }
    if ui.take_key(.Up) {
        select_move(thor, -1)
    }
    if ui.take_key(.Down) {
        select_move(thor, 1)
    }
    if ui.take_key(.Page_Up) {
        select_move(thor, -SELECT_MAX_ROWS)
    }
    if ui.take_key(.Page_Down) {
        select_move(thor, SELECT_MAX_ROWS)
    }
    if ui.take_key(.Home) {
        select_move(thor, -len(s.options))
    }
    if ui.take_key(.End) {
        select_move(thor, len(s.options))
    }
}

@(private = "file")
select_box :: proc(thor: ^Thor) {
    s := &thor.select

    ui.scope(
        {
            key = "select-box",
            flags = {.Clickable},
            props = {
                w = ui.Px(SELECT_WIDTH),
                max_w = ui.viewport().x - 80,
                h = ui.FIT,
                dir = .Column,
                pad = ui.all(6),
                bg = thor.theme.second_background,
                radius = ui.rad(8),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 6}, blur = 24, color = thor.theme.contrast},
            },
        },
    )

    ui.label(
        s.title,
        {
            key = "title",
            props = {pad = ui.xy(10, 10), color = thor.theme.foreground, text_wrap = .None},
        },
    )

    hovered := -1
    clicked := false
    {
        list := ui.scope(
            {
                key = "list",
                flags = {.Clickable},
                props = {w = ui.Grow(1), h = ui.FIT, dir = .Column},
            },
        )
        if list.wheel.y != 0 {
            select_move(thor, list.wheel.y > 0 ? 1 : -1)
        }

        s.scroll = clamp(s.scroll, 0, max(len(s.options) - SELECT_MAX_ROWS, 0))
        last := min(s.scroll + SELECT_MAX_ROWS, len(s.options))
        for i in s.scroll ..< last {
            ui.push_id_int(i64(i))
            it := select_row(thor, i)
            ui.pop_id()
            // Hovering a row previews it, so the whole list is browsable by mouse.
            if it.hovered {
                hovered = i
            }
            if it.clicked {
                clicked = true
            }
        }
    }

    if hovered >= 0 && hovered != s.selected {
        select_move(thor, hovered - s.selected)
    }
    if clicked {
        select_confirm(thor)
    }
}

@(private = "file")
select_row :: proc(thor: ^Thor, index: int) -> ui.Interaction {
    s := &thor.select
    on := index == s.selected

    it := ui.scope(
        {
            key = "row",
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(SELECT_ROW_H),
                dir = .Row,
                align = .Center,
                pad = ui.xy(10, 0),
                radius = ui.rad(4),
                bg = on ? thor.theme.selection_background : ui.Color{0, 0, 0, 0},
            },
            hover = {bg = thor.theme.buttons},
        },
    )
    ui.label(
        s.options[index],
        {
            key = "text",
            props = {
                w = ui.Grow(1),
                color = on ? thor.theme.foreground : thor.theme.muted_color,
                text_wrap = .Ellipsis,
            },
        },
    )
    return it
}
