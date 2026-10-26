package odinsema

import "core:mem"
import "core:mem/virtual"

import odinsyntax "../syntax"

// What a name declares.
Decl_Kind :: enum u8 {
    Var,
    Const,
    Proc,
    Type,
    Param,
    Result,     // a named result
    Loop_Var,   // a `for ... in` variable
    Switch_Var, // the `v` of `switch v in u`; one declaration for every case clause
    Label,
    Poly,       // `$T` or `$N`
    Import,
}

// What an identifier names, as far as the lexical scopes tell.
Name_Ref_Kind :: enum u8 {
    None,              // not on an identifier, or a name that names nothing (`_`, an attribute name)
    Local,             // a declaration in a procedure, a signature or a record
    Top_Level,         // the name of a file-scope declaration, where it is declared
    Member_Decl,       // a struct or bit_field field, or an enum member, where it is declared
    Field_Or_Member,   // the right side of a selector whose operand is not a free name
    Implicit_Selector, // `.Member`
    Field_Name,        // `Foo{x = 1}` or the named argument of `f(x = 1)`
    Package_Qualified, // `pkg.name` where `pkg` is a free name
    Free,              // a file, package, import or builtin name the caller looks up
}

// One identifier and what it names. Strings borrow the text of the parse.
Name_Ref :: struct {
    kind:          Name_Ref_Kind,
    name:          string,
    start:         int, // the identifier
    end:           int,
    decl:          int, // Local and Top_Level: the name offset of the declaration; -1 otherwise
    decl_kind:     Decl_Kind,
    is_decl:       bool, // the identifier is the name of its declaration
    is_using:      bool, // Local: the declaration has `using`
    operand_start: int, // Field_Or_Member and Package_Qualified: the operand; Field_Name: the literal type or callee; -1 when none
    operand_end:   int,
    operand:       string, // Package_Qualified: the package name
}

// How a local takes its value from `value_offset`.
Local_Source :: enum u8 {
    Value,       // the value, or result `value_index` of a multi-value value
    Range,       // an element of the iterated value; `value_index` is the position of the name in the variables
    Type_Switch, // the subject, narrowed to the type of each case clause
}

// A name declared in a procedure, a signature or a record.
Local :: struct {
    name:         string,
    kind:         Decl_Kind,
    name_offset:  int,
    scope:        int,
    is_using:     bool,
    type_offset:  int, // the type expression; -1 when absent
    value_offset: int, // the value expression or default; -1 when absent
    value_index:  int, // see Local_Source; -1 when the value is the name's own
    source:       Local_Source,
}

// The type and value a declaration gives a local.
@(private = "file")
Local_Value :: struct {
    type_offset:  int,
    value_offset: int,
    value_index:  int,
    source:       Local_Source,
}

@(private = "file")
NO_VALUE :: Local_Value{-1, -1, -1, .Value}

// A lexical scope. A procedure literal, a procedure type and a record open a new procedure level:
// the variables, parameters and labels of a lower level are not visible in it.
Scope :: struct {
    parent:     int, // -1 at file scope
    start:      int,
    end:        int,
    proc_depth: int,
}

// A `using` statement operand. The lexical pass does not expand it; using_lookup does.
Using_Entry :: struct {
    start: int,
    end:   int,
    scope: int,
}

// The scopes, local declarations and identifier references of a parsed file, or of its declarations
// that touch a range. Everything is in `arena`; strings borrow the text of the parse.
Scope_Map :: struct {
    arena:     virtual.Arena,
    scopes:    []Scope,
    locals:    []Local,
    refs:      []Name_Ref, // one per identifier, in walk order
    usings:    []Using_Entry,
    has_using: bool, // a `using` statement or a `using` local is in the map
}

@(private = "file")
SCOPE_ARENA_BLOCK :: 16 * mem.Kilobyte

@(private = "file")
ALL_KINDS :: ~odinsyntax.Kind_Set{}

@(private = "file")
Walker :: struct {
    scopes:     [dynamic]Scope,
    locals:     [dynamic]Local,
    refs:       [dynamic]Name_Ref,
    usings:     [dynamic]Using_Entry,
    active:     [dynamic]int, // the locals in reach, innermost last
    cur:        int,          // the current scope; -1 at file scope
    proc_depth: int,
    err:        mem.Allocator_Error,
}

@(private = "file")
Scope_Mark :: struct {
    active:     int,
    cur:        int,
    proc_depth: int,
}

