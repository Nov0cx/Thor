// Plugin panels: a plugin describes a dockable panel as a tree of plain nodes
// and the host turns that into widgets. The description is data, so this package
// keeps no dependency on `ui` or `widgets`. A canvas node inverts the flow for
// custom drawing: the host calls back once per frame with the canvas bounds and
// the plugin issues immediate-mode draw calls into it.
package plugin

import "base:runtime"
import "core:c"
import "core:strings"

import lua "vendor:lua/5.4"

// What a view node draws. Everything but Canvas is laid out by the host.
View_Kind :: enum {
    Label,
    Button,
    Row,
    Column,
    List,
    Separator,
    Spacer,
    Canvas,
}

// One node of a panel description. Strings live in the temp allocator, so a
// host that keeps a node past the render call must clone it. `action` indexes
// the panel's callback list (see manager_panel_click), or is -1.
View_Node :: struct {
    kind:     View_Kind,
    text:     string,
    role:     string, // theme role, "" for the default
    action:   int,
    items:    []string,    // List
    height:   f32,         // Canvas, Spacer
    gap:      f32,         // Row, Column
    children: []View_Node, // Row, Column
}

// Canvas bounds in screen space, held while a draw callback runs so the plugin
// can work in canvas-local coordinates.
Canvas_Rect :: struct {
    x, y, w, h: f32,
}

// Creates the panel `id` (or updates its title) docked at `dock` ("right",
// "bottom" or "left"). The host owns the widget; the plugin only names it.
Panel_Proc :: #type proc(host: rawptr, id, title, dock: string)
// Replaces the panel's contents with `nodes`, valid only for the call.
Panel_Render_Proc :: #type proc(host: rawptr, id: string, nodes: []View_Node)
// Reveals and focuses the panel.
Panel_Show_Proc :: #type proc(host: rawptr, id: string)
// Hides the panel and drops its widgets.
Panel_Close_Proc :: #type proc(host: rawptr, id: string)

// Immediate-mode drawing inside the canvas being rendered. Coordinates are
// already in screen space; `role` is a theme role.
Draw_Rect_Proc :: #type proc(host: rawptr, x, y, w, h: f32, role: string, fill: bool)
Draw_Text_Proc :: #type proc(host: rawptr, x, y: f32, text, role: string)
Draw_Line_Proc :: #type proc(host: rawptr, x0, y0, x1, y1, thickness: f32, role: string)
// Size `text` takes in the UI font.
Measure_Text_Proc :: #type proc(host: rawptr, text: string) -> (w, h: f32)

// thor.panel{ id = "...", title = "...", dock = "right" }: creates a dockable
// panel and returns an object with :render{...}, :show() and :close(). Needs the
// `ui` permission.
@(private)
api_panel :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    p := caller_plugin(m, index)
    if m == nil || p == nil || !lua.istable(L, 1) {
        return 0
    }
    context.allocator = m.allocator

    name := tbl_string(L, 1, "id")
    if name == "" {
        name = "panel"
    }
    title := tbl_string(L, 1, "title")
    if title == "" {
        title = name
    }
    dock := tbl_string(L, 1, "dock")
    if dock == "" {
        dock = "right"
    }

    id := panel_id(p.id, name)
    if _, exists := m.panel_refs[id]; !exists {
        m.panel_refs[strings.clone(id)] = make([dynamic]Callback)
    }
    if m.panel_proc != nil {
        m.panel_proc(m.host, id, title, dock)
    }

    lua.createtable(L, 0, 4)
    obj := lua.gettop(L)
    lua.pushstring(L, strings.clone_to_cstring(id, context.temp_allocator))
    lua.setfield(L, obj, "id")
    push_closure(L, m, index, api_panel_render)
    lua.setfield(L, obj, "render")
    push_closure(L, m, index, api_panel_show)
    lua.setfield(L, obj, "show")
    push_closure(L, m, index, api_panel_close)
    lua.setfield(L, obj, "close")
    return 1
}

