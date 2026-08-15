package widgets

import "core:c"
import "core:math"
import rl "vendor:raylib"

import "../ui"

// Cursor travel that turns a press on a maximized window into a restore.
@(private = "file")
UNMAXIMIZE_THRESHOLD :: 4

Titlebar :: struct {
    using widget: ui.Widget,
    gap:              f32,
    padding:          ui.Padding,
    background_color: rl.Color,
    dragging:         bool,
    // Grabbed point: x as a fraction of the window width, so a restore mid-drag
    // puts it back proportionally along the smaller titlebar.
    grab_ratio:       f32,
    grab_y:           f32,
    // The maximize state lives in the host, not here.
    is_maximized:     #type proc(data: rawptr) -> bool,
    toggle_maximize:  #type proc(data: rawptr),
    maximize_data:    rawptr,
}

titlebar_vtable := ui.Widget_VTable {
    layout = titlebar_layout,
    handle_event = titlebar_handle_event,
    draw = titlebar_draw,
    destroy = titlebar_destroy,
}

titlebar_create :: proc(id: string) -> ^Titlebar {
    titlebar := new(Titlebar)
    ui.widget_init(&titlebar.widget, id, titlebar_vtable)
    titlebar.gap = 8
    titlebar.padding = ui.padding_xy(12, 8)
    return titlebar
}

titlebar_set_gap :: proc(titlebar: ^Titlebar, gap: f32) -> ^Titlebar {
    titlebar.gap = gap
    return titlebar
}

titlebar_set_padding :: proc(titlebar: ^Titlebar, padding: ui.Padding) -> ^Titlebar {
    titlebar.padding = padding
    return titlebar
}

titlebar_set_background :: proc(titlebar: ^Titlebar, background_color: rl.Color) -> ^Titlebar {
    titlebar.background_color = background_color
    return titlebar
}

// Sets the hooks the drag needs to read and change the maximize state.
titlebar_set_maximize :: proc(
    titlebar: ^Titlebar,
    is_maximized: #type proc(data: rawptr) -> bool,
    toggle_maximize: #type proc(data: rawptr),
    data: rawptr,
) -> ^Titlebar {
    titlebar.is_maximized = is_maximized
    titlebar.toggle_maximize = toggle_maximize
    titlebar.maximize_data = data
    return titlebar
}

titlebar_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    titlebar := cast(^Titlebar) widget
    titlebar.bounds = bounds

    inner_bounds := ui.shrink_rectangle(bounds, titlebar.padding)

    visible_children := 0
    min_width: f32 = 0
    total_grow: f32 = 0

    child := titlebar.first_child
    for child != nil {
        if child.visible {
            visible_children += 1
            min_width += child.min_size.x
            total_grow += child.grow
        }
        child = child.next_sibling
    }

    if visible_children == 0 {
        return
    }

    total_gap := titlebar.gap * cast(f32) (visible_children - 1)
    extra_width := inner_bounds.width - min_width - total_gap
    if extra_width < 0 {
        extra_width = 0
    }

    x := inner_bounds.x
    child = titlebar.first_child
    for child != nil {
        if child.visible {
            child_width := child.min_size.x
            if extra_width > 0 {
                if total_grow > 0 && child.grow > 0 {
                    child_width += extra_width * (child.grow / total_grow)
                } else if total_grow == 0 {
                    child_width += extra_width / cast(f32) visible_children
                }
            }

            ui.widget_layout_tree(child, rl.Rectangle {
                x = x,
                y = inner_bounds.y,
                width = child_width,
                height = inner_bounds.height,
            })
            x += child_width + titlebar.gap
        }
        child = child.next_sibling
    }
}

// Window origin that puts the grabbed point back under the cursor. Anchored on
// the grab point, not on per-frame deltas: X11 sends no motion event when the
// window itself moves, so a delta-driven drag oscillates instead of tracking.
titlebar_drag_position :: proc(window_pos, mouse_pos, grab: rl.Vector2) -> [2]c.int {
    return [2]c.int {
        cast(c.int) math.round(window_pos[0] + mouse_pos[0] - grab[0]),
        cast(c.int) math.round(window_pos[1] + mouse_pos[1] - grab[1]),
    }
}

// The grabbed point in the window of this frame.
@(private = "file")
titlebar_grab :: proc(titlebar: ^Titlebar) -> rl.Vector2 {
    return rl.Vector2 {titlebar.grab_ratio * cast(f32) rl.GetScreenWidth(), titlebar.grab_y}
}

titlebar_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    titlebar := cast(^Titlebar) widget

    #partial switch event.kind {
    case .Mouse_Down:
        if event.mouse_button != .LEFT {
            return false
        }
        if event.target != widget && event.target.vtable.handle_event != nil {
            return false
        }
        if event.click_count >= 2 {
            titlebar.dragging = false
            if titlebar.toggle_maximize != nil {
                titlebar.toggle_maximize(titlebar.maximize_data)
            }
            return true
        }
        titlebar.dragging = true
        width := cast(f32) rl.GetScreenWidth()
        titlebar.grab_ratio = width > 0 ? event.mouse_position[0] / width : 0
        titlebar.grab_y = event.mouse_position[1]
        return true
    case .Mouse_Move:
        if !titlebar.dragging {
            return false
        }
        // The window manager can swallow the release, a drag past a screen edge
        // does, which would leave the window glued to the cursor.
        if !rl.IsMouseButtonDown(.LEFT) {
            titlebar.dragging = false
            return false
        }
        grab := titlebar_grab(titlebar)
        if titlebar.toggle_maximize != nil && titlebar.is_maximized != nil &&
           titlebar.is_maximized(titlebar.maximize_data) {
            moved := abs(event.mouse_position[0] - grab[0]) > UNMAXIMIZE_THRESHOLD ||
                abs(event.mouse_position[1] - grab[1]) > UNMAXIMIZE_THRESHOLD
            if moved {
                // The restored size lands one frame later, and grab_ratio then
                // puts the grabbed point back under the cursor.
                titlebar.toggle_maximize(titlebar.maximize_data)
            }
            return true
        }
        pos := rl.GetWindowPosition()
        current := [2]c.int {cast(c.int) math.round(pos[0]), cast(c.int) math.round(pos[1])}
        target := titlebar_drag_position(pos, event.mouse_position, grab)
        // A move of zero still costs an X11 round trip every frame.
        if target != current {
            rl.SetWindowPosition(target[0], target[1])
        }
        return true
    case .Mouse_Up:
        titlebar.dragging = false
    case .Click, .Key_Press, .None:
    }

    return false
}

titlebar_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    titlebar := cast(^Titlebar) widget
    rl.DrawRectangleRec(titlebar.bounds, titlebar.background_color)
}

titlebar_destroy :: proc(widget: ^ui.Widget) {
    free(cast(^Titlebar) widget)
}
