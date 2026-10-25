// Hover: the declaration the name under the caret names, with its doc comment, or the type of
// the expression under the caret.
package odin

import "core:fmt"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Most fields, members or variants a type declaration lists.
@(private = "file")
HOVER_MEMBERS_MAX :: 16

@(private = "file")
HOVER_INDENT :: "    "

// Fills res.hover with the text for the name or expression at req.offset.
@(private)
hover :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened {
        return
    }
    text, start, end := hover_text(&ctx)
    if text == "" || lang.request_cancelled(req) {
        return
    }
    res.hover = lang.Hover_Info{text = strings.clone(text), start = start, end = end}
    res.ok = true
}

// The hover text and the range it covers. Temp-allocated; "" when there is none.
@(private = "file")
hover_text :: proc(ctx: ^Request_Context) -> (text: string, start, end: int) {
    offset := ctx.req.offset
    m, merr := odinsema.scope_map_range(ctx.parsed, offset, offset, context.temp_allocator)
    if merr != nil {
        return
    }
    ref, found := odinsema.ref_at(m, offset)
    odinsema.scope_map_destroy(m, context.temp_allocator)
    if found {
        if ref.kind == .None {
            return
        }
        return name_hover(ctx, ref), ref.start, ref.end
    }
    if item := import_item_at(ctx, offset); item != nil {
        return item_text(ctx, item, nil, odinsema.Symbol{}, false), item.path_offset, item.end
    }
    return expr_hover(ctx, offset)
}

// The hover text of the identifier `ref`.
@(private = "file")
name_hover :: proc(ctx: ^Request_Context, ref: odinsema.Name_Ref) -> string {
    name := strings.clone(ref.name, context.temp_allocator)
    if ref.kind == .Free {
        if text, ok := universe_hover(ctx, name, ref.start); ok {
            return text
        }
    }
    t := ref_target(ctx)
    switch t.kind {
    case .Unbound:
        return selector_hover(ctx, ref)
    case .Local:
        return local_hover(ctx, name, ref.start, t.decl)
    case .Param:
        if t.path == ctx.req.path {
            return local_hover(ctx, name, ref.start, t.decl)
        }
        c := request_checker(ctx)
        if c == nil {
            return ""
        }
        return typed_line(c, name, odinsema.decl_type(c, t.symbol))
    case .Import_Alias:
        for &item in ctx.live.tree.items {
            if (item.kind == .Import || item.kind == .Foreign_Import) && item.name == t.name {
                return item_text(ctx, &item, nil, odinsema.Symbol{}, false)
            }
        }
    case .Package_Item, .Builtin, .Member:
        if sym, ok := decl_symbol(ctx, t.path, t.decl); ok {
            return symbol_hover(ctx, sym)
        }
        if t.kind != .Member {
            return ""
        }
        // A field of a record declared in a procedure body.
        if c := request_checker(ctx); c != nil && t.typed {
            if type := odinsema.decl_type(c, t.symbol); type != odinsema.INVALID_TYPE {
                return typed_line(c, name, type)
            }
        }
        if text := selector_hover(ctx, ref); text != "" {
            return text
        }
        return name
    }
    return ""
}

// The hover text of a basic type or a compiler constant `name` at `offset` of the buffer.
// False when `name` names neither there.
@(private = "file")
universe_hover :: proc(ctx: ^Request_Context, name: string, offset: int) -> (string, bool) {
    c := request_checker(ctx)
    if c == nil {
        return "", false
    }
    r := odinsema.lookup_name(c, ctx.live.id, name, offset)
    #partial switch r.kind {
    case .Basic:
        id := odinsema.type_basic(r.basic)
        canonical := odinsema.type_string(&c.table, id, context.temp_allocator)
        if canonical != name {
            return fmt.tprintf("%s :: %s", name, canonical), true
        }
        if size := odinsema.basic_size(r.basic, ctx.target); size > 0 {
            return fmt.tprintf("%s: builtin type, %d byte%s", name, size, size == 1 ? "" : "s"), true
        }
        return fmt.tprintf("%s: builtin type", name), true
    case .Builtin:
        n, ok := odinsema.expr_under(c, ctx.live.id, offset)
        if !ok {
            return "", false
        }
        op := odinsema.expr_type(c, ctx.live.id, n)
        if op.mode == .Const && op.value != nil {
            return fmt.tprintf("%s :: %s", name, const_text(c, op.type, op.value)), true
        }
        return typed_line(c, name, op.type), true
    }
    return "", false
}

