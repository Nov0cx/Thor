// Live body errors: what the compiler reports about the expressions of a file whose names resolve.
package odin

import "core:fmt"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// Appends the body errors of the request's buffer to `report`. Silent where a type is not known.
@(private)
body_diagnostics :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, whens: []Branch, report: ^lang.Diagnostic_Report) {
    if !rc.live.in_build {
        return
    }
    c := request_checker(rc)
    if c == nil {
        return
    }
    rc.naming = config_naming(rc.e, rc.req.workspace)
    rc.vet = live_vet_flags(rc)
    severities := config_severities(rc.e, rc.req.workspace)
    rc.own_leak = severities[CODE_LEAK] != .Off && CODE_LEAK in severities
    rc.own_double = severities[CODE_DOUBLE_FREE] != .Off && CODE_DOUBLE_FREE in severities
    rc.own_after = severities[CODE_USE_AFTER_FREE] != .Off && CODE_USE_AFTER_FREE in severities
    walk_body(rc, c, m, whens, odinsyntax.node_root(rc.parsed.tree), report)
}

@(private = "file")
walk_body :: proc(rc: ^Request_Context, c: ^odinsema.Checker, m: ^odinsema.Scope_Map, whens: []Branch, n: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    if lang.request_cancelled(rc.req) || in_untaken_branch(whens, int(n.offset)) {
        return
    }
    n := n
    #partial switch n.green.kind {
    case .Value_Decl, .Field, .Range_Stmt, .Enum_Type:
        naming_errors(rc, n, report)
    }
    #partial switch n.green.kind {
    case .Call_Expr:
        call_errors(rc, c, n, report)
        arity_errors(rc, c, n, report)
        group_errors(rc, c, n, report)
        conversion_errors(rc, c, n, report)
        where_errors(rc, c, n, report)
        assert_errors(rc, c, n, report)
        mismatch_errors(rc, c, odinsema.argument_mismatches(c, rc.live.id, n, context.temp_allocator), "a procedure argument", report)
        order_errors(rc, c, n, report)
        mismatch_errors(rc, c, odinsema.min_max_mismatches(c, rc.live.id, n, context.temp_allocator), "a procedure argument", report)
        format_errors(rc, c, n, report)
        ce, _ := odinsyntax.as_call_expr(n)
        if callee, has := odinsyntax.call_expr_callee(&ce); has && callee.green.kind == .Ident {
            deprecated_uses(rc, c, callee, report)
        }
    case .Selector_Expr:
        member_errors(rc, c, n, report)
        deprecated_uses(rc, c, n, report)
    case .Assign_Stmt:
        count_errors(rc, c, n, report)
        mismatch_errors(rc, c, odinsema.assign_mismatches(c, rc.live.id, n, context.temp_allocator), "assignment", report)
        for call in odinsema.no_value_calls(c, rc.live.id, n, context.temp_allocator) {
            no_value_error(rc, call, report)
        }
        dangling_stores(rc, c, n, report)
        if odinsema.self_assign(n) {
            report_error(rc, report, int(n.offset), CODE_SELF_ASSIGN, strings.clone("A place is assigned to itself"), .Hint, lint = true)
        }
    case .If_Stmt:
        logic_errors(rc, n, report)
    case .Value_Decl:
        count_errors(rc, c, n, report)
        mismatch_errors(rc, c, odinsema.assign_mismatches(c, rc.live.id, n, context.temp_allocator), "a variable declaration", report)
        for call in odinsema.no_value_calls(c, rc.live.id, n, context.temp_allocator) {
            no_value_error(rc, call, report)
        }
    case .Return_Stmt:
        mismatch_errors(rc, c, odinsema.return_mismatches(c, rc.live.id, n, context.temp_allocator), "return statement", report)
        dangling_returns(rc, c, n, report)
    case .Switch_Stmt, .Type_Switch_Stmt:
        switch_errors(rc, c, n, report)
    case .Proc_Lit:
        return_errors(rc, c, n, report)
        unreachable_errors(rc, c, n, report)
        liveness_errors(rc, c, m, n, report)
        ownership_errors(rc, c, m, n, report)
        nil_errors(rc, c, m, whens, n, report)
    case .Binary_Expr:
        if p, ok := odinsema.const_arith_overflow(c, rc.live.id, n); ok {
            text := strings.join(strings.fields(odinsyntax.node_text(n), context.temp_allocator), " ", context.temp_allocator)
            type := odinsema.type_string(&c.table, p.type, context.temp_allocator)
            report_error(rc, report, int(n.offset), CODE_OVERFLOW, fmt.aprintf("Numeric value '%d' from '%s' cannot be represented by '%s'", p.value, text, type))
        }
    case .Or_Return_Expr:
        or_return_errors(rc, c, n, report)
    case .Cast_Expr:
        if .Cast in rc.vet {
            cast_errors(rc, c, n, report)
        }
    case .Expr_Stmt:
        ignored_errors(rc, c, n, report)
    case .For_Stmt:
        defer_in_loop(rc, m, n, report)
    case .Range_Stmt:
        defer_in_loop(rc, m, n, report)
        range_copies(rc, c, m, n, report)
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        walk_body(rc, c, m, whens, child, report)
    }
}

