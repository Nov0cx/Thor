// `thor.ts`: tree-sitter for plugins. A plugin parses a buffer with any grammar
// compiled into the editor, walks the syntax tree, and runs its own queries —
// either inline or from a `.scm` file shipped beside plugin.lua. Grammars stay
// statically linked; only queries are data.
package plugin

import "base:runtime"
import "core:c"
import "core:strings"

import lua "vendor:lua/5.4"

import "../syntax"
import ts "../vendor/odin-tree-sitter"

// Metatable names for the two userdata types the API hands out.
@(private)
TREE_MT :: "thor.ts.tree"
@(private)
NODE_MT :: "thor.ts.node"

// Parser driving thor.ts, kept apart from the highlighter's so a plugin cannot
// disturb the language it has loaded mid-parse.
Ts_State :: struct {
    parser:  ts.Parser,
    lang_id: string, // grammar currently set on the parser; borrowed
}

// A parsed tree handed to Lua. Owns its source, since node:text() slices it
// long after the Lua string that produced it may have been collected.
@(private)
Ts_Tree :: struct {
    tree:    ts.Tree,
    source:  string, // owned
    lang_id: string, // owned
    owner:   int,    // plugin that parsed it, for .scm lookups
    m:       ^Manager,
}

// A node. `ts.Node` is a value, so the userdata only has to keep its tree alive;
// user value 1 holds the tree userdata for exactly that.
@(private)
Ts_Node :: struct {
    node: ts.Node,
    m:    ^Manager,
}

ts_init :: proc(m: ^Manager) {
    m.ts_state.parser = ts.parser_new()
    install_tree_metatable(m.state)
    install_node_metatable(m.state)
}

ts_destroy :: proc(m: ^Manager) {
    if m.ts_state.parser != nil {
        ts.parser_delete(m.ts_state.parser)
        m.ts_state.parser = nil
    }
}

// Builds the `thor.ts` table for one plugin.
@(private)
push_ts_table :: proc(m: ^Manager, index: int) {
    L := m.state
    lua.createtable(L, 0, 2)
    push_closure(L, m, index, api_ts_parse)
    lua.setfield(L, -2, "parse")
    push_closure(L, m, index, api_ts_supports)
    lua.setfield(L, -2, "supports")
}

// thor.ts.supports(grammar): whether the grammar is compiled into this build.
@(private)
api_ts_supports :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, _ := caller(L)
    if m == nil || lua.type(L, 1) != .STRING {
        lua.pushboolean(L, false)
        return 1
    }
    lua.pushboolean(L, b32(syntax.supports(&m.highlighter, string(lua.tostring(L, 1)))))
    return 1
}

// thor.ts.parse(source, grammar): parses `source`, returning a tree. Returns
// nil plus a message when the grammar is unknown or the parse fails.
@(private)
api_ts_parse :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    m, index := caller(L)
    if m == nil || lua.type(L, 1) != .STRING || lua.type(L, 2) != .STRING {
        lua.pushnil(L)
        lua.pushstring(L, "ts.parse expects (source, grammar)")
        return 2
    }
    context.allocator = m.allocator

    source := string(lua.tostring(L, 1))
    lang_id := string(lua.tostring(L, 2))

    lang, known := syntax.language(&m.highlighter, lang_id)
    if !known {
        lua.pushnil(L)
        lua.pushstring(L, strings.clone_to_cstring(
            strings.concatenate({"unknown grammar: ", lang_id}, context.temp_allocator),
            context.temp_allocator,
        ))
        return 2
    }

    if m.ts_state.lang_id != lang_id {
        ts.parser_set_language(m.ts_state.parser, lang)
        m.ts_state.lang_id = lang_id
    }
    tree := ts.parser_parse_string(m.ts_state.parser, source)
    if tree == nil {
        lua.pushnil(L)
        lua.pushstring(L, "parse failed")
        return 2
    }

    ud := cast(^Ts_Tree) lua.newuserdatauv(L, size_of(Ts_Tree), 0)
    ud^ = Ts_Tree {
        tree    = tree,
        source  = strings.clone(source),
        lang_id = strings.clone(lang_id),
        owner   = index,
        m       = m,
    }
    lua.L_setmetatable(L, TREE_MT)
    return 1
}

// Installs the shared tree metatable: methods, `__gc`, and a lock so a plugin
// cannot reach in and redefine them for every other plugin.
@(private)
install_tree_metatable :: proc(L: ^lua.State) {
    if lua.L_newmetatable(L, TREE_MT) == 0 {
        lua.pop(L, 1)
        return
    }
    mt := lua.gettop(L)

    lua.createtable(L, 0, 4)
    set_method(L, "root", tree_root)
    set_method(L, "query", tree_query)
    set_method(L, "language", tree_language)
    set_method(L, "source", tree_source)
    lua.setfield(L, mt, "__index")

    lua.pushcfunction(L, tree_gc)
    lua.setfield(L, mt, "__gc")
    lua.pushstring(L, "locked")
    lua.setfield(L, mt, "__metatable")
    lua.pop(L, 1)
}

