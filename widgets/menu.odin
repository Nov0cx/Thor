package widgets

import rl "vendor:raylib"

import "../ui"

// Right-click hook: widgets that support a context menu call this with the
// click position; the owner (thor) populates and opens the shared Menu.
Context_Menu_Proc :: #type proc(data: rawptr, position: rl.Vector2)

// A floating menu used both for right-click context menus and top-bar
// dropdowns. It draws its own rows (no child widgets) and, while open, captures
// the whole screen so a click anywhere outside the box dismisses it — the same
// overlay pattern as the command palette.
Menu_Item :: struct {
    label:     string, // borrowed; caller owns (string literals are fine)
    run:       proc(data: rawptr),
    data:      rawptr,
    separator: bool, // a divider row, not selectable
    enabled:   bool,
}

Menu :: struct {
    using widget: ui.Widget,
    items:        [dynamic]Menu_Item,
    // Top-left corner where the box opens, in screen space (set on open).
    anchor:       rl.Vector2,
    box:          rl.Rectangle,
    hovered:      int,
    min_width:    f32,
    row_height:   f32,
    sep_height:   f32,
    font_size:    i32,
    pad_x:        f32,
    // Focus handed back here when the menu closes.
    return_focus: ^ui.Widget,
    background_color: rl.Color,
    border_color:     rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    hover_color:      rl.Color,
    separator_color:  rl.Color,
}

menu_vtable := ui.Widget_VTable {
    layout = menu_layout,
    handle_event = menu_handle_event,
    draw = menu_draw,
    destroy = menu_destroy,
}

menu_create :: proc(id: string) -> ^Menu {
    menu := new(Menu)
    ui.widget_init(&menu.widget, id, menu_vtable)
    menu.visible = false
    menu.items = make([dynamic]Menu_Item)
    menu.hovered = -1
    menu.min_width = 180
    menu.row_height = 28
    menu.sep_height = 9
    menu.font_size = 16
    menu.pad_x = 12
    menu.background_color = rl.Color {24, 26, 31, 250}
    menu.border_color = rl.Color {132, 255, 255, 255}
    menu.text_color = rl.Color {238, 255, 255, 255}
    menu.muted_color = rl.Color {120, 128, 160, 255}
    menu.hover_color = rl.Color {132, 255, 255, 40}
    menu.separator_color = rl.Color {60, 66, 92, 255}
    return menu
}

menu_set_colors :: proc(
    menu: ^Menu,
    background, border, text, muted, hover, separator: rl.Color,
) -> ^Menu {
    menu.background_color = background
    menu.border_color = border
    menu.text_color = text
    menu.muted_color = muted
    menu.hover_color = hover
    menu.separator_color = separator
    return menu
}

menu_clear :: proc(menu: ^Menu) {
    clear(&menu.items)
}

// Appends a clickable row. `label` must outlive the menu (literals do).
menu_add :: proc(menu: ^Menu, label: string, run: proc(data: rawptr), data: rawptr, enabled := true) {
    append(&menu.items, Menu_Item {label = label, run = run, data = data, enabled = enabled})
}

menu_add_separator :: proc(menu: ^Menu) {
    append(&menu.items, Menu_Item {separator = true})
}

// Opens the menu with its top-left at `anchor` (clamped on screen in layout).
menu_open :: proc(menu: ^Menu, ctx: ^ui.Context, anchor: rl.Vector2) {
    menu.anchor = anchor
    menu.hovered = -1
    menu.visible = true
    ctx.focused = &menu.widget
    ui.widget_bring_to_front(&menu.widget)
}

menu_close :: proc(menu: ^Menu, ctx: ^ui.Context) {
    menu.visible = false
    if ctx.focused == &menu.widget {
        ctx.focused = menu.return_focus
    }
}

menu_is_open :: proc(menu: ^Menu) -> bool {
    return menu.visible
}

menu_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    menu := cast(^Menu) widget
    // Cover the whole screen so clicks outside the box dismiss the menu.
    menu.bounds = bounds

    width := menu.min_width
    height: f32 = 6
    for item in menu.items {
        if item.separator {
            height += menu.sep_height
            continue
        }
        w := cast(f32) ui.measure_text(item.label, menu.font_size) + menu.pad_x * 2
        if w > width {
            width = w
        }
        height += menu.row_height
    }
    height += 6

    x := menu.anchor.x
    y := menu.anchor.y
    if x + width > bounds.width {
        x = bounds.width - width
    }
    if y + height > bounds.height {
        y = bounds.height - height
    }
    x = max(x, bounds.x)
    y = max(y, bounds.y)

    menu.box = rl.Rectangle {x, y, width, height}
}

menu_handle_event :: proc(widget: ^ui.Widget, ctx: ^ui.Context, event: ^ui.Event) -> bool {
    menu := cast(^Menu) widget
    if !menu.visible {
        return false
    }

    #partial switch event.kind {
    case .Mouse_Down:
        if !rl.CheckCollisionPointRec(event.mouse_position, menu.box) {
            menu_close(menu, ctx)
        }
        return true

    case .Click:
        row := menu_row_at(menu, event.mouse_position)
        if row >= 0 {
            item := menu.items[row]
            if !item.separator && item.enabled && item.run != nil {
                menu_close(menu, ctx)
                item.run(item.data)
            }
        }
        return true

    case .Key_Press:
        if event.key == .ESCAPE {
            menu_close(menu, ctx)
        }
        return true
    }

    return true // block everything underneath while open
}

@(private = "file")
menu_row_at :: proc(menu: ^Menu, point: rl.Vector2) -> int {
    if !rl.CheckCollisionPointRec(point, menu.box) {
        return -1
    }
    y := menu.box.y + 6
    for item, i in menu.items {
        h := item.separator ? menu.sep_height : menu.row_height
        if point.y >= y && point.y < y + h {
            return item.separator ? -1 : i
        }
        y += h
    }
    return -1
}

menu_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    menu := cast(^Menu) widget
    if !menu.visible {
        return
    }

    // Mouse_Move is only dispatched while a button is held, so track the
    // hovered row here from the live cursor position (as the tree does).
    menu.hovered = menu_row_at(menu, ctx.mouse_pos)

    rl.DrawRectangleRec(menu.box, menu.background_color)
    rl.DrawRectangleLinesEx(menu.box, 1, menu.border_color)

    y := menu.box.y + 6
    for item, i in menu.items {
        if item.separator {
            line_y := y + menu.sep_height * 0.5
            rl.DrawLineEx(
                rl.Vector2 {menu.box.x + menu.pad_x, line_y},
                rl.Vector2 {menu.box.x + menu.box.width - menu.pad_x, line_y},
                1,
                menu.separator_color,
            )
            y += menu.sep_height
            continue
        }

        row_rect := rl.Rectangle {menu.box.x, y, menu.box.width, menu.row_height}
        if i == menu.hovered && item.enabled {
            rl.DrawRectangleRec(row_rect, menu.hover_color)
        }
        color := item.enabled ? menu.text_color : menu.muted_color
        text_y := cast(i32) (y + (menu.row_height - cast(f32) menu.font_size) * 0.5)
        ui.draw_text(item.label, cast(i32) (menu.box.x + menu.pad_x), text_y, menu.font_size, color)
        y += menu.row_height
    }
}

menu_destroy :: proc(widget: ^ui.Widget) {
    menu := cast(^Menu) widget
    delete(menu.items)
    free(menu)
}
