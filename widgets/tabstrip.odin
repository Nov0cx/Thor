package widgets

import rl "vendor:raylib"

import "../ui"

Tabstrip_Add_Proc :: #type proc(data: rawptr)

// Compact tab strip for terminals. It shares Tabbar's callbacks and Tab_Info, but
// tabs are content-sized pills with a status dot instead of fixed-width tabs with
// an accent bar, and the add button is pinned to the right end.
Tabstrip :: struct {
    using widget: ui.Widget,
    scroll_x:          f32,
    font_size:         i32,
    count_proc:        Tabbar_Count_Proc,
    info_proc:         Tabbar_Info_Proc,
    active_proc:       Tabbar_Active_Proc,
    on_select:         Tabbar_Action_Proc,
    on_close:          Tabbar_Action_Proc,
    on_add:            Tabstrip_Add_Proc,
    data:              rawptr,
    text_color:        rl.Color,
    active_text_color: rl.Color,
    background_color:  rl.Color,
    active_tab_color:  rl.Color,
    hover_color:       rl.Color,
    busy_color:        rl.Color,
    dead_color:        rl.Color,
}

@(private = "file")
STRIP_MAX_WIDTH :: 168
@(private = "file")
STRIP_PAD_LEFT :: 9
@(private = "file")
STRIP_PAD_RIGHT :: 5
// The dot and the close box keep their slot whether or not they are drawn, so a
// tab never changes width while a command runs.
@(private = "file")
STRIP_DOT_SLOT :: 14
@(private = "file")
STRIP_CLOSE_SLOT :: 18
@(private = "file")
STRIP_GAP :: 2
@(private = "file")
STRIP_INSET :: 3
@(private = "file")
STRIP_ADD_WIDTH :: 26

tabstrip_vtable := ui.Widget_VTable {
    layout = tabstrip_layout,
    handle_event = tabstrip_handle_event,
    draw = tabstrip_draw,
    destroy = tabstrip_destroy,
}

tabstrip_create :: proc(id: string) -> ^Tabstrip {
    strip := new(Tabstrip)
    ui.widget_init(&strip.widget, id, tabstrip_vtable)
    strip.font_size = 14
    strip.text_color = rl.Color {150, 158, 180, 255}
    strip.active_text_color = rl.Color {230, 235, 245, 255}
    strip.background_color = rl.Color {20, 22, 32, 255}
    strip.active_tab_color = rl.Color {15, 17, 26, 255}
    strip.hover_color = rl.Color {255, 255, 255, 14}
    strip.busy_color = rl.Color {132, 255, 255, 255}
    strip.dead_color = rl.Color {235, 100, 100, 255}
    strip.min_size = rl.Vector2 {0, 26}
    return strip
}

tabstrip_set_callbacks :: proc(
    strip: ^Tabstrip,
    count_proc: Tabbar_Count_Proc,
    info_proc: Tabbar_Info_Proc,
    active_proc: Tabbar_Active_Proc,
    on_select: Tabbar_Action_Proc,
    on_close: Tabbar_Action_Proc,
    on_add: Tabstrip_Add_Proc,
    data: rawptr,
) -> ^Tabstrip {
    strip.count_proc = count_proc
    strip.info_proc = info_proc
    strip.active_proc = active_proc
    strip.on_select = on_select
    strip.on_close = on_close
    strip.on_add = on_add
    strip.data = data
    return strip
}

tabstrip_set_colors :: proc(strip: ^Tabstrip, text, active_text, background, active_tab, hover, busy, dead: rl.Color) -> ^Tabstrip {
    strip.text_color = text
    strip.active_text_color = active_text
    strip.background_color = background
    strip.active_tab_color = active_tab
    strip.hover_color = hover
    strip.busy_color = busy
    strip.dead_color = dead
    return strip
}

// The add button, pinned to the right end. The shell menu opens under it.
tabstrip_add_bounds :: proc(strip: ^Tabstrip) -> rl.Rectangle {
    width := min(cast(f32) STRIP_ADD_WIDTH, strip.bounds.width)
    return rl.Rectangle {
        x = strip.bounds.x + strip.bounds.width - width,
        y = strip.bounds.y,
        width = width,
        height = strip.bounds.height,
    }
}

