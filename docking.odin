package main

import rl "vendor:raylib"
import "core:fmt"
import "core:math"

TITLE_BAR_HEIGHT  :: 18
DOCK_MARGIN_PROP  :: 0.25
MAX_DOCK_MARGIN   :: 60
MIN_DRAG_DISTANCE :: 10
RESIZE_MARGIN     :: 8
MIN_WINDOW_W      :: 200
MIN_WINDOW_H      :: 100

ResizeEdge :: enum int {
    None = -1,
    Left, Right, Top, Bottom,
    TopLeft, TopRight, BottomLeft, BottomRight,
}

Window :: struct {
    id:            int,
    title:         string,
    rect:          rl.Rectangle,
    is_floating:   bool,
    is_closed:     bool,
    leaf:          ^Container,
    resize_edge:   ResizeEdge,
    resize_start:  rl.Rectangle,
    resize_mouse:  rl.Vector2,
}

ContainerType :: enum { Leaf, Split }
SplitDir      :: enum { Horizontal, Vertical }

Container :: struct {
    type: ContainerType,
    rect: rl.Rectangle,
}

Leaf :: struct {
    using container: Container,
    window: ^Window,
}

Split :: struct {
    using container: Container,
    dir:   SplitDir,
    ratio: f32,
    left, right: ^Container,
}

DockingSystem :: struct {
    root:              ^Container,
    windows:           [dynamic]Window,
    drag_window:       ^Window,
    drag_offset:       rl.Vector2,
    drag_start_pos:    rl.Vector2,
    highlight_rect:    rl.Rectangle,
    highlight_show:    bool,
    highlight_is_fill: bool,
}

new_leaf :: proc(w: ^Window = nil) -> ^Container {
    leaf := new(Leaf)
    leaf.type = .Leaf
    leaf.window = w
    return leaf
}

new_split :: proc(dir: SplitDir, ratio: f32, left, right: ^Container) -> ^Container {
    s := new(Split)
    s.type  = .Split
    s.dir   = dir
    s.ratio = ratio
    s.left  = left
    s.right = right
    return s
}

layout_container :: proc(c: ^Container, rect: rl.Rectangle) {
    c.rect = rect
    if c.type == .Split {
        s := cast(^Split)c
        if s.dir == .Horizontal {
            left_w := rect.width * s.ratio
            layout_container(s.left,  rl.Rectangle{ rect.x, rect.y, left_w, rect.height })
            layout_container(s.right, rl.Rectangle{ rect.x + left_w, rect.y, rect.width - left_w, rect.height })
        } else {
            top_h := rect.height * s.ratio
            layout_container(s.left,  rl.Rectangle{ rect.x, rect.y, rect.width, top_h })
            layout_container(s.right, rl.Rectangle{ rect.x, rect.y + top_h, rect.width, rect.height - top_h })
        }
    } else if c.type == .Leaf {
        leaf := cast(^Leaf)c
        if leaf.window != nil && !leaf.window.is_floating {
            leaf.window.rect = rect
        }
    }
}

find_leaf :: proc(c: ^Container, point: rl.Vector2) -> ^Container {
    if !rl.CheckCollisionPointRec(point, c.rect) do return nil
    if c.type == .Leaf do return c
    s := cast(^Split)c
    if leaf := find_leaf(s.left, point); leaf != nil do return leaf
    return find_leaf(s.right, point)
}

replace_child :: proc(parent, old_child, new_node: ^Container) -> bool {
    if parent.type != .Split do return false
    s := cast(^Split)parent
    if s.left == old_child {
        s.left = new_node
        return true
    }
    if s.right == old_child {
        s.right = new_node
        return true
    }
    return false
}

find_parent :: proc(node, target: ^Container) -> ^Container {
    if node.type != .Split do return nil
    s := cast(^Split)node
    if s.left == target || s.right == target do return node
    if p := find_parent(s.left, target); p != nil do return p
    return find_parent(s.right, target)
}

Edge :: enum int { None = -1, Left = 0, Right = 1, Top = 2, Bottom = 3 }

