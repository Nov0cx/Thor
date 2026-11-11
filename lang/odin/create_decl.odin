// Quick fixes that declare a name no scope binds.
package odin

import "core:fmt"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Offers a declaration for the unresolved identifier under the caret: a procedure for a callee, a
// struct for a type, `:=` for the place of a plain `=`, else a variable of the expected type.
@(private)
create_decl_fixes :: proc(rc: ^Request_Context, caret: Caret, res: ^lang.Result) {
    src := rc.req.source
    start, end := caret.offset, caret.offset
    for start > 0 && is_word_byte(src[start - 1]) {
        start -= 1
    }
    for end < len(src) && is_word_byte(src[end]) {
        end += 1
    }
    if start == end || !odinsema.is_identifier(src[start:end]) {
        return
    }
    if (end < len(src) && src[end] == '.') || (start > 0 && src[start - 1] == '.') {
        return
    }
    c := request_checker(rc)
    if c == nil {
        return
    }
    tokens, ok := semantic_classify(rc, start, end, strict = true)
    if !ok {
        return
    }
    unresolved := false
    for t in tokens {
        if t.start == start && t.kind == .Unresolved {
            unresolved = true
        }
    }
    if !unresolved {
        return
    }
    tok, found := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(start), context.temp_allocator)
    if !found || tok.parent == nil || tok.parent.green.kind != .Ident || tok.parent.parent == nil {
        return
    }
    ident  := tok.parent^
    parent := tok.parent.parent^
    name   := src[start:end]
    switch {
    case is_callee(parent, ident):
        create_proc(rc, c, name, parent, res)
    case is_type_place(parent, ident):
        create_struct(rc, c, name, parent, ident, res)
    case is_single_store(parent, ident):
        declare_store(rc, parent, name, res)
    case:
        create_variable(rc, c, name, ident, res)
    }
}

@(private = "file")
same :: proc(a, b: odinsyntax.Syntax_Node) -> bool {
    return a.green == b.green && a.offset == b.offset
}

@(private = "file")
is_callee :: proc(parent, ident: odinsyntax.Syntax_Node) -> bool {
    ce, is_call := odinsyntax.as_call_expr(parent)
    if !is_call {
        return false
    }
    callee, ok := odinsyntax.call_expr_callee(&ce)
    return ok && same(callee, ident)
}

// True when `ident` stands where a type is written.
@(private = "file")
is_type_place :: proc(parent, ident: odinsyntax.Syntax_Node) -> bool {
    parent := parent
    #partial switch parent.green.kind {
    case .Comp_Lit:
        cl    := odinsyntax.Comp_Lit(parent)
        t, ok := odinsyntax.comp_lit_type(&cl)
        return ok && same(t, ident)
    case .Value_Decl:
        vd    := odinsyntax.Value_Decl(parent)
        t, ok := odinsyntax.value_decl_type(&vd)
        return ok && same(t, ident)
    case .Field:
        f := odinsyntax.Field(parent)
        if names, ok := odinsyntax.field_names(&f); ok {
            ns, ne := odinsyntax.node_range(odinsyntax.Syntax_Node(names))
            if ident.offset >= ns && ident.offset < ne {
                return false
            }
        }
        if d, ok := odinsyntax.field_default(&f); ok && same(d, ident) {
            return false
        }
        return true
    case .Array_Type:
        at       := odinsyntax.Array_Type(parent)
        elem, ok := odinsyntax.array_type_elem(&at)
        return ok && same(elem, ident)
    case .Matrix_Type:
        mt       := odinsyntax.Matrix_Type(parent)
        elem, ok := odinsyntax.matrix_type_elem(&mt)
        return ok && same(elem, ident)
    case .Pointer_Type, .Multi_Pointer_Type, .Dynamic_Array_Type, .Ellipsis_Type, .Distinct_Type, .Map_Type:
        return true
    }
    return false
}

// True when `ident` is the only place of a plain `=` assignment.
@(private = "file")
is_single_store :: proc(list, ident: odinsyntax.Syntax_Node) -> bool {
    if list.green.kind != .Expr_List || list.parent == nil {
        return false
    }
    as, is_assign := odinsyntax.as_assign_stmt(list.parent^)
    if !is_assign {
        return false
    }
    lhs, has_lhs := odinsyntax.assign_stmt_lhs(&as)
    op, has_op   := odinsyntax.assign_stmt_op(&as)
    if !has_lhs || !has_op || op.green.kind != .Eq || lhs.offset != list.offset {
        return false
    }
    count := 0
    it    := odinsyntax.expr_list_items(&lhs)
    for _ in odinsyntax.child_iter_next(&it) {
        count += 1
    }
    return count == 1
}

