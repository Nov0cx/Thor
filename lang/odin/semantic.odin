// Semantic tokens: what each identifier of the buffer names, from the scopes of package odinsema
// and, for selectors, implicit selectors, field names and named arguments, from the checker.
package odin

import "core:fmt"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// How many references are classified between two cancel checks.
@(private = "file")
SEMANTIC_CANCEL_STEP :: 512

// The class of a name: its token kind when `emit`; `undeclared` when no scope declares it.
@(private = "file")
Name_Class :: struct {
    kind:       lang.Token_Kind,
    emit:       bool,
    undeclared: bool,
}

// A file-scope declaration of the buffer and whether a `using` brings names into it.
@(private = "file")
Decl_Range :: struct {
    start:     int,
    end:       int,
    has_using: bool,
}

// The state of one semantic tokens request. Everything is temp-allocated.
@(private = "file")
Semantic_Ctx :: struct {
    rc:          ^Request_Context,
    c:           ^odinsema.Checker, // nil when the checker cannot start
    m:           ^odinsema.Scope_Map,
    lo, hi:      int,
    items:       map[int]int, // item index by name offset of the buffer's declarations
    free_memo:   map[string]Name_Class, // a free name names the same declaration in the whole file
    sel_memo:    map[string]Name_Class, // by operand declaration and field name
    decls:       [dynamic]Decl_Range,
    path:        [dynamic]odinsyntax.Syntax_Node,
    tokens:      [dynamic]lang.Semantic_Token,
    undeclared:  bool, // an undeclared name can be marked
}

// Fills res.tokens with the classified identifiers of the buffer, or of [req.offset, req.end) when the request has a range.
@(private)
semantic_tokens :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    rc: Request_Context
    opened := request_open(e, req, &rc)
    defer request_close(&rc)
    if !opened || rc.parsed.tree == nil || rc.parsed.tree.root == nil {
        return
    }
    lo, hi := 0, len(req.source)
    if req.end > req.offset {
        lo, hi = clamp(req.offset, 0, len(req.source)), clamp(req.end, 0, len(req.source))
    }
    m, merr := odinsema.scope_map_range(rc.parsed, lo, hi, context.temp_allocator)
    if merr != nil {
        return
    }
    defer odinsema.scope_map_destroy(m, context.temp_allocator)

    ctx := Semantic_Ctx {
        rc        = &rc,
        c         = request_checker(&rc),
        m         = m,
        lo        = lo,
        hi        = hi,
        items     = make(map[int]int, len(rc.live.tree.items), context.temp_allocator),
        free_memo = make(map[string]Name_Class, 256, context.temp_allocator),
        sel_memo  = make(map[string]Name_Class, 256, context.temp_allocator),
        decls     = make([dynamic]Decl_Range, context.temp_allocator),
        path      = make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator),
        tokens    = make([dynamic]lang.Semantic_Token, 0, len(m.refs), context.temp_allocator),
    }
    for item, i in rc.live.tree.items {
        ctx.items[item.name_offset] = i
    }
    collect_decls(&ctx)
    ctx.undeclared = undeclared_allowed(&ctx)

    for ref, i in m.refs {
        if i % SEMANTIC_CANCEL_STEP == 0 && lang.request_cancelled(req) {
            return
        }
        if ref.end <= lo || ref.start >= hi || ref.kind == .None {
            continue
        }
        if class := classify_ref(&ctx, i); class.emit {
            append(&ctx.tokens, lang.Semantic_Token{ref.start, ref.end, class.kind})
        }
    }
    if lang.request_cancelled(req) {
        return
    }

    // The walk declares a name after its type and value, so the order is not by offset.
    slice.sort_by(ctx.tokens[:], proc(a, b: lang.Semantic_Token) -> bool {
        return a.start < b.start
    })
    res.tokens = make([dynamic]lang.Semantic_Token, 0, len(ctx.tokens))
    cut := 0
    for tok in ctx.tokens {
        if tok.start < cut {
            continue
        }
        append(&res.tokens, tok)
        cut = tok.end
    }
    res.ok = len(res.tokens) > 0
}