// Adds a method to the table on top of the stack.
@(private)
set_method :: proc(L: ^lua.State, name: cstring, fn: lua.CFunction) {
    lua.pushcfunction(L, fn)
    lua.setfield(L, -2, name)
}

@(private)
tree_gc :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    ud := cast(^Ts_Tree) lua.L_checkudata(L, 1, TREE_MT)
    if ud == nil || ud.tree == nil {
        return 0
    }
    context.allocator = ud.m.allocator
    ts.tree_delete(ud.tree)
    delete(ud.source)
    delete(ud.lang_id)
    ud.tree = nil
    return 0
}

// tree:root(): the root node.
@(private)
tree_root :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    ud := cast(^Ts_Tree) lua.L_checkudata(L, 1, TREE_MT)
    if ud == nil || ud.tree == nil {
        lua.pushnil(L)
        return 1
    }
    push_node(L, ud.m, 1, ts.tree_root_node(ud.tree))
    return 1
}

// tree:language(): the grammar id it was parsed with.
@(private)
tree_language :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    ud := cast(^Ts_Tree) lua.L_checkudata(L, 1, TREE_MT)
    if ud == nil {
        lua.pushnil(L)
        return 1
    }
    lua.pushstring(L, strings.clone_to_cstring(ud.lang_id, context.temp_allocator))
    return 1
}

// tree:source(): the text the tree was built from.
@(private)
tree_source :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    ud := cast(^Ts_Tree) lua.L_checkudata(L, 1, TREE_MT)
    if ud == nil {
        lua.pushnil(L)
        return 1
    }
    lua.pushstring(L, strings.clone_to_cstring(ud.source, context.temp_allocator))
    return 1
}

// tree:query(source): runs a tree-sitter query. `source` is the query itself,
// or the name of a `.scm` file in the plugin's folder. Returns an array of
// matches, each a table of capture name -> node plus a `pattern` index; nil and
// a message when the query does not compile.
@(private)
tree_query :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    ud := cast(^Ts_Tree) lua.L_checkudata(L, 1, TREE_MT)
    if ud == nil || ud.tree == nil || lua.type(L, 2) != .STRING {
        lua.pushnil(L)
        lua.pushstring(L, "tree:query expects a query string or a .scm file name")
        return 2
    }
    m := ud.m
    context.allocator = m.allocator

    arg := string(lua.tostring(L, 2))
    source, found := query_source(m, ud.owner, arg)
    if !found {
        lua.pushnil(L)
        lua.pushstring(L, "query not found")
        return 2
    }

    query, offset, err := syntax.query_for(&m.highlighter, ud.lang_id, source)
    if err != .None {
        report_query_error(m, ud.owner, arg, offset, err)
        lua.pushnil(L)
        lua.pushstring(L, strings.clone_to_cstring(query_error_text(err), context.temp_allocator))
        return 2
    }

    cursor := ts.query_cursor_new()
    defer ts.query_cursor_delete(cursor)
    ts.query_cursor_exec(cursor, query, ts.tree_root_node(ud.tree))

    lua.createtable(L, 0, 0)
    results := lua.gettop(L)
    count: lua.Integer = 0
    for match in ts.query_cursor_next_match(cursor) {
        if !syntax.predicates_ok(query, match, ud.source) {
            continue
        }
        lua.createtable(L, 0, c.int(match.capture_count) + 1)
        entry := lua.gettop(L)
        lua.pushinteger(L, lua.Integer(match.pattern_index) + 1)
        lua.setfield(L, entry, "pattern")
        for i in 0 ..< int(match.capture_count) {
            capture := match.captures[i]
            name := ts.query_capture_name_for_id(query, capture.index)
            push_node(L, m, 1, capture.node)
            lua.setfield(L, entry, strings.clone_to_cstring(name, context.temp_allocator))
        }
        count += 1
        lua.rawseti(L, results, count)
    }
    return 1
}

// Pushes a node userdata bound to the tree userdata at `tree_index`, which
// keeps the tree alive for as long as any node off it is reachable.
@(private)
push_node :: proc(L: ^lua.State, m: ^Manager, tree_index: c.int, node: ts.Node) {
    if ts.node_is_null(node) {
        lua.pushnil(L)
        return
    }
    absolute := lua.absindex(L, tree_index)
    ud := cast(^Ts_Node) lua.newuserdatauv(L, size_of(Ts_Node), 1)
    ud^ = Ts_Node {node = node, m = m}
    lua.L_setmetatable(L, NODE_MT)
    lua.pushvalue(L, absolute)
    lua.setiuservalue(L, -2, 1)
}

