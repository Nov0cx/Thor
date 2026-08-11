// Host side of plugin panels. A plugin describes its panel as plugin.View_Nodes
// (see plugin/view.odin) and this file turns that description into widgets, then
// routes clicks, list selections and canvas draws back into the plugin VM.
package thor

import "core:strings"
import rl "vendor:raylib"

import "../plugin"
import "../ui"
import "../widgets"

// Where a panel docks. An unknown name docks right.
Plugin_Dock :: enum {
    Right,
    Bottom,
}

// A dockable panel a plugin created with thor.panel. Its content widgets are
// rebuilt on every render, so everything they borrow is owned here.
Plugin_Panel :: struct {
    thor:     ^Thor,
    id:       string, // owned; "<plugin>/<name>"
    title:    string, // owned; the header label borrows it
    dock:     Plugin_Dock,
    panel:    ^widgets.Panel, // outer container, a child of the dock stack
    content:  ^widgets.Stack, // holds the rendered nodes
    actions:  [dynamic]^Plugin_Panel_Action, // owned
    canvases: [dynamic]^Plugin_Panel_Canvas, // owned
    texts:    [dynamic]string,               // owned; widget labels borrow these
}

// A click target: a button, or one row of a list.
Plugin_Panel_Action :: struct {
    panel:  ^Plugin_Panel,
    action: int,
    row:    int,    // -1 for a button
    item:   string, // borrowed from Plugin_Panel.texts
}

// A canvas node, drawn by calling back into the plugin every frame.
Plugin_Panel_Canvas :: struct {
    panel:  ^Plugin_Panel,
    action: int,
}

// thor.panel{...}: creates the panel, or retitles it when it already exists. It
// stays hidden until the plugin calls :show().
thor_plugin_panel :: proc(host: rawptr, id, title, dock: string) {
    thor := cast(^Thor) host
    side := dock == "bottom" ? Plugin_Dock.Bottom : Plugin_Dock.Right

    if p := thor_find_plugin_panel(thor, id); p != nil {
        delete(p.title)
        p.title = strings.clone(title)
        thor_plugin_panel_set_title(p)
        return
    }

    p := new(Plugin_Panel)
    p.thor = thor
    p.id = strings.clone(id)
    p.title = strings.clone(title)
    p.dock = side
    p.actions = make([dynamic]^Plugin_Panel_Action)
    p.canvases = make([dynamic]^Plugin_Panel_Canvas)
    p.texts = make([dynamic]string)
    thor_build_plugin_panel(thor, p)
    p.panel.visible = false
    append(&thor.plugin_panels, p)

    stack := side == .Bottom ? thor.plugin_dock_bottom_stack : thor.plugin_dock_right_stack
    widgets.append_child(&stack.widget, &p.panel.widget)
    thor_update_plugin_docks(thor)
}

// Builds the panel chrome: a header with the title and a close button, over the
// content stack the render fills.
@(private = "file")
thor_build_plugin_panel :: proc(thor: ^Thor, p: ^Plugin_Panel) {
    p.panel = widgets.panel_create("plugin-panel", thor.theme.second_background)
    ui.widget_set_grow(&p.panel.widget, 1)
    p.panel.min_size = rl.Vector2 {0, 80}

    stack := widgets.stack_create("plugin-panel-stack", .Vertical)
    widgets.stack_set_gap(stack, 1)
    widgets.stack_set_padding(stack, ui.padding(0))
    widgets.stack_set_background(stack, thor.theme.border)
    ui.widget_set_grow(&stack.widget, 1)

    header := widgets.stack_create("plugin-panel-header", .Horizontal)
    widgets.stack_set_gap(header, 8)
    widgets.stack_set_padding(header, ui.padding_xy(10, 6))
    widgets.stack_set_background(header, thor.theme.highlight)
    header.min_size = rl.Vector2 {0, 32}

    label := widgets.label_create("plugin-panel-title", p.title)
    widgets.label_set_text_color(label, thor.theme.primary_text_color)
    ui.widget_set_grow(&label.widget, 1)
    label.min_size = rl.Vector2 {0, 20}

    close := widgets.button_create("plugin-panel-close", "")
    widgets.button_set_icon(close, "x", 14)
    thor_theme_icon_button(thor, close, thor.theme.highlight)
    widgets.button_set_on_click(close, thor_plugin_panel_close_click, p)
    close.min_size = rl.Vector2 {24, 20}

    p.content = widgets.stack_create("plugin-panel-content", .Vertical)
    widgets.stack_set_gap(p.content, 6)
    widgets.stack_set_padding(p.content, ui.padding(8))
    widgets.stack_set_background(p.content, thor.theme.second_background)
    ui.widget_set_grow(&p.content.widget, 1)

    widgets.append_child(&p.panel.widget, &stack.widget)
    widgets.append_child(&stack.widget, &header.widget)
    widgets.append_child(&stack.widget, &p.content.widget)
    widgets.append_child(&header.widget, &label.widget)
    widgets.append_child(&header.widget, &close.widget)
}