// Reports the arguments of `call` that do not fit its procedure.
@(private = "file")
call_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, call: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    p := odinsema.call_problem(c, rc.live.id, call)
    switch p.kind {
    case .None:
    case .Missing:
        if p.type == odinsema.INVALID_TYPE {
            return
        }
        // The compiler names a parameter with no name `_`.
        name := p.name == "" ? "_" : p.name
        type := odinsema.type_string(&c.table, p.type, context.temp_allocator)
        report_error(rc, report, p.offset, CODE_ARITY, fmt.aprintf("Parameter '%s' of type '%s' is missing in procedure call", name, type))
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

// Reports a call of a builtin or a conversion with the wrong number of arguments.
@(private = "file")
arity_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, call: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    p := odinsema.arity_problem(c, rc.live.id, call)
    switch p.kind {
    case .None:
    case .Too_Few:
        report_error(rc, report, p.offset, CODE_ARITY, fmt.aprintf("Too few arguments for '%s', expected %d, got %d", p.name, p.want, p.got))
    case .Too_Many:
        report_error(rc, report, p.offset, CODE_ARITY, fmt.aprintf("Too many arguments for '%s', expected %d, got %d", p.name, p.want, p.got))
    case .Two_Or_More:
        report_error(rc, report, p.offset, CODE_ARITY, fmt.aprintf("Too few arguments for '%s', two or more are required", p.name))
    case .Type_Only:
        report_error(rc, report, p.offset, CODE_ARITY, fmt.aprintf("If '%s' gets a type, only 1 arguments is allowed, got %d", p.name, p.got))
    case .Conversion_Missing:
        type := odinsema.type_string(&c.table, p.type, context.temp_allocator)
        report_error(rc, report, p.offset, CODE_ARITY, fmt.aprintf("Missing argument in conversion to '%s'", type))
    case .Conversion_Too_Many:
        type := odinsema.type_string(&c.table, p.type, context.temp_allocator)
        report_error(rc, report, p.offset, CODE_ARITY, fmt.aprintf("Too many arguments in conversion to '%s'", type))
    }
}

// Reports a boolean argument of `min`, `max` or `clamp`.
@(private = "file")
order_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, call: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    p, ok := odinsema.min_max_order_problem(c, rc.live.id, call)
    if !ok {
        return
    }
    type := odinsema.type_string(&c.table, p.type, context.temp_allocator)
    kinds := "ordered numeric or string" if p.name == "clamp" else "ordered numeric"
    report_error(rc, report, p.offset, CODE_MISMATCH, fmt.aprintf("Expected an %s type to '%s', got '%s'", kinds, p.name, type))
}

// Reports a call of a procedure with no result that is used as a value.
@(private = "file")
no_value_error :: proc(rc: ^Request_Context, call: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    text := strings.join(strings.fields(odinsyntax.node_text(call), context.temp_allocator), " ", context.temp_allocator)
    report_error(rc, report, int(call.offset), CODE_MISMATCH, fmt.aprintf("'%s' call does not return a value and cannot be used as a value", text))
}