// The scope map of the whole file.
scope_map :: proc(parsed: odinsyntax.Parse, allocator := context.allocator) -> (m: ^Scope_Map, err: mem.Allocator_Error) {
    return scope_map_range(parsed, 0, max(int), allocator)
}

// The scope map of the file-scope declarations that touch [start, end]. A local is declared and
// used inside one file-scope declaration, so this is enough to resolve the names in the range.
scope_map_range :: proc(parsed: odinsyntax.Parse, start, end: int, allocator := context.allocator) -> (m: ^Scope_Map, err: mem.Allocator_Error) {
    m = new(Scope_Map, allocator) or_return
    if err = virtual.arena_init_growing(&m.arena, SCOPE_ARENA_BLOCK); err != nil {
        free(m, allocator)
        return nil, err
    }
    if parsed.tree == nil || parsed.tree.root == nil {
        return m, nil
    }
    alloc := virtual.arena_allocator(&m.arena)
    w := Walker {
        scopes = make([dynamic]Scope, alloc),
        locals = make([dynamic]Local, alloc),
        refs   = make([dynamic]Name_Ref, alloc),
        usings = make([dynamic]Using_Entry, alloc),
        active = make([dynamic]int, alloc),
        cur    = -1,
    }
    root := odinsyntax.node_root(parsed.tree)
    it := odinsyntax.child_iter(&root, {kinds = ALL_KINDS})
    for child in odinsyntax.child_iter_next(&it) {
        cs, ce := odinsyntax.node_range(child)
        if int(ce) < start || int(cs) > end {
            continue
        }
        walk(&w, child)
    }
    if w.err != nil {
        scope_map_destroy(m, allocator)
        return nil, w.err
    }
    m.scopes = w.scopes[:]
    m.locals = w.locals[:]
    m.refs = w.refs[:]
    m.usings = w.usings[:]
    m.has_using = len(w.usings) > 0
    for l in w.locals {
        if l.is_using {
            m.has_using = true
            break
        }
    }
    return m, nil
}

scope_map_destroy :: proc(m: ^Scope_Map, allocator := context.allocator) {
    if m == nil {
        return
    }
    virtual.arena_destroy(&m.arena)
    free(m, allocator)
}

@(private = "file")
note_err :: proc(w: ^Walker, err: mem.Allocator_Error) {
    if err != nil && w.err == nil {
        w.err = err
    }
}

@(private = "file")
open_scope :: proc(w: ^Walker, n: odinsyntax.Syntax_Node, new_proc := false) -> Scope_Mark {
    mark := Scope_Mark{len(w.active), w.cur, w.proc_depth}
    if new_proc {
        w.proc_depth += 1
    }
    start, end := odinsyntax.node_range(n)
    _, err := append(&w.scopes, Scope{parent = w.cur, start = int(start), end = int(end), proc_depth = w.proc_depth})
    if err != nil {
        note_err(w, err)
        return mark
    }
    w.cur = len(w.scopes) - 1
    return mark
}

@(private = "file")
close_scope :: proc(w: ^Walker, mark: Scope_Mark) {
    resize(&w.active, mark.active)
    w.cur = mark.cur
    w.proc_depth = mark.proc_depth
}

@(private = "file")
base_ref :: proc(n: odinsyntax.Syntax_Node) -> Name_Ref {
    start, end := odinsyntax.node_range(n)
    return Name_Ref {
        name          = odinsyntax.node_text(n),
        start         = int(start),
        end           = int(end),
        decl          = -1,
        operand_start = -1,
        operand_end   = -1,
    }
}

@(private = "file")
add_ref :: proc(w: ^Walker, ref: Name_Ref) {
    _, err := append(&w.refs, ref)
    note_err(w, err)
}

// Declares the identifier `n` in the current scope and records its name as a reference to itself.
// With `push` false the local stays out of reach until the caller pushes it.
@(private = "file")
declare :: proc(w: ^Walker, n: odinsyntax.Syntax_Node, kind: Decl_Kind, is_using := false, push := true, value := NO_VALUE) -> int {
    ref := base_ref(n)
    if ref.name == "_" {
        add_ref(w, ref)
        return -1
    }
    ref.decl = ref.start
    ref.decl_kind = kind
    ref.is_decl = true
    ref.is_using = is_using
    if w.cur < 0 {
        ref.kind = .Top_Level
        add_ref(w, ref)
        return -1
    }
    ref.kind = .Local
    local := Local {
        name         = ref.name,
        kind         = kind,
        name_offset  = ref.start,
        scope        = w.cur,
        is_using     = is_using,
        type_offset  = value.type_offset,
        value_offset = value.value_offset,
        value_index  = value.value_index,
        source       = value.source,
    }
    if _, err := append(&w.locals, local); err != nil {
        note_err(w, err)
        return -1
    }
    index := len(w.locals) - 1
    if push {
        _, err := append(&w.active, index)
        note_err(w, err)
    }
    add_ref(w, ref)
    return index
}

