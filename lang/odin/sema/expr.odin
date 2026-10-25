package odinsema

import "core:strings"

import odinsyntax "../syntax"

// The deepest nesting expr_type follows before it gives an Invalid operand.
EXPR_DEPTH :: 64

// The operand an expression gives in a single-value use: its mode, its type and, for a constant,
// its value. `expected` types an untyped composite literal, an implicit selector and `auto_cast`.
expr_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, expected := INVALID_TYPE) -> Operand {
    return single_value(c, expr_values(c, file, n, expected))
}

// The operand an expression gives where it can give more than one value: a call gives a Tuple of
// its results, a map index and a type assertion give (value, bool).
expr_values :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, expected := INVALID_TYPE) -> Operand {
    if c.depth >= EXPR_DEPTH || n.green == nil {
        return {}
    }
    c.depth += 1
    defer c.depth -= 1
    return operand_of(c, file, n, expected)
}

// The first value of an operand whose last value a single-value use drops.
@(private)
single_value :: proc(c: ^Checker, op: Operand) -> Operand {
    if !op.optional {
        return op
    }
    op := op
    op.optional = false
    if tuple, ok := type_get(&c.table, op.type).(Tuple_Type); ok && len(tuple.types) > 0 {
        op.type = tuple.types[0]
    }
    return op
}

// The values of a Tuple; the type itself when it is not one.
@(private)
tuple_types :: proc(c: ^Checker, t: ^Type_Id) -> []Type_Id {
    if tuple, ok := type_get(&c.table, t^).(Tuple_Type); ok {
        return tuple.types
    }
    if t^ == INVALID_TYPE {
        return nil
    }
    return ([^]Type_Id)(t)[:1]
}

// `(value, bool)`, made once per value type.
@(private)
with_ok :: proc(c: ^Checker, value: Type_Id) -> Operand {
    if value == INVALID_TYPE {
        return {}
    }
    if t, ok := c.pairs[value]; ok {
        return {mode = .Value, type = t, optional = true}
    }
    t := type_tuple(&c.table, {value, type_basic(.Bool)})
    if _, entry, _, err := map_entry(&c.pairs, value); note_alloc(c, err) {
        entry^ = t
    }
    return {mode = .Value, type = t, optional = true}
}

