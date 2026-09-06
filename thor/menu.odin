// The popup menu shared by the titlebar dropdowns and every context menu. An
// opener fills the item list and names an anchor; `thor_menu_view` declares it
// until a pick, an outside click or Escape closes it.
package thor

import ui "../vendor/loom/loom"

MENU_MIN_W :: f32(180)
MENU_ROW_H :: f32(26)

// One row. `title` and `shortcut` are borrowed: every opener passes a literal,
// and the list is rebuilt on the next open.
Menu_Item :: struct {
    title:     string,
    shortcut:  string,
    run:       proc(data: rawptr),
    data:      rawptr,
    enabled:   bool,
    separator: bool,
}

Menu :: struct {
    items:  [dynamic]Menu_Item,
    anchor: ui.Vec2,
    // Pane key the focus goes back to when the menu closes.
    return_focus: string,
}

thor_menu_init :: proc(thor: ^Thor) {
    thor.menu.items = make([dynamic]Menu_Item)
}

thor_menu_destroy :: proc(thor: ^Thor) {
    delete(thor.menu.items)
}

thor_menu_clear :: proc(thor: ^Thor) {
    clear(&thor.menu.items)
}

thor_menu_add :: proc(
    thor: ^Thor,
    title: string,
    run: proc(data: rawptr),
    data: rawptr,
    enabled := true,
    shortcut := "",
) {
    append(
        &thor.menu.items,
        Menu_Item {
            title = title,
            shortcut = shortcut,
            run = run,
            data = data,
            enabled = enabled,
        },
    )
}

thor_menu_add_separator :: proc(thor: ^Thor) {
    append(&thor.menu.items, Menu_Item{separator = true})
}

// Shows the filled list with its top left corner at `position`.
thor_menu_open :: proc(thor: ^Thor, position: ui.Vec2) {
    if !thor.menu_open {
        thor.menu.return_focus = thor.focus_owner
    }
    thor.menu.anchor = position
    thor.menu_open = true
}

thor_menu_close :: proc(thor: ^Thor) {
    if !thor.menu_open {
        return
    }
    thor.menu_open = false
    if thor.menu.return_focus != "" {
        thor.focus_request = thor.menu.return_focus
    }
}

thor_menu_is_open :: proc(thor: ^Thor) -> bool {
    return thor.menu_open
}

// ---- the view --------------------------------------------------------------------

thor_menu_view :: proc(thor: ^Thor) {
    if !thor.menu_open {
        return
    }
    m := &thor.menu

    if ui.take_key(.Escape) {
        thor_menu_close(thor)
        return
    }

    // The backdrop catches a click anywhere else, which dismisses the menu.
    backdrop := ui.scope(
        {
            key = "menu-backdrop",
            flags = {.Floating, .Clickable},
            props = {
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                z = 500,
            },
        },
    )

    // Kept inside the window: a menu near the right or bottom edge flips back.
    vp := ui.viewport()
    x, y := m.anchor.x, m.anchor.y
    picked: Menu_Item

    {
        box := ui.scope(
            {
                key = "menu-box",
                flags = {.Clickable},
                props = {
                    position = .Fixed,
                    inset = {l = x, t = y},
                    w = ui.FIT,
                    min_w = MENU_MIN_W,
                    h = ui.FIT,
                    dir = .Column,
                    pad = ui.all(4),
                    bg = thor.theme.second_background,
                    radius = ui.rad(6),
                    border = {width = ui.all(1), color = thor.theme.border},
                    shadow = {offset = {0, 4}, blur = 16, color = thor.theme.contrast},
                },
            },
        )
        // The rect is a frame behind, which is exactly what the flip needs: the
        // first frame draws at the anchor, the second corrects it.
        if box.rect.w > 0 {
            if x + box.rect.w > vp.x {
                x = max(vp.x - box.rect.w, 0)
            }
            if y + box.rect.h > vp.y {
                y = max(m.anchor.y - box.rect.h, 0)
            }
        }

        for item, i in m.items {
            ui.push_id_int(i64(i))
            if menu_row(thor, item) {
                picked = item
            }
            ui.pop_id()
        }
    }

    if picked.run != nil {
        thor_menu_close(thor)
        picked.run(picked.data)
        return
    }
    if backdrop.clicked {
        thor_menu_close(thor)
    }
}

// One row. Reports whether it was picked; a separator and a disabled row never are.
@(private = "file")
menu_row :: proc(thor: ^Thor, item: Menu_Item) -> bool {
    if item.separator {
        ui.leaf(
            {
                key = "sep",
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(1),
                    margin = ui.xy(6, 4),
                    bg = thor.theme.border,
                },
            },
        )
        return false
    }

    it := ui.scope(
        {
            key = "item",
            flags = item.enabled ? {.Clickable} : {},
            props = {
                w = ui.Grow(1),
                h = ui.Px(MENU_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {16, 0},
                pad = ui.xy(10, 0),
                radius = ui.rad(4),
                cursor = item.enabled ? .Pointer : .Not_Allowed,
            },
            hover = {bg = item.enabled ? thor.theme.buttons : nil},
        },
    )
    ui.label(
        item.title,
        {
            key = "title",
            props = {
                w = ui.Grow(1),
                color = item.enabled ? thor.theme.foreground : thor.theme.disabled,
                text_wrap = .None,
            },
        },
    )
    if item.shortcut != "" {
        ui.label(
            item.shortcut,
            {key = "sc", props = {color = thor.theme.disabled, text_wrap = .None}},
        )
    }
    return item.enabled && it.clicked
}
