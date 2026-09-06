// Host side of plugin panels. A plugin describes its panel as plugin.View_Nodes
// (see plugin/view.odin); this file keeps that description and declares it as a
// Loom tree each frame, routing clicks, list selections and canvas draws back
// into the plugin VM.
package thor

import "core:strings"
import rl "vendor:raylib"

import "../font"
import "../plugin"
import "../theme"
import ui "../vendor/loom/loom"

// Where a panel docks. An unknown name docks right.
Plugin_Dock :: enum {
    Right,
    Bottom,
}

// A dockable panel a plugin created with thor.panel. The node tree is cloned on
// every render, so nothing it holds points into the plugin's temp allocator.
Plugin_Panel :: struct {
    thor:     ^Thor,
    id:       string, // owned; "<plugin>/<name>"
    title:    string, // owned
    dock:     Plugin_Dock,
    visible:  bool,
    nodes:    []plugin.View_Node, // owned; the whole tree, cloned
    // One record per canvas node, kept because a draw callback takes a rawptr.
    canvases: [dynamic]^Plugin_Panel_Canvas, // owned
}

// A canvas node, drawn by calling back into the plugin every frame.
Plugin_Panel_Canvas :: struct {
    panel:  ^Plugin_Panel,
    action: int,
}

// Font size a canvas draws and measures text at.
@(private = "file")
PLUGIN_CANVAS_FONT_SIZE :: 14

PLUGIN_DOCK_RIGHT_W :: f32(280)
PLUGIN_DOCK_BOTTOM_H :: f32(200)

// thor.panel{...}: creates the panel, or retitles it when it already exists. It
// stays hidden until the plugin calls :show().
thor_plugin_panel :: proc(host: rawptr, id, title, dock: string) {
    thor := cast(^Thor)host
    side := dock == "bottom" ? Plugin_Dock.Bottom : Plugin_Dock.Right

    if p := thor_find_plugin_panel(thor, id); p != nil {
        heading := strings.clone(title)
        delete(p.title)
        p.title = heading
        return
    }

    p := new(Plugin_Panel)
    p.thor = thor
    p.id = strings.clone(id)
    p.title = strings.clone(title)
    p.dock = side
    p.canvases = make([dynamic]^Plugin_Panel_Canvas)
    append(&thor.plugin_panels, p)
}

// panel:render(nodes): replaces the panel's contents. Anything the previous
// render owned goes first, so a plugin may re-render as often as it likes.
thor_plugin_panel_render :: proc(host: rawptr, id: string, nodes: []plugin.View_Node) {
    thor := cast(^Thor)host
    p := thor_find_plugin_panel(thor, id)
    if p == nil {
        return
    }
    thor_clear_plugin_panel(p)
    p.nodes = plugin_clone_nodes(p, nodes)
}

// panel:show(): reveals the panel and its dock.
thor_plugin_panel_show :: proc(host: rawptr, id: string) {
    thor := cast(^Thor)host
    if p := thor_find_plugin_panel(thor, id); p != nil {
        p.visible = true
    }
}

// panel:close(): hides the panel and drops the contents it held.
thor_plugin_panel_close :: proc(host: rawptr, id: string) {
    thor := cast(^Thor)host
    if p := thor_find_plugin_panel(thor, id); p != nil {
        thor_clear_plugin_panel(p)
        p.visible = false
    }
}

@(private = "file")
thor_find_plugin_panel :: proc(thor: ^Thor, id: string) -> ^Plugin_Panel {
    for p in thor.plugin_panels {
        if p.id == id {
            return p
        }
    }
    return nil
}

// A dock shows only while one of its panels does, so an unused side takes no
// width or height from the editor.
thor_plugin_dock_visible :: proc(thor: ^Thor, dock: Plugin_Dock) -> bool {
    for p in thor.plugin_panels {
        if p.visible && p.dock == dock {
            return true
        }
    }
    return false
}

// Frees the rendered node tree and the canvas records that went with it.
@(private = "file")
thor_clear_plugin_panel :: proc(p: ^Plugin_Panel) {
    plugin_free_nodes(p.nodes)
    p.nodes = nil
    for canvas in p.canvases {
        free(canvas)
    }
    clear(&p.canvases)
}

// Drops every panel plugins built.
thor_clear_plugin_panels :: proc(thor: ^Thor) {
    for p in thor.plugin_panels {
        thor_destroy_plugin_panel(p)
    }
    clear(&thor.plugin_panels)
}

thor_destroy_plugin_panel :: proc(p: ^Plugin_Panel) {
    thor_clear_plugin_panel(p)
    delete(p.canvases)
    delete(p.title)
    delete(p.id)
    free(p)
}

