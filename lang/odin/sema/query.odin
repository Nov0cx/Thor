package odinsema

import "core:slice"

import odinsyntax "../syntax"

// What a member that follows `x.` is.
Member_Kind :: enum u8 {
    Field,          // a struct, bit_field or `#soa` field, or a field of `any`
    Enum_Member,
    Package_Member, // a declaration of a package that is not a procedure
    Proc,           // a procedure or procedure group of a package
}

// A name that can follow `x.`. `name` borrows the checker or the snapshot; end neither while it is used.
Member :: struct {
    name:       string,
    type:       Type_Id,
    symbol:     Symbol, // when `has_symbol`
    has_symbol: bool,
    kind:       Member_Kind,
    depth:      int, // Field: the `using` fields it is reached through
}

// The symbol of the field or enum member declared at `name_offset` of `file`: a child of its item,
// or a local symbol for a record declared in a procedure body.
field_symbol :: proc(c: ^Checker, file: File_Id, name_offset: int) -> Symbol {
    fc := file_cache(c, file)
    if fc != nil && fc.data != nil {
        for item, i in fc.data.tree.items {
            if name_offset < item.start || name_offset >= item.end {
                continue
            }
            for child, j in item.children {
                if child.name_offset == name_offset {
                    return Symbol{file, i32(i), i32(j)}
                }
            }
        }
    }
    return local_symbol(file, name_offset)
}

// The name range of the declaration `sym` names; false when it cannot be found.
symbol_range :: proc(c: ^Checker, sym: Symbol) -> (file: File_Id, start, end: int, ok: bool) {
    if sym.item == LOCAL_ITEM {
        if sym.child < 0 {
            return
        }
        n, found := node_of_kind(c, sym.file, int(sym.child), .Ident)
        if !found {
            return
        }
        s, e := odinsyntax.node_range(n)
        return sym.file, int(s), int(e), true
    }
    item := checker_item(c, sym)
    if item == nil || item.name_offset < 0 {
        return
    }
    return sym.file, item.name_offset, item.name_offset + len(item.name), true
}

// The members `x.` gives for an operand: a package's exported declarations, an enum type's members,
// or the fields of a value. The slice is in `allocator`; names borrow as in Member.
operand_members :: proc(c: ^Checker, op: Operand, allocator := context.allocator) -> []Member {
    #partial switch op.mode {
    case .Package:
        return package_members(c, op.dir, NO_FILE, allocator)
    case .Type:
        return enum_members(c, op.type, allocator)
    case .Value, .Const:
        return type_members(c, op.type, allocator)
    }
    return nil
}

// The fields `x.` gives for a value of type `t`, through one pointer. Fields promoted through `using`
// follow the direct ones; a promoted name that a shallower field has is left out.
type_members :: proc(c: ^Checker, t: Type_Id, allocator := context.allocator) -> []Member {
    out := make([dynamic]Member, allocator)
    collect_fields(c, t, 0, &out)
    return out[:]
}

// The members of an enum type; nil for another type.
enum_members :: proc(c: ^Checker, t: Type_Id, allocator := context.allocator) -> []Member {
    e, is_enum := type_get(&c.table, type_base(&c.table, t)).(Enum_Type)
    if !is_enum {
        return nil
    }
    out, err := make([dynamic]Member, 0, len(e.members), allocator)
    if !note_alloc(c, err) {
        return nil
    }
    for m in e.members {
        member := Member{name = m.name, type = t, kind = .Enum_Member}
        if m.name_offset >= 0 {
            member.symbol, member.has_symbol = field_symbol(c, e.file, m.name_offset), true
        }
        if _, aerr := append(&out, member); !note_alloc(c, aerr) {
            break
        }
    }
    return out[:]
}

