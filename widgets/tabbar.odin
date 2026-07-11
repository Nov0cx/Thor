package widgets

import rl "vendor:raylib"

import "../ui"

Tab_Info :: struct {
    name:     string,
    modified: bool,
    loading:  bool,
}

Tabbar_Count_Proc :: #type proc(data: rawptr) -> int
Tabbar_Info_Proc :: #type proc(data: rawptr, index: int) -> Tab_Info
Tabbar_Active_Proc :: #type proc(data: rawptr) -> int
Tabbar_Action_Proc :: #type proc(data: rawptr, index: int)

// Editor tab strip. Tabs are drawn directly from callbacks into the owner
// (count/info/active), so the widget never stores per-tab state and needs no
// rebuilding when files open or close.
Tabbar :: struct {
    using widget: ui.Widget,
    scroll_x:          f32,
    font_size:         i32,
    icon_size:         i32,
    count_proc:        Tabbar_Count_Proc,
    info_proc:         Tabbar_Info_Proc,
    active_proc:       Tabbar_Active_Proc,
    on_select:         Tabbar_Action_Proc,
    on_close:          Tabbar_Action_Proc,
    data:              rawptr,
    text_color:        rl.Color,
    active_text_color: rl.Color,
    background_color:  rl.Color,
    tab_color:         rl.Color,
    active_tab_color:  rl.Color,
    hover_color:       rl.Color,
    accent_color:      rl.Color,
    modified_color:    rl.Color,
}

@(private = "file")
TAB_MIN_WIDTH :: 110
@(private = "file")
TAB_MAX_WIDTH :: 260
@(private = "file")
TAB_PAD_LEFT :: 14
@(private = "file")
TAB_PAD_RIGHT :: 8
@(private = "file")
TAB_GAP :: 1
@(private = "file")
CLOSE_BOX :: 20

tabbar_vtable := ui.Widget_VTable {
    layout = tabbar_layout,
    handle_event = tabbar_handle_event,
    draw = tabbar_draw,
    destroy = tabbar_destroy,
}

tabbar_create :: proc(id: string) -> ^Tabbar {
    tabbar := new(Tabbar)
    ui.widget_init(&tabbar.widget, id, tabbar_vtable)
    tabbar.font_size = 17
    tabbar.icon_size = 16
    tabbar.text_color = rl.Color {150, 158, 180, 255}
    tabbar.active_text_color = rl.Color {230, 235, 245, 255}
    tabbar.background_color = rl.Color {20, 22, 32, 255}
    tabbar.tab_color = rl.Color {26, 28, 40, 255}
    tabbar.active_tab_color = rl.Color {15, 17, 26, 255}
    tabbar.hover_color = rl.Color {255, 255, 255, 12}
    tabbar.accent_color = rl.Color {132, 255, 255, 255}
    tabbar.modified_color = rl.Color {230, 235, 245, 255}
    tabbar.min_size = rl.Vector2 {0, 38}
    return tabbar
}

tabbar_set_callbacks :: proc(
    tabbar: ^Tabbar,
    count_proc: Tabbar_Count_Proc,
    info_proc: Tabbar_Info_Proc,
    active_proc: Tabbar_Active_Proc,
    on_select: Tabbar_Action_Proc,
    on_close: Tabbar_Action_Proc,
    data: rawptr,
) -> ^Tabbar {
    tabbar.count_proc = count_proc
    tabbar.info_proc = info_proc
    tabbar.active_proc = active_proc
    tabbar.on_select = on_select
    tabbar.on_close = on_close
    tabbar.data = data
    return tabbar
}

tabbar_set_colors :: proc(tabbar: ^Tabbar, text, active_text, background, tab, active_tab, hover, accent: rl.Color) -> ^Tabbar {
    tabbar.text_color = text
    tabbar.active_text_color = active_text
    tabbar.background_color = background
    tabbar.tab_color = tab
    tabbar.active_tab_color = active_tab
    tabbar.hover_color = hover
    tabbar.accent_color = accent
    tabbar.modified_color = active_text
    return tabbar
}