// The hover text of a selector name the scopes and the checker do not bind to a declaration:
// a swizzle, a field of an anonymous struct.
@(private = "file")
selector_hover :: proc(ctx: ^Request_Context, ref: odinsema.Name_Ref) -> string {
    #partial switch ref.kind {
    case .Field_Or_Member, .Implicit_Selector:
    case:
        return ""
    }
    c := request_checker(ctx)
    if c == nil {
        return ""
    }
    n, ok := odinsema.expr_under(c, ctx.live.id, ref.start)
    if !ok {
        return ""
    }
    op := odinsema.expr_type(c, ctx.live.id, n)
    if op.mode == .Invalid || op.type == odinsema.INVALID_TYPE {
        return ""
    }
    return typed_line(c, strings.clone(ref.name, context.temp_allocator), op.type)
}

// The hover text of a local of the buffer declared at `decl`, named at `offset`.
@(private = "file")
local_hover :: proc(ctx: ^Request_Context, name: string, offset, decl: int) -> string {
    c := request_checker(ctx)
    if c == nil || decl < 0 {
        return name
    }
    file := ctx.live.id
    l, found := odinsema.local_at(c, file, decl)
    op: odinsema.Operand
    if n, ok := odinsema.expr_under(c, file, offset); ok && n.green.kind == .Ident {
        op = odinsema.expr_type(c, file, n)
    }
    if op.mode == .Invalid {
        sym := odinsema.local_symbol(file, decl)
        op.type = odinsema.decl_type(c, sym)
        op.mode = odinsema.decl_is_type(c, sym) ? .Type : .Value
    }
    if !found {
        return typed_line(c, name, op.type)
    }
    #partial switch l.kind {
    case .Label:
        return fmt.tprintf("%s: label", name)
    case .Proc:
        if op.type != odinsema.INVALID_TYPE {
            return fmt.tprintf("%s :: %s", name, odinsema.type_string(&c.table, op.type, context.temp_allocator))
        }
    case .Type, .Const, .Poly:
        if op.mode == .Type {
            under := odinsema.type_underlying(&c.table, op.type)
            if under == odinsema.INVALID_TYPE || under == op.type {
                return typed_line(c, name, op.type)
            }
            return fmt.tprintf("%s :: %s", name, odinsema.type_string(&c.table, under, context.temp_allocator))
        }
        if op.mode == .Const && op.value != nil {
            return fmt.tprintf("%s :: %s", name, const_text(c, op.type, op.value))
        }
    }
    return typed_line(c, name, op.type)
}

// `name: T`, or `name` alone when the type is not known.
@(private = "file")
typed_line :: proc(c: ^odinsema.Checker, name: string, type: odinsema.Type_Id) -> string {
    if type == odinsema.INVALID_TYPE {
        return name
    }
    return fmt.tprintf("%s: %s", name, odinsema.type_string(&c.table, type, context.temp_allocator))
}

// The symbol of the declaration, field or member whose name is at `decl` of the file at `path`.
@(private = "file")
decl_symbol :: proc(ctx: ^Request_Context, path: string, decl: int) -> (odinsema.Symbol, bool) {
    if decl < 0 {
        return {}, false
    }
    file := ctx.live.id
    if path != ctx.req.path {
        file = odinsema.db_file_id(&ctx.snap, path)
        if file == odinsema.NO_FILE {
            return {}, false
        }
    }
    data := odinsema.db_file(&ctx.snap, file)
    if data == nil {
        return {}, false
    }
    for item, i in data.tree.items {
        if item.name_offset == decl {
            return odinsema.Symbol{file = file, item = i32(i), child = -1}, true
        }
        if decl < item.start || decl >= item.end {
            continue
        }
        for child, j in item.children {
            if child.name_offset == decl {
                return odinsema.Symbol{file = file, item = i32(i), child = i32(j)}, true
            }
        }
    }
    return {}, false
}