// The declarations of the package at `dir` that `from` reaches, by name. From another package
// (`from` NO_FILE or in another directory) only public ones count.
package_members :: proc(c: ^Checker, dir: string, from := NO_FILE, allocator := context.allocator) -> []Member {
    view := checker_package(c, dir)
    if view == nil || view.scope == nil {
        return nil
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    external := true
    if from != NO_FILE {
        if fc := file_cache(c, from); fc != nil {
            external = fc.dir_key != path_key(dir, c.tmp)
        }
    }
    out, err := make([dynamic]Member, 0, len(view.scope.names), allocator)
    if !note_alloc(c, err) {
        return nil
    }
    for name in view.scope.names {
        sym, ok := member_lookup(c, dir, name, from, external)
        if !ok {
            continue
        }
        item := checker_item(c, sym)
        if item == nil {
            continue
        }
        kind := Member_Kind.Package_Member
        if item.kind == .Proc || item.kind == .Proc_Group {
            kind = .Proc
        }
        member := Member{name = item.name, type = decl_type(c, sym), symbol = sym, has_symbol = true, kind = kind}
        if _, aerr := append(&out, member); !note_alloc(c, aerr) {
            break
        }
    }
    slice.sort_by(out[:], proc(a, b: Member) -> bool { return a.name < b.name })
    return out[:]
}

@(private)
collect_fields :: proc(c: ^Checker, t: Type_Id, depth: int, out: ^[dynamic]Member) {
    if depth > USING_DEPTH {
        return
    }
    #partial switch v in type_get(&c.table, deref_base(c, t)) {
    case Struct_Type:
        for f in v.fields {
            add_field(c, out, f.name, f.type, v.file, f.name_offset, depth)
        }
        for f in v.fields {
            if f.is_using {
                collect_fields(c, f.type, depth + 1, out)
            }
        }
    case Bit_Field_Type:
        for f in v.fields {
            add_field(c, out, f.name, f.type, v.file, f.name_offset, depth)
        }
    case Soa_Type:
        start := len(out)
        collect_fields(c, v.elem, depth, out)
        for &m in out[start:] {
            if v.kind == .Array {
                m.type = type_array(&c.table, v.len, m.type)
            } else {
                m.type = type_multi_pointer(&c.table, m.type)
            }
        }
    case Basic_Type:
        if v.kind == .Any {
            add_field(c, out, "data", type_basic(.Rawptr), NO_FILE, -1, depth)
            add_field(c, out, "id", type_basic(.Typeid), NO_FILE, -1, depth)
        }
    case Dynamic_Array_Type, Map_Type:
        if a := runtime_type(c, "Allocator"); a != INVALID_TYPE {
            add_field(c, out, "allocator", a, NO_FILE, -1, depth)
        }
    }
}

// Appends a field; of two fields with one name the shallower one stays.
@(private)
add_field :: proc(c: ^Checker, out: ^[dynamic]Member, name: string, type: Type_Id, file: File_Id, name_offset, depth: int) {
    if name == "" || name == "_" {
        return
    }
    member := Member{name = name, type = type, kind = .Field, depth = depth}
    if name_offset >= 0 {
        member.symbol, member.has_symbol = field_symbol(c, file, name_offset), true
    }
    for &m in out {
        if m.name == name {
            if depth < m.depth {
                m = member
            }
            return
        }
    }
    _, err := append(out, member)
    note_alloc(c, err)
}

// A copy of the node path to `offset` in `c.tmp`.
@(private)
path_copy :: proc(c: ^Checker, file: File_Id, offset: int) -> []odinsyntax.Syntax_Node {
    path := node_path(c, file, offset)
    out, err := slice.clone(path, c.tmp)
    if !note_alloc(c, err) {
        return nil
    }
    return out
}

// True when `a` and `b` are the same node.
@(private)
same_node :: proc(a, b: odinsyntax.Syntax_Node) -> bool {
    return a.green == b.green && a.offset == b.offset
}

// The index of `child` among the items of an iterator; -1 when it is not one of them.
@(private)
child_index :: proc(it: odinsyntax.Child_Iter, child: odinsyntax.Syntax_Node) -> int {
    it := it
    i := 0
    for n in odinsyntax.child_iter_next(&it) {
        if same_node(n, child) {
            return i
        }
        i += 1
    }
    return -1
}

// The item `k` of an iterator.
@(private)
child_nth :: proc(it: odinsyntax.Child_Iter, k: int) -> (odinsyntax.Syntax_Node, bool) {
    it := it
    i := 0
    for n in odinsyntax.child_iter_next(&it) {
        if i == k {
            return n, true
        }
        i += 1
    }
    return {}, false
}