// Points the header label at the panel's current title.
@(private = "file")
thor_plugin_panel_set_title :: proc(p: ^Plugin_Panel) {
    stack := p.panel.first_child
    if stack == nil || stack.first_child == nil {
        return
    }
    if label := stack.first_child.first_child; label != nil {
        (cast(^widgets.Label) label).text = p.title
    }
}

// panel:render(nodes): rebuilds the panel's contents. Anything the previous
// render owned goes first, so a plugin may re-render as often as it likes.
thor_plugin_panel_render :: proc(host: rawptr, id: string, nodes: []plugin.View_Node) {
    thor := cast(^Thor) host
    p := thor_find_plugin_panel(thor, id)
    if p == nil {
        return
    }
    thor_clear_plugin_panel(p)
    for node in nodes {
        if child := thor_build_view_node(p, node); child != nil {
            widgets.append_child(&p.content.widget, child)
        }
    }
}

// panel:show(): reveals the panel and its dock.
thor_plugin_panel_show :: proc(host: rawptr, id: string) {
    thor := cast(^Thor) host
    if p := thor_find_plugin_panel(thor, id); p != nil {
        p.panel.visible = true
        thor_update_plugin_docks(thor)
    }
}

// panel:close(): hides the panel and drops the widgets it held.
thor_plugin_panel_close :: proc(host: rawptr, id: string) {
    thor := cast(^Thor) host
    if p := thor_find_plugin_panel(thor, id); p != nil {
        thor_clear_plugin_panel(p)
        p.panel.visible = false
        thor_update_plugin_docks(thor)
    }
}

// The close button in a panel's header, which also tells the plugin its panel
// is gone so a later render does not resurrect stale contents.
@(private = "file")
thor_plugin_panel_close_click :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    p := cast(^Plugin_Panel) data
    thor_plugin_panel_close(p.thor, p.id)
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
@(private = "file")
thor_update_plugin_docks :: proc(thor: ^Thor) {
    right, bottom := false, false
    for p in thor.plugin_panels {
        if !p.panel.visible {
            continue
        }
        switch p.dock {
        case .Right:  right = true
        case .Bottom: bottom = true
        }
    }
    thor.plugin_dock_right.visible = right
    thor.plugin_dock_bottom.visible = bottom
}

// Destroys the rendered widgets and frees everything they borrowed.
@(private = "file")
thor_clear_plugin_panel :: proc(p: ^Plugin_Panel) {
    child := p.content.first_child
    for child != nil {
        next := child.next_sibling
        ui.context_forget(&p.thor.ui_context, child)
        ui.widget_remove_child(child)
        ui.widget_destroy_tree(child)
        child = next
    }
    for action in p.actions {
        free(action)
    }
    clear(&p.actions)
    for canvas in p.canvases {
        free(canvas)
    }
    clear(&p.canvases)
    for text in p.texts {
        delete(text)
    }
    clear(&p.texts)
}