// The hover text of a file-scope declaration, field or enum member.
@(private = "file")
symbol_hover :: proc(ctx: ^Request_Context, sym: odinsema.Symbol) -> string {
    data := odinsema.db_file(&ctx.snap, sym.file)
    if data == nil || int(sym.item) >= len(data.tree.items) {
        return ""
    }
    item := &data.tree.items[sym.item]
    if sym.child < 0 {
        return item_text(ctx, item, nil, sym, true)
    }
    if int(sym.child) >= len(item.children) {
        return ""
    }
    return item_text(ctx, &item.children[sym.child], item, sym, true)
}

// The signature of `item` and its doc comment. `owner` is the declaration of a field or member.
@(private = "file")
item_text :: proc(ctx: ^Request_Context, item, owner: ^odinsema.Item, sym: odinsema.Symbol, has_sym: bool) -> string {
    c: ^odinsema.Checker
    if has_sym {
        c = request_checker(ctx)
    }
    sb := strings.builder_make(context.temp_allocator)
    if owner == nil {
        write_attributes(&sb, item.attributes)
    }
    switch item.kind {
    case .Field:
        type := c != nil ? odinsema.decl_type(c, sym) : odinsema.INVALID_TYPE
        if type != odinsema.INVALID_TYPE {
            fmt.sbprintf(&sb, "%s.%s: %s", owner.name, item.name, odinsema.type_string(&c.table, type, context.temp_allocator))
        } else {
            fmt.sbprintf(&sb, "%s.%s%s", owner.name, item.name, signature_tail(item))
        }
    case .Enum_Member:
        fmt.sbprintf(&sb, "%s.%s", owner.name, item.name)
        if value, ok := member_value(c, sym, item.name); ok {
            fmt.sbprintf(&sb, " = %d", value)
        } else {
            strings.write_string(&sb, signature_tail(item))
        }
    case .Var:
        type := c != nil ? odinsema.decl_type(c, sym) : odinsema.INVALID_TYPE
        if type != odinsema.INVALID_TYPE {
            fmt.sbprintf(&sb, "%s: %s", item.name, odinsema.type_string(&c.table, type, context.temp_allocator))
        } else {
            strings.write_string(&sb, item.signature)
        }
    case .Const:
        strings.write_string(&sb, item.signature)
        if c != nil {
            op := odinsema.item_operand(c, sym)
            if op.mode == .Const && op.value != nil {
                value := const_text(c, op.type, op.value)
                if !strings.has_suffix(item.signature, value) {
                    fmt.sbprintf(&sb, " // = %s", value)
                }
            }
        }
    case .Struct, .Enum, .Bit_Field:
        strings.write_string(&sb, item.signature)
        write_children(&sb, item.children)
    case .Union:
        strings.write_string(&sb, item.signature)
        write_variants(&sb, c, sym)
    case .Proc, .Proc_Group, .Bit_Set, .Type, .Import, .Foreign_Import:
        strings.write_string(&sb, item.signature)
    }
    if item.doc != "" {
        strings.write_string(&sb, "\n\n")
        strings.write_string(&sb, item.doc)
    }
    return strings.to_string(sb)
}

// The signature of a field or member after its name: `: int`, ` = 3`.
@(private = "file")
signature_tail :: proc(item: ^odinsema.Item) -> string {
    if i := strings.index_any(item.signature, ":="); i >= 0 {
        if item.signature[i] == '=' {
            return strings.concatenate({" ", item.signature[i:]}, context.temp_allocator)
        }
        return item.signature[i:]
    }
    return ""
}

// The value of the enum member `name` of the type `sym` is a member of.
@(private = "file")
member_value :: proc(c: ^odinsema.Checker, sym: odinsema.Symbol, name: string) -> (i64, bool) {
    if c == nil {
        return 0, false
    }
    type := odinsema.type_base(&c.table, odinsema.decl_type(c, sym))
    e, ok := odinsema.type_get(&c.table, type).(odinsema.Enum_Type)
    if !ok {
        return 0, false
    }
    for m in e.members {
        if m.name == name {
            return m.value, true
        }
    }
    return 0, false
}

// `@(a, b = v)` and a line break; nothing when there are no attributes.
@(private = "file")
write_attributes :: proc(sb: ^strings.Builder, attrs: []odinsema.Item_Attribute) {
    if len(attrs) == 0 {
        return
    }
    strings.write_string(sb, "@(")
    for a, i in attrs {
        if i > 0 {
            strings.write_string(sb, ", ")
        }
        strings.write_string(sb, a.name)
        if a.value != "" {
            strings.write_string(sb, " = ")
            strings.write_string(sb, a.value)
        }
    }
    strings.write_string(sb, ")\n")
}