// Reports a call of a procedure group that no member takes.
@(private = "file")
group_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, call: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    no_match := odinsema.group_no_match(c, rc.live.id, call)
    if !no_match && !odinsema.group_ambiguous(c, rc.live.id, call) {
        return
    }
    ce, _ := odinsyntax.as_call_expr(call)
    callee, _ := odinsyntax.call_expr_callee(&ce)
    name := strings.join(strings.fields(odinsyntax.node_text(callee), context.temp_allocator), "", context.temp_allocator)
    if !no_match {
        report_error(rc, report, int(call.offset), CODE_OVERLOAD, fmt.aprintf("Ambiguous procedure group call '%s' that match with the given arguments", name))
        return
    }
    report_error(rc, report, int(call.offset), CODE_OVERLOAD, fmt.aprintf("No procedures or ambiguous call for procedure group '%s' that match with the given arguments", name))
}

// Reports a conversion `T(x)` of a constant that `T` cannot take.
@(private = "file")
conversion_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, call: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    p, ok := odinsema.conversion_problem(c, rc.live.id, call)
    if !ok {
        return
    }
    value := strings.join(strings.fields(odinsyntax.node_text(p.value), context.temp_allocator), " ", context.temp_allocator)
    to := odinsema.type_string(&c.table, p.to, context.temp_allocator)
    from := untyped_name(odinsema.type_string(&c.table, p.op.type, context.temp_allocator))
    report_error(rc, report, int(p.value.offset), CODE_OVERFLOW if p.overflow else CODE_MISMATCH, fmt.aprintf("Cannot cast '%s' as '%s' from '%s'", value, to, from))
}

// Reports a selector that names no field or member of its operand.
@(private = "file")
member_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, selector: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    p := odinsema.member_problem(c, rc.live.id, selector)
    if !p.missing {
        return
    }
    sel, _ := odinsyntax.as_selector_expr(selector)
    operand, _ := odinsyntax.selector_expr_operand(&sel)
    field, _ := odinsyntax.selector_expr_field(&sel)
    name := odinsyntax.node_text(odinsyntax.Syntax_Node(field))
    owner := odinsema.type_string(&c.table, p.owner, context.temp_allocator)
    if p.is_type {
        report_error(rc, report, int(selector.offset), CODE_NO_MEMBER, fmt.aprintf("Type '%s' has no field '%s'", owner, name))
        return
    }
    text := strings.join(strings.fields(odinsyntax.node_text(operand), context.temp_allocator), "", context.temp_allocator)
    report_error(rc, report, int(selector.offset), CODE_NO_MEMBER, fmt.aprintf("'%s' of type '%s' has no field '%s'", text, owner, name))
}

// Reports the enum members or union variants a switch without `#partial` leaves out.
@(private = "file")
switch_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, sw: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    missing := odinsema.switch_missing(c, rc.live.id, sw, context.temp_allocator)
    if len(missing) == 0 {
        return
    }
    sw := sw
    offset := int(sw.offset)
    if kw, ok := odinsyntax.find_child_token(&sw, {tokens = {.Switch}}); ok {
        offset = int(kw.offset)
    }
    if len(missing) == 1 {
        report_error(rc, report, offset, CODE_SWITCH, fmt.aprintf("Unhandled switch case: %s", missing[0]))
        return
    }
    report_error(rc, report, offset, CODE_SWITCH, fmt.aprintf("Unhandled switch cases: %s", strings.join(missing, ", ", context.temp_allocator)))
}

// Reports a procedure with results whose body can end with no `return`.
@(private = "file")
return_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, lit: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    name, at, missing := odinsema.missing_return(c, rc.live.id, lit)
    if !missing {
        return
    }
    if name == "" {
        report_error(rc, report, at, CODE_RETURN, strings.clone("Missing return statement at the end of the procedure"))
        return
    }
    report_error(rc, report, at, CODE_RETURN, fmt.aprintf("Missing return statement at the end of the procedure '%s'", name))
}

// Reports the code of a procedure that control cannot reach: as the compiler does a statement after
// a terminator in the same list and a `defer` before a diverging call that ends its scope, as a lint
// the rest the control-flow graph finds.
@(private = "file")
unreachable_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, lit: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    r, err := odinsema.unreachable_code(c, rc.live.id, lit, context.temp_allocator)
    if err != nil {
        return
    }
    for n in r.never_executed {
        message: string
        switch n.kind {
        case .Return:    message = "Statements after this 'return' are never executed"
        case .Break:     message = "Statements after this 'break' are never executed"
        case .Continue:  message = "Statements after this 'continue' are never executed"
        case .Diverging: message = "Statements after a diverging procedure call are never executed"
        }
        report_error(rc, report, n.offset, CODE_UNREACHABLE, strings.clone(message))
    }
    for at in r.defers {
        report_error(rc, report, at, CODE_UNREACHABLE_DEFER, strings.clone("Unreachable defer statement due to diverging procedure call at the end of the current scope"))
    }
    for at in r.dead {
        report_error(rc, report, at, CODE_UNREACHABLE, strings.clone("Unreachable code"), .Warning, lint = true)
    }
}