get_drop_edge :: proc(rect: rl.Rectangle, point: rl.Vector2) -> Edge {
    margin_x := min(rect.width  * DOCK_MARGIN_PROP, MAX_DOCK_MARGIN)
    margin_y := min(rect.height * DOCK_MARGIN_PROP, MAX_DOCK_MARGIN)
    if point.x < rect.x + margin_x do return .Left
    if point.x > rect.x + rect.width - margin_x do return .Right
    if point.y < rect.y + margin_y do return .Top
    if point.y > rect.y + rect.height - margin_y do return .Bottom
    return .None
}

close_window :: proc(ds: ^DockingSystem, w: ^Window) {
    if w == nil do return
    w.is_closed = true
    if w.leaf != nil {
        leaf := cast(^Leaf)w.leaf
        if leaf != nil {
            leaf.window = nil
        }
        w.leaf = nil
    }

    if ds.root != nil {
        collapse_empty_containers(&ds.root)
    }
}

collapse_empty_containers :: proc(root: ^^Container) {
    if root^ == nil do return
    if root^.type == .Leaf {
        return
    }

    s := cast(^Split)root^
    collapse_empty_containers(&s.left)
    collapse_empty_containers(&s.right)

    left_is_empty := s.left == nil || (s.left.type == .Leaf && (cast(^Leaf)s.left).window == nil)
    right_is_empty := s.right == nil || (s.right.type == .Leaf && (cast(^Leaf)s.right).window == nil)

    if left_is_empty && right_is_empty {
        root^ = nil
        return
    }
    if left_is_empty {
        root^ = s.right
        return
    }
    if right_is_empty {
        root^ = s.left
        return
    }
}

dock_window_to_leaf :: proc(ds: ^DockingSystem, leaf: ^Container, edge: Edge, w: ^Window) {
    l := cast(^Leaf)leaf
    if l.window == nil {
        l.window = w
        w.is_floating = false
        w.leaf = leaf
        w.rect = leaf.rect
        return
    }
    old_leaf := leaf
    new_leaf := new_leaf(w)
    w.is_floating = false
    w.leaf = new_leaf

    dir: SplitDir
    left, right: ^Container
    switch edge {
    case .Left:   dir = .Horizontal; left = new_leaf; right = old_leaf
    case .Right:  dir = .Horizontal; left = old_leaf; right = new_leaf
    case .Top:    dir = .Vertical;   left = new_leaf; right = old_leaf
    case .Bottom: dir = .Vertical;   left = old_leaf; right = new_leaf
    case .None:   return
    }

    split_node := new_split(dir, 0.5, left, right)
    old_rect := old_leaf.rect

    if old_leaf == ds.root {
        ds.root = split_node
        layout_container(ds.root, old_rect)
    } else {
        parent := find_parent(ds.root, old_leaf)
        if parent != nil {
            replace_child(parent, old_leaf, split_node)
        }
        layout_container(ds.root, ds.root.rect)
    }
}

undock_window :: proc(ds: ^DockingSystem, leaf: ^Container) {
    l := cast(^Leaf)leaf
    w := l.window
    if w == nil do return
    screen_w := f32(rl.GetScreenWidth())
    screen_h := f32(rl.GetScreenHeight())
    max_w := screen_w * 0.8
    max_h := screen_h * 0.8
    new_w := min(leaf.rect.width,  max_w)
    new_h := min(leaf.rect.height, max_h)
    w.rect = {
        leaf.rect.x + (leaf.rect.width  - new_w) * 0.5,
        leaf.rect.y + (leaf.rect.height - new_h) * 0.5,
        new_w,
        new_h,
    }
    w.is_floating = true
    w.leaf = nil
    l.window = nil
}

get_resize_edge :: proc(w: ^Window, mouse: rl.Vector2) -> ResizeEdge {
    r := w.rect

    in_left   := mouse.x >= r.x - RESIZE_MARGIN && mouse.x <= r.x + RESIZE_MARGIN
    in_right  := mouse.x >= r.x + r.width - RESIZE_MARGIN && mouse.x <= r.x + r.width + RESIZE_MARGIN
    in_top    := mouse.y >= r.y - RESIZE_MARGIN && mouse.y <= r.y + RESIZE_MARGIN
    in_bottom := mouse.y >= r.y + r.height - RESIZE_MARGIN && mouse.y <= r.y + r.height + RESIZE_MARGIN

    if in_left && in_top       do return .TopLeft
    if in_right && in_top      do return .TopRight
    if in_left && in_bottom    do return .BottomLeft
    if in_right && in_bottom   do return .BottomRight

    if in_left   do return .Left
    if in_right  do return .Right
    if in_top    do return .Top
    if in_bottom do return .Bottom

    return .None
}