// The class of reference `i` of the scope map.
@(private = "file")
classify_ref :: proc(ctx: ^Semantic_Ctx, i: int) -> Name_Class {
    ref := ctx.m.refs[i]
    switch ref.kind {
    case .None:
    case .Local:
        if ref.decl < 0 {
            return {}
        }
        return local_class(ctx, ref.decl_kind, odinsema.local_symbol(ctx.rc.live.id, ref.decl))
    case .Top_Level:
        return top_level_class(ctx, ref)
    case .Member_Decl:
        return member_decl_class(ctx, ref.start)
    case .Free:
        class := free_class(ctx, ref.name)
        if class.undeclared {
            if ctx.undeclared && undeclared_at(ctx, ref.start, ref.name) {
                return {kind = .Unresolved, emit = true}
            }
            return {}
        }
        return class
    case .Package_Qualified:
        key := strings.concatenate({"F|", ref.operand, "|", ref.name}, context.temp_allocator)
        if class, ok := ctx.sel_memo[key]; ok {
            return class
        }
        class, found := package_member_class(ctx, ref.operand, ref.name)
        if !found {
            class = typed_class(ctx, ref.start)
        }
        ctx.sel_memo[key] = class
        return class
    case .Field_Or_Member:
        if key, ok := selector_key(ctx, i); ok {
            return memo_selector(ctx, key, ref.start)
        }
        return typed_class(ctx, ref.start)
    case .Implicit_Selector, .Field_Name:
        return typed_class(ctx, ref.start)
    }
    return {}
}

// The memo key of the selector name at ref `i` when its operand is a chain of names `a.b.c` whose
// head is a local or a free name.
@(private = "file")
selector_key :: proc(ctx: ^Semantic_Ctx, i: int) -> (string, bool) {
    ref := ctx.m.refs[i]
    src := ctx.rc.req.source
    if ref.operand_start < 0 || ref.operand_end > len(src) || ref.operand_start >= ref.operand_end {
        return "", false
    }
    text := src[ref.operand_start:ref.operand_end]
    for ch in transmute([]byte)text {
        if !(ch == '.' || ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
            return "", false
        }
    }
    head := -1
    for k := i - 1; k >= 0 && ctx.m.refs[k].start >= ref.operand_start; k -= 1 {
        if ctx.m.refs[k].start == ref.operand_start {
            head = k
            break
        }
    }
    if head < 0 {
        return "", false
    }
    h := ctx.m.refs[head]
    #partial switch h.kind {
    case .Local:
        // A switch variable takes another type in each case clause.
        if h.decl < 0 || h.decl_kind == .Switch_Var {
            return "", false
        }
        return fmt.tprintf("L%d|%s|%s", h.decl, text, ref.name), true
    case .Free:
        return strings.concatenate({"F|", text, "|", ref.name}, context.temp_allocator), true
    }
    return "", false
}

// The class of `alias.name` when `alias` is an import of the buffer, from the item trees of the package.
// False when `alias` is no import, or the package declares no active `name`.
@(private = "file")
package_member_class :: proc(ctx: ^Semantic_Ctx, alias, name: string) -> (Name_Class, bool) {
    dir, is_import := import_alias_dir(ctx.rc, alias)
    if !is_import || dir == "" {
        return {}, false
    }
    view := request_package(ctx.rc, dir)
    if view == nil || view.scope == nil {
        return {}, false
    }
    for ref in odinsema.package_scope_lookup(view.scope, name) {
        item := odinsema.package_item(view.sema_files, ref)
        if item.visibility != .Public || !odinsema.package_ref_active(view.scope, ref) {
            continue
        }
        if item.kind == .Const {
            if ctx.c == nil {
                return {}, true
            }
            return const_class(ctx, odinsema.Symbol{view.files[ref.file], i32(ref.item), -1}), true
        }
        return item_class(ctx, {}, item), true
    }
    return {}, false
}

@(private = "file")
memo_selector :: proc(ctx: ^Semantic_Ctx, key: string, offset: int) -> Name_Class {
    if class, ok := ctx.sel_memo[key]; ok {
        return class
    }
    class := typed_class(ctx, offset)
    ctx.sel_memo[key] = class
    return class
}