// A plugin's nodes live in its temp allocator, so the whole tree is copied.
@(private = "file")
plugin_clone_nodes :: proc(p: ^Plugin_Panel, nodes: []plugin.View_Node) -> []plugin.View_Node {
    if len(nodes) == 0 {
        return nil
    }
    out := make([]plugin.View_Node, len(nodes))
    for node, i in nodes {
        out[i] = node
        out[i].text = strings.clone(node.text)
        out[i].role = strings.clone(node.role)
        if len(node.items) > 0 {
            items := make([]string, len(node.items))
            for item, j in node.items {
                items[j] = strings.clone(item)
            }
            out[i].items = items
        } else {
            out[i].items = nil
        }
        out[i].children = plugin_clone_nodes(p, node.children)
        if node.kind == .Canvas {
            target := new(Plugin_Panel_Canvas)
            target.panel = p
            target.action = node.action
            append(&p.canvases, target)
        }
    }
    return out
}

@(private = "file")
plugin_free_nodes :: proc(nodes: []plugin.View_Node) {
    for node in nodes {
        delete(node.text)
        delete(node.role)
        for item in node.items {
            delete(item)
        }
        delete(node.items)
        plugin_free_nodes(node.children)
    }
    delete(nodes)
}

// A theme role, or `fallback` when the plugin named none.
@(private = "file")
thor_plugin_role_color :: proc(thor: ^Thor, role: string, fallback: ui.Color) -> ui.Color {
    if role == "" {
        return fallback
    }
    return theme.role_color(thor.theme, role)
}

// ---- the view ---------------------------------------------------------------------

// Every visible panel of one side, stacked. The caller places the dock.
thor_plugin_dock_view :: proc(thor: ^Thor, dock: Plugin_Dock) {
    ui.scope(
        {
            key = dock == .Right ? "plugin-dock-right" : "plugin-dock-bottom",
            props = {
                w = dock == .Right ? ui.Px(PLUGIN_DOCK_RIGHT_W) : ui.Grow(1),
                h = dock == .Right ? ui.Grow(1) : ui.Px(PLUGIN_DOCK_BOTTOM_H),
                dir = .Column,
                gap = {0, 1},
                bg = thor.theme.border,
            },
        },
    )

    for p, index in thor.plugin_panels {
        if !p.visible || p.dock != dock {
            continue
        }
        ui.push_id_int(i64(index))
        plugin_panel_view(thor, p)
        ui.pop_id()
    }
}

@(private = "file")
plugin_panel_view :: proc(thor: ^Thor, p: ^Plugin_Panel) {
    ui.scope(
        {
            key = "panel",
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                min_h = 80,
                dir = .Column,
                bg = thor.theme.second_background,
            },
        },
    )

    {
        ui.scope(
            {
                key = "header",
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(32),
                    dir = .Row,
                    align = .Center,
                    gap = {8, 0},
                    pad = ui.xy(10, 0),
                    bg = thor.theme.highlight,
                },
            },
        )
        ui.label(
            p.title,
            {
                key = "title",
                props = {
                    w = ui.Grow(1),
                    color = thor.theme.primary_text_color,
                    text_wrap = .Ellipsis,
                },
            },
        )
        close := ui.scope(
            {
                key = "close",
                flags = {.Clickable},
                props = {
                    w = ui.Px(24),
                    h = ui.Px(20),
                    dir = .Row,
                    justify = .Center,
                    align = .Center,
                    radius = ui.rad(4),
                    cursor = .Pointer,
                },
                hover = {bg = thor.theme.active},
            },
        )
        thor_icon_label(thor, "x", thor.theme.primary_text_color, 14)
        ui.tooltip("Close this panel", close.id)
        if close.clicked {
            // The plugin is told too, so a later render does not resurrect
            // contents the user closed.
            thor_plugin_panel_close(thor, p.id)
            return
        }
    }

    ui.scope(
        {
            key = "content",
            flags = {.Clip, .Scroll_Y},
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                gap = {0, 6},
                pad = ui.all(8),
                bg = thor.theme.second_background,
            },
        },
    )
    plugin_view_nodes(thor, p, p.nodes)
}

@(private = "file")
plugin_view_nodes :: proc(thor: ^Thor, p: ^Plugin_Panel, nodes: []plugin.View_Node) {
    for node, index in nodes {
        ui.push_id_int(i64(index))
        plugin_view_node(thor, p, node)
        ui.pop_id()
    }
}

