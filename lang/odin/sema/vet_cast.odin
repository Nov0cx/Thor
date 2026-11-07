package odinsema

import "core:strings"

import odinsyntax "../syntax"

// A `cast` or `transmute` to the type its operand already has.
Vet_Cast :: struct {
    offset:    int,    // the operand of a `cast`, the expression of a `transmute`
    operand:   string, // borrows the text of the parse
    type:      Type_Id,
    is_transmute: bool,
}

// The redundant conversion `n` holds, as `-vet-cast` reports it: the operand already has the type,
// compared by type id so an alias and a distinct type of the same name count. An untyped constant
// operand and anything inside a polymorphic procedure, which the compiler checks per instance, are not
// reported.
vet_cast :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (out: Vet_Cast, ok: bool) {
    ce := odinsyntax.as_cast_expr(n) or_return
    keyword := odinsyntax.cast_expr_keyword(&ce) or_return
    type_node := odinsyntax.cast_expr_type(&ce) or_return
    operand := odinsyntax.cast_expr_operand(&ce) or_return
    is_transmute := keyword.green.kind == .Transmute
    if !is_transmute && keyword.green.kind != .Cast {
        return
    }
    if in_poly_proc(n) {
        return
    }
    to := type_expr(c, file, type_node)
    from := expr_type(c, file, operand)
    if to == INVALID_TYPE || from.mode != .Value || from.type != to {
        return
    }
    if type_has_unknown(&c.table, to) {
        return
    }
    out = Vet_Cast {
        offset    = int(operand.offset),
        operand   = strings.trim_space(odinsyntax.node_text(operand)),
        type      = to,
        is_transmute = is_transmute,
    }
    if is_transmute {
        out.offset = int(n.offset)
        out.operand = strings.trim_space(odinsyntax.node_text(n))
    }
    return out, true
}

// True when a procedure literal around `n` has a polymorphic parameter or result.
@(private = "file")
in_poly_proc :: proc(n: odinsyntax.Syntax_Node) -> bool {
    for p := n.parent; p != nil; p = p.parent {
        if p.green.kind != .Proc_Lit {
            continue
        }
        lit, _ := odinsyntax.as_proc_lit(p^)
        if pt, has := odinsyntax.proc_lit_type(&lit); has && strings.contains(odinsyntax.node_text(odinsyntax.Syntax_Node(pt)), "$") {
            return true
        }
    }
    return false
}

// True when `id` is, or is built from, a polymorphic parameter.
@(private = "file")
type_has_unknown :: proc(t: ^Type_Table, id: Type_Id) -> bool {
    return strings.contains(type_string(t, id, context.temp_allocator), "$")
}
