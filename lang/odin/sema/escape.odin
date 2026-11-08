// Addresses and slices of a local that outlive its frame (`mem/dangling-slice`).
package odinsema

import "core:strings"

import odinsyntax "../syntax"

// The root local of the place `n` and the offset of the expression that takes its address or
// slice, when `n` is `&x`, `&x.f`, `&x[i]` or `x[a:b]` with `x` a by-value local of the procedure.
// A `@(static)` local, a `for &v` variable and a pointer or slice local are left out.
dangling_place :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (offset: int, name: string, ok: bool) {
    n := n
    for n.green.kind == .Paren_Expr {
        p, _ := odinsyntax.as_paren_expr(n)
        n = odinsyntax.paren_expr_expr(&p) or_return
    }
    #partial switch n.green.kind {
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        op := odinsyntax.unary_expr_op(&u) or_return
        if op.green.kind != .And {
            return
        }
        operand := odinsyntax.unary_expr_operand(&u) or_return
        root := by_value_root(c, file, operand) or_return
        return int(n.offset), root_name(root), true
    case .Slice_Expr:
        se, _ := odinsyntax.as_slice_expr(n)
        operand := odinsyntax.slice_expr_operand(&se) or_return
        if !fixed_array(c, file, operand) {
            return
        }
        root := by_value_root(c, file, operand) or_return
        return int(n.offset), root_name(root), true
    }
    return
}

// True when assigning to the place `lhs` stores into memory that outlives the frame: a global, a
// named result, or what a pointer or slice parameter points at.
// A named result counts only when `results` is set.
outliving_store :: proc(c: ^Checker, file: File_Id, lhs: odinsyntax.Syntax_Node, results := true) -> bool {
    n := lhs
    through_pointer := false
    for {
        #partial switch n.green.kind {
        case .Paren_Expr:
            p, _ := odinsyntax.as_paren_expr(n)
            n = odinsyntax.paren_expr_expr(&p) or_return
        case .Deref_Expr:
            d, _ := odinsyntax.as_deref_expr(n)
            n = odinsyntax.deref_expr_operand(&d) or_return
            through_pointer = true
        case .Selector_Expr:
            sel, _ := odinsyntax.as_selector_expr(n)
            _, arrow := odinsyntax.selector_expr_arrow(&sel)
            n = odinsyntax.selector_expr_operand(&sel) or_return
            through_pointer ||= arrow || !inline_record(c, file, n)
        case .Index_Expr:
            ie, _ := odinsyntax.as_index_expr(n)
            n = odinsyntax.index_expr_operand(&ie) or_return
            through_pointer ||= !fixed_array(c, file, n)
        case .Ident:
            r := lookup_name(c, file, odinsyntax.node_text(n), int(n.offset))
            #partial switch r.kind {
            case .Item:
                return true
            case .Local:
                if r.local.kind == .Result {
                    return results && !through_pointer
                }
                if r.local.kind == .Param && through_pointer {
                    t := type_get(&c.table, type_base(&c.table, expr_type(c, file, n).type))
                    #partial switch _ in t {
                    case Pointer_Type, Multi_Pointer_Type, Slice_Type:
                        return true
                    }
                }
            }
            return false
        case:
            return false
        }
    }
}

// The offset of `n` and the call that made it, when `n` is a value from the temp allocator: a call
// given `context.temp_allocator` or a `tprint*` call, or a local declared with one, or a slice of
// either, or a local copied from one. A procedure whose own name has `temp` or `tprint` in it stores such values on purpose.
temp_place :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, depth := 0) -> (offset: int, ok: bool) {
    if temp_helper(n) {
        return
    }
    n := n
    for {
        #partial switch n.green.kind {
        case .Paren_Expr:
            p, _ := odinsyntax.as_paren_expr(n)
            n = odinsyntax.paren_expr_expr(&p) or_return
        case .Slice_Expr:
            se, _ := odinsyntax.as_slice_expr(n)
            n = odinsyntax.slice_expr_operand(&se) or_return
        case .Call_Expr:
            return int(n.offset), temp_call(n)
        case .Ident:
            r := lookup_name(c, file, odinsyntax.node_text(n), int(n.offset))
            if r.kind != .Local || r.local.kind != .Var || static_local(c, file, r.local.name_offset) {
                return
            }
            value := local_value(c, file, r.local.name_offset) or_return
            // A copy of another temp local carries the taint.
            if depth < 4 && (value.green.kind == .Ident || value.green.kind == .Slice_Expr) {
                _, tainted := temp_place(c, file, value, depth + 1)
                return int(n.offset), tainted
            }
            return int(n.offset), temp_call(value)
        case:
            return
        }
    }
}

// The value a plain `:=` or `:` declaration gives the local declared at `name_offset`.
@(private = "file")
local_value :: proc(c: ^Checker, file: File_Id, name_offset: int) -> (value: odinsyntax.Syntax_Node, ok: bool) {
    path := node_path(c, file, name_offset)
    #reverse for d in path {
        if d.green.kind != .Value_Decl {
            continue
        }
        d := d
        v, result, found := decl_value(&d, name_offset)
        if !found || result > 0 {
            return
        }
        for v.green.kind == .Paren_Expr {
            p, _ := odinsyntax.as_paren_expr(v)
            v = odinsyntax.paren_expr_expr(&p) or_return
        }
        return v, true
    }
    return
}