@(private)
operand_of :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, expected: Type_Id) -> Operand {
    n := n
    kind := n.green.kind
    if kind in odinsyntax.KINDS_TYPE && kind != .Ellipsis_Type {
        return {mode = .Type, type = type_expr(c, file, n)}
    }
    #partial switch kind {
    case .Ident:
        return ident_operand(c, file, n)
    case .Literal:
        return literal_operand(c, n)
    case .Unary_Expr:
        return unary_operand(c, file, n, expected)
    case .Binary_Expr:
        return binary_operand(c, file, n, expected)
    case .Ternary_Expr, .Ternary_If_Expr, .Ternary_When_Expr:
        return ternary_operand(c, file, n, expected)
    case .Paren_Expr:
        p, _ := odinsyntax.as_paren_expr(n)
        inner, ok := odinsyntax.paren_expr_expr(&p)
        return ok ? expr_values(c, file, inner, expected) : {}
    case .Selector_Expr:
        return selector_operand(c, file, n)
    case .Implicit_Selector:
        is, _ := odinsyntax.as_implicit_selector(n)
        field, ok := odinsyntax.implicit_selector_field(&is)
        if !ok {
            return {}
        }
        return implicit_operand(c, odinsyntax.node_text(odinsyntax.Syntax_Node(field)), expected)
    case .Selector_Call_Expr:
        sc, _ := odinsyntax.as_selector_call_expr(n)
        call, ok := odinsyntax.selector_call_expr_call(&sc)
        return ok ? call_operand(c, file, odinsyntax.Syntax_Node(call), expected) : {}
    case .Call_Expr:
        return call_operand(c, file, n, expected)
    case .Index_Expr:
        ie, _ := odinsyntax.as_index_expr(n)
        operand, ok := odinsyntax.index_expr_operand(&ie)
        return ok ? index_operand(c, expr_type(c, file, operand).type) : {}
    case .Matrix_Index_Expr:
        me, _ := odinsyntax.as_matrix_index_expr(n)
        operand, ok := odinsyntax.matrix_index_expr_operand(&me)
        if !ok {
            return {}
        }
        if m, is_matrix := type_get(&c.table, deref_base(c, expr_type(c, file, operand).type)).(Matrix_Type); is_matrix {
            return {mode = .Value, type = m.elem}
        }
        return {}
    case .Slice_Expr:
        return slice_operand(c, file, n)
    case .Deref_Expr:
        de, _ := odinsyntax.as_deref_expr(n)
        operand, ok := odinsyntax.deref_expr_operand(&de)
        if !ok {
            return {}
        }
        #partial switch v in type_get(&c.table, type_base(&c.table, expr_type(c, file, operand).type)) {
        case Pointer_Type:
            return {mode = .Value, type = v.elem}
        case Multi_Pointer_Type:
            return {mode = .Value, type = v.elem}
        }
        return {}
    case .Comp_Lit:
        return comp_lit_operand(c, file, n, expected)
    case .Cast_Expr:
        ce, _ := odinsyntax.as_cast_expr(n)
        return {mode = .Value, type = elem_type(c, file, odinsyntax.cast_expr_type(&ce))}
    case .Auto_Cast_Expr:
        if expected != INVALID_TYPE {
            return {mode = .Value, type = expected}
        }
        ac, _ := odinsyntax.as_auto_cast_expr(n)
        operand, ok := odinsyntax.auto_cast_expr_operand(&ac)
        return ok ? {mode = .Value, type = expr_type(c, file, operand).type} : {}
    case .Type_Assertion:
        return assertion_operand(c, file, n)
    case .Or_Else_Expr:
        oe, _ := odinsyntax.as_or_else_expr(n)
        lhs, ok := odinsyntax.or_else_expr_lhs(&oe)
        if !ok {
            return {}
        }
        op := expr_values(c, file, lhs, expected)
        types := tuple_types(c, &op.type)
        if len(types) == 0 {
            return {}
        }
        return {mode = .Value, type = types[0]}
    case .Or_Return_Expr:
        oe, _ := odinsyntax.as_or_return_expr(n)
        operand, ok := odinsyntax.or_return_expr_operand(&oe)
        return ok ? drop_last(c, expr_values(c, file, operand, expected)) : {}
    case .Or_Branch_Expr:
        ob, _ := odinsyntax.as_or_branch_expr(n)
        operand, ok := odinsyntax.or_branch_expr_operand(&ob)
        return ok ? drop_last(c, expr_values(c, file, operand, expected)) : {}
    case .Spread_Expr:
        se, _ := odinsyntax.as_spread_expr(n)
        inner, ok := odinsyntax.spread_expr_expr(&se)
        return ok ? expr_type(c, file, inner, expected) : {}
    case .Proc_Lit:
        p, _ := odinsyntax.as_proc_lit(n)
        pt, ok := odinsyntax.proc_lit_type(&p)
        if !ok {
            return {}
        }
        tags := directive_tags(odinsyntax.proc_lit_tags(&p))
        return {mode = .Value, type = proc_type(c, file, odinsyntax.Syntax_Node(pt), tags)}
    case .Proc_Group:
        return {mode = .Value, type = proc_group_type(c, file, n)}
    case .Tag_Expr:
        tag, _ := odinsyntax.as_tag_expr(n)
        inner, ok := odinsyntax.tag_expr_expr(&tag)
        if !ok {
            return {}
        }
        if inner.green.kind in odinsyntax.KINDS_TYPE {
            return {mode = .Type, type = tag_type(c, file, n)}
        }
        return expr_values(c, file, inner, expected)
    case .Undef_Expr:
        return {mode = .Value, type = type_untyped(.Uninit)}
    case .Context_Expr:
        return {mode = .Value, type = runtime_type(c, "Context")}
    case .Directive:
        d, _ := odinsyntax.as_directive(n)
        if tok, ok := odinsyntax.directive_name(&d); ok {
            return directive_call(c, file, odinsyntax.syntax_token_text(tok), nil)
        }
    }
    return {}
}

// The values of `x or_return`: those of `x` but the last.
@(private)
drop_last :: proc(c: ^Checker, op: Operand) -> Operand {
    tuple, is_tuple := type_get(&c.table, op.type).(Tuple_Type)
    if !is_tuple {
        return op.mode == .Invalid ? {} : {mode = .No_Value}
    }
    switch len(tuple.types) {
    case 0, 1:
        return {mode = .No_Value}
    case 2:
        return {mode = .Value, type = tuple.types[0]}
    }
    return {mode = .Value, type = type_tuple(&c.table, tuple.types[:len(tuple.types) - 1])}
}

// The base type of `t`, through one pointer.
@(private)
deref_base :: proc(c: ^Checker, t: Type_Id) -> Type_Id {
    base := type_base(&c.table, t)
    if p, ok := type_get(&c.table, base).(Pointer_Type); ok {
        return type_base(&c.table, p.elem)
    }
    return base
}

