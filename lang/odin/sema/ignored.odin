// Call statements that drop an error result (`api/ignored-error`).
package odinsema

import "core:strings"

import odinsyntax "../syntax"

// The call of the expression statement `stmt` and the error type it drops. False when the
// statement is no call, or the call gives no error, is a builtin, is deferred or is
// `@(require_results)`, which the compiler reports.
ignored_error :: proc(c: ^Checker, file: File_Id, stmt: odinsyntax.Syntax_Node) -> (offset: int, type: Type_Id, ok: bool) {
    call, _, _, _ := ignored_call(c, file, stmt) or_return
    result := expr_type(c, file, call)
    if result.mode != .Value {
        return
    }
    if tuple, is_tuple := type_get(&c.table, result.type).(Tuple_Type); is_tuple {
        for t in tuple.types {
            if error_like(&c.table, t, 0) {
                return int(call.offset), t, true
            }
        }
        return
    }
    if error_like(&c.table, result.type, 0) {
        return int(call.offset), result.type, true
    }
    return
}

// The call of the expression statement `stmt` and the type of its callee, unless the call is deferred, a
// builtin, a directive, `@(require_results)` or a write to a sink.
@(private = "file")
ignored_call :: proc(c: ^Checker, file: File_Id, stmt: odinsyntax.Syntax_Node) -> (call: odinsyntax.Syntax_Node, ce: odinsyntax.Call_Expr, callee: odinsyntax.Syntax_Node, fn: Operand, ok: bool) {
    es := odinsyntax.as_expr_stmt(stmt) or_return
    call = odinsyntax.expr_stmt_expr(&es) or_return
    for call.green.kind == .Paren_Expr {
        p, _ := odinsyntax.as_paren_expr(call)
        call = odinsyntax.paren_expr_expr(&p) or_return
    }
    ce = odinsyntax.as_call_expr(call) or_return
    if deferred(stmt) {
        return
    }
    callee = odinsyntax.call_expr_callee(&ce) or_return
    if _, is_directive := odinsyntax.as_directive(callee); is_directive {
        return
    }
    if _, is_builtin := builtin_callee(c, file, callee); is_builtin {
        return
    }
    fn = expr_type(c, file, callee)
    if fn.has_symbol {
        if item := checker_item(c, fn.symbol); item != nil {
            for a in item.attributes {
                if a.name == "require_results" {
                    return
                }
            }
        }
    }
    if writes_sink(c, file, &ce) {
        return
    }
    return call, ce, callee, fn, true
}

// The call of the expression statement `stmt` when it drops a trailing `ok: bool` result, and the name
// of the procedure. False when the statement is no call, the procedure has `#optional_ok` or the last
// result is not a bool named `ok`.
ignored_ok :: proc(c: ^Checker, file: File_Id, stmt: odinsyntax.Syntax_Node) -> (offset: int, name: string, ok: bool) {
    call, _, callee, fn, found := ignored_call(c, file, stmt)
    if !found || fn.mode != .Value {
        return
    }
    p := type_get(&c.table, type_base(&c.table, fn.type)).(Proc_Type) or_return
    if len(p.results) < 2 || .Optional_Ok in p.tags {
        return
    }
    last := p.results[len(p.results) - 1]
    if last.name != "ok" {
        return
    }
    basic := type_get(&c.table, type_base(&c.table, last.type)).(Basic_Type) or_return
    if basic.kind != .Bool {
        return
    }
    return int(call.offset), strings.join(strings.fields(odinsyntax.node_text(callee), context.temp_allocator), "", context.temp_allocator), true
}

// True when the first argument of `ce` is a `^strings.Builder`, whose writes fail only when they
// cannot allocate, or an `io` stream or writer, whose write errors stream output commonly drops.
@(private = "file")
writes_sink :: proc(c: ^Checker, file: File_Id, ce: ^odinsyntax.Call_Expr) -> bool {
    list := odinsyntax.call_expr_args(ce) or_return
    it := odinsyntax.arg_list_args(&list)
    first := odinsyntax.child_iter_next(&it) or_return
    type := expr_type(c, file, first).type
    if named, is_named := type_get(&c.table, type).(Named_Type); is_named && named.qualifier == "io" {
        return named.name == "Stream" || strings.contains(named.name, "Writer")
    }
    p := type_get(&c.table, type_base(&c.table, type)).(Pointer_Type) or_return
    named := type_get(&c.table, p.elem).(Named_Type) or_return
    return named.name == "Builder" && named.qualifier == "strings"
}

// True when `stmt` is the statement of a `defer`, or a statement of its block.
@(private = "file")
deferred :: proc(stmt: odinsyntax.Syntax_Node) -> bool {
    p := stmt.parent
    if p != nil && p.green.kind == .Block {
        p = p.parent
    }
    return p != nil && p.green.kind == .Defer_Stmt
}

// True for a named type called `Error` or `*_Error`, or a union with such a variant.
// `Allocator_Error` on its own is not one: the result of `delete` and `append` is commonly dropped.
@(private = "file")
error_like :: proc(t: ^Type_Table, id: Type_Id, depth: int) -> bool {
    if depth > 4 {
        return false
    }
    #partial switch v in type_get(t, id) {
    case Named_Type:
        if v.name == "Allocator_Error" {
            return false
        }
        if v.name == "Error" || strings.has_suffix(v.name, "_Error") {
            return true
        }
        return error_like(t, v.underlying, depth + 1)
    case Union_Type:
        for variant in v.variants {
            if error_like(t, variant, depth + 1) {
                return true
            }
        }
    }
    return false
}