set_resize_cursor :: proc(edge: ResizeEdge) {
    switch edge {
    case .Left, .Right:
        rl.SetMouseCursor(.RESIZE_EW)
    case .Top, .Bottom:
        rl.SetMouseCursor(.RESIZE_NS)
    case .TopLeft, .BottomRight:
        rl.SetMouseCursor(.RESIZE_NWSE)
    case .TopRight, .BottomLeft:
        rl.SetMouseCursor(.RESIZE_NESW)
    case .None:
        rl.SetMouseCursor(.DEFAULT)
    }
}

draw_resize_highlight :: proc(w: ^Window, edge: ResizeEdge) {
    if edge == .None do return
    r := w.rect
    col := rl.Color{255, 255, 255, 80}

    switch edge {
    case .Left:        rl.DrawRectangle(i32(r.x), i32(r.y), i32(RESIZE_MARGIN), i32(r.height), col)
    case .Right:       rl.DrawRectangle(i32(r.x + r.width - RESIZE_MARGIN), i32(r.y), i32(RESIZE_MARGIN), i32(r.height), col)
    case .Top:         rl.DrawRectangle(i32(r.x), i32(r.y), i32(r.width), i32(RESIZE_MARGIN), col)
    case .Bottom:      rl.DrawRectangle(i32(r.x), i32(r.y + r.height - RESIZE_MARGIN), i32(r.width), i32(RESIZE_MARGIN), col)
    case .TopLeft:     rl.DrawRectangle(i32(r.x), i32(r.y), i32(RESIZE_MARGIN), i32(RESIZE_MARGIN), col)
    case .TopRight:    rl.DrawRectangle(i32(r.x + r.width - RESIZE_MARGIN), i32(r.y), i32(RESIZE_MARGIN), i32(RESIZE_MARGIN), col)
    case .BottomLeft:  rl.DrawRectangle(i32(r.x), i32(r.y + r.height - RESIZE_MARGIN), i32(RESIZE_MARGIN), i32(RESIZE_MARGIN), col)
    case .BottomRight: rl.DrawRectangle(i32(r.x + r.width - RESIZE_MARGIN), i32(r.y + r.height - RESIZE_MARGIN), i32(RESIZE_MARGIN), i32(RESIZE_MARGIN), col)
    case .None:
    }
}