// The innermost node of `kind` that starts at `offset` of `file`. Its parent is not set.
@(private)
node_of_kind :: proc(c: ^Checker, file: File_Id, offset: int, kind: odinsyntax.Syntax_Kind) -> (odinsyntax.Syntax_Node, bool) {
    found: odinsyntax.Syntax_Node
    ok := false
    for n in node_path(c, file, offset) {
        if int(n.offset) == offset && n.green.kind == kind {
            found, ok = n, true
        }
    }
    return found, ok
}

@(private)
proc_group_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Type_Id {
    g, _ := odinsyntax.as_proc_group(n)
    temp := scratch_begin(c)
    defer scratch_end(temp)
    members := make([dynamic]Type_Id, c.tmp)
    it := odinsyntax.proc_group_members(&g)
    for m in odinsyntax.child_iter_next(&it) {
        if _, err := append(&members, expr_type(c, file, m).type); !note_alloc(c, err) {
            return INVALID_TYPE
        }
    }
    return type_proc_group(&c.table, members[:])
}

// The untyped type of a constant value.
@(private)
untyped_of :: proc(v: Const_Value) -> Type_Id {
    switch _ in v {
    case i64:    return type_untyped(.Int)
    case f64:    return type_untyped(.Float)
    case string: return type_untyped(.String)
    case bool:   return type_untyped(.Bool)
    case rune:   return type_untyped(.Rune)
    }
    return INVALID_TYPE
}

@(private)
literal_operand :: proc(c: ^Checker, n: odinsyntax.Syntax_Node) -> Operand {
    n := n
    if v, ok := literal_value(c, n); ok {
        return {mode = .Const, type = untyped_of(v), value = v}
    }
    lit, _ := odinsyntax.as_literal(n)
    if tok, ok := odinsyntax.literal_token(&lit); ok {
        #partial switch tok.green.kind {
        case .Integer: return {mode = .Const, type = type_untyped(.Int)}
        case .Float:   return {mode = .Const, type = type_untyped(.Float)}
        case .Imag:    return {mode = .Const, type = type_untyped(.Complex)}
        case .Rune:    return {mode = .Const, type = type_untyped(.Rune)}
        case .String:  return {mode = .Const, type = type_untyped(.String)}
        }
    }
    return {}
}

@(private)
unary_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, expected: Type_Id) -> Operand {
    u, _ := odinsyntax.as_unary_expr(n)
    op, has_op := odinsyntax.unary_expr_op(&u)
    operand, has_operand := odinsyntax.unary_expr_operand(&u)
    if !has_op || !has_operand {
        return {}
    }
    if op.green.kind == .And {
        elem := INVALID_TYPE
        if p, ok := type_get(&c.table, type_base(&c.table, expected)).(Pointer_Type); ok {
            elem = p.elem
        }
        inner := expr_type(c, file, operand, elem)
        if inner.mode == .Invalid || inner.mode == .Type {
            return {}
        }
        return {mode = .Value, type = type_pointer(&c.table, inner.type)}
    }
    inner := expr_type(c, file, operand, expected)
    if inner.mode == .Invalid {
        return {}
    }
    if inner.mode == .Const {
        if inner.value != nil {
            if v, ok := const_unary(op.green.kind, inner.value); ok {
                return {mode = .Const, type = inner.type, value = v}
            }
        }
        return {mode = .Const, type = inner.type}
    }
    return {mode = .Value, type = inner.type}
}