// The type the expression at `offset` of `file` is expected to have, from where it stands: an
// assignment, a declared type, a call argument, a return value, a composite literal element, the
// other operand of a comparison or a switch subject. The expression is the innermost one at
// `offset`, widened to the selector, call or index it is the head of. INVALID_TYPE when nothing gives one.
expected_type_at :: proc(c: ^Checker, file: File_Id, offset: int) -> Type_Id {
    temp := scratch_begin(c)
    defer scratch_end(temp)
    path := path_copy(c, file, offset)
    i := -1
    for n, k in path {
        if n.green.kind in odinsyntax.KINDS_EXPR {
            i = k
        }
    }
    if i < 0 {
        return INVALID_TYPE
    }
    for i > 0 && is_head_of(path[i - 1], path[i]) {
        i -= 1
    }
    return expected_in(c, file, path, i)
}

// True when `child` is the operand a postfix expression `parent` starts with.
@(private)
is_head_of :: proc(parent, child: odinsyntax.Syntax_Node) -> bool {
    if parent.offset != child.offset {
        return false
    }
    #partial switch parent.green.kind {
    case .Selector_Expr, .Call_Expr, .Index_Expr, .Matrix_Index_Expr, .Slice_Expr, .Deref_Expr, .Type_Assertion,
         .Or_Return_Expr, .Or_Branch_Expr, .Selector_Call_Expr:
        return true
    }
    return false
}

// The type `path[i]` is expected to have from its parent.
@(private)
expected_in :: proc(c: ^Checker, file: File_Id, path: []odinsyntax.Syntax_Node, i: int) -> Type_Id {
    if i <= 0 || i >= len(path) || c.depth >= EXPR_DEPTH {
        return INVALID_TYPE
    }
    c.depth += 1
    defer c.depth -= 1
    child := path[i]
    parent := path[i - 1]
    t := &c.table
    #partial switch parent.green.kind {
    case .Paren_Expr, .Implicit_Selector, .Tag_Expr:
        return expected_in(c, file, path, i - 1)
    case .If_Stmt, .For_Stmt, .When_Stmt:
        return type_basic(.Bool)
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(parent)
        op, _ := odinsyntax.unary_expr_op(&u)
        outer := expected_in(c, file, path, i - 1)
        if op.green.kind == .And {
            if p, ok := type_get(t, type_base(t, outer)).(Pointer_Type); ok {
                return p.elem
            }
            return INVALID_TYPE
        }
        if op.green.kind == .Not {
            return type_basic(.Bool)
        }
        return outer
    case .Binary_Expr:
        return binary_expected(c, file, path, i)
    case .Ternary_Expr, .Ternary_If_Expr, .Ternary_When_Expr:
        cond, then, other: odinsyntax.Syntax_Node
        #partial switch parent.green.kind {
        case .Ternary_Expr:
            te, _ := odinsyntax.as_ternary_expr(parent)
            cond, _ = odinsyntax.ternary_expr_cond(&te)
            then, _ = odinsyntax.ternary_expr_then(&te)
            other, _ = odinsyntax.ternary_expr_else_value(&te)
        case .Ternary_If_Expr:
            te, _ := odinsyntax.as_ternary_if_expr(parent)
            cond, _ = odinsyntax.ternary_if_expr_cond(&te)
            then, _ = odinsyntax.ternary_if_expr_then(&te)
            other, _ = odinsyntax.ternary_if_expr_else_value(&te)
        case .Ternary_When_Expr:
            te, _ := odinsyntax.as_ternary_when_expr(parent)
            cond, _ = odinsyntax.ternary_when_expr_cond(&te)
            then, _ = odinsyntax.ternary_when_expr_then(&te)
            other, _ = odinsyntax.ternary_when_expr_else_value(&te)
        }
        if cond.green != nil && same_node(cond, child) {
            return type_basic(.Bool)
        }
        if outer := expected_in(c, file, path, i - 1); outer != INVALID_TYPE {
            return outer
        }
        // The other branch types this one.
        sibling := same_node(then, child) ? other : then
        if sibling.green == nil || sibling.green.kind == .Implicit_Selector {
            return INVALID_TYPE
        }
        if st := expr_type(c, file, sibling).type; !type_is_untyped(t, st) {
            return st
        }
        return INVALID_TYPE
    case .Or_Else_Expr:
        oe, _ := odinsyntax.as_or_else_expr(parent)
        lhs, ok := odinsyntax.or_else_expr_lhs(&oe)
        if !ok || same_node(lhs, child) {
            return expected_in(c, file, path, i - 1)
        }
        op := expr_values(c, file, lhs)
        types := tuple_types(c, &op.type)
        return len(types) > 0 ? types[0] : INVALID_TYPE
    case .Index_Expr:
        ie, _ := odinsyntax.as_index_expr(parent)
        index, ok := odinsyntax.index_expr_index(&ie)
        operand, has_operand := odinsyntax.index_expr_operand(&ie)
        if !ok || !has_operand || !same_node(index, child) {
            return INVALID_TYPE
        }
        #partial switch v in type_get(t, deref_base(c, expr_type(c, file, operand).type)) {
        case Map_Type:
            return v.key
        case Enumerated_Array_Type:
            return v.index
        }
        return INVALID_TYPE
    case .Field:
        f, _ := odinsyntax.as_field(parent)
        default, ok := odinsyntax.field_default(&f)
        if !ok || !same_node(default, child) {
            return INVALID_TYPE
        }
        if type, tok := odinsyntax.field_type(&f); tok {
            return type_expr(c, file, type)
        }
        return INVALID_TYPE
    case .Expr_List:
        return list_expected(c, file, path, i)
    case .Arg_List:
        if i < 2 || path[i - 2].green.kind != .Call_Expr {
            return INVALID_TYPE
        }
        return arg_expected(c, file, path[i - 2], child, "")
    case .Field_Value:
        return field_value_expected(c, file, path, i)
    case .Comp_Lit:
        cl, _ := odinsyntax.as_comp_lit(parent)
        if type, ok := odinsyntax.comp_lit_type(&cl); ok && same_node(type, child) {
            return INVALID_TYPE
        }
        k := child_index(odinsyntax.comp_lit_elems(&cl), child)
        if k < 0 {
            return INVALID_TYPE
        }
        return element_type(c, lit_type(c, file, path, i - 1), k)
    }
    return INVALID_TYPE
}