update_docking :: proc(ds: ^DockingSystem) {
    mouse := rl.GetMousePosition()

    hovered_edge := ResizeEdge.None
    if ds.drag_window == nil {
        for i := len(ds.windows) - 1; i >= 0; i -= 1 {
            w := &ds.windows[i]
            if w.is_closed do continue
            if w.is_floating && w.resize_edge == .None {
                if rl.CheckCollisionPointRec(mouse, w.rect) {
                    edge := get_resize_edge(w, mouse)
                    if edge != .None {
                        hovered_edge = edge
                        break
                    }
                }
            }
        }
    }
    set_resize_cursor(hovered_edge)

    if rl.IsMouseButtonPressed(.LEFT) {
        for i := len(ds.windows) - 1; i >= 0; i -= 1 {
            w := &ds.windows[i]
            if w.is_closed do continue
            if w.is_floating && rl.CheckCollisionPointRec(mouse, w.rect) {
                edge := get_resize_edge(w, mouse)
                if edge != .None {
                    w.resize_edge = edge
                    w.resize_start = w.rect
                    w.resize_mouse = mouse
                    break
                }
            }
        }

        if ds.drag_window == nil {
            for i := len(ds.windows) - 1; i >= 0; i -= 1 {
                w := &ds.windows[i]
                if w.is_closed do continue
                if w.is_floating && w.resize_edge == .None {
                    title_rect := rl.Rectangle{
                        w.rect.x, w.rect.y,
                        w.rect.width, TITLE_BAR_HEIGHT,
                    }
                    if rl.CheckCollisionPointRec(mouse, title_rect) &&
                       rl.CheckCollisionPointRec(mouse, w.rect) {
                        ds.drag_window = w
                        ds.drag_offset = mouse - rl.Vector2{ w.rect.x, w.rect.y }
                        ds.drag_start_pos = mouse
                        break
                    }
                }
            }
        }

        if ds.drag_window == nil {
            leaf := find_leaf(ds.root, mouse)
            if leaf != nil {
                l := cast(^Leaf)leaf
                if l.window != nil && !l.window.is_closed {
                    title_rect := rl.Rectangle{
                        l.rect.x, l.rect.y,
                        l.rect.width, TITLE_BAR_HEIGHT,
                    }
                    if rl.CheckCollisionPointRec(mouse, title_rect) {
                        w := l.window
                        undock_window(ds, leaf)
                        ds.drag_window = w
                        ds.drag_offset = mouse - rl.Vector2{ w.rect.x, w.rect.y }
                        ds.drag_start_pos = mouse
                    }
                }
            }
        }
    }

    if rl.IsMouseButtonDown(.LEFT) {
        for &w in ds.windows {
            if w.is_closed do continue
            if w.resize_edge != .None {
                delta := mouse - w.resize_mouse
                r := w.resize_start
                min_w := f32(MIN_WINDOW_W)
                min_h := f32(MIN_WINDOW_H)
                edge := w.resize_edge

                #partial switch edge {
                case .Left, .TopLeft, .BottomLeft:
                    new_w := r.width - delta.x
                    if new_w >= min_w {
                        w.rect.x = r.x + delta.x
                        w.rect.width = new_w
                    }
                }
                #partial switch edge {
                case .Right, .TopRight, .BottomRight:
                    w.rect.width = max(min_w, r.width + delta.x)
                }
                #partial switch edge {
                case .Top, .TopLeft, .TopRight:
                    new_h := r.height - delta.y
                    if new_h >= min_h {
                        w.rect.y = r.y + delta.y
                        w.rect.height = new_h
                    }
                }
                #partial switch edge {
                case .Bottom, .BottomLeft, .BottomRight:
                    w.rect.height = max(min_h, r.height + delta.y)
                }
                break
            }
        }
    }

    if ds.drag_window != nil {
        ds.drag_window.rect.x = mouse.x - ds.drag_offset.x
        ds.drag_window.rect.y = mouse.y - ds.drag_offset.y

        dist := math.sqrt(
            (mouse.x - ds.drag_start_pos.x)*(mouse.x - ds.drag_start_pos.x) +
            (mouse.y - ds.drag_start_pos.y)*(mouse.y - ds.drag_start_pos.y),
        )
        ds.highlight_show = false
        if dist >= MIN_DRAG_DISTANCE {
            leaf := find_leaf(ds.root, mouse)
            if leaf != nil {
                l := cast(^Leaf)leaf
                if l.window == nil {
                    ds.highlight_show = true
                    ds.highlight_is_fill = true
                    ds.highlight_rect = leaf.rect
                } else {
                    edge := get_drop_edge(leaf.rect, mouse)
                    if edge != .None {
                        ds.highlight_show = true
                        ds.highlight_is_fill = false
                        r := leaf.rect
                        #partial switch edge {
                        case .Left:   ds.highlight_rect = { r.x, r.y, r.width * 0.5, r.height }
                        case .Right:  ds.highlight_rect = { r.x + r.width * 0.5, r.y, r.width * 0.5, r.height }
                        case .Top:    ds.highlight_rect = { r.x, r.y, r.width, r.height * 0.5 }
                        case .Bottom: ds.highlight_rect = { r.x, r.y + r.height * 0.5, r.width, r.height * 0.5 }
                        }
                    }
                }
            }
        }

        if rl.IsMouseButtonReleased(.LEFT) {
            if ds.highlight_show {
                leaf := find_leaf(ds.root, mouse)
                if leaf != nil {
                    drop_edge := Edge.None
                    if !ds.highlight_is_fill {
                        drop_edge = get_drop_edge(leaf.rect, mouse)
                    }
                    dock_window_to_leaf(ds, leaf, drop_edge, ds.drag_window)
                }
            }
            ds.drag_window = nil
            ds.highlight_show = false
        }
    }

    if rl.IsMouseButtonReleased(.LEFT) {
        for &w in ds.windows {
            if !w.is_closed {
                w.resize_edge = .None
            }
        }
        set_resize_cursor(.None)
    }
}