// Drops every panel plugins built. `destroy_widgets` unlinks and destroys their
// chrome, which a reload must do and shutdown must not — the context tears the
// whole widget tree down on its own.
thor_clear_plugin_panels :: proc(thor: ^Thor, destroy_widgets: bool) {
    for p in thor.plugin_panels {
        thor_destroy_plugin_panel(p, destroy_widgets)
    }
    clear(&thor.plugin_panels)
    thor_update_plugin_docks(thor)
}

// Frees a panel outright. Its rendered contents always go; `destroy_widgets`
// takes the chrome with them. A merely closed panel keeps both, so :show() can
// bring it back.
thor_destroy_plugin_panel :: proc(p: ^Plugin_Panel, destroy_widgets := false) {
    thor_clear_plugin_panel(p)
    if destroy_widgets {
        ui.context_forget(&p.thor.ui_context, &p.panel.widget)
        ui.widget_remove_child(&p.panel.widget)
        ui.widget_destroy_tree(&p.panel.widget)
    }
    delete(p.actions)
    delete(p.canvases)
    delete(p.texts)
    delete(p.title)
    delete(p.id)
    free(p)
}

// Keeps `text` alive for as long as the widgets that borrow it.
@(private = "file")
thor_panel_text :: proc(p: ^Plugin_Panel, text: string) -> string {
    owned := strings.clone(text)
    append(&p.texts, owned)
    return owned
}

// Builds one node (and its children). Returns nil for a node the host does not
// render, so the caller simply skips it.
@(private = "file")
thor_build_view_node :: proc(p: ^Plugin_Panel, node: plugin.View_Node) -> ^ui.Widget {
    thor := p.thor
    switch node.kind {
    case .Label:
        label := widgets.label_create("plugin-label", thor_panel_text(p, node.text))
        widgets.label_set_text_color(label, thor_plugin_role_color(thor, node.role, thor.theme.foreground))
        widgets.label_set_top_align(label, true)
        label.min_size = rl.Vector2 {0, 20}
        return &label.widget

    case .Button:
        button := widgets.button_create("plugin-button", thor_panel_text(p, node.text))
        widgets.button_set_colors(
            button,
            thor_plugin_role_color(thor, node.role, thor.theme.primary_text_color),
            thor.theme.buttons,
            thor.theme.highlight,
            thor.theme.active,
            thor.theme.border,
        )
        button.min_size = rl.Vector2 {0, 26}
        widgets.button_set_on_click(button, thor_plugin_panel_action_click, thor_panel_action(p, node.action, -1, ""))
        return &button.widget

    case .Row, .Column:
        axis: ui.Axis = node.kind == .Row ? .Horizontal : .Vertical
        stack := widgets.stack_create("plugin-stack", axis)
        widgets.stack_set_gap(stack, node.gap > 0 ? node.gap : 6)
        widgets.stack_set_padding(stack, ui.padding(0))
        if node.height > 0 {
            stack.min_size = rl.Vector2 {0, node.height}
        }
        for child in node.children {
            if built := thor_build_view_node(p, child); built != nil {
                widgets.append_child(&stack.widget, built)
            }
        }
        return &stack.widget

    case .List:
        stack := widgets.stack_create("plugin-list", .Vertical)
        widgets.stack_set_gap(stack, 2)
        widgets.stack_set_padding(stack, ui.padding(0))
        for item, row in node.items {
            entry := widgets.button_create("plugin-list-row", thor_panel_text(p, item))
            widgets.button_set_colors(
                entry,
                thor_plugin_role_color(thor, node.role, thor.theme.foreground),
                thor.theme.second_background,
                thor.theme.highlight,
                thor.theme.active,
                thor.theme.second_background,
            )
            entry.min_size = rl.Vector2 {0, 22}
            widgets.button_set_on_click(entry, thor_plugin_panel_action_click, thor_panel_action(p, node.action, row, thor_panel_text(p, item)))
            widgets.append_child(&stack.widget, &entry.widget)
        }
        return &stack.widget

    case .Separator:
        line := widgets.panel_create("plugin-separator", thor.theme.border)
        line.min_size = rl.Vector2 {0, 1}
        return &line.widget

    case .Spacer:
        space := widgets.panel_create("plugin-spacer", rl.Color {0, 0, 0, 0})
        if node.height > 0 {
            space.min_size = rl.Vector2 {0, node.height}
        } else {
            ui.widget_set_grow(&space.widget, 1)
        }
        return &space.widget

    case .Canvas:
        canvas := widgets.canvas_create("plugin-canvas")
        canvas.min_size = rl.Vector2 {0, node.height > 0 ? node.height : 120}
        target := new(Plugin_Panel_Canvas)
        target.panel = p
        target.action = node.action
        append(&p.canvases, target)
        widgets.canvas_set_on_draw(canvas, thor_plugin_canvas_draw, target)
        return &canvas.widget
    }
    return nil
}