// A binary expression. An untyped operand takes the type of a typed one; a comparison gives an
// untyped bool; a shift gives the type of its left side.
@(private)
binary_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, expected: Type_Id) -> Operand {
    b, _ := odinsyntax.as_binary_expr(n)
    op_tok, has_op := odinsyntax.binary_expr_op(&b)
    lhs_n, has_lhs := odinsyntax.binary_expr_lhs(&b)
    rhs_n, has_rhs := odinsyntax.binary_expr_rhs(&b)
    if !has_op || !has_lhs || !has_rhs {
        return {}
    }
    op := op_tok.green.kind
    lhs, rhs: Operand
    #partial switch op {
    case .In, .Not_In:
        rhs = expr_type(c, file, rhs_n)
        elem := INVALID_TYPE
        if bs, ok := type_get(&c.table, type_base(&c.table, rhs.type)).(Bit_Set_Type); ok {
            elem = bs.elem
        }
        lhs = expr_type(c, file, lhs_n, elem)
        return {mode = .Value, type = type_untyped(.Bool)}
    }
    if lhs_n.green.kind == .Implicit_Selector {
        rhs = expr_type(c, file, rhs_n, expected)
        lhs = expr_type(c, file, lhs_n, rhs.type != INVALID_TYPE ? rhs.type : expected)
    } else {
        lhs = expr_type(c, file, lhs_n, expected)
        rhs = expr_type(c, file, rhs_n, lhs.type != INVALID_TYPE && !type_is_untyped(&c.table, lhs.type) ? lhs.type : expected)
    }
    mode: Operand_Mode = lhs.mode == .Const && rhs.mode == .Const ? .Const : .Value
    value: Const_Value
    if mode == .Const && lhs.value != nil && rhs.value != nil {
        if v, ok := const_binary(c, op, lhs.value, rhs.value); ok {
            value = v
        }
    }
    #partial switch op {
    case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq, .Cmp_And, .Cmp_Or:
        if value == nil && (lhs_n.green.kind == .Implicit_Selector || rhs_n.green.kind == .Implicit_Selector) {
            if v, ok := const_eval(c, file, n); ok {
                return {mode = .Const, type = type_untyped(.Bool), value = v}
            }
        }
        return {mode = mode, type = type_untyped(.Bool), value = value}
    case .Shl, .Shr:
        if lhs.mode == .Invalid {
            return {}
        }
        if type_is_untyped(&c.table, lhs.type) && value != nil {
            return {mode = mode, type = untyped_of(value), value = value}
        }
        return {mode = mode, type = lhs.type, value = value}
    case .Range_Half, .Range_Full, .Ellipsis:
        t := lhs.type
        if type_is_untyped(&c.table, t) || t == INVALID_TYPE {
            t = rhs.type
        }
        return {mode = .Value, type = type_default(&c.table, t)}
    }
    if lhs.mode == .Invalid && rhs.mode == .Invalid {
        return {}
    }
    type := lhs.type
    l_untyped := type_is_untyped(&c.table, lhs.type)
    r_untyped := type_is_untyped(&c.table, rhs.type)
    switch {
    case type == INVALID_TYPE:
        type = rhs.type
    case l_untyped && !r_untyped && rhs.type != INVALID_TYPE:
        type = rhs.type
    case l_untyped && r_untyped:
        if value != nil {
            type = untyped_of(value)
        } else if type_is_float(&c.table, rhs.type) {
            type = rhs.type
        }
    }
    return {mode = mode, type = type, value = value}
}

// A ternary expression: the branch a constant condition picks, else typed by both branches.
@(private)
ternary_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, expected: Type_Id) -> Operand {
    cond, then, other: odinsyntax.Syntax_Node
    has_cond, has_then, has_other: bool
    #partial switch n.green.kind {
    case .Ternary_Expr:
        te, _ := odinsyntax.as_ternary_expr(n)
        cond, has_cond = odinsyntax.ternary_expr_cond(&te)
        then, has_then = odinsyntax.ternary_expr_then(&te)
        other, has_other = odinsyntax.ternary_expr_else_value(&te)
    case .Ternary_If_Expr:
        te, _ := odinsyntax.as_ternary_if_expr(n)
        cond, has_cond = odinsyntax.ternary_if_expr_cond(&te)
        then, has_then = odinsyntax.ternary_if_expr_then(&te)
        other, has_other = odinsyntax.ternary_if_expr_else_value(&te)
    case .Ternary_When_Expr:
        te, _ := odinsyntax.as_ternary_when_expr(n)
        cond, has_cond = odinsyntax.ternary_when_expr_cond(&te)
        then, has_then = odinsyntax.ternary_when_expr_then(&te)
        other, has_other = odinsyntax.ternary_when_expr_else_value(&te)
    }
    if !has_then {
        return {}
    }
    if has_cond && has_other {
        if v, ok := const_eval(c, file, cond); ok {
            if b, is_bool := v.(bool); is_bool {
                return expr_type(c, file, b ? then : other, expected)
            }
        }
    }
    a := expr_type(c, file, then, expected)
    if !has_other {
        return a
    }
    if a.mode != .Invalid && a.type != INVALID_TYPE && !type_is_untyped(&c.table, a.type) {
        a.value = nil
        if a.mode == .Const {
            a.mode = .Value
        }
        a.has_symbol = false
        return a
    }
    b := expr_type(c, file, other, a.type != INVALID_TYPE ? a.type : expected)
    if b.mode != .Invalid && b.type != INVALID_TYPE && (a.type == INVALID_TYPE || !type_is_untyped(&c.table, b.type)) {
        return {mode = .Value, type = b.type}
    }
    return {mode = a.mode == .Const && b.mode == .Const ? .Const : .Value, type = a.type}
}