// panel:render(nodes): replaces the panel's contents. Callbacks the previous
// render held are released here, so a plugin may re-render every frame.
@(private)
api_panel_render :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    id, ok := panel_target(m, index, L)
    if !ok || !lua.istable(L, 2) {
        return 0
    }
    context.allocator = m.allocator

    clear_panel_refs(m, id)
    nodes := parse_nodes(m, index, id, L, 2)
    if m.panel_render_proc != nil {
        m.panel_render_proc(m.host, id, nodes)
    }
    return 0
}

// panel:show(): reveals and focuses the panel.
@(private)
api_panel_show :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    id, ok := panel_target(m, index, L)
    if !ok || m.panel_show_proc == nil {
        return 0
    }
    context.allocator = m.allocator
    m.panel_show_proc(m.host, id)
    return 0
}

// panel:close(): hides the panel and releases the callbacks it held.
@(private)
api_panel_close :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    id, ok := panel_target(m, index, L)
    if !ok {
        return 0
    }
    context.allocator = m.allocator
    clear_panel_refs(m, id)
    if m.panel_close_proc != nil {
        m.panel_close_proc(m.host, id)
    }
    return 0
}

// The panel a `self` argument names, checked to belong to the calling plugin so
// a forged `id` field cannot reach another plugin's panel.
@(private)
panel_target :: proc(m: ^Manager, index: int, L: ^lua.State) -> (string, bool) {
    p := caller_plugin(m, index)
    if p == nil || !lua.istable(L, 1) {
        return "", false
    }
    id := tbl_string(L, 1, "id")
    if id == "" || !strings.has_prefix(id, strings.concatenate({p.id, "/"}, context.temp_allocator)) {
        return "", false
    }
    if _, ok := m.panel_refs[id]; !ok {
        return "", false
    }
    return id, true
}

// "<plugin>/<name>", so two plugins may both own a panel called "status".
@(private)
panel_id :: proc(plugin, name: string) -> string {
    return strings.concatenate({plugin, "/", name}, context.temp_allocator)
}

// Releases every callback the panel holds, keeping the (owned) key.
@(private)
clear_panel_refs :: proc(m: ^Manager, id: string) {
    refs, ok := &m.panel_refs[id]
    if !ok {
        return
    }
    for cb in refs {
        unref(m, cb.ref)
    }
    clear(refs)
}

// Refs the function at `idx` against the panel and returns its action index.
@(private)
add_panel_ref :: proc(m: ^Manager, index: int, id: string, L: ^lua.State, idx: c.int) -> int {
    refs, ok := &m.panel_refs[id]
    if !ok {
        return -1
    }
    lua.pushvalue(L, idx)
    append(refs, Callback {index, int(lua.L_ref(L, lua.REGISTRYINDEX))})
    return len(refs) - 1
}

// The callback a host event names, or an unset one when the panel re-rendered
// between the event and its delivery.
@(private)
panel_callback :: proc(m: ^Manager, id: string, action: int) -> Callback {
    refs, ok := m.panel_refs[id]
    if !ok || action < 0 || action >= len(refs) {
        return Callback {-1, NOREF}
    }
    return refs[action]
}

// Reads an array of node tables into View_Nodes. Everything lives in the temp
// allocator: the host consumes the tree inside the render call.
@(private)
parse_nodes :: proc(m: ^Manager, index: int, id: string, L: ^lua.State, tbl: c.int) -> []View_Node {
    out := make([dynamic]View_Node, context.temp_allocator)
    n := lua.L_len(L, tbl)
    for i in 1 ..= n {
        lua.rawgeti(L, tbl, i)
        if lua.istable(L, -1) {
            append(&out, parse_node(m, index, id, L, lua.gettop(L)))
        }
        lua.pop(L, 1)
    }
    return out[:]
}