// Whether the name at `offset` was declared ahead of its statement (a hoisted constant, a `$T`).
@(private = "file")
predeclared :: proc(w: ^Walker, offset: int) -> bool {
    #reverse for index in w.active {
        if w.locals[index].name_offset == offset {
            return true
        }
    }
    return false
}

@(private = "file")
var_like :: proc(kind: Decl_Kind) -> bool {
    #partial switch kind {
    case .Var, .Param, .Result, .Loop_Var, .Switch_Var, .Label:
        return true
    }
    return false
}

// The innermost local in reach named `name`, or -1. Labels and other names do not see each other.
@(private = "file")
lookup :: proc(w: ^Walker, name: string, label: bool) -> int {
    #reverse for index in w.active {
        l := &w.locals[index]
        if (l.kind == .Label) != label || l.name != name {
            continue
        }
        if var_like(l.kind) && w.scopes[l.scope].proc_depth < w.proc_depth {
            continue
        }
        return index
    }
    return -1
}

@(private = "file")
use_ident :: proc(w: ^Walker, n: odinsyntax.Syntax_Node, label := false) {
    ref := base_ref(n)
    if ref.name == "_" {
        add_ref(w, ref)
        return
    }
    index := lookup(w, ref.name, label)
    if index < 0 {
        ref.kind = .Free
        add_ref(w, ref)
        return
    }
    l := w.locals[index]
    ref.kind = .Local
    ref.decl = l.name_offset
    ref.decl_kind = l.kind
    ref.is_using = l.is_using
    add_ref(w, ref)
}

@(private = "file")
walk_children :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    n := n
    it := odinsyntax.child_iter(&n, {kinds = ALL_KINDS})
    for child in odinsyntax.child_iter_next(&it) {
        walk(w, child)
    }
}