@(private = "file")
tabbar_count :: proc(tabbar: ^Tabbar) -> int {
    if tabbar.count_proc == nil {
        return 0
    }
    return tabbar.count_proc(tabbar.data)
}

@(private = "file")
tabbar_tab_width :: proc(tabbar: ^Tabbar, info: Tab_Info) -> f32 {
    width := cast(f32) (TAB_PAD_LEFT + ui.measure_text(info.name, tabbar.font_size) + 10 + CLOSE_BOX + TAB_PAD_RIGHT)
    return clamp(width, TAB_MIN_WIDTH, TAB_MAX_WIDTH)
}

@(private = "file")
tabbar_content_width :: proc(tabbar: ^Tabbar) -> f32 {
    total: f32 = 0
    for index in 0 ..< tabbar_count(tabbar) {
        total += tabbar_tab_width(tabbar, tabbar.info_proc(tabbar.data, index)) + TAB_GAP
    }
    return total
}

@(private = "file")
tabbar_clamp_scroll :: proc(tabbar: ^Tabbar) {
    max_scroll := tabbar_content_width(tabbar) - tabbar.bounds.width
    if max_scroll < 0 {
        max_scroll = 0
    }
    tabbar.scroll_x = clamp(tabbar.scroll_x, 0, max_scroll)
}

// Rectangle of the close box inside a tab rect; also the modified-dot slot.
@(private = "file")
tabbar_close_rect :: proc(tabbar: ^Tabbar, tab_rect: rl.Rectangle) -> rl.Rectangle {
    return rl.Rectangle {
        x = tab_rect.x + tab_rect.width - CLOSE_BOX - TAB_PAD_RIGHT,
        y = tab_rect.y + (tab_rect.height - CLOSE_BOX) * 0.5,
        width = CLOSE_BOX,
        height = CLOSE_BOX,
    }
}

// Walks tab rects left to right, invoking visit for each; returns early if
// visit returns false. Shared by drawing and hit testing so both always agree
// on geometry.
@(private = "file")
tabbar_each_tab :: proc(tabbar: ^Tabbar, visit: proc(tabbar: ^Tabbar, index: int, rect: rl.Rectangle, user: rawptr) -> bool, user: rawptr) {
    x := tabbar.bounds.x - tabbar.scroll_x
    for index in 0 ..< tabbar_count(tabbar) {
        info := tabbar.info_proc(tabbar.data, index)
        width := tabbar_tab_width(tabbar, info)
        rect := rl.Rectangle {x = x, y = tabbar.bounds.y, width = width, height = tabbar.bounds.height}
        if !visit(tabbar, index, rect, user) {
            return
        }
        x += width + TAB_GAP
    }
}

tabbar_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    tabbar := cast(^Tabbar) widget
    tabbar.bounds = bounds
    tabbar_clamp_scroll(tabbar)
}

@(private = "file")
Tabbar_Hit :: struct {
    position: rl.Vector2,
    index:    int,
    close:    bool,
}

tabbar_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    tabbar := cast(^Tabbar) widget

    #partial switch event.kind {
    case .Scroll:
        tabbar.scroll_x -= event.wheel_delta * 60
        tabbar_clamp_scroll(tabbar)
        return true
    case .Mouse_Down:
        hit := Tabbar_Hit {position = event.mouse_position, index = -1}
        tabbar_each_tab(tabbar, proc(tabbar: ^Tabbar, index: int, rect: rl.Rectangle, user: rawptr) -> bool {
            hit := cast(^Tabbar_Hit) user
            if !rl.CheckCollisionPointRec(hit.position, rect) {
                return true
            }
            hit.index = index
            hit.close = rl.CheckCollisionPointRec(hit.position, tabbar_close_rect(tabbar, rect))
            return false
        }, &hit)

        if hit.index >= 0 {
            if hit.close {
                if tabbar.on_close != nil {
                    tabbar.on_close(tabbar.data, hit.index)
                }
            } else if tabbar.on_select != nil {
                tabbar.on_select(tabbar.data, hit.index)
            }
        }
        return true
    }

    return false
}