// The node at stack index 1 and the tree behind it.
@(private)
node_args :: proc(L: ^lua.State) -> (^Ts_Node, ^Ts_Tree, bool) {
    node := cast(^Ts_Node) lua.L_checkudata(L, 1, NODE_MT)
    if node == nil {
        return nil, nil, false
    }
    lua.getiuservalue(L, 1, 1)
    tree := cast(^Ts_Tree) lua.L_testudata(L, -1, TREE_MT)
    lua.pop(L, 1)
    if tree == nil {
        return nil, nil, false
    }
    return node, tree, true
}

// Pushes a node reached from the node at stack index 1, carrying its tree over.
@(private)
push_related :: proc(L: ^lua.State, m: ^Manager, node: ts.Node) -> c.int {
    lua.getiuservalue(L, 1, 1)
    tree_index := lua.gettop(L)
    push_node(L, m, tree_index, node)
    lua.remove(L, tree_index)
    return 1
}

@(private)
install_node_metatable :: proc(L: ^lua.State) {
    if lua.L_newmetatable(L, NODE_MT) == 0 {
        lua.pop(L, 1)
        return
    }
    mt := lua.gettop(L)

    lua.createtable(L, 0, 16)
    set_method(L, "type", node_type)
    set_method(L, "text", node_text)
    set_method(L, "child", node_child)
    set_method(L, "child_count", node_child_count)
    set_method(L, "named_child", node_named_child)
    set_method(L, "named_child_count", node_named_child_count)
    set_method(L, "children", node_children)
    set_method(L, "named_children", node_named_children)
    set_method(L, "field", node_field)
    set_method(L, "parent", node_parent)
    set_method(L, "next", node_next)
    set_method(L, "prev", node_prev)
    set_method(L, "descendant_at", node_descendant_at)
    // Closes over the method table, so `node.start_byte` and `node:type()` both
    // resolve through one __index.
    lua.pushcclosure(L, node_index, 1)
    lua.setfield(L, mt, "__index")

    lua.pushcfunction(L, node_tostring)
    lua.setfield(L, mt, "__tostring")
    lua.pushcfunction(L, node_eq)
    lua.setfield(L, mt, "__eq")
    lua.pushstring(L, "locked")
    lua.setfield(L, mt, "__metatable")
    lua.pop(L, 1)
}

// Node `__index`: the byte and point offsets read as fields, everything else
// comes from the method table held as upvalue 1.
@(private)
node_index :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node := cast(^Ts_Node) lua.L_testudata(L, 1, NODE_MT)
    if node == nil || lua.type(L, 2) != .STRING {
        lua.pushnil(L)
        return 1
    }

    switch string(lua.tostring(L, 2)) {
    case "start_byte":
        lua.pushinteger(L, lua.Integer(ts.node_start_byte(node.node)))
        return 1
    case "end_byte":
        lua.pushinteger(L, lua.Integer(ts.node_end_byte(node.node)))
        return 1
    case "start_row":
        lua.pushinteger(L, lua.Integer(ts.node_start_point(node.node).row))
        return 1
    case "start_column":
        lua.pushinteger(L, lua.Integer(ts.node_start_point(node.node).col))
        return 1
    case "end_row":
        lua.pushinteger(L, lua.Integer(ts.node_end_point(node.node).row))
        return 1
    case "end_column":
        lua.pushinteger(L, lua.Integer(ts.node_end_point(node.node).col))
        return 1
    case "named":
        lua.pushboolean(L, b32(ts.node_is_named(node.node)))
        return 1
    case "missing":
        lua.pushboolean(L, b32(ts.node_is_missing(node.node)))
        return 1
    case "has_error":
        lua.pushboolean(L, b32(ts.node_has_error(node.node)))
        return 1
    }

    lua.pushvalue(L, 2)
    lua.rawget(L, upvalueindex(1))
    return 1
}

// node:type(): the grammar's name for this node ("procedure_declaration", "{").
@(private)
node_type :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.pushnil(L)
        return 1
    }
    lua.pushstring(L, ts.node_type(node.node))
    return 1
}

// node:text(): the source the node spans.
@(private)
node_text :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, tree, ok := node_args(L)
    if !ok {
        lua.pushstring(L, "")
        return 1
    }
    text := ts.node_text(node.node, tree.source)
    lua.pushlstring(L, transmute(cstring) raw_data(text), c.size_t(len(text)))
    return 1
}