@(private = "file")
walk :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    if w.err != nil {
        return
    }
    n := n
    #partial switch n.green.kind {
    case .Ident:
        use_ident(w, n)
    case .Package_Decl:
        if name, ok := odinsyntax.find_child_node(&n, {kinds = {.Ident}}); ok {
            add_ref(w, base_ref(name))
        }
    case .Value_Decl:
        walk_value_decl(w, n)
    case .Import_Decl:
        imp, _ := odinsyntax.as_import_decl(n)
        if alias, ok := odinsyntax.import_decl_alias(&imp); ok {
            declare(w, odinsyntax.Syntax_Node(alias), .Import)
        }
    case .Foreign_Import_Decl:
        fi, _ := odinsyntax.as_foreign_import_decl(n)
        if name, ok := odinsyntax.foreign_import_decl_name(&fi); ok {
            declare(w, odinsyntax.Syntax_Node(name), .Import)
        }
        paths := odinsyntax.foreign_import_decl_paths(&fi)
        for p in odinsyntax.child_iter_next(&paths) {
            walk(w, p)
        }
    case .Foreign_Block:
        walk_foreign_block(w, n)
    case .Attribute:
        walk_attribute(w, n)
    case .Block, .Do_Body, .Case_Clause:
        mark := open_scope(w, n)
        hoist(w, n)
        walk_children(w, n)
        close_scope(w, mark)
    case .If_Stmt, .For_Stmt, .Switch_Stmt:
        mark := open_scope(w, n)
        walk_children(w, n)
        close_scope(w, mark)
    case .Range_Stmt:
        walk_range(w, n)
    case .Type_Switch_Stmt:
        walk_type_switch(w, n)
    case .When_Stmt:
        walk_when(w, n)
    case .Label:
        lbl, _ := odinsyntax.as_label(n)
        if name, ok := odinsyntax.label_name(&lbl); ok {
            declare(w, odinsyntax.Syntax_Node(name), .Label)
        }
    case .Branch_Stmt:
        br, _ := odinsyntax.as_branch_stmt(n)
        if name, ok := odinsyntax.branch_stmt_label(&br); ok {
            use_ident(w, odinsyntax.Syntax_Node(name), true)
        }
    case .Or_Branch_Expr:
        ob, _ := odinsyntax.as_or_branch_expr(n)
        if operand, ok := odinsyntax.or_branch_expr_operand(&ob); ok {
            walk(w, operand)
        }
        if name, ok := odinsyntax.or_branch_expr_label(&ob); ok {
            use_ident(w, odinsyntax.Syntax_Node(name), true)
        }
    case .Using_Stmt:
        us, _ := odinsyntax.as_using_stmt(n)
        if exprs, ok := odinsyntax.using_stmt_exprs(&us); ok {
            items := odinsyntax.expr_list_items(&exprs)
            for item in odinsyntax.child_iter_next(&items) {
                start, end := odinsyntax.node_range(item)
                _, err := append(&w.usings, Using_Entry{int(start), int(end), w.cur})
                note_err(w, err)
                walk(w, item)
            }
        }
    case .Proc_Lit:
        mark := open_scope(w, n, true)
        it := odinsyntax.child_iter(&n, {kinds = ALL_KINDS})
        for child in odinsyntax.child_iter_next(&it) {
            if child.green.kind == .Proc_Type {
                walk_signature(w, child)
            } else {
                walk(w, child)
            }
        }
        close_scope(w, mark)
    case .Proc_Type:
        mark := open_scope(w, n, true)
        walk_signature(w, n)
        close_scope(w, mark)
    case .Struct_Type, .Union_Type:
        walk_record(w, n)
    case .Enum_Type:
        walk_enum(w, n)
    case .Bit_Field_Type:
        walk_bit_field(w, n)
    case .Poly_Type:
        pt, _ := odinsyntax.as_poly_type(n)
        if name, ok := odinsyntax.poly_type_name(&pt); ok && !predeclared(w, int(name.offset)) {
            declare(w, odinsyntax.Syntax_Node(name), .Poly)
        }
        if spec, ok := odinsyntax.poly_type_specialization(&pt); ok {
            walk(w, spec)
        }
    case .Selector_Expr:
        walk_selector(w, n)
    case .Implicit_Selector:
        is, _ := odinsyntax.as_implicit_selector(n)
        if field, ok := odinsyntax.implicit_selector_field(&is); ok {
            ref := base_ref(odinsyntax.Syntax_Node(field))
            ref.kind = .Implicit_Selector
            add_ref(w, ref)
        }
    case .Comp_Lit:
        cl, _ := odinsyntax.as_comp_lit(n)
        op_start, op_end := -1, -1
        if type, ok := odinsyntax.comp_lit_type(&cl); ok {
            walk(w, type)
            s, e := odinsyntax.node_range(type)
            op_start, op_end = int(s), int(e)
        }
        elems := odinsyntax.comp_lit_elems(&cl)
        for elem in odinsyntax.child_iter_next(&elems) {
            walk_elem(w, elem, op_start, op_end)
        }
    case .Call_Expr:
        call, _ := odinsyntax.as_call_expr(n)
        op_start, op_end := -1, -1
        if callee, ok := odinsyntax.call_expr_callee(&call); ok {
            walk(w, callee)
            s, e := odinsyntax.node_range(callee)
            op_start, op_end = int(s), int(e)
        }
        if args, ok := odinsyntax.call_expr_args(&call); ok {
            it := odinsyntax.arg_list_args(&args)
            for arg in odinsyntax.child_iter_next(&it) {
                walk_elem(w, arg, op_start, op_end)
            }
        }
    case .Field_Value:
        walk_elem(w, n, -1, -1)
    case:
        walk_children(w, n)
    }
}

// Walks an element of a literal or an argument list. The name of a `name = value` element is a
// field or parameter name of the literal type or callee at [op_start, op_end).
@(private = "file")
walk_elem :: proc(w: ^Walker, n: odinsyntax.Syntax_Node, op_start, op_end: int) {
    fv, is_fv := odinsyntax.as_field_value(n)
    if !is_fv {
        walk(w, n)
        return
    }
    if name, ok := odinsyntax.field_value_name(&fv); ok {
        if name.green.kind == .Ident {
            ref := base_ref(name)
            ref.kind = .Field_Name
            ref.operand_start, ref.operand_end = op_start, op_end
            add_ref(w, ref)
        } else {
            walk(w, name)
        }
    }
    if value, ok := odinsyntax.field_value_value(&fv); ok {
        walk(w, value)
    }
}