@(private = "file")
tabstrip_tabs_bounds :: proc(strip: ^Tabstrip) -> rl.Rectangle {
    bounds := strip.bounds
    bounds.width = max(0, bounds.width - STRIP_ADD_WIDTH)
    return bounds
}

@(private = "file")
tabstrip_count :: proc(strip: ^Tabstrip) -> int {
    if strip.count_proc == nil {
        return 0
    }
    return strip.count_proc(strip.data)
}

@(private = "file")
tabstrip_tab_width :: proc(strip: ^Tabstrip, info: Tab_Info) -> f32 {
    width := cast(f32) (STRIP_PAD_LEFT + STRIP_DOT_SLOT + ui.measure_text(info.name, strip.font_size) + STRIP_CLOSE_SLOT + STRIP_PAD_RIGHT)
    return min(width, STRIP_MAX_WIDTH)
}

@(private = "file")
tabstrip_content_width :: proc(strip: ^Tabstrip) -> f32 {
    total: f32 = 0
    for index in 0 ..< tabstrip_count(strip) {
        total += tabstrip_tab_width(strip, strip.info_proc(strip.data, index)) + STRIP_GAP
    }
    return total
}

@(private = "file")
tabstrip_clamp_scroll :: proc(strip: ^Tabstrip) {
    max_scroll := tabstrip_content_width(strip) - tabstrip_tabs_bounds(strip).width
    if max_scroll < 0 {
        max_scroll = 0
    }
    strip.scroll_x = clamp(strip.scroll_x, 0, max_scroll)
}

@(private = "file")
tabstrip_close_rect :: proc(rect: rl.Rectangle) -> rl.Rectangle {
    return rl.Rectangle {
        x = rect.x + rect.width - STRIP_CLOSE_SLOT - STRIP_PAD_RIGHT,
        y = rect.y + (rect.height - STRIP_CLOSE_SLOT) * 0.5,
        width = STRIP_CLOSE_SLOT,
        height = STRIP_CLOSE_SLOT,
    }
}

// Walks tab rects left to right, invoking visit for each (stops when it returns
// false). Shared by drawing and hit testing so both agree on geometry.
@(private = "file")
tabstrip_each_tab :: proc(strip: ^Tabstrip, visit: proc(strip: ^Tabstrip, index: int, rect: rl.Rectangle, user: rawptr) -> bool, user: rawptr) {
    bounds := tabstrip_tabs_bounds(strip)
    x := bounds.x - strip.scroll_x
    for index in 0 ..< tabstrip_count(strip) {
        info := strip.info_proc(strip.data, index)
        width := tabstrip_tab_width(strip, info)
        rect := rl.Rectangle {
            x = x,
            y = bounds.y + STRIP_INSET,
            width = width,
            height = max(0, bounds.height - STRIP_INSET * 2),
        }
        if !visit(strip, index, rect, user) {
            return
        }
        x += width + STRIP_GAP
    }
}

tabstrip_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    strip := cast(^Tabstrip) widget
    strip.bounds = bounds
    tabstrip_clamp_scroll(strip)
}

@(private = "file")
Tabstrip_Hit :: struct {
    position: rl.Vector2,
    index:    int,
    close:    bool,
}

tabstrip_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    strip := cast(^Tabstrip) widget

    #partial switch event.kind {
    case .Scroll:
        strip.scroll_x -= event.wheel_delta * 40
        tabstrip_clamp_scroll(strip)
        return true
    case .Mouse_Down:
        if rl.CheckCollisionPointRec(event.mouse_position, tabstrip_add_bounds(strip)) {
            if strip.on_add != nil {
                strip.on_add(strip.data)
            }
            return true
        }

        hit := Tabstrip_Hit {position = event.mouse_position, index = -1}
        tabstrip_each_tab(strip, proc(strip: ^Tabstrip, index: int, rect: rl.Rectangle, user: rawptr) -> bool {
            hit := cast(^Tabstrip_Hit) user
            if !rl.CheckCollisionPointRec(hit.position, rect) {
                return true
            }
            hit.index = index
            hit.close = rl.CheckCollisionPointRec(hit.position, tabstrip_close_rect(rect))
            return false
        }, &hit)

        if hit.index >= 0 {
            if hit.close {
                if strip.on_close != nil {
                    strip.on_close(strip.data, hit.index)
                }
            } else if strip.on_select != nil {
                strip.on_select(strip.data, hit.index)
            }
        }
        return true
    }

    return false
}