@(private)
ident_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Operand {
    name := odinsyntax.node_text(n)
    r := lookup_name(c, file, name, int(n.offset))
    switch r.kind {
    case .None:
        if is_builtin_proc(name) {
            return {mode = .Builtin, symbol = {item = LOCAL_ITEM, child = -1}}
        }
        return {}
    case .Basic:
        return {mode = .Type, type = type_basic(r.basic)}
    case .Builtin:
        return builtin_operand(c, name)
    case .Import:
        return {mode = .Package, dir = r.dir}
    case .Item:
        if r.symbol in c.pending {
            // `i32 :: i32` in base:builtin: the declaration stands for the universe name.
            if u := universe_name(c, name); u.kind == .Basic || u.kind == .Builtin {
                return u.kind == .Basic ? {mode = .Type, type = type_basic(u.basic)} : builtin_operand(c, name)
            }
        }
        return item_operand(c, r.symbol, r.builtin)
    case .Local:
        op := local_operand(c, r, int(n.offset))
        if op.mode != .Invalid {
            op.symbol = r.symbol
            op.has_symbol = true
        }
        return op
    }
    return {}
}

@(private)
builtin_operand :: proc(c: ^Checker, name: string) -> Operand {
    switch name {
    case "true":
        return {mode = .Const, type = type_untyped(.Bool), value = true}
    case "false":
        return {mode = .Const, type = type_untyped(.Bool), value = false}
    case "nil":
        return {mode = .Value, type = type_untyped(.Nil)}
    }
    v := constant_value(name, c.snap.target)
    #partial switch v.kind {
    case .Bool:
        return {mode = .Const, type = type_untyped(.Bool), value = v.i != 0}
    case .Int:
        return {mode = .Const, type = type_untyped(.Int), value = v.i}
    case .String:
        return {mode = .Const, type = type_untyped(.String), value = v.s}
    }
    if t := runtime_type(c, odin_constant_type(name)); t != INVALID_TYPE {
        return {mode = .Const, type = t}
    }
    return {mode = .Const}
}

// The base:runtime type of a build constant whose value is an enum member.
@(private)
odin_constant_type :: proc(name: string) -> string {
    switch name {
    case "ODIN_OS":                return "Odin_OS_Type"
    case "ODIN_ARCH":              return "Odin_Arch_Type"
    case "ODIN_BUILD_MODE":        return "Odin_Build_Mode_Type"
    case "ODIN_ENDIAN":            return "Odin_Endian_Type"
    case "ODIN_OPTIMIZATION_MODE": return "Odin_Optimization_Mode"
    case "ODIN_PLATFORM_SUBTARGET": return "Odin_Platform_Subtarget_Type"
    case "ODIN_SANITIZER_FLAGS":   return "Odin_Sanitizer_Flags"
    case "ODIN_ERROR_POS_STYLE":   return "Odin_Error_Pos_Style_Type"
    case "ODIN_WINDOWS_SUBSYSTEM": return "Odin_Windows_Subsystem_Type"
    }
    return ""
}

// The operand a package-level declaration gives.
item_operand :: proc(c: ^Checker, sym: Symbol, builtin := false) -> Operand {
    item := checker_item(c, sym)
    if item == nil {
        return {}
    }
    out: Operand
    #partial switch item.kind {
    case .Import, .Foreign_Import:
        return {}
    case .Proc:
        if builtin {
            return {mode = .Builtin, type = decl_type(c, sym), symbol = sym, has_symbol = true}
        }
        out = {mode = .Value, type = decl_type(c, sym)}
    case .Proc_Group, .Var, .Field:
        out = {mode = .Value, type = decl_type(c, sym)}
    case .Enum_Member:
        out = {mode = .Const, type = decl_type(c, sym)}
    case:
        info := decl_info(c, sym)
        if info.is_type {
            out = {mode = .Type, type = info.type}
        } else {
            v, _ := symbol_const(c, sym, sym.file, item.value_offset, item.value_index)
            out = {mode = .Const, type = info.type, value = v}
        }
    }
    out.symbol = sym
    out.has_symbol = true
    return out
}

@(private)
local_operand :: proc(c: ^Checker, r: Resolved, at: int) -> Operand {
    if len(c.env) > 0 {
        if bound, ok := env_lookup(c, r.symbol); ok {
            return bound
        }
    }
    l := r.local
    info := decl_info(c, r.symbol)
    #partial switch l.kind {
    case .Type:
        return {mode = .Type, type = info.type}
    case .Poly:
        if info.is_type {
            return {mode = .Type, type = info.type}
        }
        return {mode = .Const, type = info.type}
    case .Const:
        if info.is_type {
            return {mode = .Type, type = info.type}
        }
        v, _ := symbol_const(c, r.symbol, r.file, l.value_offset, l.value_index)
        return {mode = .Const, type = info.type, value = v}
    case .Switch_Var:
        if t, ok := switch_clause_type(c, r.file, l, at); ok {
            return {mode = .Value, type = t}
        }
        return {mode = .Value, type = info.type}
    case .Proc, .Var, .Param, .Result, .Loop_Var:
        return {mode = .Value, type = info.type}
    }
    return {}
}