// True when `n` is a call that takes `context.temp_allocator`, or a `tprint*` call.
@(private = "file")
temp_call :: proc(n: odinsyntax.Syntax_Node) -> bool {
    if n.green.kind != .Call_Expr {
        return false
    }
    ce, _ := odinsyntax.as_call_expr(n)
    if callee, has := odinsyntax.call_expr_callee(&ce); has {
        text := odinsyntax.node_text(callee)
        if strings.has_suffix(text, "tprint") || strings.has_suffix(text, "tprintf") || strings.has_suffix(text, "tprintln") {
            return true
        }
    }
    list := odinsyntax.call_expr_args(&ce) or_return
    it := odinsyntax.arg_list_args(&list)
    for arg in odinsyntax.child_iter_next(&it) {
        if strings.has_suffix(odinsyntax.node_text(arg), "context.temp_allocator") {
            return true
        }
    }
    return false
}

// True when `n` is in a procedure whose name has `temp` or `tprint` in it.
@(private = "file")
temp_helper :: proc(n: odinsyntax.Syntax_Node) -> bool {
    for p := n.parent; p != nil; p = p.parent {
        if p.green.kind != .Value_Decl {
            continue
        }
        v, _ := odinsyntax.as_value_decl(p^)
        names, has := odinsyntax.value_decl_names(&v)
        if !has {
            return false
        }
        text := odinsyntax.node_text(odinsyntax.Syntax_Node(names))
        return strings.contains(text, "temp") || strings.contains(text, "tprint")
    }
    return false
}

// True when a `defer` in the block of `stmt` assigns to the place `target`, which resets it on exit.
cleared_by_defer :: proc(stmt, target: odinsyntax.Syntax_Node) -> bool {
    p := stmt.parent
    if p == nil {
        return false
    }
    want := odinsyntax.node_text(target)
    it := odinsyntax.child_iter(p, {kinds = ~odinsyntax.Kind_Set{}})
    for sibling in odinsyntax.child_iter_next(&it) {
        if sibling.green.kind == .Defer_Stmt && strings.contains(odinsyntax.node_text(sibling), want) {
            return true
        }
    }
    return false
}

// The name of the identifier `root`.
@(private = "file")
root_name :: proc(root: odinsyntax.Syntax_Node) -> string {
    return odinsyntax.node_text(root)
}

// True when `n` has a fixed array type, which a slice of keeps pointing into the frame.
@(private = "file")
fixed_array :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> bool {
    t := type_get(&c.table, type_base(&c.table, expr_type(c, file, n).type))
    #partial switch _ in t {
    case Array_Type, Enumerated_Array_Type:
        return true
    }
    return false
}

// The identifier at the root of the place `n` when every step from it stays inside the local's own
// storage (a field of a record, an element of a fixed array) and it names a plain local.
@(private = "file")
by_value_root :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (root: odinsyntax.Syntax_Node, ok: bool) {
    n := n
    for {
        #partial switch n.green.kind {
        case .Paren_Expr:
            p, _ := odinsyntax.as_paren_expr(n)
            n = odinsyntax.paren_expr_expr(&p) or_return
        case .Selector_Expr:
            sel, _ := odinsyntax.as_selector_expr(n)
            if _, arrow := odinsyntax.selector_expr_arrow(&sel); arrow {
                return
            }
            operand := odinsyntax.selector_expr_operand(&sel) or_return
            if !inline_record(c, file, operand) {
                return
            }
            n = operand
        case .Index_Expr:
            ie, _ := odinsyntax.as_index_expr(n)
            operand := odinsyntax.index_expr_operand(&ie) or_return
            if !fixed_array(c, file, operand) {
                return
            }
            n = operand
        case .Ident:
            return n, plain_local(c, file, n)
        case:
            return
        }
    }
}

// True when `n` is a record or a union held by value, whose fields lie in its own storage.
@(private = "file")
inline_record :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> bool {
    t := type_get(&c.table, type_base(&c.table, expr_type(c, file, n).type))
    #partial switch _ in t {
    case Struct_Type, Union_Type:
        return true
    }
    return false
}

// True when the identifier `n` names a variable or named result of a procedure body that is held
// by value in the frame.
@(private = "file")
plain_local :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> bool {
    r := lookup_name(c, file, odinsyntax.node_text(n), int(n.offset))
    if r.kind != .Local || r.local.is_using {
        return false
    }
    if r.local.kind != .Var && r.local.kind != .Result {
        return false
    }
    if static_local(c, file, r.local.name_offset) {
        return false
    }
    t := type_get(&c.table, type_base(&c.table, expr_type(c, file, n).type))
    #partial switch _ in t {
    case Pointer_Type, Multi_Pointer_Type, Slice_Type, Dynamic_Array_Type, Map_Type:
        return false
    }
    return true
}

// True when the local declared at `name_offset` has a `static` attribute.
@(private = "file")
static_local :: proc(c: ^Checker, file: File_Id, name_offset: int) -> bool {
    path := node_path(c, file, name_offset)
    #reverse for d in path {
        if d.green.kind != .Value_Decl {
            continue
        }
        v, _ := odinsyntax.as_value_decl(d)
        attrs := odinsyntax.value_decl_attributes(&v)
        for attr in odinsyntax.child_iter_next(&attrs) {
            if contains_static(attr) {
                return true
            }
        }
        return false
    }
    return false
}

// True when the attribute `n` names or sets `static`.
@(private = "file")
contains_static :: proc(n: odinsyntax.Syntax_Node) -> bool {
    n := n
    a, _ := odinsyntax.as_attribute(n)
    elems := odinsyntax.attribute_elems(&a)
    for e in odinsyntax.child_iter_next(&elems) {
        text := odinsyntax.node_text(e)
        if text == "static" || (len(text) > 6 && text[:6] == "static" && (text[6] == ' ' || text[6] == '=')) {
            return true
        }
    }
    return false
}