// A click target owned by the panel until its next render.
@(private = "file")
thor_panel_action :: proc(p: ^Plugin_Panel, action, row: int, item: string) -> ^Plugin_Panel_Action {
    target := new(Plugin_Panel_Action)
    target.panel = p
    target.action = action
    target.row = row
    target.item = item
    append(&p.actions, target)
    return target
}

// Runs a button's on_click, or a list row's on_select.
@(private = "file")
thor_plugin_panel_action_click :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    target := cast(^Plugin_Panel_Action) data
    if target.action < 0 {
        return
    }
    if target.row < 0 {
        plugin.manager_panel_click(&target.panel.thor.plugins, target.panel.id, target.action)
    } else {
        plugin.manager_panel_select(&target.panel.thor.plugins, target.panel.id, target.action, target.row, target.item)
    }
}

// Runs a canvas's draw callback for the frame. The plugin's draw calls land in
// thor_plugin_draw_* below while this runs.
@(private = "file")
thor_plugin_canvas_draw :: proc(data: rawptr, bounds: rl.Rectangle) {
    target := cast(^Plugin_Panel_Canvas) data
    if target.action < 0 {
        return
    }
    plugin.manager_panel_draw(
        &target.panel.thor.plugins,
        target.panel.id,
        target.action,
        bounds.x,
        bounds.y,
        bounds.width,
        bounds.height,
    )
}

// A theme role, or `fallback` when the plugin named none.
@(private = "file")
thor_plugin_role_color :: proc(thor: ^Thor, role: string, fallback: rl.Color) -> rl.Color {
    if role == "" {
        return fallback
    }
    return ui.theme_role_color(thor.theme, role)
}

// ctx:rect / ctx:outline inside a canvas draw.
thor_plugin_draw_rect :: proc(host: rawptr, x, y, w, h: f32, role: string, fill: bool) {
    thor := cast(^Thor) host
    rect := rl.Rectangle {x, y, w, h}
    color := thor_plugin_role_color(thor, role, thor.theme.foreground)
    if fill {
        rl.DrawRectangleRec(rect, color)
    } else {
        rl.DrawRectangleLinesEx(rect, 1, color)
    }
}

// ctx:text inside a canvas draw.
thor_plugin_draw_text :: proc(host: rawptr, x, y: f32, text, role: string) {
    thor := cast(^Thor) host
    ui.draw_text(text, i32(x), i32(y), PLUGIN_CANVAS_FONT_SIZE, thor_plugin_role_color(thor, role, thor.theme.foreground))
}

// ctx:line inside a canvas draw.
thor_plugin_draw_line :: proc(host: rawptr, x0, y0, x1, y1, thickness: f32, role: string) {
    thor := cast(^Thor) host
    rl.DrawLineEx(
        rl.Vector2 {x0, y0},
        rl.Vector2 {x1, y1},
        thickness,
        thor_plugin_role_color(thor, role, thor.theme.foreground),
    )
}

// ctx:measure: the size ctx:text would take.
thor_plugin_measure_text :: proc(_: rawptr, text: string) -> (f32, f32) {
    width := ui.measure_text(text, PLUGIN_CANVAS_FONT_SIZE)
    return f32(width), f32(ui.text_line_height(PLUGIN_CANVAS_FONT_SIZE))
}

// Font size a canvas draws and measures text at.
@(private = "file")
PLUGIN_CANVAS_FONT_SIZE :: 14