@(private = "file")
plugin_view_node :: proc(thor: ^Thor, p: ^Plugin_Panel, node: plugin.View_Node) {
    switch node.kind {
    case .Label:
        ui.label(
            node.text,
            {
                key = "label",
                props = {
                    w = ui.Grow(1),
                    color = thor_plugin_role_color(thor, node.role, thor.theme.foreground),
                    text_wrap = .Words,
                },
            },
        )

    case .Button:
        if plugin_view_button(
            thor,
            "button",
            node.text,
            thor_plugin_role_color(thor, node.role, thor.theme.primary_text_color),
            thor.theme.buttons,
        ) {
            plugin_panel_click(p, node.action)
        }

    case .Row, .Column:
        ui.scope(
            {
                key = "stack",
                props = {
                    w = ui.Grow(1),
                    h = node.height > 0 ? ui.Px(node.height) : ui.FIT,
                    dir = node.kind == .Row ? .Row : .Column,
                    gap = node.kind == .Row \
                    ? ui.Vec2{node.gap > 0 ? node.gap : 6, 0} \
                    : ui.Vec2{0, node.gap > 0 ? node.gap : 6},
                },
            },
        )
        plugin_view_nodes(thor, p, node.children)

    case .List:
        ui.scope(
            {key = "list", props = {w = ui.Grow(1), h = ui.FIT, dir = .Column, gap = {0, 2}}},
        )
        for item, row in node.items {
            ui.push_id_int(i64(row))
            hit := plugin_view_button(
                thor,
                "row",
                item,
                thor_plugin_role_color(thor, node.role, thor.theme.foreground),
                thor.theme.second_background,
            )
            ui.pop_id()
            if hit {
                plugin_panel_select(p, node.action, row, item)
                return
            }
        }

    case .Separator:
        ui.leaf({key = "sep", props = {w = ui.Grow(1), h = ui.Px(1), bg = thor.theme.border}})

    case .Spacer:
        ui.leaf(
            {
                key = "spacer",
                props = {
                    w = ui.Grow(1),
                    h = node.height > 0 ? ui.Px(node.height) : ui.Grow(1),
                },
            },
        )

    case .Canvas:
        target := plugin_canvas_for(p, node.action)
        if target == nil {
            return
        }
        ui.custom(
            {
                key = "canvas",
                props = {w = ui.Grow(1), h = ui.Px(node.height > 0 ? node.height : 120)},
            },
            plugin_canvas_draw,
            target,
        )
    }
}

// The record for `action`, made when the tree was cloned. A canvas node with no
// record was added outside a render and draws nothing.
@(private = "file")
plugin_canvas_for :: proc(p: ^Plugin_Panel, action: int) -> ^Plugin_Panel_Canvas {
    for canvas in p.canvases {
        if canvas.action == action {
            return canvas
        }
    }
    return nil
}

@(private = "file")
plugin_panel_click :: proc(p: ^Plugin_Panel, action: int) {
    if action < 0 {
        return
    }
    plugin.manager_panel_click(&p.thor.plugins, p.id, action)
}

@(private = "file")
plugin_panel_select :: proc(p: ^Plugin_Panel, action, row: int, item: string) {
    if action < 0 {
        return
    }
    plugin.manager_panel_select(&p.thor.plugins, p.id, action, row, item)
}

@(private = "file")
plugin_view_button :: proc(thor: ^Thor, key, text: string, color, fill: ui.Color) -> bool {
    it := ui.scope(
        {
            key = key,
            flags = {.Clickable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(26),
                dir = .Row,
                align = .Center,
                pad = ui.xy(8, 0),
                radius = ui.rad(4),
                bg = fill,
                border = {width = ui.all(1), color = thor.theme.border},
                cursor = .Pointer,
            },
            hover = {bg = thor.theme.active},
        },
    )
    ui.label(text, {key = "text", props = {w = ui.Grow(1), color = color, text_wrap = .Ellipsis}})
    return it.clicked
}

// Runs a canvas's draw callback for the frame. The plugin's draw calls land in
// thor_plugin_draw_* below while this runs.
@(private = "file")
plugin_canvas_draw :: proc(node: ^ui.Node, user: rawptr) {
    target := cast(^Plugin_Panel_Canvas)user
    if target == nil || target.action < 0 {
        return
    }
    plugin.manager_panel_draw(
        &target.panel.thor.plugins,
        target.panel.id,
        target.action,
        node.rect.x,
        node.rect.y,
        node.rect.w,
        node.rect.h,
    )
}

// ctx:rect / ctx:outline inside a canvas draw.
thor_plugin_draw_rect :: proc(host: rawptr, x, y, w, h: f32, role: string, fill: bool) {
    thor := cast(^Thor)host
    rect := rl.Rectangle{x, y, w, h}
    color := thor_plugin_role_color(thor, role, thor.theme.foreground)
    if fill {
        rl.DrawRectangleRec(rect, {color[0], color[1], color[2], color[3]})
    } else {
        rl.DrawRectangleLinesEx(rect, 1, {color[0], color[1], color[2], color[3]})
    }
}

// ctx:text inside a canvas draw.
thor_plugin_draw_text :: proc(host: rawptr, x, y: f32, text, role: string) {
    thor := cast(^Thor)host
    color := thor_plugin_role_color(thor, role, thor.theme.foreground)
    font.draw(
        text,
        i32(x),
        i32(y),
        PLUGIN_CANVAS_FONT_SIZE,
        {color[0], color[1], color[2], color[3]},
    )
}

// ctx:line inside a canvas draw.
thor_plugin_draw_line :: proc(host: rawptr, x0, y0, x1, y1, thickness: f32, role: string) {
    thor := cast(^Thor)host
    color := thor_plugin_role_color(thor, role, thor.theme.foreground)
    rl.DrawLineEx(
        rl.Vector2{x0, y0},
        rl.Vector2{x1, y1},
        thickness,
        {color[0], color[1], color[2], color[3]},
    )
}

// ctx:measure: the size ctx:text would take.
thor_plugin_measure_text :: proc(_: rawptr, text: string) -> (f32, f32) {
    width := font.measure(text, PLUGIN_CANVAS_FONT_SIZE)
    return f32(width), f32(font.line_height(PLUGIN_CANVAS_FONT_SIZE))
}