// The operand type of the other side of a binary expression, or the bit_set element for `in`.
@(private)
binary_expected :: proc(c: ^Checker, file: File_Id, path: []odinsyntax.Syntax_Node, i: int) -> Type_Id {
    t := &c.table
    b, _ := odinsyntax.as_binary_expr(path[i - 1])
    op, has_op := odinsyntax.binary_expr_op(&b)
    lhs, has_lhs := odinsyntax.binary_expr_lhs(&b)
    rhs, has_rhs := odinsyntax.binary_expr_rhs(&b)
    if !has_op || !has_lhs || !has_rhs {
        return INVALID_TYPE
    }
    is_lhs := same_node(lhs, path[i])
    other := is_lhs ? rhs : lhs
    #partial switch op.green.kind {
    case .In, .Not_In:
        if !is_lhs {
            return INVALID_TYPE
        }
        bs, ok := type_get(t, type_base(t, expr_type(c, file, rhs).type)).(Bit_Set_Type)
        return ok && !bs.range ? bs.elem : INVALID_TYPE
    case .Cmp_And, .Cmp_Or:
        return type_basic(.Bool)
    case .Shl, .Shr:
        return is_lhs ? expected_in(c, file, path, i - 1) : INVALID_TYPE
    case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
        if other.green.kind == .Implicit_Selector {
            return INVALID_TYPE
        }
        if ot := expr_type(c, file, other).type; ot != INVALID_TYPE && !type_is_untyped(t, ot) {
            return ot
        }
        return INVALID_TYPE
    case .Range_Half, .Range_Full, .Ellipsis:
        if other.green.kind != .Implicit_Selector {
            if ot := expr_type(c, file, other).type; ot != INVALID_TYPE && !type_is_untyped(t, ot) {
                return ot
            }
        }
        return expected_in(c, file, path, i - 1)
    }
    if other.green.kind != .Implicit_Selector {
        if ot := expr_type(c, file, other).type; ot != INVALID_TYPE && !type_is_untyped(t, ot) {
            return ot
        }
    }
    return expected_in(c, file, path, i - 1)
}