@(private = "file")
walk_selector :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    sel, _ := odinsyntax.as_selector_expr(n)
    operand, has_operand := odinsyntax.selector_expr_operand(&sel)
    operand_free := false
    if has_operand {
        walk(w, operand)
        if operand.green.kind == .Ident && len(w.refs) > 0 {
            last := w.refs[len(w.refs) - 1]
            operand_free = last.kind == .Free && last.start == int(operand.offset)
        }
    }
    field, has_field := odinsyntax.selector_expr_field(&sel)
    if !has_field {
        return
    }
    ref := base_ref(odinsyntax.Syntax_Node(field))
    ref.kind = .Field_Or_Member
    if has_operand {
        s, e := odinsyntax.node_range(operand)
        ref.operand_start, ref.operand_end = int(s), int(e)
    }
    _, arrow := odinsyntax.selector_expr_arrow(&sel)
    if operand_free && !arrow {
        ref.kind = .Package_Qualified
        ref.operand = odinsyntax.node_text(operand)
    }
    add_ref(w, ref)
}

@(private = "file")
walk_attribute :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    attr, _ := odinsyntax.as_attribute(n)
    elems := odinsyntax.attribute_elems(&attr)
    for elem in odinsyntax.child_iter_next(&elems) {
        fv, ok := odinsyntax.as_field_value(elem)
        if !ok {
            continue
        }
        if value, vok := odinsyntax.field_value_value(&fv); vok {
            walk(w, value)
        }
    }
}

// Whether a Value_Decl declares constants: `::` or `: T :`.
@(private = "file")
is_constant_decl :: proc(n: odinsyntax.Syntax_Node) -> bool {
    colons := 0
    for child in odinsyntax.green_children(n.green) {
        if tok, ok := odinsyntax.element_token(child); ok && tok.kind == .Colon {
            colons += 1
        }
    }
    return colons >= 2
}

@(private = "file")
classify_value :: proc(value: odinsyntax.Syntax_Node) -> Decl_Kind {
    value := value
    if value.green.kind == .Tag_Expr {
        tag, _ := odinsyntax.as_tag_expr(value)
        if inner, ok := odinsyntax.tag_expr_expr(&tag); ok {
            return classify_value(inner)
        }
    }
    kind := value.green.kind
    if kind == .Proc_Lit || kind == .Proc_Group {
        return .Proc
    }
    if odinsyntax.kind_is_type(kind) {
        return .Type
    }
    return .Const
}

// The names of a Value_Decl and, for each, its value when the counts match or there is one value.
@(private = "file")
Decl_Names :: struct {
    names:  [dynamic]odinsyntax.Syntax_Node,
    values: [dynamic]odinsyntax.Syntax_Node,
}

@(private = "file")
decl_names :: proc(w: ^Walker, v: ^odinsyntax.Value_Decl) -> Decl_Names {
    d := Decl_Names {
        names  = make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator),
        values = make([dynamic]odinsyntax.Syntax_Node, context.temp_allocator),
    }
    if list, ok := odinsyntax.value_decl_names(v); ok {
        it := odinsyntax.name_list_names(&list)
        for name in odinsyntax.child_iter_next(&it) {
            _, err := append(&d.names, name)
            note_err(w, err)
        }
    }
    if list, ok := odinsyntax.value_decl_values(v); ok {
        it := odinsyntax.expr_list_items(&list)
        for value in odinsyntax.child_iter_next(&it) {
            _, err := append(&d.values, value)
            note_err(w, err)
        }
    }
    return d
}

@(private = "file")
name_kind :: proc(d: Decl_Names, i: int, constant: bool) -> Decl_Kind {
    if !constant {
        return .Var
    }
    if len(d.values) == len(d.names) {
        return classify_value(d.values[i])
    }
    if len(d.values) == 1 {
        return classify_value(d.values[0])
    }
    return .Const
}

@(private = "file")
has_using :: proc(n: odinsyntax.Syntax_Node) -> bool {
    for child in odinsyntax.green_children(n.green) {
        if tok, ok := odinsyntax.element_token(child); ok && tok.kind == .Using {
            return true
        }
    }
    return false
}