// The class of the name at `offset` that the checker types through its operand or its context.
@(private = "file")
typed_class :: proc(ctx: ^Semantic_Ctx, offset: int) -> Name_Class {
    if ctx.c == nil {
        return {}
    }
    sym, ok := odinsema.selector_symbol(ctx.c, ctx.rc.live.id, offset)
    if !ok {
        return {}
    }
    return symbol_class(ctx, sym)
}

// The class of the declaration `sym`.
@(private = "file")
symbol_class :: proc(ctx: ^Semantic_Ctx, sym: odinsema.Symbol) -> Name_Class {
    c := ctx.c
    if sym.item == odinsema.LOCAL_ITEM {
        offset := int(sym.child)
        if l, ok := odinsema.local_at(c, sym.file, offset); ok {
            return local_class(ctx, l.kind, sym)
        }
        // A member of a record declared in a procedure body.
        if sym.file == ctx.rc.live.id && member_decl_is_enum(ctx, offset) {
            return {kind = .Enum_Member, emit = true}
        }
        type := odinsema.decl_type(c, sym)
        if is_proc_type(c, type) {
            return {kind = .Procedure, emit = true}
        }
        if odinsema.type_kind(&c.table, odinsema.type_base(&c.table, type)) == .Enum {
            return {}
        }
        return {kind = .Field, emit = true}
    }
    item := odinsema.checker_item(c, sym)
    if item == nil {
        return {}
    }
    if sym.child >= 0 {
        #partial switch item.kind {
        case .Enum_Member:
            return {kind = .Enum_Member, emit = true}
        case .Field:
            if is_proc_type(c, odinsema.decl_type(c, sym)) {
                return {kind = .Procedure, emit = true}
            }
            return {kind = .Field, emit = true}
        }
        return {}
    }
    return item_class(ctx, sym, item)
}

// The class of the field or enum member declared at `offset` of the buffer.
@(private = "file")
member_decl_class :: proc(ctx: ^Semantic_Ctx, offset: int) -> Name_Class {
    if member_decl_is_enum(ctx, offset) {
        return {kind = .Enum_Member, emit = true}
    }
    // Read from the syntax: typing the field types the whole record and every type it names.
    #reverse for n in ctx.path {
        f, is_field := odinsyntax.as_field(n)
        if !is_field {
            continue
        }
        if type, ok := odinsyntax.field_type(&f); ok && proc_type_syntax(ctx, type) {
            return {kind = .Procedure, emit = true}
        }
        break
    }
    return {kind = .Field, emit = true}
}

// True when a type expression is a procedure type, or names a type of the buffer declared as one.
@(private = "file")
proc_type_syntax :: proc(ctx: ^Semantic_Ctx, type: odinsyntax.Syntax_Node) -> bool {
    text := odinsyntax.node_text(type)
    if is_proc_text(text) {
        return true
    }
    if type.green.kind != .Ident {
        return false
    }
    src := ctx.rc.req.source
    for item in ctx.rc.live.tree.items {
        if item.name == text && item.kind == .Type && item.value_offset >= 0 && item.value_offset < len(src) {
            return is_proc_text(src[item.value_offset:])
        }
    }
    return false
}

@(private = "file")
is_proc_text :: proc(source: string) -> bool {
    text := strings.trim_prefix(source, "#type")
    text = strings.trim_left_space(text)
    if !strings.has_prefix(text, "proc") {
        return false
    }
    rest := text[len("proc"):]
    return rest == "" || rest[0] == '(' || rest[0] == ' ' || rest[0] == '"'
}

// The class of a file-scope declaration. A variable and a constant value get none.
@(private = "file")
item_class :: proc(ctx: ^Semantic_Ctx, sym: odinsema.Symbol, item: ^odinsema.Item) -> Name_Class {
    switch item.kind {
    case .Proc, .Proc_Group:
        return {kind = .Procedure, emit = true}
    case .Struct, .Enum, .Union, .Bit_Set, .Bit_Field, .Type:
        return {kind = .Type, emit = true}
    case .Import, .Foreign_Import:
        return {kind = .Package, emit = true}
    case .Const:
        return const_class(ctx, sym)
    case .Var, .Field, .Enum_Member:
    }
    return {}
}