@(private = "file")
Tabbar_Draw_State :: struct {
    ctx:    ^ui.Context,
    active: int,
    hot:    bool,
}

tabbar_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    tabbar := cast(^Tabbar) widget

    rl.DrawRectangleRec(tabbar.bounds, tabbar.background_color)

    ui.begin_clip(tabbar.bounds)
    defer ui.end_clip()

    state := Tabbar_Draw_State {
        ctx = ctx,
        active = tabbar.active_proc != nil ? tabbar.active_proc(tabbar.data) : -1,
        hot = ctx.hot == widget,
    }

    tabbar_each_tab(tabbar, proc(tabbar: ^Tabbar, index: int, rect: rl.Rectangle, user: rawptr) -> bool {
        state := cast(^Tabbar_Draw_State) user
        if rect.x + rect.width < tabbar.bounds.x {
            return true
        }
        if rect.x > tabbar.bounds.x + tabbar.bounds.width {
            return false
        }

        info := tabbar.info_proc(tabbar.data, index)
        is_active := index == state.active
        hovered := state.hot && rl.CheckCollisionPointRec(state.ctx.mouse_pos, rect)

        rl.DrawRectangleRec(rect, is_active ? tabbar.active_tab_color : tabbar.tab_color)
        if hovered && !is_active {
            rl.DrawRectangleRec(rect, tabbar.hover_color)
        }
        if is_active {
            rl.DrawRectangleRec(
                rl.Rectangle {x = rect.x, y = rect.y, width = rect.width, height = 2},
                tabbar.accent_color,
            )
        }

        close_rect := tabbar_close_rect(tabbar, rect)
        text_color := is_active ? tabbar.active_text_color : tabbar.text_color

        text_x := cast(i32) (rect.x + TAB_PAD_LEFT)
        text_y := cast(i32) (rect.y + (rect.height - cast(f32) tabbar.font_size) * 0.5)
        // Scissor calls do not nest, so clip the text to the tab rect
        // (intersected with the bar) and then restore the bar clip.
        text_clip := rl.GetCollisionRec(tabbar.bounds, rl.Rectangle {
            x = rect.x,
            y = rect.y,
            width = close_rect.x - rect.x - 4,
            height = rect.height,
        })
        if text_clip.width > 0 && text_clip.height > 0 {
            ui.end_clip()
            ui.begin_clip(text_clip)
            ui.draw_text(info.name, text_x, text_y, tabbar.font_size, text_color)
            ui.end_clip()
            ui.begin_clip(tabbar.bounds)
        }

        // Right slot: close x when hovered, otherwise the modified dot or a
        // loading spinner glyph; empty when the file is clean.
        close_hovered := hovered && rl.CheckCollisionPointRec(state.ctx.mouse_pos, close_rect)
        icon_x := cast(i32) (close_rect.x + (close_rect.width - cast(f32) tabbar.icon_size) * 0.5)
        icon_y := cast(i32) (close_rect.y + (close_rect.height - cast(f32) tabbar.icon_size) * 0.5)

        if close_hovered {
            rl.DrawRectangleRounded(close_rect, 0.3, 4, tabbar.hover_color)
            ui.draw_icon("x", icon_x, icon_y, tabbar.icon_size, text_color)
        } else if info.loading {
            ui.draw_icon("loader-2", icon_x, icon_y, tabbar.icon_size, tabbar.text_color)
        } else if info.modified {
            ui.draw_icon("point", icon_x, icon_y, tabbar.icon_size, tabbar.modified_color)
        } else if hovered {
            ui.draw_icon("x", icon_x, icon_y, tabbar.icon_size, tabbar.text_color)
        }

        return true
    }, &state)
}

tabbar_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Tabbar) widget)
}