@(private)
parse_node :: proc(m: ^Manager, index: int, id: string, L: ^lua.State, tbl: c.int) -> View_Node {
    node: View_Node
    node.action = -1
    node.kind = view_kind(tbl_string(L, tbl, "kind"))
    node.text = strings.clone(tbl_string(L, tbl, "text"), context.temp_allocator)
    node.role = strings.clone(tbl_string(L, tbl, "role"), context.temp_allocator)
    node.height = tbl_number(L, tbl, "height", 0)
    node.gap = tbl_number(L, tbl, "gap", 0)

    for key in ([]cstring {"on_click", "on_select", "draw"}) {
        lua.getfield(L, tbl, key)
        if lua.isfunction(L, -1) {
            node.action = add_panel_ref(m, index, id, L, lua.gettop(L))
        }
        lua.pop(L, 1)
    }

    lua.getfield(L, tbl, "items")
    if lua.istable(L, -1) {
        items_tbl := lua.gettop(L)
        items := make([dynamic]string, context.temp_allocator)
        count := lua.L_len(L, items_tbl)
        for i in 1 ..= count {
            lua.rawgeti(L, items_tbl, i)
            if lua.type(L, -1) == .STRING {
                append(&items, strings.clone(string(lua.tostring(L, -1)), context.temp_allocator))
            }
            lua.pop(L, 1)
        }
        node.items = items[:]
    }
    lua.pop(L, 1)

    lua.getfield(L, tbl, "children")
    if lua.istable(L, -1) {
        node.children = parse_nodes(m, index, id, L, lua.gettop(L))
    }
    lua.pop(L, 1)
    return node
}

// An unknown or missing kind is a label: the harmless node.
@(private)
view_kind :: proc(name: string) -> View_Kind {
    switch name {
    case "button":    return .Button
    case "row":       return .Row
    case "column":    return .Column
    case "list":      return .List
    case "separator": return .Separator
    case "spacer":    return .Spacer
    case "canvas":    return .Canvas
    }
    return .Label
}

// Runs a button's on_click. No-op when the panel re-rendered first.
manager_panel_click :: proc(m: ^Manager, id: string, action: int) {
    call_callback(m, panel_callback(m, id, action), 0, 0, "panel click")
}

// Runs a list's on_select with the 1-based row and its text.
manager_panel_select :: proc(m: ^Manager, id: string, action, row: int, item: string) {
    cb := panel_callback(m, id, action)
    if cb.ref == NOREF {
        return
    }
    L := m.state
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(cb.ref))
    if !lua.isfunction(L, -1) {
        lua.pop(L, 1)
        return
    }
    lua.pushinteger(L, lua.Integer(row + 1))
    lua.pushstring(L, strings.clone_to_cstring(item, context.temp_allocator))
    call_guarded(m, cb.owner, 2, 0, "panel select")
}

// Runs a canvas's draw callback for the frame, giving it a context whose
// coordinates start at the canvas's top-left corner. Called from the host's
// draw pass, with the canvas already clipped.
manager_panel_draw :: proc(m: ^Manager, id: string, action: int, x, y, w, h: f32) {
    cb := panel_callback(m, id, action)
    if cb.ref == NOREF {
        return
    }
    L := m.state
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(cb.ref))
    if !lua.isfunction(L, -1) {
        lua.pop(L, 1)
        return
    }
    m.canvas = Canvas_Rect{x, y, w, h}
    push_canvas(m, cb.owner, w, h)
    call_guarded(m, cb.owner, 1, 0, "panel draw")
    m.canvas = {}
}

// The table a draw callback receives: the canvas size plus the drawing calls.
// They only exist here, so a plugin cannot draw outside its own canvas.
@(private)
push_canvas :: proc(m: ^Manager, owner: int, w, h: f32) {
    L := m.state
    lua.createtable(L, 0, 7)
    ctx := lua.gettop(L)
    lua.pushnumber(L, lua.Number(w))
    lua.setfield(L, ctx, "w")
    lua.pushnumber(L, lua.Number(h))
    lua.setfield(L, ctx, "h")
    push_closure(L, m, owner, api_canvas_rect)
    lua.setfield(L, ctx, "rect")
    push_closure(L, m, owner, api_canvas_outline)
    lua.setfield(L, ctx, "outline")
    push_closure(L, m, owner, api_canvas_text)
    lua.setfield(L, ctx, "text")
    push_closure(L, m, owner, api_canvas_line)
    lua.setfield(L, ctx, "line")
    push_closure(L, m, owner, api_canvas_measure)
    lua.setfield(L, ctx, "measure")
}