// The class of a constant: a type, a procedure, or none for a value.
@(private = "file")
const_class :: proc(ctx: ^Semantic_Ctx, sym: odinsema.Symbol) -> Name_Class {
    c := ctx.c
    if c == nil {
        return {}
    }
    if odinsema.decl_is_type(c, sym) {
        return {kind = .Type, emit = true}
    }
    if is_proc_type(c, odinsema.decl_type(c, sym)) {
        return {kind = .Procedure, emit = true}
    }
    return {}
}

// The class of a local declared as `kind`.
@(private = "file")
local_class :: proc(ctx: ^Semantic_Ctx, kind: odinsema.Decl_Kind, sym: odinsema.Symbol) -> Name_Class {
    switch kind {
    case .Param, .Result:
        return {kind = .Parameter, emit = true}
    case .Var, .Loop_Var, .Switch_Var:
        return {kind = .Local, emit = true}
    case .Proc:
        return {kind = .Procedure, emit = true}
    case .Type:
        return {kind = .Type, emit = true}
    case .Const:
        return const_class(ctx, sym)
    case .Poly:
        // `$T` and `$T: typeid` name a type; `$N: int` names a value.
        if ctx.c != nil && !odinsema.decl_is_type(ctx.c, sym) && odinsema.decl_type(ctx.c, sym) != odinsema.INVALID_TYPE {
            return {kind = .Parameter, emit = true}
        }
        return {kind = .Type, emit = true}
    case .Import:
        return {kind = .Package, emit = true}
    case .Label:
    }
    return {}
}

// The class of the declaration name of a file-scope declaration.
@(private = "file")
top_level_class :: proc(ctx: ^Semantic_Ctx, ref: odinsema.Name_Ref) -> Name_Class {
    #partial switch ref.decl_kind {
    case .Proc:
        return {kind = .Procedure, emit = true}
    case .Type:
        return {kind = .Type, emit = true}
    case .Import:
        return {kind = .Package, emit = true}
    case .Const:
        index, ok := ctx.items[ref.start]
        if !ok {
            return {}
        }
        return const_class(ctx, odinsema.Symbol{ctx.rc.live.id, i32(index), -1})
    }
    return {}
}

// The class of a free name, memoized: a free name names the same declaration in the whole file.
@(private = "file")
free_class :: proc(ctx: ^Semantic_Ctx, name: string) -> Name_Class {
    if class, ok := ctx.free_memo[name]; ok {
        return class
    }
    class := free_class_uncached(ctx, name)
    ctx.free_memo[name] = class
    return class
}

@(private = "file")
free_class_uncached :: proc(ctx: ^Semantic_Ctx, name: string) -> Name_Class {
    for item in ctx.rc.live.tree.items {
        if item.name == name && (item.kind == .Import || item.kind == .Foreign_Import) {
            return {kind = .Package, emit = true}
        }
    }
    c := ctx.c
    if c == nil {
        for &item in ctx.rc.live.tree.items {
            if item.name == name {
                return item_class(ctx, {}, &item)
            }
        }
        return {}
    }
    r := odinsema.lookup_name(c, ctx.rc.live.id, name, -1)
    #partial switch r.kind {
    case .None:
        return {undeclared = true}
    case .Import:
        return {kind = .Package, emit = true}
    case .Item:
        if r.universe {
            return {}
        }
        item := odinsema.checker_item(c, r.symbol)
        if item == nil {
            return {}
        }
        return item_class(ctx, r.symbol, item)
    }
    return {}
}

// True when the type of a value is a procedure or a procedure group.
@(private = "file")
is_proc_type :: proc(c: ^odinsema.Checker, type: odinsema.Type_Id) -> bool {
    if type == odinsema.INVALID_TYPE {
        return false
    }
    kind := odinsema.type_kind(&c.table, odinsema.type_base(&c.table, type))
    return kind == .Proc || kind == .Proc_Group
}