// The type of the case clause of a type switch that holds `at`, for the switch variable `l`.
// False outside a clause, or in a clause of more than one type or none.
@(private)
switch_clause_type :: proc(c: ^Checker, file: File_Id, l: Local, at: int) -> (Type_Id, bool) {
    clause: odinsyntax.Syntax_Node
    in_switch, has_clause := false, false
    for n in node_path(c, file, at) {
        n := n
        #partial switch n.green.kind {
        case .Type_Switch_Stmt:
            ts, _ := odinsyntax.as_type_switch_stmt(n)
            if subject, ok := odinsyntax.type_switch_stmt_subject(&ts); ok && int(subject.offset) == l.value_offset {
                in_switch, has_clause = true, false
            }
        case .Case_Clause:
            if in_switch && !has_clause {
                clause, has_clause = n, true
            }
        }
    }
    if !has_clause {
        return INVALID_TYPE, false
    }
    cc, _ := odinsyntax.as_case_clause(clause)
    values, ok := odinsyntax.case_clause_values(&cc)
    if !ok {
        return INVALID_TYPE, false
    }
    it := odinsyntax.expr_list_items(&values)
    first: odinsyntax.Syntax_Node
    count := 0
    for item in odinsyntax.child_iter_next(&it) {
        if count == 0 {
            first = item
        }
        count += 1
    }
    if count != 1 || (first.green.kind == .Ident && odinsyntax.node_text(first) == "nil") {
        return INVALID_TYPE, false
    }
    t := type_expr(c, file, first)
    return t, t != INVALID_TYPE
}

// The type of a `for ... in` variable: an element, index, key or value of the iterated value.
@(private)
range_var_type :: proc(c: ^Checker, file: File_Id, l: Local) -> Type_Id {
    n, ok := node_at(c, file, l.value_offset)
    if !ok {
        return INVALID_TYPE
    }
    index := l.value_index
    if b, is_binary := odinsyntax.as_binary_expr(n); is_binary {
        op, _ := odinsyntax.binary_expr_op(&b)
        if op.green.kind == .Range_Half || op.green.kind == .Range_Full || op.green.kind == .Ellipsis {
            if index != 0 {
                return type_basic(.Int)
            }
            return expr_type(c, file, n).type
        }
    }
    op := expr_values(c, file, n)
    if tuple, is_tuple := type_get(&c.table, op.type).(Tuple_Type); is_tuple {
        // An iterator call: the values but the last bool.
        if index < len(tuple.types) - 1 {
            return tuple.types[index]
        }
        return INVALID_TYPE
    }
    #partial switch v in type_get(&c.table, deref_base(c, op.type)) {
    case Slice_Type:
        return index == 0 ? v.elem : type_basic(.Int)
    case Array_Type:
        return index == 0 ? v.elem : type_basic(.Int)
    case Dynamic_Array_Type:
        return index == 0 ? v.elem : type_basic(.Int)
    case Simd_Type:
        return index == 0 ? v.elem : type_basic(.Int)
    case Soa_Type:
        return index == 0 ? v.elem : type_basic(.Int)
    case Multi_Pointer_Type:
        return INVALID_TYPE
    case Enumerated_Array_Type:
        return index == 0 ? v.elem : v.index
    case Map_Type:
        return index == 0 ? v.key : v.value
    case Bit_Set_Type:
        if index != 0 {
            return INVALID_TYPE
        }
        return v.range ? type_default(&c.table, v.elem) : v.elem
    case Basic_Type:
        if type_is_string(&c.table, op.type) {
            return index == 0 ? type_basic(.Rune) : type_basic(.Int)
        }
        if type_is_integer(&c.table, op.type) {
            return type_basic(.Int)
        }
    case Untyped_Type:
        if v.kind == .String {
            return index == 0 ? type_basic(.Rune) : type_basic(.Int)
        }
        if v.kind == .Int {
            return type_basic(.Int)
        }
    }
    return INVALID_TYPE
}

// A field of a struct, a bit_field or `any`; one of an embedded `using` field when `depth` > 0.
Field_Hit :: struct {
    type:        Type_Id,
    file:        File_Id, // the file of the record
    name_offset: int,     // -1 for a field with no declaration
    depth:       int,     // the `using` fields it is reached through
}

// The field `name` of a value of type `t`, through one pointer and through `using` fields.
find_field :: proc(c: ^Checker, t: Type_Id, name: string) -> (Field_Hit, bool) {
    return find_field_at(c, t, name, 0)
}

@(private)
USING_DEPTH :: 8

