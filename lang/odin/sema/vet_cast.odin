package odinsema

import "core:strings"

import odinsyntax "../syntax"

// A `cast` or `transmute` to the type its operand already has, or a `transmute` a `cast` can do.
Vet_Cast :: struct {
    offset:       int,    // the operand of a `cast`, the expression of a `transmute`
    operand:      string, // borrows the text of the parse
    type:         Type_Id,
    is_transmute: bool,
    prefer_cast:  bool, // a `transmute` between integers of one endianness; `from` is the operand's type
    from:         Type_Id,
}

// The redundant conversion `n` holds, as `-vet-cast` reports it: the operand already has the type,
// compared by type id so an alias and a distinct type of the same name count. An untyped constant
// operand and anything inside a polymorphic procedure, which the compiler checks per instance, are not
// reported.
vet_cast :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (out: Vet_Cast, ok: bool) {
    ce           := odinsyntax.as_cast_expr(n) or_return
    keyword      := odinsyntax.cast_expr_keyword(&ce) or_return
    type_node    := odinsyntax.cast_expr_type(&ce) or_return
    operand      := odinsyntax.cast_expr_operand(&ce) or_return
    is_transmute := keyword.green.kind == .Transmute
    if !is_transmute && keyword.green.kind != .Cast {
        return
    }
    if in_poly_proc(n) {
        return
    }
    to   := type_expr(c, file, type_node)
    from := expr_type(c, file, operand)
    if to == INVALID_TYPE || from.mode != .Value || from.type == INVALID_TYPE {
        return
    }
    if type_has_unknown(&c.table, to) || type_has_unknown(&c.table, from.type) {
        return
    }
    if from.type != to {
        if !is_transmute || type_is_untyped(&c.table, from.type) || !type_is_integer(&c.table, from.type) || !type_is_integer(&c.table, to) {
            return
        }
        if integer_endian(&c.table, from.type) != integer_endian(&c.table, to) {
            return
        }
        return Vet_Cast{
            offset = int(n.offset),
            operand = strings.trim_space(odinsyntax.node_text(n)),
            type = to,
            is_transmute = true,
            prefer_cast = true,
            from = from.type,
        }, true
    }
    out = Vet_Cast{offset = int(operand.offset), operand = strings.trim_space(odinsyntax.node_text(operand)), type = to, is_transmute = is_transmute}
    if is_transmute {
        out.offset = int(n.offset)
        out.operand = strings.trim_space(odinsyntax.node_text(n))
    }
    return out, true
}

// How an integer type states its byte order: 0 native, 1 `le`, 2 `be`. The compiler compares the
// spelling, so `u16le` and `i16` differ even on a little-endian target.
@(private = "file")
integer_endian :: proc(t: ^Type_Table, id: Type_Id) -> int {
    if b, ok := type_get(t, type_base(t, id)).(Basic_Type); ok {
        #partial switch b.kind {
        case .I16le ..= .U128le:
            return 1
        case .I16be ..= .U128be:
            return 2
        }
    }
    return 0
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