// Walks a Value_Decl. A variable is declared after its type and values, so `x := x` reads the outer `x`.
@(private = "file")
walk_value_decl :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    v, _ := odinsyntax.as_value_decl(n)
    constant := is_constant_decl(n)
    is_using := has_using(n)
    attrs := odinsyntax.value_decl_attributes(&v)
    for attr in odinsyntax.child_iter_next(&attrs) {
        walk_attribute(w, attr)
    }
    if type, ok := odinsyntax.value_decl_type(&v); ok {
        walk(w, type)
    }
    d := decl_names(w, &v)
    for value in d.values {
        walk(w, value)
    }
    for name, i in d.names {
        if name.green.kind != .Ident {
            walk(w, name)
            continue
        }
        if w.cur >= 0 && predeclared(w, int(name.offset)) {
            continue
        }
        declare(w, name, name_kind(d, i, constant), is_using, value = decl_local_value(n, name))
    }
}

// The type and value Value_Decl `n` gives the name `name`.
@(private = "file")
decl_local_value :: proc(n, name: odinsyntax.Syntax_Node) -> Local_Value {
    n := n
    out := NO_VALUE
    v, _ := odinsyntax.as_value_decl(n)
    if type, ok := odinsyntax.value_decl_type(&v); ok {
        out.type_offset = int(type.offset)
    }
    if value, result, ok := decl_value(&n, int(name.offset)); ok {
        out.value_offset = int(value.offset)
        out.value_index = result
    }
    return out
}

// Declares the constants of a statement list ahead of it: `::` is order-independent in its block.
// A `when` body opens no scope, so its constants belong to the list too.
@(private = "file")
hoist :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    n := n
    it := odinsyntax.child_iter(&n, {kinds = {.Value_Decl, .When_Stmt}})
    for child in odinsyntax.child_iter_next(&it) {
        if child.green.kind == .When_Stmt {
            hoist_when(w, child)
            continue
        }
        if !is_constant_decl(child) {
            continue
        }
        v, _ := odinsyntax.as_value_decl(child)
        d := decl_names(w, &v)
        for name, i in d.names {
            if name.green.kind == .Ident {
                declare(w, name, name_kind(d, i, true), value = decl_local_value(child, name))
            }
        }
    }
}

@(private = "file")
hoist_when :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    ws, _ := odinsyntax.as_when_stmt(n)
    if body, ok := odinsyntax.when_stmt_body(&ws); ok {
        hoist(w, body)
    }
    if other, ok := odinsyntax.when_stmt_else_branch(&ws); ok {
        if other.green.kind == .When_Stmt {
            hoist_when(w, other)
        } else {
            hoist(w, other)
        }
    }
}

// Walks a `when` statement. Its bodies open no scope.
@(private = "file")
walk_when :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    ws, _ := odinsyntax.as_when_stmt(n)
    if cond, ok := odinsyntax.when_stmt_cond(&ws); ok {
        walk(w, cond)
    }
    if body, ok := odinsyntax.when_stmt_body(&ws); ok {
        walk_children(w, body)
    }
    if other, ok := odinsyntax.when_stmt_else_branch(&ws); ok {
        if other.green.kind == .When_Stmt {
            walk_when(w, other)
        } else {
            walk_children(w, other)
        }
    }
}

@(private = "file")
walk_foreign_block :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    fb, _ := odinsyntax.as_foreign_block(n)
    attrs := odinsyntax.foreign_block_attributes(&fb)
    for attr in odinsyntax.child_iter_next(&attrs) {
        walk_attribute(w, attr)
    }
    if lib, ok := odinsyntax.foreign_block_library(&fb); ok {
        walk(w, odinsyntax.Syntax_Node(lib))
    }
    body, ok := odinsyntax.foreign_block_body(&fb)
    if !ok {
        return
    }
    if w.cur < 0 {
        walk_children(w, odinsyntax.Syntax_Node(body))
    } else {
        walk(w, odinsyntax.Syntax_Node(body))
    }
}

// The identifier a loop or switch variable names: `v` or `&v`.
@(private = "file")
var_ident :: proc(n: odinsyntax.Syntax_Node) -> (odinsyntax.Syntax_Node, bool) {
    if n.green.kind == .Ident {
        return n, true
    }
    if n.green.kind != .Unary_Expr {
        return {}, false
    }
    u, _ := odinsyntax.as_unary_expr(n)
    operand, ok := odinsyntax.unary_expr_operand(&u)
    if !ok || operand.green.kind != .Ident {
        return {}, false
    }
    return operand, true
}