// ` {` with one line per field or member, then `}`. A field declared with several names is one line.
@(private = "file")
write_children :: proc(sb: ^strings.Builder, children: []odinsema.Item) {
    if len(children) == 0 {
        strings.write_string(sb, " {}")
        return
    }
    strings.write_string(sb, " {\n")
    lines := 0
    last_start := -1
    for &child in children {
        if child.start == last_start {
            continue
        }
        last_start = child.start
        if lines == HOVER_MEMBERS_MAX {
            strings.write_string(sb, HOVER_INDENT)
            strings.write_string(sb, "...\n")
            break
        }
        strings.write_string(sb, HOVER_INDENT)
        strings.write_string(sb, child.signature)
        strings.write_string(sb, ",\n")
        lines += 1
    }
    strings.write_byte(sb, '}')
}

// ` {` with one line per variant of the union `sym` declares, then `}`. Nothing when the checker does not know it.
@(private = "file")
write_variants :: proc(sb: ^strings.Builder, c: ^odinsema.Checker, sym: odinsema.Symbol) {
    if c == nil {
        return
    }
    type := odinsema.type_base(&c.table, odinsema.decl_type(c, sym))
    u, ok := odinsema.type_get(&c.table, type).(odinsema.Union_Type)
    if !ok {
        return
    }
    if len(u.variants) == 0 {
        strings.write_string(sb, " {}")
        return
    }
    strings.write_string(sb, " {\n")
    for v, i in u.variants {
        strings.write_string(sb, HOVER_INDENT)
        if i == HOVER_MEMBERS_MAX {
            strings.write_string(sb, "...\n")
            break
        }
        strings.write_string(sb, odinsema.type_string(&c.table, v, context.temp_allocator))
        strings.write_string(sb, ",\n")
    }
    strings.write_byte(sb, '}')
}

// A constant value as Odin source: an enum value prints as its member.
@(private = "file")
const_text :: proc(c: ^odinsema.Checker, type: odinsema.Type_Id, v: odinsema.Const_Value) -> string {
    switch x in v {
    case i64:
        if e, ok := odinsema.type_get(&c.table, odinsema.type_base(&c.table, type)).(odinsema.Enum_Type); ok {
            for m in e.members {
                if m.value == x {
                    return fmt.tprintf(".%s", m.name)
                }
            }
        }
        return fmt.tprintf("%d", x)
    case f64:
        return fmt.tprintf("%v", x)
    case string:
        return fmt.tprintf("%q", x)
    case bool:
        return x ? "true" : "false"
    case rune:
        return fmt.tprintf("%q", x)
    }
    return ""
}

// The import or foreign import of the buffer whose path holds `offset`; nil when none.
@(private = "file")
import_item_at :: proc(ctx: ^Request_Context, offset: int) -> ^odinsema.Item {
    for &item in ctx.live.tree.items {
        if (item.kind == .Import || item.kind == .Foreign_Import) && item.path_offset >= 0 && item.path_offset <= offset && offset < item.end {
            return &item
        }
    }
    return nil
}

// The type of the expression under the caret, and its range. "" on trivia or a statement keyword.
@(private = "file")
expr_hover :: proc(ctx: ^Request_Context, offset: int) -> (text: string, start, end: int) {
    c := request_checker(ctx)
    if c == nil {
        return
    }
    n, ok := odinsema.expr_under(c, ctx.live.id, offset)
    if !ok {
        return
    }
    op := odinsema.expr_type(c, ctx.live.id, n)
    if op.mode == .Invalid || op.type == odinsema.INVALID_TYPE {
        return
    }
    s, e := odinsyntax.node_range(n)
    type := odinsema.type_string(&c.table, op.type, context.temp_allocator)
    switch {
    case n.green.kind == .Context_Expr:
        text = fmt.tprintf("context: %s", type)
    case op.mode == .Const && op.value != nil:
        text = fmt.tprintf("%s = %s", type, const_text(c, op.type, op.value))
    case:
        text = type
    }
    return text, int(s), int(e)
}