// Reports the unused variables of a procedure, as `-vet-unused-variables` does, and as a lint the
// stores whose value no path reads.
@(private = "file")
liveness_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, m: ^odinsema.Scope_Map, lit: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    r, err := odinsema.liveness(c, rc.live.id, m, lit, context.temp_allocator)
    if err != nil {
        return
    }
    if .Unused_Variables in rc.vet {
        for u in r.unused {
            report_error(rc, report, u.offset, CODE_UNUSED_VAR, fmt.aprintf("'%s' declared but not used", u.name), .Warning)
        }
    }
    for d in r.dead_stores {
        report_error(rc, report, d.offset, CODE_DEAD_STORE, fmt.aprintf("Value assigned to '%s' is never used", d.name), .Warning, lint = true)
    }
}

// Reports, as a lint, the directives of a format string that `fmt` prints as `%!(...)`.
@(private = "file")
format_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, call: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    for p in odinsema.format_problems(c, rc.live.id, call, context.temp_allocator) {
        message: string
        switch p.kind {
        case .Missing:
            if p.verb == '*' {
                message = strings.clone("No argument for '*' in the format string")
            } else {
                message = fmt.aprintf("No argument for verb '%c' in the format string", p.verb)
            }
        case .Bad_Index:
            message = strings.clone("Argument index in the format string is out of range")
        case .No_Verb:
            message = strings.clone("No verb after '%' in the format string")
        case .Missing_Brace:
            message = strings.clone("No '}' for '{' in the format string; write '{{' for a literal '{'")
        case .Bad_Width:
            message = fmt.aprintf("Width argument of type '%s' is not a number", odinsema.type_string(&c.table, p.type, context.temp_allocator))
        case .Bad_Precision:
            message = fmt.aprintf("Precision argument of type '%s' is not a number", odinsema.type_string(&c.table, p.type, context.temp_allocator))
        case .Bad_Verb:
            if user_formatted(c, call, p.type) {
                continue
            }
            message = fmt.aprintf("Verb '%c' does not take an argument of type '%s'", p.verb, odinsema.type_string(&c.table, p.type, context.temp_allocator))
        case .Extra:
            message = p.count == 1 ? strings.clone("1 argument more than the format string uses") : fmt.aprintf("%d arguments more than the format string uses", p.count)
        }
        report_error(rc, report, p.offset, CODE_FMT_VERBS, message, .Hint, lint = true)
    }
}

// True when `type` is a named type and the file of `call` registers a user formatter, which may take
// any verb. A formatter registered in another file is not seen.
@(private = "file")
user_formatted :: proc(c: ^odinsema.Checker, call: odinsyntax.Syntax_Node, type: odinsema.Type_Id) -> bool {
    #partial switch _ in odinsema.type_get(&c.table, type) {
    case odinsema.Named_Type, odinsema.Distinct_Type:
    case:
        return false
    }
    root := call
    for root.parent != nil {
        root = root.parent^
    }
    return strings.contains(odinsyntax.node_text(root), "register_user_formatter")
}

// Reports, as a lint, a call statement that drops an error result.
@(private = "file")
ignored_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, stmt: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    if at, name, dropped := odinsema.ignored_ok(c, rc.live.id, stmt); dropped {
        report_error(rc, report, at, CODE_IGNORED_ERROR, fmt.aprintf("The 'ok' result of '%s' is ignored", name), .Hint, lint = true)
        return
    }
    at, type, ok := odinsema.ignored_error(c, rc.live.id, stmt)
    if !ok {
        return
    }
    report_error(rc, report, at, CODE_IGNORED_ERROR, fmt.aprintf("Error result of type '%s' is ignored", odinsema.type_string(&c.table, type, context.temp_allocator)), .Hint, lint = true)
}