// Walks `for k, v in expr`. The variables are declared after `expr`.
@(private = "file")
walk_range :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    r, _ := odinsyntax.as_range_stmt(n)
    mark := open_scope(w, n)
    defer close_scope(w, mark)
    if lbl, ok := odinsyntax.range_stmt_label(&r); ok {
        walk(w, odinsyntax.Syntax_Node(lbl))
    }
    if args, ok := odinsyntax.range_stmt_unroll_args(&r); ok {
        walk(w, odinsyntax.Syntax_Node(args))
    }
    value := Local_Value{-1, -1, 0, .Range}
    if expr, ok := odinsyntax.range_stmt_expr(&r); ok {
        walk(w, expr)
        value.value_offset = int(expr.offset)
    }
    if vars, ok := odinsyntax.range_stmt_vars(&r); ok {
        it := odinsyntax.expr_list_items(&vars)
        for item in odinsyntax.child_iter_next(&it) {
            if ident, iok := var_ident(item); iok {
                declare(w, ident, .Loop_Var, value = value)
            } else {
                walk(w, item)
            }
            value.value_index += 1
        }
    }
    if body, ok := odinsyntax.range_stmt_body(&r); ok {
        walk(w, body)
    }
}

// Walks `switch v in u`. `v` is one declaration that each case clause brings into reach.
@(private = "file")
walk_type_switch :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    ts, _ := odinsyntax.as_type_switch_stmt(n)
    mark := open_scope(w, n)
    defer close_scope(w, mark)
    if lbl, ok := odinsyntax.type_switch_stmt_label(&ts); ok {
        walk(w, odinsyntax.Syntax_Node(lbl))
    }
    value := Local_Value{-1, -1, -1, .Type_Switch}
    if subject, ok := odinsyntax.type_switch_stmt_subject(&ts); ok {
        walk(w, subject)
        value.value_offset = int(subject.offset)
    }
    vars := make([dynamic]int, context.temp_allocator)
    if list, ok := odinsyntax.type_switch_stmt_vars(&ts); ok {
        it := odinsyntax.expr_list_items(&list)
        for item in odinsyntax.child_iter_next(&it) {
            ident, iok := var_ident(item)
            if !iok {
                walk(w, item)
                continue
            }
            if index := declare(w, ident, .Switch_Var, push = false, value = value); index >= 0 {
                _, err := append(&vars, index)
                note_err(w, err)
            }
        }
    }
    body, ok := odinsyntax.type_switch_stmt_body(&ts)
    if !ok {
        return
    }
    body_mark := open_scope(w, odinsyntax.Syntax_Node(body))
    defer close_scope(w, body_mark)
    it := odinsyntax.child_iter((^odinsyntax.Syntax_Node)(&body), {kinds = ALL_KINDS})
    for child in odinsyntax.child_iter_next(&it) {
        clause, is_clause := odinsyntax.as_case_clause(child)
        if !is_clause {
            walk(w, child)
            continue
        }
        clause_mark := open_scope(w, child)
        if values, vok := odinsyntax.case_clause_values(&clause); vok {
            walk(w, odinsyntax.Syntax_Node(values))
        }
        for index in vars {
            _, err := append(&w.active, index)
            note_err(w, err)
        }
        hoist(w, child)
        stmts := odinsyntax.case_clause_stmts(&clause)
        for s in odinsyntax.child_iter_next(&stmts) {
            walk(w, s)
        }
        close_scope(w, clause_mark)
    }
}

// Declares every `$T` of a signature or record parameter list ahead of it, so each is in reach in
// the whole list, the results, the `where` clause and the body.
@(private = "file")
prescan_poly :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit, .Struct_Type, .Union_Type:
        return
    case .Poly_Type:
        pt, _ := odinsyntax.as_poly_type(n)
        if name, ok := odinsyntax.poly_type_name(&pt); ok && !predeclared(w, int(name.offset)) {
            declare(w, odinsyntax.Syntax_Node(name), .Poly)
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ALL_KINDS})
    for child in odinsyntax.child_iter_next(&it) {
        prescan_poly(w, child)
    }
}

// Walks the parameters and results of a procedure type in the current scope.
@(private = "file")
walk_signature :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    pt, _ := odinsyntax.as_proc_type(n)
    params, has_params := odinsyntax.proc_type_params(&pt)
    results, has_results := odinsyntax.proc_type_results(&pt)
    if has_params {
        prescan_poly(w, odinsyntax.Syntax_Node(params))
    }
    if has_results {
        prescan_poly(w, odinsyntax.Syntax_Node(results))
    }
    if has_params {
        walk_fields(w, odinsyntax.Syntax_Node(params), .Param)
    }
    if has_results {
        walk_fields(w, odinsyntax.Syntax_Node(results), .Result)
    }
}

