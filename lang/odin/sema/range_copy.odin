// Range loops that copy a large element on every iteration (`perf/range-copy`).
package odinsema

import odinsyntax "../syntax"

// The element size in bytes from which a copy per iteration is worth a hint.
RANGE_COPY_SIZE :: 512

// The offset, name and size of the value variable of the range loop `loop` when it copies a large
// element and only reads it. A `for &v` variable, a map, a string and a variable the body takes the
// address of, slices or assigns through are left out.
range_copy :: proc(c: ^Checker, m: ^Scope_Map, file: File_Id, loop: odinsyntax.Syntax_Node) -> (offset: int, name: string, size: i64, ok: bool) {
    rs    := odinsyntax.as_range_stmt(loop) or_return
    vars  := odinsyntax.range_stmt_vars(&rs) or_return
    it    := odinsyntax.expr_list_items(&vars)
    first := odinsyntax.child_iter_next(&it) or_return
    if first.green.kind != .Ident || odinsyntax.node_text(first) == "_" {
        return
    }
    subject := odinsyntax.range_stmt_expr(&rs) or_return
    op      := expr_type(c, file, subject)
    if op.mode != .Value {
        return
    }
    t    := &c.table
    elem := INVALID_TYPE
    #partial switch v in type_get(t, type_base(t, op.type)) {
    case Slice_Type:
        elem = v.elem
    case Array_Type:
        elem = v.elem
    case Dynamic_Array_Type:
        elem = v.elem
    case Enumerated_Array_Type:
        elem = v.elem
    case:
        return
    }
    layout, known := layout_of(c, elem)
    if !known || layout.size < RANGE_COPY_SIZE {
        return
    }
    if !only_read(c, m, file, int(first.offset)) {
        return
    }
    return int(first.offset), odinsyntax.node_text(first), layout.size, true
}

// True when no use of the local declared at `decl` takes its address, slices it or assigns to it
// or to a part of it.
@(private = "file")
only_read :: proc(c: ^Checker, m: ^Scope_Map, file: File_Id, decl: int) -> bool {
    temp := scratch_begin(c)
    defer scratch_end(temp)
    for r in m.refs {
        if r.kind != .Local || r.decl != decl || r.is_decl {
            continue
        }
        path := path_copy(c, file, r.start)
        if len(path) == 0 || path[len(path) - 1].green.kind != .Ident {
            return false
        }
        if written(path) {
            return false
        }
    }
    return true
}

// True when the identifier at the end of `path` is, or is a part of, an address taken, a slice or
// the target of an assignment.
@(private = "file")
written :: proc(path: []odinsyntax.Syntax_Node) -> bool {
    j := len(path) - 1
    for j > 0 {
        parent := path[j - 1]
        child  := path[j]
        #partial switch parent.green.kind {
        case .Paren_Expr, .Expr_List:
        case .Selector_Expr:
            sel, _      := odinsyntax.as_selector_expr(parent)
            operand, ok := odinsyntax.selector_expr_operand(&sel)
            if !ok || !same_node(operand, child) {
                return false
            }
        case .Index_Expr:
            ie, _       := odinsyntax.as_index_expr(parent)
            operand, ok := odinsyntax.index_expr_operand(&ie)
            if !ok || !same_node(operand, child) {
                return false
            }
        case .Slice_Expr:
            return true
        case .Unary_Expr:
            u, _   := odinsyntax.as_unary_expr(parent)
            op, ok := odinsyntax.unary_expr_op(&u)
            return ok && op.green.kind == .And
        case .Assign_Stmt:
            as, _   := odinsyntax.as_assign_stmt(parent)
            lhs, ok := odinsyntax.assign_stmt_lhs(&as)
            if !ok {
                return false
            }
            return child.offset >= lhs.offset && child.offset < lhs.offset + lhs.green.text_len
        case:
            return false
        }
        j -= 1
    }
    return false
}