// The type an item of an Expr_List is expected to have from the statement or clause it is in.
@(private)
list_expected :: proc(c: ^Checker, file: File_Id, path: []odinsyntax.Syntax_Node, i: int) -> Type_Id {
    if i < 2 {
        return INVALID_TYPE
    }
    list := path[i - 1]
    owner := path[i - 2]
    el, _ := odinsyntax.as_expr_list(list)
    k := child_index(odinsyntax.expr_list_items(&el), path[i])
    if k < 0 {
        return INVALID_TYPE
    }
    #partial switch owner.green.kind {
    case .Assign_Stmt:
        a, _ := odinsyntax.as_assign_stmt(owner)
        rhs, has_rhs := odinsyntax.assign_stmt_rhs(&a)
        lhs, has_lhs := odinsyntax.assign_stmt_lhs(&a)
        if !has_rhs || !has_lhs || !same_node(odinsyntax.Syntax_Node(rhs), list) {
            return INVALID_TYPE
        }
        target, ok := child_nth(odinsyntax.expr_list_items(&lhs), k)
        if !ok {
            return INVALID_TYPE
        }
        return expr_type(c, file, target).type
    case .Value_Decl:
        v, _ := odinsyntax.as_value_decl(owner)
        if type, ok := odinsyntax.value_decl_type(&v); ok {
            return type_expr(c, file, type)
        }
    case .Return_Stmt:
        for j := i - 3; j >= 0; j -= 1 {
            if path[j].green.kind != .Proc_Lit {
                continue
            }
            p, ok := type_get(&c.table, expr_type(c, file, path[j]).type).(Proc_Type)
            if !ok || k >= len(p.results) {
                return INVALID_TYPE
            }
            return p.results[k].type
        }
    case .Case_Clause:
        for j := i - 3; j >= 0; j -= 1 {
            #partial switch path[j].green.kind {
            case .Switch_Stmt:
                s, _ := odinsyntax.as_switch_stmt(path[j])
                if tag, ok := odinsyntax.switch_stmt_tag(&s); ok {
                    return expr_type(c, file, tag).type
                }
                return INVALID_TYPE
            case .Type_Switch_Stmt:
                return INVALID_TYPE
            }
        }
    }
    return INVALID_TYPE
}

// The arguments of a call as Call_Arg; operands are read for all but `skip`.
@(private)
call_args :: proc(c: ^Checker, file: File_Id, list: odinsyntax.Syntax_Node, skip: odinsyntax.Syntax_Node) -> []Call_Arg {
    al, _ := odinsyntax.as_arg_list(list)
    args := make([dynamic]Call_Arg, c.tmp)
    it := odinsyntax.arg_list_args(&al)
    for arg in odinsyntax.child_iter_next(&it) {
        a := Call_Arg{node = arg}
        #partial switch arg.green.kind {
        case .Field_Value:
            fv, _ := odinsyntax.as_field_value(arg)
            if name, ok := odinsyntax.field_value_name(&fv); ok {
                a.name = odinsyntax.node_text(name)
            }
            if value, ok := odinsyntax.field_value_value(&fv); ok {
                a.node = value
            }
        case .Spread_Expr:
            se, _ := odinsyntax.as_spread_expr(arg)
            if inner, ok := odinsyntax.spread_expr_expr(&se); ok {
                a.node = inner
            }
            a.spread = true
        }
        if !same_node(arg, skip) && !same_node(a.node, skip) && a.node.green != nil {
            a.op = expr_type(c, file, a.node)
        }
        if _, err := append(&args, a); !note_alloc(c, err) {
            return nil
        }
    }
    return args[:]
}