// Reports, as a lint, the names of `n` that do not fit the naming rules of the workspace.
@(private = "file")
naming_errors :: proc(rc: ^Request_Context, n: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    for p in odinsema.naming_problems(n, rc.naming, context.temp_allocator) {
        want := odinsema.styles_text(p.want, context.temp_allocator)
        report_error(rc, report, p.offset, CODE_NAMING, fmt.aprintf("'%s' should be %s", p.name, want), .Hint, lint = true)
    }
}

// Reports, as a lint, an `if` with a literal condition or the same text in both branches.
@(private = "file")
logic_errors :: proc(rc: ^Request_Context, stmt: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    identical, constant, value := odinsema.if_problems(stmt)
    if constant >= 0 {
        message := value ? "The condition is always true" : "The condition is always false"
        report_error(rc, report, constant, CODE_CONST_CONDITION, strings.clone(message), .Hint, lint = true)
    }
    if identical >= 0 {
        report_error(rc, report, identical, CODE_IDENTICAL_BRANCHES, strings.clone("Both branches of the if statement are the same"), .Hint, lint = true)
    }
}

// Reports, as a lint, a range loop that copies a large element on every iteration.
@(private = "file")
range_copies :: proc(rc: ^Request_Context, c: ^odinsema.Checker, m: ^odinsema.Scope_Map, loop: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    at, name, size, ok := odinsema.range_copy(c, m, rc.live.id, loop)
    if !ok {
        return
    }
    report_error(rc, report, at, CODE_RANGE_COPY, fmt.aprintf("'%s' copies %d bytes on every iteration; 'for &%s' avoids the copy", name, size, name), .Hint, lint = true)
}

// Reports, as a lint, a use of a declaration marked `@(deprecated)`.
@(private = "file")
deprecated_uses :: proc(rc: ^Request_Context, c: ^odinsema.Checker, expr: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    at, name, message, ok := odinsema.deprecated_use(c, rc.live.id, expr)
    if !ok {
        return
    }
    if message == "" {
        report_error(rc, report, at, CODE_DEPRECATED, fmt.aprintf("'%s' is deprecated", name), .Hint, lint = true)
        return
    }
    report_error(rc, report, at, CODE_DEPRECATED, fmt.aprintf("'%s' is deprecated: %s", name, message), .Hint, lint = true)
}

// Reports, as a lint, a `defer` in the body of the loop `loop` that releases an outer variable.
@(private = "file")
defer_in_loop :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, loop: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    for at in odinsema.loop_defers(m, loop, context.temp_allocator) {
        report_error(rc, report, at, CODE_DEFER_IN_LOOP, strings.clone("A defer in a loop body releases a variable declared outside the loop on every iteration"), .Hint, lint = true)
    }
}

// Reports, as a lint, a returned address or slice of a local.
@(private = "file")
dangling_returns :: proc(rc: ^Request_Context, c: ^odinsema.Checker, ret: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    ret := ret
    rs, _ := odinsyntax.as_return_stmt(ret)
    values, has := odinsyntax.return_stmt_values(&rs)
    if !has {
        return
    }
    it := odinsyntax.expr_list_items(&values)
    for v in odinsyntax.child_iter_next(&it) {
        dangling_report(rc, c, v, "returned", false, report)
    }
}

// Reports, as a lint, an address or slice of a local stored where it outlives the frame.
@(private = "file")
dangling_stores :: proc(rc: ^Request_Context, c: ^odinsema.Checker, assign: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    as, _ := odinsyntax.as_assign_stmt(assign)
    lhs, has_lhs := odinsyntax.assign_stmt_lhs(&as)
    rhs, has_rhs := odinsyntax.assign_stmt_rhs(&as)
    if !has_lhs || !has_rhs {
        return
    }
    targets := odinsyntax.expr_list_items(&lhs)
    values := odinsyntax.expr_list_items(&rhs)
    for target in odinsyntax.child_iter_next(&targets) {
        value, more := odinsyntax.child_iter_next(&values)
        if !more {
            return
        }
        if odinsema.outliving_store(c, rc.live.id, target) && !odinsema.cleared_by_defer(assign, target) {
            temp := odinsema.outliving_store(c, rc.live.id, target, results = false)
            dangling_report(rc, c, value, "stored", temp, report)
        }
    }
}