// The file-scope declarations of the buffer, each marked when a `using` statement or a `using`
// local is in it.
@(private = "file")
collect_decls :: proc(ctx: ^Semantic_Ctx) {
    root := odinsyntax.node_root(ctx.rc.parsed.tree)
    pos := int(root.offset)
    for child in odinsyntax.green_children(root.green) {
        n := int(odinsyntax.element_len(child))
        if _, is_node := odinsyntax.element_node(child); is_node {
            append(&ctx.decls, Decl_Range{start = pos, end = pos + n})
        }
        pos += n
    }
    for u in ctx.m.usings {
        if d := decl_at(ctx, u.start); d != nil {
            d.has_using = true
        }
    }
    for l in ctx.m.locals {
        if l.is_using {
            if d := decl_at(ctx, l.name_offset); d != nil {
                d.has_using = true
            }
        }
    }
}

@(private = "file")
decl_at :: proc(ctx: ^Semantic_Ctx, offset: int) -> ^Decl_Range {
    i, _ := slice.binary_search_by(ctx.decls[:], offset, proc(d: Decl_Range, offset: int) -> slice.Ordering {
        if d.end <= offset {
            return .Less
        }
        if d.start > offset {
            return .Greater
        }
        return .Equal
    })
    if i < len(ctx.decls) && ctx.decls[i].start <= offset && offset < ctx.decls[i].end {
        return &ctx.decls[i]
    }
    return nil
}

// True when the scopes can prove a name undeclared: a buffer with a file in a workspace whose
// package and universe scope can be read.
@(private = "file")
undeclared_allowed :: proc(ctx: ^Semantic_Ctx) -> bool {
    rc := ctx.rc
    if ctx.c == nil || rc.req.path == "" || rc.req.workspace == "" {
        return false
    }
    if request_package(rc, live_dir(rc)) == nil {
        return false
    }
    // An Odin root with no base:builtin leaves every builtin undeclared.
    for name in ([]string{"len", "make"}) {
        if odinsema.lookup_name(ctx.c, rc.live.id, name, -1).kind != .Item {
            return false
        }
    }
    return true
}

// True when the free name at `offset` is undeclared at that position: no `using` can bring it in,
// no directive or `offset_of` reads it as a name, and no file of the package declares it.
@(private = "file")
undeclared_at :: proc(ctx: ^Semantic_Ctx, offset: int, name: string) -> bool {
    d := decl_at(ctx, offset)
    if d == nil || d.has_using {
        return false
    }
    node_path_to(ctx, offset)
    for n in ctx.path {
        #partial switch n.green.kind {
        case .Asm_Template, .Asm_Group, .Asm_Directive:
            return false
        case .Call_Expr:
            call, _ := odinsyntax.as_call_expr(n)
            callee, ok := odinsyntax.call_expr_callee(&call)
            if !ok {
                return false
            }
            if callee.green.kind == .Directive || strings.has_prefix(odinsyntax.node_text(callee), "offset_of") {
                return false
            }
        }
    }
    rc := ctx.rc
    cands := make([dynamic]Def_Candidate, context.temp_allocator)
    package_candidates(rc, live_dir(rc), name, "", true, &cands)
    if len(cands) > 0 {
        return false
    }
    return builtin_candidates(rc, name, &cands) == ""
}

// Fills ctx.path with the nodes from the root down to the innermost node that holds byte `offset`.
@(private = "file")
node_path_to :: proc(ctx: ^Semantic_Ctx, offset: int) {
    clear(&ctx.path)
    cur := odinsyntax.node_root(ctx.rc.parsed.tree)
    off := u32(offset)
    for {
        append(&ctx.path, cur)
        pos := cur.offset
        next: ^odinsyntax.Green_Node
        next_pos: u32
        for child in odinsyntax.green_children(cur.green) {
            child_len := odinsyntax.element_len(child)
            if off >= pos && off < pos + child_len {
                if g, is_node := odinsyntax.element_node(child); is_node {
                    next, next_pos = g, pos
                }
                break
            }
            pos += child_len
        }
        if next == nil {
            return
        }
        cur = odinsyntax.Syntax_Node{next, next_pos, nil, cur.tree}
    }
}

// True when the member declared at `offset` of the buffer is an enum member, not a field.
@(private = "file")
member_decl_is_enum :: proc(ctx: ^Semantic_Ctx, offset: int) -> bool {
    node_path_to(ctx, offset)
    #reverse for n in ctx.path {
        #partial switch n.green.kind {
        case .Enum_Type:
            return true
        case .Struct_Type, .Union_Type, .Bit_Field_Type:
            return false
        }
    }
    return false
}