// ctx:rect(x, y, w, h[, role]) — filled.
@(private)
api_canvas_rect :: proc "c" (L: ^lua.State) -> c.int {
    return canvas_rect(L, true)
}

// ctx:outline(x, y, w, h[, role]) — one-pixel border.
@(private)
api_canvas_outline :: proc "c" (L: ^lua.State) -> c.int {
    return canvas_rect(L, false)
}

@(private)
canvas_rect :: proc "c" (L: ^lua.State, fill: bool) -> c.int {
    context = runtime.default_context()
    m, _ := caller(L)
    if m == nil || m.draw_rect_proc == nil {
        return 0
    }
    context.allocator = m.allocator
    x := m.canvas.x + arg_number(L, 2)
    y := m.canvas.y + arg_number(L, 3)
    m.draw_rect_proc(m.host, x, y, arg_number(L, 4), arg_number(L, 5), arg_string(L, 6), fill)
    return 0
}

// ctx:text(x, y, text[, role]).
@(private)
api_canvas_text :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, _ := caller(L)
    if m == nil || m.draw_text_proc == nil {
        return 0
    }
    context.allocator = m.allocator
    x := m.canvas.x + arg_number(L, 2)
    y := m.canvas.y + arg_number(L, 3)
    m.draw_text_proc(m.host, x, y, arg_string(L, 4), arg_string(L, 5))
    return 0
}

// ctx:line(x0, y0, x1, y1[, role[, thickness]]).
@(private)
api_canvas_line :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, _ := caller(L)
    if m == nil || m.draw_line_proc == nil {
        return 0
    }
    context.allocator = m.allocator
    thickness := arg_number(L, 7)
    if thickness <= 0 {
        thickness = 1
    }
    m.draw_line_proc(
        m.host,
        m.canvas.x + arg_number(L, 2),
        m.canvas.y + arg_number(L, 3),
        m.canvas.x + arg_number(L, 4),
        m.canvas.y + arg_number(L, 5),
        thickness,
        arg_string(L, 6),
    )
    return 0
}

// ctx:measure(text) -> width, height in the UI font.
@(private)
api_canvas_measure :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, _ := caller(L)
    if m == nil || m.measure_text_proc == nil {
        lua.pushnumber(L, 0)
        lua.pushnumber(L, 0)
        return 2
    }
    context.allocator = m.allocator
    w, h := m.measure_text_proc(m.host, arg_string(L, 2))
    lua.pushnumber(L, lua.Number(w))
    lua.pushnumber(L, lua.Number(h))
    return 2
}

@(private)
arg_number :: proc "c" (L: ^lua.State, idx: c.int) -> f32 {
    return f32(lua.tonumber(L, idx))
}

@(private)
arg_string :: proc "c" (L: ^lua.State, idx: c.int) -> string {
    if lua.type(L, idx) != .STRING {
        return ""
    }
    return string(lua.tostring(L, idx))
}

// Reads a string field of the table at `tbl`; "" when absent.
@(private)
tbl_string :: proc "c" (L: ^lua.State, tbl: c.int, key: cstring) -> string {
    lua.getfield(L, tbl, key)
    defer lua.pop(L, 1)
    if lua.type(L, -1) != .STRING {
        return ""
    }
    return string(lua.tostring(L, -1))
}

// Reads a number field of the table at `tbl`, falling back to `fallback`.
@(private)
tbl_number :: proc "c" (L: ^lua.State, tbl: c.int, key: cstring, fallback: f32) -> f32 {
    lua.getfield(L, tbl, key)
    defer lua.pop(L, 1)
    if !lua.isnumber(L, -1) {
        return fallback
    }
    return f32(lua.tonumber(L, -1))
}