// Reports a dangling address or slice in `value`, and a temp allocator value when `temp` is set:
// a procedure may hand out a temp value in its result on purpose, but not park it in a global.
@(private = "file")
dangling_report :: proc(rc: ^Request_Context, c: ^odinsema.Checker, value: odinsyntax.Syntax_Node, what: string, temp: bool, report: ^lang.Diagnostic_Report) {
    if at, name, ok := odinsema.dangling_place(c, rc.live.id, value); ok {
        report_error(rc, report, at, CODE_DANGLING_SLICE, fmt.aprintf("Address of local '%s' is %s and dangles after the procedure returns", name, what), .Hint, lint = true)
        return
    }
    if !temp {
        return
    }
    if at, ok := odinsema.temp_place(c, rc.live.id, value); ok {
        report_error(rc, report, at, CODE_TEMP_ESCAPE, fmt.aprintf("Value from the temp allocator is %s and is freed by the next free_all(context.temp_allocator)", what), .Hint, lint = true)
    }
}

// Reports an `or_return` that does not fit the procedure around it.
@(private = "file")
or_return_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, n: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    p := odinsema.or_return_problem(c, rc.live.id, n)
    at := int(n.offset)
    switch p.kind {
    case .None:
    case .No_Results:
        report_error(rc, report, at, CODE_OR_RETURN, strings.clone("'or_return' requires the current procedure to have at least one return value"))
    case .Unnamed_Results:
        report_error(rc, report, at, CODE_OR_RETURN, strings.clone("'or_return' within a procedure with more than 1 return value requires that the return values are named, allowing for early return"))
    case .Single_Value:
        end := odinsema.type_string(&c.table, p.end, context.temp_allocator)
        report_error(rc, report, at, CODE_OR_RETURN, fmt.aprintf("'or_return' expects an \"optional ok\" like value, or an n-valued expression where the last value is either a boolean or can be compared against 'nil', got %s", end))
    case .End_Mismatch:
        end := odinsema.type_string(&c.table, p.end, context.temp_allocator)
        to := odinsema.type_string(&c.table, p.to, context.temp_allocator)
        report_error(rc, report, at, CODE_OR_RETURN, fmt.aprintf("Cannot assign end value of type '%s' to '%s' in 'or_return'", end, to))
    }
}

// Reports, as a lint, a pointer dereference or a procedure value call whose operand is nil on every
// path to it.
@(private = "file")
nil_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, m: ^odinsema.Scope_Map, whens: []Branch, lit: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    uses, err := odinsema.nil_deref(c, rc.live.id, m, lit, context.temp_allocator)
    if err != nil {
        return
    }
    for u in uses {
        if in_untaken_branch(whens, u.offset) {
            continue
        }
        verb := u.is_call ? "Calling" : "Dereferencing"
        report_error(rc, report, u.offset, CODE_NIL_DEREF, fmt.aprintf("%s '%s', which is always nil here", verb, u.name), .Hint, lint = true)
    }
}

// Reports a `cast` or `transmute` to the type its operand already has.
@(private = "file")
cast_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, n: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    v, ok := odinsema.vet_cast(c, rc.live.id, n)
    if !ok {
        return
    }
    type := odinsema.type_string(&c.table, v.type, context.temp_allocator)
    what := v.is_transmute ? "transmute" : "cast"
    report_error(rc, report, v.offset, CODE_CAST, fmt.aprintf("Unneeded %s of '%s' to identical type '%s'", what, v.operand, type), .Warning)
}

// Reports a call of a polymorphic procedure whose `where` clause is false for its arguments.
@(private = "file")
where_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, call: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    constraint, fails := odinsema.where_problem(c, rc.live.id, call)
    if !fails {
        return
    }
    text := strings.join(strings.fields(constraint, context.temp_allocator), " ", context.temp_allocator)
    report_error(rc, report, int(call.offset), CODE_WHERE, fmt.aprintf("'where' clause evaluated to false: %s", text))
}

// Reports an assignment or declaration whose places and values differ in count.
@(private = "file")
count_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, stmt: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    at, places, values, mismatch := odinsema.assign_count(c, rc.live.id, stmt)
    if mismatch {
        report_error(rc, report, at, CODE_COUNT, fmt.aprintf("Assignment count mismatch '%d' = '%d'", places, values))
    }
}

