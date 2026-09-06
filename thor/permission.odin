// The plugin permission prompt: one row per plugin waiting on an answer, and one
// Allow/Cancel pair for the whole batch. `thor/plugin_trust.odin` fills it and
// owns what an answer means.
package thor

import "core:strings"

import ui "../vendor/loom/loom"

Permission_Dialog_Proc :: #type proc(data: rawptr)

PERMISSION_WIDTH :: f32(520)
PERMISSION_ROW_H :: f32(46)
PERMISSION_MAX_ROWS :: 8

@(private = "file")
Permission_Item :: struct {
    id:    string, // owned
    perms: string, // owned
}

Permission_Dialog :: struct {
    title:        string, // owned
    note:         string, // owned; footer hint
    items:        [dynamic]Permission_Item, // owned
    on_allow:     Permission_Dialog_Proc,
    on_cancel:    Permission_Dialog_Proc,
    data:         rawptr,
    // Pane key the focus goes back to when the prompt closes.
    return_focus: string,
}

thor_permission_init :: proc(thor: ^Thor) {
    thor.permission.items = make([dynamic]Permission_Item)
}

thor_permission_destroy :: proc(thor: ^Thor) {
    d := &thor.permission
    permission_clear(d)
    delete(d.items)
    delete(d.title)
    delete(d.note)
}

thor_permission_open :: proc(
    thor: ^Thor,
    title, note: string,
    ids, perms: []string,
    on_allow, on_cancel: Permission_Dialog_Proc,
    data: rawptr,
) {
    d := &thor.permission
    permission_clear(d)

    for id, i in ids {
        append(
            &d.items,
            Permission_Item {
                id = strings.clone(id),
                perms = strings.clone(i < len(perms) ? perms[i] : ""),
            },
        )
    }
    heading := strings.clone(title)
    delete(d.title)
    d.title = heading
    hint := strings.clone(note)
    delete(d.note)
    d.note = hint

    d.on_allow = on_allow
    d.on_cancel = on_cancel
    d.data = data

    if !thor.permission_open {
        d.return_focus = thor.focus_owner
    }
    thor.permission_open = true
}

thor_permission_is_open :: proc(thor: ^Thor) -> bool {
    return thor.permission_open
}

@(private = "file")
permission_clear :: proc(d: ^Permission_Dialog) {
    for item in d.items {
        delete(item.id)
        delete(item.perms)
    }
    clear(&d.items)
}

// Closes and fires one of the two answers. The callback loads plugins, which
// rebuilds this list, so it runs after the state is settled.
@(private = "file")
permission_answer :: proc(thor: ^Thor, allow: bool) {
    d := &thor.permission
    run := allow ? d.on_allow : d.on_cancel
    data := d.data
    thor.permission_open = false
    if d.return_focus != "" {
        thor.focus_request = d.return_focus
    }
    if run != nil {
        run(data)
    }
}

// ---- the view ---------------------------------------------------------------------

thor_permission_view :: proc(thor: ^Thor) {
    if !thor.permission_open {
        return
    }

    ui.scope(
        {
            key = "perm-backdrop",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                justify = .Center,
                align = .Center,
                z = 480,
                bg = ui.Color{0, 0, 0, 150},
            },
        },
    )

    permission_box(thor)

    // No outside-click dismissal: an unanswered prompt must not read as a
    // decision. Escape is the explicit no.
    if ui.take_key(.Escape) {
        permission_answer(thor, false)
    }
}

@(private = "file")
permission_box :: proc(thor: ^Thor) {
    d := &thor.permission

    ui.scope(
        {
            key = "perm-box",
            flags = {.Clickable},
            props = {
                w = ui.Px(PERMISSION_WIDTH),
                max_w = ui.viewport().x - 60,
                h = ui.FIT,
                dir = .Column,
                gap = {0, 8},
                pad = ui.all(16),
                bg = thor.theme.second_background,
                radius = ui.rad(8),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 6}, blur = 24, color = thor.theme.contrast},
            },
        },
    )

    ui.label(
        d.title,
        {key = "title", props = {color = thor.theme.foreground, text_wrap = .Words}},
    )

    {
        ui.scope(
            {
                key = "rows",
                flags = {.Clip, .Scroll_Y},
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(min(f32(len(d.items)), PERMISSION_MAX_ROWS) * PERMISSION_ROW_H),
                    dir = .Column,
                    gap = {0, 4},
                },
            },
        )
        for item, index in d.items {
            ui.push_id_int(i64(index))
            permission_row(thor, item)
            ui.pop_id()
        }
    }

    ui.label(
        d.note,
        {key = "note", props = {color = thor.theme.disabled, text_wrap = .Words}},
    )

    {
        ui.scope(
            {
                key = "buttons",
                props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, justify = .End, gap = {8, 0}},
            },
        )
        if permission_button(thor, "cancel", "Cancel", thor.theme.muted_color) {
            permission_answer(thor, false)
            return
        }
        if permission_button(thor, "allow", "Allow", thor.theme.accent_color) {
            permission_answer(thor, true)
        }
    }
}

@(private = "file")
permission_row :: proc(thor: ^Thor, item: Permission_Item) {
    ui.scope(
        {
            key = "row",
            props = {
                w = ui.Grow(1),
                h = ui.Px(PERMISSION_ROW_H),
                dir = .Column,
                justify = .Center,
                pad = ui.xy(10, 0),
                radius = ui.rad(6),
                bg = thor.theme.background,
            },
        },
    )
    ui.label(
        item.id,
        {key = "id", props = {color = thor.theme.foreground, text_wrap = .Ellipsis}},
    )
    ui.label(
        item.perms,
        {key = "perms", props = {color = thor.theme.muted_color, text_wrap = .Ellipsis}},
    )
}

@(private = "file")
permission_button :: proc(thor: ^Thor, key, label: string, color: ui.Color) -> bool {
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {
                w = ui.Px(96),
                h = ui.Px(30),
                dir = .Row,
                justify = .Center,
                align = .Center,
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