// The procedure type a call picks, from the callee and the other arguments; false when the callee is none.
// A group takes the best member, else the first whose parameters take the arguments.
@(private)
called_proc :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node, skip: odinsyntax.Syntax_Node) -> (p: Proc_Type, args: []Call_Arg, ok: bool) {
    ce, _ := odinsyntax.as_call_expr(call)
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list {
        return
    }
    fn := expr_type(c, file, callee)
    if fn.mode != .Value && fn.mode != .Const {
        return
    }
    args = call_args(c, file, odinsyntax.Syntax_Node(list), skip)
    with, wok := with_receiver(c, file, callee, args)
    if !wok {
        return
    }
    args = with
    base := type_base(&c.table, fn.type)
    #partial switch v in type_get(&c.table, base) {
    case Proc_Type:
        return v, args, true
    case Proc_Group_Type:
        chosen, first_fit := choose_member(c, file, v, args)
        if chosen == INVALID_TYPE {
            chosen = first_fit
        }
        if chosen == INVALID_TYPE && len(v.members) > 0 {
            chosen = v.members[0]
        }
        p, ok = type_get(&c.table, type_base(&c.table, chosen)).(Proc_Type)
        return
    }
    return
}

// The arguments of a call with the receiver of an `x->f` callee first; false when the copy fails.
@(private)
with_receiver :: proc(c: ^Checker, file: File_Id, callee: odinsyntax.Syntax_Node, args: []Call_Arg) -> ([]Call_Arg, bool) {
    sel, is_sel := odinsyntax.as_selector_expr(callee)
    if !is_sel {
        return args, true
    }
    if _, is_arrow := odinsyntax.selector_expr_arrow(&sel); !is_arrow {
        return args, true
    }
    operand, ok := odinsyntax.selector_expr_operand(&sel)
    if !ok {
        return args, true
    }
    with, err := make([]Call_Arg, len(args) + 1, c.tmp)
    if !note_alloc(c, err) {
        return nil, false
    }
    with[0] = Call_Arg{op = expr_type(c, file, operand)}
    copy(with[1:], args)
    return with, true
}