// node:child(i) / node:named_child(i): the i-th child, 0-based, nil past the end.
@(private)
node_child :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.pushnil(L)
        return 1
    }
    i := lua.tointeger(L, 2)
    if i < 0 || u32(i) >= ts.node_child_count(node.node) {
        lua.pushnil(L)
        return 1
    }
    return push_related(L, node.m, ts.node_child(node.node, u32(i)))
}

@(private)
node_named_child :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.pushnil(L)
        return 1
    }
    i := lua.tointeger(L, 2)
    if i < 0 || u32(i) >= ts.node_named_child_count(node.node) {
        lua.pushnil(L)
        return 1
    }
    return push_related(L, node.m, ts.node_named_child(node.node, u32(i)))
}

@(private)
node_child_count :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.pushinteger(L, 0)
        return 1
    }
    lua.pushinteger(L, lua.Integer(ts.node_child_count(node.node)))
    return 1
}

@(private)
node_named_child_count :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.pushinteger(L, 0)
        return 1
    }
    lua.pushinteger(L, lua.Integer(ts.node_named_child_count(node.node)))
    return 1
}

// node:children() / node:named_children(): a 1-based array, for `ipairs`.
@(private)
node_children :: proc "c" (L: ^lua.State) -> c.int {
    return push_child_array(L, false)
}

@(private)
node_named_children :: proc "c" (L: ^lua.State) -> c.int {
    return push_child_array(L, true)
}

@(private)
push_child_array :: proc "c" (L: ^lua.State, named: bool) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.createtable(L, 0, 0)
        return 1
    }
    count := named ? ts.node_named_child_count(node.node) : ts.node_child_count(node.node)
    lua.createtable(L, c.int(count), 0)
    array := lua.gettop(L)
    lua.getiuservalue(L, 1, 1)
    tree_index := lua.gettop(L)
    for i in 0 ..< count {
        child := named ? ts.node_named_child(node.node, i) : ts.node_child(node.node, i)
        push_node(L, node.m, c.int(tree_index), child)
        lua.rawseti(L, array, lua.Integer(i) + 1)
    }
    lua.pop(L, 1) // the tree
    return 1
}

// node:field(name): the child under a grammar field ("body", "name"), or nil.
@(private)
node_field :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok || lua.type(L, 2) != .STRING {
        lua.pushnil(L)
        return 1
    }
    return push_related(L, node.m, ts.node_child_by_field_name(node.node, string(lua.tostring(L, 2))))
}

@(private)
node_parent :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.pushnil(L)
        return 1
    }
    return push_related(L, node.m, ts.node_parent(node.node))
}

// node:next([named]) / node:prev([named]): the sibling beside this node.
@(private)
node_next :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.pushnil(L)
        return 1
    }
    if bool(lua.toboolean(L, 2)) {
        return push_related(L, node.m, ts.node_next_named_sibling(node.node))
    }
    return push_related(L, node.m, ts.node_next_sibling(node.node))
}

@(private)
node_prev :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.pushnil(L)
        return 1
    }
    if bool(lua.toboolean(L, 2)) {
        return push_related(L, node.m, ts.node_prev_named_sibling(node.node))
    }
    return push_related(L, node.m, ts.node_prev_sibling(node.node))
}

// node:descendant_at(byte): the smallest named node covering `byte`.
@(private)
node_descendant_at :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.pushnil(L)
        return 1
    }
    offset := u32(max(lua.tointeger(L, 2), 0))
    return push_related(L, node.m, ts.node_named_descendant_for_byte_range(node.node, offset, offset))
}

@(private)
node_tostring :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    node, _, ok := node_args(L)
    if !ok {
        lua.pushstring(L, "<node>")
        return 1
    }
    text := strings.concatenate({
        "<", string(ts.node_type(node.node)), " ",
        u32_text(ts.node_start_byte(node.node)), "..", u32_text(ts.node_end_byte(node.node)), ">",
    }, context.temp_allocator)
    lua.pushstring(L, strings.clone_to_cstring(text, context.temp_allocator))
    return 1
}

@(private)
node_eq :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    a := cast(^Ts_Node) lua.L_testudata(L, 1, NODE_MT)
    b := cast(^Ts_Node) lua.L_testudata(L, 2, NODE_MT)
    lua.pushboolean(L, b32(a != nil && b != nil && ts.node_eq(a.node, b.node)))
    return 1
}

@(private)
u32_text :: proc(value: u32) -> string {
    buffer: [20]byte
    return strings.clone(itoa_u32(buffer[:], value), context.temp_allocator)
}

@(private)
itoa_u32 :: proc(buffer: []byte, value: u32) -> string {
    if value == 0 {
        buffer[0] = '0'
        return string(buffer[:1])
    }
    n := value
    end := len(buffer)
    for n > 0 {
        end -= 1
        buffer[end] = byte('0' + n % 10)
        n /= 10
    }
    return string(buffer[end:])
}
