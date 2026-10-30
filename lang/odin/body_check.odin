// Live body errors: what the compiler reports about the expressions of a file whose names resolve.
package odin

import "core:fmt"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Appends the body errors of the request's buffer to `report`. Silent where a type is not known.
@(private)
body_diagnostics :: proc(rc: ^Request_Context, whens: []Branch, report: ^lang.Diagnostic_Report) {
    if !rc.live.in_build {
        return
    }
    c := request_checker(rc)
    if c == nil {
        return
    }
    walk_body(rc, c, whens, odinsyntax.node_root(rc.parsed.tree), report)
}

@(private = "file")
walk_body :: proc(rc: ^Request_Context, c: ^odinsema.Checker, whens: []Branch, n: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    if lang.request_cancelled(rc.req) || in_untaken_branch(whens, int(n.offset)) {
        return
    }
    n := n
    #partial switch n.green.kind {
    case .Call_Expr:
        call_errors(rc, c, n, report)
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        walk_body(rc, c, whens, child, report)
    }
}

// Reports the arguments of `call` that do not fit its procedure.
@(private = "file")
call_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, call: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    p := odinsema.call_problem(c, rc.live.id, call)
    switch p.kind {
    case .None:
    case .Missing:
        if p.type == odinsema.INVALID_TYPE || p.name == "" {
            return
        }
        type := odinsema.type_string(&c.table, p.type, context.temp_allocator)
        report_error(rc, report, p.offset, CODE_ARITY, fmt.aprintf("Parameter '%s' of type '%s' is missing in procedure call", p.name, type))
    case .Too_Many:
        ce, _ := odinsyntax.as_call_expr(call)
        callee, _ := odinsyntax.call_expr_callee(&ce)
        name := strings.join(strings.fields(odinsyntax.node_text(callee), context.temp_allocator), "", context.temp_allocator)
        if p.least == p.want {
            report_error(rc, report, p.offset, CODE_ARITY, fmt.aprintf("Too many arguments for '%s', expected %d arguments, got %d", name, p.want, p.got))
        } else {
            report_error(rc, report, p.offset, CODE_ARITY, fmt.aprintf("Too many arguments for '%s', expected %d..=%d arguments, got %d", name, p.least, p.want, p.got))
        }
    case .Unknown_Name:
        report_error(rc, report, p.offset, CODE_NAMED, fmt.aprintf("No parameter named '%s' for this procedure type", p.name))
    case .Duplicate_Name:
        report_error(rc, report, p.offset, CODE_NAMED, fmt.aprintf("Duplicate parameter '%s' in procedure call", p.name))
    case .Positional_After_Named:
        report_error(rc, report, p.offset, CODE_NAMED, strings.clone("Non-named parameter is not allowed to follow named parameter i.e. 'field = value' in a procedure call"))
    }
}