@(private)
find_field_at :: proc(c: ^Checker, t: Type_Id, name: string, depth: int) -> (Field_Hit, bool) {
    if depth > USING_DEPTH {
        return {}, false
    }
    #partial switch v in type_get(&c.table, deref_base(c, t)) {
    case Struct_Type:
        for f in v.fields {
            if f.name == name {
                return {f.type, v.file, f.name_offset, depth}, true
            }
        }
        for f in v.fields {
            if f.is_using {
                if hit, ok := find_field_at(c, f.type, name, depth + 1); ok {
                    return hit, true
                }
            }
        }
    case Bit_Field_Type:
        for f in v.fields {
            if f.name == name {
                return {f.type, v.file, f.name_offset, depth}, true
            }
        }
    case Soa_Type:
        hit, ok := find_field_at(c, v.elem, name, depth)
        if !ok {
            return {}, false
        }
        if v.kind == .Array {
            hit.type = type_array(&c.table, v.len, hit.type)
        } else {
            hit.type = type_multi_pointer(&c.table, hit.type)
        }
        return hit, true
    case Basic_Type:
        if v.kind == .Any {
            switch name {
            case "data": return {type_basic(.Rawptr), NO_FILE, -1, depth}, true
            case "id":   return {type_basic(.Typeid), NO_FILE, -1, depth}, true
            }
        }
    }
    return {}, false
}

// The type of a swizzle of an array of up to four elements: `v.x`, `v.xy`, `c.rgba`.
@(private)
swizzle_type :: proc(c: ^Checker, t: Type_Id, name: string) -> (Type_Id, bool) {
    a, ok := type_get(&c.table, deref_base(c, t)).(Array_Type)
    if !ok || a.len < 1 || a.len > 4 || len(name) < 1 || len(name) > 4 {
        return INVALID_TYPE, false
    }
    xyzw, rgba := true, true
    for ch in name {
        i := strings.index_rune("xyzw", ch)
        j := strings.index_rune("rgba", ch)
        xyzw = xyzw && i >= 0 && i64(i) < a.len
        rgba = rgba && j >= 0 && i64(j) < a.len
    }
    if !xyzw && !rgba {
        return INVALID_TYPE, false
    }
    if len(name) == 1 {
        return a.elem, true
    }
    return type_array(&c.table, i64(len(name)), a.elem), true
}

@(private)
selector_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Operand {
    sel, _ := odinsyntax.as_selector_expr(n)
    operand, has_operand := odinsyntax.selector_expr_operand(&sel)
    field, has_field := odinsyntax.selector_expr_field(&sel)
    if !has_operand || !has_field {
        return {}
    }
    name := odinsyntax.node_text(odinsyntax.Syntax_Node(field))
    op := expr_type(c, file, operand)
    #partial switch op.mode {
    case .Package:
        sym, ok := member_lookup(c, op.dir, name, NO_FILE, true, true)
        if !ok {
            return {}
        }
        return item_operand(c, sym)
    case .Type:
        if e, is_enum := type_get(&c.table, type_base(&c.table, op.type)).(Enum_Type); is_enum {
            for m in e.members {
                if m.name == name {
                    return {mode = .Const, type = op.type, value = m.value, symbol = local_symbol(e.file, m.name_offset), has_symbol = true}
                }
            }
        }
    case .Value, .Const:
        if hit, ok := find_field(c, op.type, name); ok {
            out := Operand{mode = .Value, type = hit.type}
            if hit.name_offset >= 0 {
                out.symbol = local_symbol(hit.file, hit.name_offset)
                out.has_symbol = true
            }
            return out
        }
        if t, ok := swizzle_type(c, op.type, name); ok {
            return {mode = .Value, type = t}
        }
    }
    return {}
}

// `.Member` against the type the context expects: an enum, the enum of a bit_set, or an enum variant of a union.
@(private)
implicit_operand :: proc(c: ^Checker, name: string, expected: Type_Id) -> Operand {
    t := expected
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Bit_Set_Type:
        t = v.elem
    case Union_Type:
        for variant in v.variants {
            if op := implicit_operand(c, name, variant); op.mode != .Invalid {
                return op
            }
        }
        return {}
    case Pointer_Type:
        t = v.elem
    }
    e, is_enum := type_get(&c.table, type_base(&c.table, t)).(Enum_Type)
    if !is_enum {
        return {}
    }
    for m in e.members {
        if m.name == name {
            return {mode = .Const, type = t, value = m.value, symbol = local_symbol(e.file, m.name_offset), has_symbol = true}
        }
    }
    return {}
}