// The member of the procedure group a call picks for the arguments it has. INVALID_TYPE when the
// callee is not a group, no member takes the arguments or the call is ambiguous.
call_group_member :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node) -> Type_Id {
    ce, is_call := odinsyntax.as_call_expr(call)
    if !is_call {
        return INVALID_TYPE
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list {
        return INVALID_TYPE
    }
    fn := expr_type(c, file, callee)
    if fn.mode != .Value && fn.mode != .Const {
        return INVALID_TYPE
    }
    g, is_group := type_get(&c.table, type_base(&c.table, fn.type)).(Proc_Group_Type)
    if !is_group {
        return INVALID_TYPE
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    args, ok := with_receiver(c, file, callee, call_args(c, file, odinsyntax.Syntax_Node(list), {}))
    if !ok {
        return INVALID_TYPE
    }
    chosen, _ := choose_member(c, file, g, args)
    return chosen
}

// The parameter type argument `arg` of `call` is expected to have. `name` is the name of a named argument.
@(private)
arg_expected :: proc(c: ^Checker, file: File_Id, call, arg: odinsyntax.Syntax_Node, name: string) -> Type_Id {
    ce, _ := odinsyntax.as_call_expr(call)
    if callee, ok := odinsyntax.call_expr_callee(&ce); ok {
        if fn := expr_type(c, file, callee); fn.mode == .Type {
            return fn.type
        }
    }
    p, args, ok := called_proc(c, file, call, arg)
    if !ok {
        return INVALID_TYPE
    }
    slot := -1
    if name != "" {
        slot = param_named(p, name)
    } else {
        slots, fits := match_args(c, p, args)
        for a, k in args {
            if !same_node(a.node, arg) {
                continue
            }
            if fits {
                slot = slots[k]
            } else if k < len(p.params) {
                slot = k
            } else if len(p.params) > 0 && .Variadic in p.params[len(p.params) - 1].flags {
                slot = len(p.params) - 1
            }
        }
    }
    if slot < 0 || slot >= len(p.params) {
        return INVALID_TYPE
    }
    if p.generic && has_poly(c, p.params[slot].type, 0) {
        return bound_param_type(c, p, args, slot)
    }
    return p.params[slot].type
}

// The type of parameter `slot` of a polymorphic procedure, read with what the arguments bind;
// INVALID_TYPE when a polymorphic part stays unbound.
@(private)
bound_param_type :: proc(c: ^Checker, p: Proc_Type, args: []Call_Arg, slot: int) -> Type_Id {
    slots, fits := match_args(c, p, args)
    if !fits {
        return INVALID_TYPE
    }
    env, ok := bind_generic(c, p, args, slots)
    if !ok || len(env) == 0 {
        return INVALID_TYPE
    }
    node, found := node_of_kind(c, p.file, p.offset, .Proc_Type)
    if !found {
        return INVALID_TYPE
    }
    pt, _ := odinsyntax.as_proc_type(node)
    params, has_params := odinsyntax.proc_type_params(&pt)
    if !has_params {
        return INVALID_TYPE
    }
    infos := param_infos(c, odinsyntax.Syntax_Node(params))
    if slot >= len(infos) || !infos[slot].has_type {
        return INVALID_TYPE
    }
    type_node := infos[slot].type
    if e, is_ellipsis := odinsyntax.as_ellipsis_type(type_node); is_ellipsis {
        elem, eok := odinsyntax.ellipsis_type_elem(&e)
        if !eok {
            return INVALID_TYPE
        }
        type_node = elem
    }
    saved := c.env
    c.env = env
    t := type_expr(c, p.file, type_node)
    c.env = saved
    if has_poly(c, t, 0) {
        return INVALID_TYPE
    }
    return t
}

// The index of the parameter named `name`, `$name` included; -1 when there is none.
@(private)
param_named :: proc(p: Proc_Type, name: string) -> int {
    for param, j in p.params {
        if param.name == name || (len(param.name) == len(name) + 1 && param.name[0] == '$' && param.name[1:] == name) {
            return j
        }
    }
    return -1
}

// The expected type of the name or the value of a `name = value` in a call or a composite literal.
@(private)
field_value_expected :: proc(c: ^Checker, file: File_Id, path: []odinsyntax.Syntax_Node, i: int) -> Type_Id {
    if i < 2 {
        return INVALID_TYPE
    }
    fv, _ := odinsyntax.as_field_value(path[i - 1])
    name, has_name := odinsyntax.field_value_name(&fv)
    value, has_value := odinsyntax.field_value_value(&fv)
    if !has_name || !has_value {
        return INVALID_TYPE
    }
    owner := path[i - 2]
    t := &c.table
    if same_node(value, path[i]) {
        #partial switch owner.green.kind {
        case .Arg_List:
            if name.green.kind != .Ident || i < 3 || path[i - 3].green.kind != .Call_Expr {
                return INVALID_TYPE
            }
            return arg_expected(c, file, path[i - 3], value, odinsyntax.node_text(name))
        case .Comp_Lit:
            lit := lit_type(c, file, path, i - 2)
            #partial switch v in type_get(t, type_base(t, lit)) {
            case Array_Type:            return v.elem
            case Enumerated_Array_Type: return v.elem
            case Map_Type:              return v.value
            case Slice_Type:            return v.elem
            case Dynamic_Array_Type:    return v.elem
            }
            if name.green.kind == .Ident {
                if hit, ok := find_field(c, lit, odinsyntax.node_text(name)); ok {
                    return hit.type
                }
            }
        }
        return INVALID_TYPE
    }
    if same_node(name, path[i]) && owner.green.kind == .Comp_Lit {
        lit := lit_type(c, file, path, i - 2)
        #partial switch v in type_get(t, type_base(t, lit)) {
        case Enumerated_Array_Type: return v.index
        case Map_Type:              return v.key
        }
    }
    return INVALID_TYPE
}

// The type of the composite literal `path[j]`: its own type, else the one its place expects.
@(private)
lit_type :: proc(c: ^Checker, file: File_Id, path: []odinsyntax.Syntax_Node, j: int) -> Type_Id {
    cl, _ := odinsyntax.as_comp_lit(path[j])
    if type, ok := odinsyntax.comp_lit_type(&cl); ok {
        return type_expr(c, file, type)
    }
    return expected_in(c, file, path, j)
}