// Walks the fields of a Param_List, Result_List or Field_List. A name is declared as `kind`, or is
// a member declaration when `member` is set.
@(private = "file")
walk_fields :: proc(w: ^Walker, list: odinsyntax.Syntax_Node, kind: Decl_Kind, member := false) {
    list := list
    it := odinsyntax.child_iter(&list, {kinds = ALL_KINDS})
    for child in odinsyntax.child_iter_next(&it) {
        f, is_field := odinsyntax.as_field(child)
        if !is_field {
            walk(w, child)
            continue
        }
        fit := odinsyntax.child_iter((^odinsyntax.Syntax_Node)(&f), {kinds = ALL_KINDS - {.Name_List}})
        for part in odinsyntax.child_iter_next(&fit) {
            walk(w, part)
        }
        names, has_names := odinsyntax.field_names(&f)
        if !has_names {
            continue
        }
        _, is_using := odinsyntax.field_using(&f)
        value := NO_VALUE
        if type, ok := odinsyntax.field_type(&f); ok {
            value.type_offset = int(type.offset)
        }
        if default, ok := odinsyntax.field_default(&f); ok {
            value.value_offset = int(default.offset)
        }
        nit := odinsyntax.name_list_names(&names)
        for name in odinsyntax.child_iter_next(&nit) {
            switch {
            case name.green.kind != .Ident:
                walk(w, name)
            case member:
                ref := base_ref(name)
                ref.kind = .Member_Decl
                ref.is_using = is_using
                add_ref(w, ref)
            case:
                declare(w, name, kind, is_using, value = value)
            }
        }
    }
}

// Walks a struct or union type: its `$T` parameters are in reach in the where clause and the fields.
@(private = "file")
walk_record :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    n := n
    mark := open_scope(w, n, true)
    defer close_scope(w, mark)
    if params, ok := odinsyntax.find_child_node(&n, {kinds = {.Param_List}}); ok {
        prescan_poly(w, params)
    }
    it := odinsyntax.child_iter(&n, {kinds = ALL_KINDS})
    for child in odinsyntax.child_iter_next(&it) {
        #partial switch child.green.kind {
        case .Param_List:
            walk_fields(w, child, .Param)
        case .Field_List:
            walk_fields(w, child, .Var, true)
        case:
            walk(w, child)
        }
    }
}

@(private = "file")
add_member_decl :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    ref := base_ref(n)
    ref.kind = .Member_Decl
    add_ref(w, ref)
}

@(private = "file")
walk_enum :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    e, _ := odinsyntax.as_enum_type(n)
    if backing, ok := odinsyntax.enum_type_backing(&e); ok {
        walk(w, backing)
    }
    members := odinsyntax.enum_type_members(&e)
    for m in odinsyntax.child_iter_next(&members) {
        if m.green.kind == .Ident {
            add_member_decl(w, m)
            continue
        }
        fv, ok := odinsyntax.as_field_value(m)
        if !ok {
            walk(w, m)
            continue
        }
        if name, nok := odinsyntax.field_value_name(&fv); nok {
            if name.green.kind == .Ident {
                add_member_decl(w, name)
            } else {
                walk(w, name)
            }
        }
        if value, vok := odinsyntax.field_value_value(&fv); vok {
            walk(w, value)
        }
    }
}

@(private = "file")
walk_bit_field :: proc(w: ^Walker, n: odinsyntax.Syntax_Node) {
    bf, _ := odinsyntax.as_bit_field_type(n)
    if backing, ok := odinsyntax.bit_field_type_backing(&bf); ok {
        walk(w, backing)
    }
    fields := odinsyntax.bit_field_type_fields(&bf)
    for field in odinsyntax.child_iter_next(&fields) {
        f, _ := odinsyntax.as_bit_field_field(field)
        if name, ok := odinsyntax.bit_field_field_name(&f); ok {
            add_member_decl(w, odinsyntax.Syntax_Node(name))
        }
        if type, ok := odinsyntax.bit_field_field_type(&f); ok {
            walk(w, type)
        }
        if bits, ok := odinsyntax.bit_field_field_bits(&f); ok {
            walk(w, bits)
        }
    }
}