// The element `x[i]` gives for a value of type `t`; a map gives (value, bool).
@(private)
index_operand :: proc(c: ^Checker, t: Type_Id) -> Operand {
    #partial switch v in type_get(&c.table, deref_base(c, t)) {
    case Array_Type:            return {mode = .Value, type = v.elem}
    case Slice_Type:            return {mode = .Value, type = v.elem}
    case Dynamic_Array_Type:    return {mode = .Value, type = v.elem}
    case Multi_Pointer_Type:    return {mode = .Value, type = v.elem}
    case Enumerated_Array_Type: return {mode = .Value, type = v.elem}
    case Simd_Type:             return {mode = .Value, type = v.elem}
    case Soa_Type:              return {mode = .Value, type = v.elem}
    case Matrix_Type:           return {mode = .Value, type = v.elem}
    case Map_Type:              return with_ok(c, v.value)
    case Basic_Type:
        #partial switch v.kind {
        case .String, .Cstring:     return {mode = .Value, type = type_basic(.U8)}
        case .String16, .Cstring16: return {mode = .Value, type = type_basic(.U16)}
        }
    case Untyped_Type:
        if v.kind == .String {
            return {mode = .Value, type = type_basic(.U8)}
        }
    }
    return {}
}

@(private)
slice_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Operand {
    se, _ := odinsyntax.as_slice_expr(n)
    operand, ok := odinsyntax.slice_expr_operand(&se)
    if !ok {
        return {}
    }
    op := expr_type(c, file, operand)
    #partial switch v in type_get(&c.table, deref_base(c, op.type)) {
    case Array_Type:
        return {mode = .Value, type = type_slice(&c.table, v.elem)}
    case Slice_Type:
        return {mode = .Value, type = type_slice(&c.table, v.elem)}
    case Dynamic_Array_Type:
        return {mode = .Value, type = type_slice(&c.table, v.elem)}
    case Multi_Pointer_Type:
        if _, has_high := odinsyntax.slice_expr_high(&se); has_high {
            return {mode = .Value, type = type_slice(&c.table, v.elem)}
        }
        return {mode = .Value, type = op.type}
    case Soa_Type:
        return {mode = .Value, type = type_soa(&c.table, .Slice, v.elem)}
    case Basic_Type, Untyped_Type:
        if type_is_string(&c.table, op.type) {
            return {mode = .Value, type = type_default(&c.table, op.type)}
        }
    }
    return {}
}

// `x.(T)` or `x.?`: (T, bool), where `.?` takes the one variant of the union.
@(private)
assertion_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Operand {
    ta, _ := odinsyntax.as_type_assertion(n)
    if type, ok := odinsyntax.type_assertion_type(&ta); ok {
        return with_ok(c, type_expr(c, file, type))
    }
    operand, ok := odinsyntax.type_assertion_operand(&ta)
    if !ok {
        return {}
    }
    u, is_union := type_get(&c.table, type_base(&c.table, expr_type(c, file, operand).type)).(Union_Type)
    if !is_union || len(u.variants) != 1 {
        return {}
    }
    return with_ok(c, u.variants[0])
}

// A composite literal: its own type, else the expected one. `[?]T{...}` takes its length from its elements.
@(private)
comp_lit_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, expected: Type_Id) -> Operand {
    cl, _ := odinsyntax.as_comp_lit(n)
    type, ok := odinsyntax.comp_lit_type(&cl)
    if !ok {
        return {mode = .Value, type = expected}
    }
    t := type_expr(c, file, type)
    if a, is_array := type_get(&c.table, t).(Array_Type); is_array && a.len < 0 {
        count: i64 = 0
        it := odinsyntax.comp_lit_elems(&cl)
        for _ in odinsyntax.child_iter_next(&it) {
            count += 1
        }
        t = type_array(&c.table, count, a.elem)
    }
    return {mode = .Value, type = t}
}

// The value of a constant declaration, read once per checker.
@(private)
symbol_const :: proc(c: ^Checker, sym: Symbol, file: File_Id, value_offset, value_index: int) -> (Const_Value, bool) {
    if info, ok := c.consts[sym]; ok {
        return info.value, info.ok
    }
    if value_index >= 0 || sym in c.evaluating {
        return nil, false
    }
    value, ok := node_at(c, file, value_offset)
    if !ok {
        return nil, false
    }
    _, _, _, eerr := map_entry(&c.evaluating, sym)
    if !note_alloc(c, eerr) {
        return nil, false
    }
    saved := c.enum_env
    c.enum_env = nil
    v, vok := const_eval(c, file, value)
    c.enum_env = saved
    delete_key(&c.evaluating, sym)
    _, entry, _, err := map_entry(&c.consts, sym)
    if note_alloc(c, err) {
        entry^ = Const_Info{v, vok}
    }
    return v, vok
}