// Reports a `#assert` whose condition is false.
@(private = "file")
assert_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, call: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    cond, message, has_message, fails := odinsema.static_assert_fails(c, rc.live.id, call)
    if !fails {
        return
    }
    text := strings.join(strings.fields(odinsyntax.node_text(cond), context.temp_allocator), " ", context.temp_allocator)
    if has_message {
        report_error(rc, report, int(call.offset), CODE_ASSERT, fmt.aprintf("Compile time assertion: %s (%s)", text, odinsyntax.node_text(message)))
        return
    }
    report_error(rc, report, int(call.offset), CODE_ASSERT, fmt.aprintf("Compile time assertion: %s", text))
}

// Reports each value that cannot be assigned to its place; `place` names the place as the compiler does.
@(private = "file")
mismatch_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, problems: []odinsema.Type_Problem, place: string, report: ^lang.Diagnostic_Report) {
    for p in problems {
        value := strings.join(strings.fields(odinsyntax.node_text(p.value), context.temp_allocator), " ", context.temp_allocator)
        to := untyped_name(odinsema.type_string(&c.table, p.to, context.temp_allocator))
        from := odinsema.type_string(&c.table, p.op.type, context.temp_allocator)
        if p.truncated {
            report_error(rc, report, int(p.value.offset), CODE_MISMATCH, fmt.aprintf("'%s' truncated to '%s', got %s", value, to, p.got))
            continue
        }
        if p.overflow {
            got, _ := const_text(p.op.value)
            if p.got != "" {
                got = p.got
            }
            report_error(rc, report, int(p.value.offset), CODE_OVERFLOW, fmt.aprintf("Cannot convert numeric value '%s' from '%s' to '%s' from '%s'", got, value, to, untyped_name(from)))
            continue
        }
        if !odinsema.type_is_untyped(&c.table, p.op.type) {
            report_error(rc, report, int(p.value.offset), CODE_MISMATCH, fmt.aprintf("Cannot assign value '%s' of type '%s' to '%s' in %s", value, from, to, place))
            continue
        }
        from = untyped_name(from)
        _, to_basic := odinsema.type_get(&c.table, odinsema.type_base(&c.table, p.to)).(odinsema.Basic_Type)
        if got, ok := const_text(p.op.value); to_basic && p.op.mode == .Const && ok {
            report_error(rc, report, int(p.value.offset), CODE_MISMATCH, fmt.aprintf("Cannot convert '%s' to '%s' from '%s', got %s", value, to, from, got))
            continue
        }
        report_error(rc, report, int(p.value.offset), CODE_MISMATCH, fmt.aprintf("Cannot convert untyped value '%s' to '%s' from '%s'", value, to, from))
    }
}

// The compiler's name of an untyped type.
@(private = "file")
untyped_name :: proc(name: string) -> string {
    return name == "untyped int" ? "untyped integer" : name
}

// A constant as the compiler prints it after "got"; false for a float or no value.
@(private = "file")
const_text :: proc(v: odinsema.Const_Value) -> (string, bool) {
    #partial switch x in v {
    case i64:    return fmt.tprint(x), true
    case rune:   return fmt.tprint(i64(x)), true
    case bool:   return x ? "true" : "false", true
    case string: return fmt.tprintf("%q", x), true
    }
    return "", false
}

// Reports, as a lint, the allocations a path leaves unfreed and the frees and uses of a freed value.
// Off until the workspace config sets one of the ids.
@(private = "file")
ownership_errors :: proc(rc: ^Request_Context, c: ^odinsema.Checker, m: ^odinsema.Scope_Map, lit: odinsyntax.Syntax_Node, report: ^lang.Diagnostic_Report) {
    leak, double, after := rc.own_leak, rc.own_double, rc.own_after
    if !leak && !double && !after {
        return
    }
    r, err := odinsema.ownership(c, rc.live.id, m, lit, context.temp_allocator)
    if err != nil {
        return
    }
    if leak {
        for l in r.leaks {
            report_error(rc, report, l.offset, CODE_LEAK, fmt.aprintf("'%s' is allocated and a path neither frees nor hands it on", l.name), .Hint, lint = true)
        }
    }
    if double {
        for d in r.double_frees {
            report_error(rc, report, d.offset, CODE_DOUBLE_FREE, fmt.aprintf("'%s' is freed twice on every path to here", d.name), .Hint, lint = true)
        }
    }
    if after {
        for u in r.uses_after_free {
            report_error(rc, report, u.offset, CODE_USE_AFTER_FREE, fmt.aprintf("'%s' is used after it is freed", u.name), .Hint, lint = true)
        }
    }
}