// The type of positional element `k` of a composite literal of type `lit`.
@(private)
element_type :: proc(c: ^Checker, lit: Type_Id, k: int) -> Type_Id {
    t := &c.table
    #partial switch v in type_get(t, type_base(t, lit)) {
    case Struct_Type:
        return k < len(v.fields) ? v.fields[k].type : INVALID_TYPE
    case Array_Type:            return v.elem
    case Slice_Type:            return v.elem
    case Dynamic_Array_Type:    return v.elem
    case Enumerated_Array_Type: return v.elem
    case Simd_Type:             return v.elem
    case Matrix_Type:           return v.elem
    case Soa_Type:              return v.elem
    case Bit_Set_Type:          return v.range ? type_default(t, v.elem) : v.elem
    }
    return INVALID_TYPE
}

// The declaration the name at `offset` of `file` refers to when it is the right side of a selector,
// an implicit `.Member`, a field name of a composite literal or a named call argument.
selector_symbol :: proc(c: ^Checker, file: File_Id, offset: int) -> (Symbol, bool) {
    temp := scratch_begin(c)
    defer scratch_end(temp)
    path := path_copy(c, file, offset)
    i := -1
    for n, k in path {
        if n.green.kind == .Ident {
            i = k
        }
    }
    if i < 1 {
        return {}, false
    }
    ident := path[i]
    name := odinsyntax.node_text(ident)
    parent := path[i - 1]
    #partial switch parent.green.kind {
    case .Selector_Expr:
        sel, _ := odinsyntax.as_selector_expr(parent)
        field, ok := odinsyntax.selector_expr_field(&sel)
        if !ok || !same_node(odinsyntax.Syntax_Node(field), ident) {
            return {}, false
        }
        op := expr_type(c, file, parent)
        return op.symbol, op.mode != .Invalid && op.has_symbol
    case .Implicit_Selector:
        op := implicit_operand(c, name, expected_type_at(c, file, int(parent.offset)))
        return op.symbol, op.mode != .Invalid && op.has_symbol
    case .Field_Value:
        fv, _ := odinsyntax.as_field_value(parent)
        fname, ok := odinsyntax.field_value_name(&fv)
        if !ok || !same_node(fname, ident) || i < 2 {
            return {}, false
        }
        owner := path[i - 2]
        #partial switch owner.green.kind {
        case .Comp_Lit:
            lit := lit_type(c, file, path, i - 2)
            hit, found := find_field(c, lit, name)
            if !found || hit.name_offset < 0 {
                return {}, false
            }
            return field_symbol(c, hit.file, hit.name_offset), true
        case .Arg_List:
            if i < 3 || path[i - 3].green.kind != .Call_Expr {
                return {}, false
            }
            p, _, pok := called_proc(c, file, path[i - 3], parent)
            if !pok {
                return {}, false
            }
            slot := param_named(p, name)
            if slot < 0 || p.params[slot].name_offset < 0 {
                return {}, false
            }
            return local_symbol(p.file, p.params[slot].name_offset), true
        }
    }
    return {}, false
}

// The innermost expression or type whose own token holds byte `offset` of `file`. A token of an
// argument list gives the call; the field name of a selector gives the selector. False on trivia.
expr_under :: proc(c: ^Checker, file: File_Id, offset: int) -> (odinsyntax.Syntax_Node, bool) {
    path := node_path(c, file, offset)
    if len(path) == 0 {
        return {}, false
    }
    last := path[len(path) - 1]
    pos := last.offset
    on_token := false
    for child in odinsyntax.green_children(last.green) {
        child_len := odinsyntax.element_len(child)
        if u32(offset) >= pos && u32(offset) < pos + child_len {
            tok, is_token := odinsyntax.element_token(child)
            on_token = is_token && !odinsyntax.token_is_trivia(tok.kind) && tok.kind != .EOF
            break
        }
        pos += child_len
    }
    if !on_token {
        return {}, false
    }
    i := len(path) - 1
    #partial switch path[i].green.kind {
    case .Arg_List:
        i -= 1
    case .Ident:
        if i > 0 && path[i - 1].offset != path[i].offset {
            #partial switch path[i - 1].green.kind {
            case .Selector_Expr, .Implicit_Selector:
                i -= 1
            }
        }
    }
    if i < 0 || path[i].green.kind not_in odinsyntax.KINDS_EXPR {
        return {}, false
    }
    return path[i], true
}