@(private = "file")
Tabstrip_Draw_State :: struct {
    ctx:    ^ui.Context,
    active: int,
    hot:    bool,
}

tabstrip_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    strip := cast(^Tabstrip) widget

    rl.DrawRectangleRec(strip.bounds, strip.background_color)

    ui.begin_clip(tabstrip_tabs_bounds(strip))

    state := Tabstrip_Draw_State {
        ctx = ctx,
        active = strip.active_proc != nil ? strip.active_proc(strip.data) : -1,
        hot = ctx.hot == widget,
    }

    tabstrip_each_tab(strip, proc(strip: ^Tabstrip, index: int, rect: rl.Rectangle, user: rawptr) -> bool {
        state := cast(^Tabstrip_Draw_State) user
        bounds := tabstrip_tabs_bounds(strip)
        if rect.x + rect.width < bounds.x {
            return true
        }
        if rect.x > bounds.x + bounds.width {
            return false
        }

        info := strip.info_proc(strip.data, index)
        is_active := index == state.active
        hovered := state.hot && rl.CheckCollisionPointRec(state.ctx.mouse_pos, rect)

        if is_active {
            rl.DrawRectangleRounded(rect, 0.3, 6, strip.active_tab_color)
        } else if hovered {
            rl.DrawRectangleRounded(rect, 0.3, 6, strip.hover_color)
        }

        // Status dot: busy while a command runs, red once the shell is gone, and
        // a dim mark otherwise.
        dot_color := strip.text_color
        dot_color.a = is_active ? 150 : 90
        if info.modified {
            dot_color = strip.dead_color
        } else if info.loading {
            dot_color = strip.busy_color
        }
        center := rl.Vector2 {rect.x + STRIP_PAD_LEFT + 3, rect.y + rect.height * 0.5}
        rl.DrawCircleV(center, 3, dot_color)

        close_rect := tabstrip_close_rect(rect)
        text_color := is_active ? strip.active_text_color : strip.text_color

        text_x := cast(i32) (rect.x + STRIP_PAD_LEFT + STRIP_DOT_SLOT)
        text_y := cast(i32) (rect.y + (rect.height - cast(f32) strip.font_size) * 0.5)
        // Scissor calls do not nest, so clip the name to its own slot and then
        // restore the strip clip.
        text_clip := rl.GetCollisionRec(bounds, rl.Rectangle {
            x = rect.x,
            y = rect.y,
            width = close_rect.x - rect.x - 2,
            height = rect.height,
        })
        if text_clip.width > 0 && text_clip.height > 0 {
            ui.end_clip()
            ui.begin_clip(text_clip)
            ui.draw_text(info.name, text_x, text_y, strip.font_size, text_color)
            ui.end_clip()
            ui.begin_clip(bounds)
        }

        // The close mark only appears on the tab under the mouse; a lone tab
        // shows a clean name.
        if hovered {
            close_hovered := rl.CheckCollisionPointRec(state.ctx.mouse_pos, close_rect)
            icon_size: i32 = 14
            icon_x := cast(i32) (close_rect.x + (close_rect.width - cast(f32) icon_size) * 0.5)
            icon_y := cast(i32) (close_rect.y + (close_rect.height - cast(f32) icon_size) * 0.5)
            ui.draw_icon("x", icon_x, icon_y, icon_size, close_hovered ? strip.active_text_color : strip.text_color)
        }

        return true
    }, &state)

    ui.end_clip()

    add_rect := tabstrip_add_bounds(strip)
    add_hovered := state.hot && rl.CheckCollisionPointRec(ctx.mouse_pos, add_rect)
    if add_hovered {
        rl.DrawRectangleRounded(rl.Rectangle {
            x = add_rect.x,
            y = add_rect.y + STRIP_INSET,
            width = add_rect.width,
            height = max(0, add_rect.height - STRIP_INSET * 2),
        }, 0.3, 6, strip.hover_color)
    }
    icon_size: i32 = 16
    ui.draw_icon(
        "plus",
        cast(i32) (add_rect.x + (add_rect.width - cast(f32) icon_size) * 0.5),
        cast(i32) (add_rect.y + (add_rect.height - cast(f32) icon_size) * 0.5),
        icon_size,
        add_hovered ? strip.active_text_color : strip.text_color,
    )
}

tabstrip_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Tabstrip) widget)
}