// Declares a procedure that takes the arguments of the call `parent`.
@(private = "file")
create_proc :: proc(rc: ^Request_Context, c: ^odinsema.Checker, name: string, call: odinsyntax.Syntax_Node, res: ^lang.Result) {
    file           := rc.live.id
    ce, _          := odinsyntax.as_call_expr(call)
    args, has_args := odinsyntax.call_expr_args(&ce)
    if !has_args {
        return
    }
    names  := make([dynamic]string, context.temp_allocator)
    params := make([dynamic]string, context.temp_allocator)
    it     := odinsyntax.arg_list_args(&args)
    for arg in odinsyntax.child_iter_next(&it) {
        value := arg
        param := ""
        #partial switch arg.green.kind {
        case .Spread_Expr:
            return
        case .Field_Value:
            fv           := odinsyntax.Field_Value(arg)
            n, has_name  := odinsyntax.field_value_name(&fv)
            v, has_value := odinsyntax.field_value_value(&fv)
            if !has_name || !has_value {
                return
            }
            param, value = odinsyntax.node_text(n), v
        case .Ident:
            param = odinsyntax.node_text(arg)
        }
        if param == "" || param == "_" || slice.contains(names[:], param) {
            param = fmt.tprintf("p%d", len(names) + 1)
        }
        op       := odinsema.expr_type(c, file, value)
        type, ok := odinsema.type_source(c, file, op.type, context.temp_allocator)
        if op.type == odinsema.INVALID_TYPE || !ok {
            return
        }
        append(&names, param)
        append(&params, fmt.tprintf("%s: %s", param, type))
    }
    result := ""
    if r := odinsema.expected_type_at(c, file, int(call.offset)); r != odinsema.INVALID_TYPE {
        if type, ok := odinsema.type_source(c, file, r, context.temp_allocator); ok {
            result = fmt.tprintf(" -> %s", type)
        }
    }
    at   := item_end_at(rc, int(call.offset))
    text := strings.concatenate(
        {"\n\n", name, " :: proc(", strings.join(params[:], ", ", context.temp_allocator), ")", result, " {\n", indent_unit(rc.req), "unimplemented()\n}"},
        context.temp_allocator,
    )
    push_action(res, rc.req, fmt.tprintf("Create procedure '%s'", name), Edit_Spec{at, at, text})
}

// Declares a struct; a composite literal of it gives the fields it names.
@(private = "file")
create_struct :: proc(rc: ^Request_Context, c: ^odinsema.Checker, name: string, parent, ident: odinsyntax.Syntax_Node, res: ^lang.Result) {
    file   := rc.live.id
    unit   := indent_unit(rc.req)
    sb     := strings.builder_make(context.temp_allocator)
    fields := 0
    if parent.green.kind == .Comp_Lit {
        cl := odinsyntax.Comp_Lit(parent)
        it := odinsyntax.comp_lit_elems(&cl)
        for elem in odinsyntax.child_iter_next(&it) {
            if elem.green.kind != .Field_Value {
                continue
            }
            fv           := odinsyntax.Field_Value(elem)
            n, has_name  := odinsyntax.field_value_name(&fv)
            v, has_value := odinsyntax.field_value_value(&fv)
            if !has_name || !has_value || n.green.kind != .Ident {
                continue
            }
            type, ok := odinsema.type_source(c, file, odinsema.expr_type(c, file, v).type, context.temp_allocator)
            if !ok {
                continue
            }
            fmt.sbprintf(&sb, "%s%s: %s,\n", unit, odinsyntax.node_text(n), type)
            fields += 1
        }
    }
    body := "{}" if fields == 0 else strings.concatenate({"{\n", strings.to_string(sb), "}"}, context.temp_allocator)
    at   := item_end_at(rc, int(ident.offset))
    push_action(res, rc.req, fmt.tprintf("Create struct '%s'", name), Edit_Spec{at, at, fmt.tprintf("\n\n%s :: struct %s", name, body)})
}

// Makes the plain `=` of `list`'s assignment a `:=`.
@(private = "file")
declare_store :: proc(rc: ^Request_Context, list: odinsyntax.Syntax_Node, name: string, res: ^lang.Result) {
    as, _ := odinsyntax.as_assign_stmt(list.parent^)
    op, _ := odinsyntax.assign_stmt_op(&as)
    at    := int(op.offset)
    lo    := at
    if lo > 0 && rc.req.source[lo - 1] == ' ' {
        lo -= 1
    }
    push_action(res, rc.req, fmt.tprintf("Declare '%s' with :=", name), Edit_Spec{lo, at + 1, " :="})
}

// Declares a variable of the type the place of `ident` expects, above its statement.
@(private = "file")
create_variable :: proc(rc: ^Request_Context, c: ^odinsema.Checker, name: string, ident: odinsyntax.Syntax_Node, res: ^lang.Result) {
    file := rc.live.id
    t    := odinsema.expected_type_at(c, file, int(ident.offset))
    if t == odinsema.INVALID_TYPE {
        return
    }
    type, ok := odinsema.type_source(c, file, t, context.temp_allocator)
    if !ok {
        return
    }
    stmt: ^odinsyntax.Syntax_Node
    in_proc := false
    for n := ident.parent; n != nil; n = n.parent {
        if stmt == nil && n.parent != nil && (n.parent.green.kind == .Block || n.parent.green.kind == .Case_Clause) && n.green.kind in odinsyntax.KINDS_STMT {
            stmt = n
        }
        if n.green.kind == .Proc_Lit {
            in_proc = true
            break
        }
    }
    if stmt == nil || !in_proc {
        return
    }
    src := rc.req.source
    ls  := line_start(src, int(stmt.offset))
    push_action(res, rc.req, fmt.tprintf("Create variable '%s'", name), Edit_Spec{ls, ls, fmt.tprintf("%s%s: %s\n", line_indent(src, ls), name, type)})
}
