// Uses of declarations marked `@(deprecated)` (`api/deprecated`).
package odinsema

import odinsyntax "../syntax"

// The offset and name of the identifier of `expr`, a bare name or a selector, when it names a
// declaration with a `deprecated` attribute, and the message of the attribute.
deprecated_use :: proc(c: ^Checker, file: File_Id, expr: odinsyntax.Syntax_Node) -> (offset: int, name, message: string, ok: bool) {
    expr := expr
    ident: odinsyntax.Syntax_Node
    #partial switch expr.green.kind {
    case .Ident:
        ident = expr
    case .Selector_Expr:
        sel, _ := odinsyntax.as_selector_expr(expr)
        field  := odinsyntax.selector_expr_field(&sel) or_return
        ident = odinsyntax.Syntax_Node(field)
    case:
        return
    }
    op := expr_type(c, file, expr)
    if op.mode == .Invalid || !op.has_symbol {
        return
    }
    item := checker_item(c, op.symbol)
    if item == nil {
        return
    }
    for a in item.attributes {
        if a.name == "deprecated" {
            return int(ident.offset), odinsyntax.node_text(ident), unquote(a.value), true
        }
    }
    return
}

// The offset of the callee name of `call` of `file`, the name of the member a procedure group call
// picks and the name of the group, when that member has a `deprecated` attribute, and the message of
// the attribute. False when the member is not known or more than one member has its type.
group_member_deprecated :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node) -> (offset: int, member, group, message: string, ok: bool) {
    ce     := odinsyntax.as_call_expr(call) or_return
    callee := odinsyntax.call_expr_callee(&ce) or_return
    ident  := callee
    #partial switch callee.green.kind {
    case .Ident:
    case .Selector_Expr:
        sel, _ := odinsyntax.as_selector_expr(callee)
        field  := odinsyntax.selector_expr_field(&sel) or_return
        ident = odinsyntax.Syntax_Node(field)
    case:
        return
    }
    fn := expr_type(c, file, callee)
    if fn.mode == .Invalid || !fn.has_symbol {
        return
    }
    item := checker_item(c, fn.symbol)
    if item == nil || item.kind != .Proc_Group || item.value_offset < 0 {
        return
    }
    chosen := call_group_member(c, file, call)
    if chosen == INVALID_TYPE {
        return
    }
    group_file := fn.symbol.file
    node       := node_of_kind(c, group_file, item.value_offset, .Proc_Group) or_return
    g, _       := odinsyntax.as_proc_group(node)
    found: Symbol
    count := 0
    it    := odinsyntax.proc_group_members(&g)
    for m in odinsyntax.child_iter_next(&it) {
        op := expr_type(c, group_file, m)
        if op.has_symbol && op.type == chosen {
            found = op.symbol
            count += 1
        }
    }
    if count != 1 {
        return
    }
    picked := checker_item(c, found)
    if picked == nil {
        return
    }
    for a in picked.attributes {
        if a.name == "deprecated" {
            return int(ident.offset), picked.name, odinsyntax.node_text(ident), unquote(a.value), true
        }
    }
    return
}

// The type expressions `n` holds directly: the type of a field, a declaration or a compound
// literal, the element of a pointer, array, variadic or distinct type, the key and value of a map.
type_children :: proc(n: odinsyntax.Syntax_Node) -> (out: [2]odinsyntax.Syntax_Node, count: int) {
    n := n
    add :: proc(out: ^[2]odinsyntax.Syntax_Node, count: ^int, t: odinsyntax.Syntax_Node, ok: bool) {
        if ok && count^ < len(out) {
            out[count^] = t
            count^ += 1
        }
    }
    #partial switch n.green.kind {
    case .Field:
        f, _  := odinsyntax.as_field(n)
        t, ok := odinsyntax.field_type(&f)
        add(&out, &count, t, ok)
    case .Value_Decl:
        v, _  := odinsyntax.as_value_decl(n)
        t, ok := odinsyntax.value_decl_type(&v)
        add(&out, &count, t, ok)
    case .Comp_Lit:
        cl, _ := odinsyntax.as_comp_lit(n)
        t, ok := odinsyntax.comp_lit_type(&cl)
        add(&out, &count, t, ok)
    case .Pointer_Type:
        p, _  := odinsyntax.as_pointer_type(n)
        t, ok := odinsyntax.pointer_type_elem(&p)
        add(&out, &count, t, ok)
    case .Multi_Pointer_Type:
        p, _  := odinsyntax.as_multi_pointer_type(n)
        t, ok := odinsyntax.multi_pointer_type_elem(&p)
        add(&out, &count, t, ok)
    case .Array_Type:
        a, _  := odinsyntax.as_array_type(n)
        t, ok := odinsyntax.array_type_elem(&a)
        add(&out, &count, t, ok)
    case .Dynamic_Array_Type:
        a, _  := odinsyntax.as_dynamic_array_type(n)
        t, ok := odinsyntax.dynamic_array_type_elem(&a)
        add(&out, &count, t, ok)
    case .Ellipsis_Type:
        e, _  := odinsyntax.as_ellipsis_type(n)
        t, ok := odinsyntax.ellipsis_type_elem(&e)
        add(&out, &count, t, ok)
    case .Distinct_Type:
        d, _  := odinsyntax.as_distinct_type(n)
        t, ok := odinsyntax.distinct_type_type(&d)
        add(&out, &count, t, ok)
    case .Map_Type:
        m, _   := odinsyntax.as_map_type(n)
        k, kok := odinsyntax.map_type_key(&m)
        add(&out, &count, k, kok)
        v, vok := odinsyntax.map_type_value(&m)
        add(&out, &count, v, vok)
    }
    return
}