draw_container :: proc(c: ^Container) {
    if c.type == .Leaf {
        leaf := cast(^Leaf)c
        rl.DrawRectangleRec(c.rect, rl.DARKGRAY)
        if leaf.window != nil && !leaf.window.is_closed {
            title_rect := rl.Rectangle{ c.rect.x, c.rect.y, c.rect.width, TITLE_BAR_HEIGHT }
            rl.DrawRectangleRec(title_rect, ui_theme.blue)
            rl.DrawText(
                fmt.ctprintf("%s", leaf.window.title),
                i32(title_rect.x) + 4, i32(title_rect.y) + 1,
                14, rl.WHITE,
            )
            close_rect := rl.Rectangle{ title_rect.x + title_rect.width - 16, title_rect.y + 2, 12, 12 }
            rl.DrawRectangleRec(close_rect, rl.RED)
            rl.DrawText("x", i32(close_rect.x) + 2, i32(close_rect.y) - 1, 10, rl.WHITE)
            content_rect := rl.Rectangle{
                c.rect.x, c.rect.y + TITLE_BAR_HEIGHT,
                c.rect.width, c.rect.height - TITLE_BAR_HEIGHT,
            }
            rl.DrawRectangleRec(content_rect, ui_theme.background)
        } else {
            rl.DrawRectangleLinesEx(c.rect, 1, rl.DARKGRAY)
        }
    } else {
        s := cast(^Split)c
        draw_container(s.left)
        draw_container(s.right)
        if s.dir == .Horizontal {
            rl.DrawLine(
                i32(s.right.rect.x), i32(s.rect.y),
                i32(s.right.rect.x), i32(s.rect.y + s.rect.height),
                rl.BLACK,
            )
        } else {
            rl.DrawLine(
                i32(s.rect.x), i32(s.right.rect.y),
                i32(s.rect.x + s.rect.width), i32(s.right.rect.y),
                rl.BLACK,
            )
        }
    }
}

draw_floating_windows :: proc(ds: ^DockingSystem) {
    hovered_edge := ResizeEdge.None
    if ds.drag_window == nil {
        mouse := rl.GetMousePosition()
        for i := len(ds.windows) - 1; i >= 0; i -= 1 {
            w := &ds.windows[i]
            if w.is_floating && w.resize_edge == .None &&
               rl.CheckCollisionPointRec(mouse, w.rect) {
                edge := get_resize_edge(w, mouse)
                if edge != .None {
                    hovered_edge = edge
                    break
                }
            }
        }
    }

    for &w in ds.windows {
        if w.is_closed do continue
        if w.is_floating {
            border_rect := rl.Rectangle{
                w.rect.x - 2, w.rect.y - 2,
                w.rect.width + 4, w.rect.height + 4,
            }
            rl.DrawRectangleRec(border_rect, rl.BLACK)
            rl.DrawRectangleRec(w.rect, ui_theme.background)

            title_rect := rl.Rectangle{
                w.rect.x, w.rect.y,
                w.rect.width, TITLE_BAR_HEIGHT,
            }
            rl.DrawRectangleRec(title_rect, ui_theme.blue)
            rl.DrawText(
                fmt.ctprintf("%s", w.title),
                i32(title_rect.x) + 4, i32(title_rect.y) + 1,
                14, rl.WHITE,
            )
            close_rect := rl.Rectangle{ title_rect.x + title_rect.width - 16, title_rect.y + 2, 12, 12 }
            rl.DrawRectangleRec(close_rect, rl.RED)
            rl.DrawText("x", i32(close_rect.x) + 2, i32(close_rect.y) - 1, 10, rl.WHITE)

            if w.resize_edge == .None && hovered_edge != .None &&
               rl.CheckCollisionPointRec(rl.GetMousePosition(), w.rect) {
                edge := get_resize_edge(&w, rl.GetMousePosition())
                if edge != .None {
                    draw_resize_highlight(&w, edge)
                }
            }
        }
    }
}

collect_docked_windows_rec :: proc(c: ^Container, list: ^[dynamic]^Window) {
    if c.type == .Leaf {
        leaf := cast(^Leaf)c
        if leaf.window != nil && !leaf.window.is_closed {
            append(list, leaf.window)
        }
    } else {
        s := cast(^Split)c
        collect_docked_windows_rec(s.left, list)
        collect_docked_windows_rec(s.right, list)
    }
}