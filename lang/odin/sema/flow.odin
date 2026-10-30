package odinsema

import odinsyntax "../syntax"

// Whether the end of the body of the procedure literal `lit` can be reached although the procedure
// has results: the compiler's "Missing return statement". `name` is the name a `::` declaration gives
// the literal, "" when there is none; `at` is the closing brace of the body. False when a statement
// whose answer is not known could end the body.
missing_return :: proc(c: ^Checker, file: File_Id, lit: odinsyntax.Syntax_Node) -> (name: string, at: int, missing: bool) {
    pl, is_lit := odinsyntax.as_proc_lit(lit)
    if !is_lit {
        return
    }
    pt, has_type := odinsyntax.proc_lit_type(&pl)
    body, has_body := odinsyntax.proc_lit_body(&pl)
    if !has_type || !has_body || body.green.kind != .Block {
        return
    }
    results, has_results := odinsyntax.proc_type_results(&pt)
    if !has_results {
        return
    }
    if _, diverging := odinsyntax.result_list_diverging(&results); diverging {
        return
    }
    fields := odinsyntax.result_list_fields(&results)
    if _, has_field := odinsyntax.child_iter_next(&fields); !has_field {
        return
    }
    if terminates(c, file, odinsyntax.Syntax_Node(body)) {
        return
    }
    _, end := odinsyntax.node_range(odinsyntax.Syntax_Node(body))
    return proc_lit_name(c, file, lit), int(end) - 1, true
}

// The name of the `::` declaration whose one value is `lit`; "" when there is none.
@(private = "file")
proc_lit_name :: proc(c: ^Checker, file: File_Id, lit: odinsyntax.Syntax_Node) -> string {
    path := node_path(c, file, int(lit.offset))
    for n, i in path {
        if n.green != lit.green || n.offset != lit.offset {
            continue
        }
        if i < 2 || path[i - 1].green.kind != .Expr_List || path[i - 2].green.kind != .Value_Decl || !is_constant_decl(path[i - 2]) {
            return ""
        }
        vd, _ := odinsyntax.as_value_decl(path[i - 2])
        names, has_names := odinsyntax.value_decl_names(&vd)
        if !has_names {
            return ""
        }
        it := odinsyntax.name_list_names(&names)
        first, has_first := odinsyntax.child_iter_next(&it)
        if _, more := odinsyntax.child_iter_next(&it); !has_first || more {
            return ""
        }
        return odinsyntax.node_text(first)
    }
    return ""
}

// True when control cannot leave the end of statement `n`, by the compiler's check_is_terminating.
// A `when` whose condition is not known, and a call whose callee type is not known, count as ending.
@(private = "file")
terminates :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> bool {
    #partial switch n.green.kind {
    case .Return_Stmt:
        return true
    case .Block:
        b, _ := odinsyntax.as_block(n)
        return list_terminates(c, file, odinsyntax.block_stmts(&b))
    case .Do_Body:
        db, _ := odinsyntax.as_do_body(n)
        stmt, ok := odinsyntax.do_body_stmt(&db)
        return ok && terminates(c, file, stmt)
    case .Branch_Stmt:
        bs, _ := odinsyntax.as_branch_stmt(n)
        kw, ok := odinsyntax.branch_stmt_keyword(&bs)
        return ok && kw.green.kind == .Fallthrough
    case .Expr_Stmt:
        es, _ := odinsyntax.as_expr_stmt(n)
        expr, ok := odinsyntax.expr_stmt_expr(&es)
        return ok && diverges(c, file, expr)
    case .If_Stmt:
        is, _ := odinsyntax.as_if_stmt(n)
        body, has_body := odinsyntax.if_stmt_body(&is)
        other, has_else := odinsyntax.if_stmt_else_branch(&is)
        return has_body && has_else && terminates(c, file, odinsyntax.Syntax_Node(body)) && terminates(c, file, other)
    case .When_Stmt:
        ws, _ := odinsyntax.as_when_stmt(n)
        cond, has_cond := odinsyntax.when_stmt_cond(&ws)
        body, has_body := odinsyntax.when_stmt_body(&ws)
        if !has_cond || !has_body {
            return true
        }
        switch when_state(c, file, cond) {
        case .True:
            return terminates(c, file, odinsyntax.Syntax_Node(body))
        case .False:
            other, has_else := odinsyntax.when_stmt_else_branch(&ws)
            return has_else && terminates(c, file, other)
        case .Unknown:
            return true
        }
    case .For_Stmt:
        fs, _ := odinsyntax.as_for_stmt(n)
        if _, has_cond := odinsyntax.for_stmt_cond(&fs); has_cond {
            return false
        }
        body, has_body := odinsyntax.for_stmt_body(&fs)
        label := ""
        if l, ok := odinsyntax.for_stmt_label(&fs); ok {
            label = label_text(l)
        }
        return has_body && !has_break(odinsyntax.Syntax_Node(body), label, true)
    case .Switch_Stmt:
        ss, _ := odinsyntax.as_switch_stmt(n)
        body, has_body := odinsyntax.switch_stmt_body(&ss)
        label := ""
        if l, ok := odinsyntax.switch_stmt_label(&ss); ok {
            label = label_text(l)
        }
        return has_body && clauses_terminate(c, file, odinsyntax.Syntax_Node(body), label)
    case .Type_Switch_Stmt:
        ss, _ := odinsyntax.as_type_switch_stmt(n)
        body, has_body := odinsyntax.type_switch_stmt_body(&ss)
        label := ""
        if l, ok := odinsyntax.type_switch_stmt_label(&ss); ok {
            label = label_text(l)
        }
        return has_body && clauses_terminate(c, file, odinsyntax.Syntax_Node(body), label)
    }
    return false
}

// True when the last statement of a list terminates.
@(private = "file")
list_terminates :: proc(c: ^Checker, file: File_Id, stmts: odinsyntax.Child_Iter) -> bool {
    stmts := stmts
    last: odinsyntax.Syntax_Node
    found := false
    for s in odinsyntax.child_iter_next(&stmts) {
        last, found = s, true
    }
    return found && terminates(c, file, last)
}

// True when the switch body has a `case:` and every clause terminates with no `break` out of it.
@(private = "file")
clauses_terminate :: proc(c: ^Checker, file: File_Id, body: odinsyntax.Syntax_Node, label: string) -> bool {
    body := body
    has_default := false
    it := odinsyntax.child_iter(&body, {kinds = {.Case_Clause}})
    for clause in odinsyntax.child_iter_next(&it) {
        cc, _ := odinsyntax.as_case_clause(clause)
        if _, has_values := odinsyntax.case_clause_values(&cc); !has_values {
            has_default = true
        }
        if !list_terminates(c, file, odinsyntax.case_clause_stmts(&cc)) {
            return false
        }
        stmts := odinsyntax.case_clause_stmts(&cc)
        for s in odinsyntax.child_iter_next(&stmts) {
            if has_break(s, label, true) {
                return false
            }
        }
    }
    return has_default
}

// True when `n` holds a `break` that leaves the statement `label` names, or, with `implicit`, a
// `break` with no label outside a nested loop or switch.
@(private = "file")
has_break :: proc(n: odinsyntax.Syntax_Node, label: string, implicit: bool) -> bool {
    n := n
    implicit := implicit
    #partial switch n.green.kind {
    case .Branch_Stmt:
        bs, _ := odinsyntax.as_branch_stmt(n)
        kw, ok := odinsyntax.branch_stmt_keyword(&bs)
        if !ok || kw.green.kind != .Break {
            return false
        }
        if l, has_label := odinsyntax.branch_stmt_label(&bs); has_label {
            return label != "" && odinsyntax.node_text(odinsyntax.Syntax_Node(l)) == label
        }
        return implicit
    case .Proc_Lit:
        return false
    case .For_Stmt, .Range_Stmt, .Switch_Stmt, .Type_Switch_Stmt:
        implicit = false
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        if has_break(child, label, implicit) {
            return true
        }
    }
    return false
}

// True when `expr` calls a procedure that does not return. A callee whose type is not known counts.
@(private = "file")
diverges :: proc(c: ^Checker, file: File_Id, expr: odinsyntax.Syntax_Node) -> bool {
    expr := expr
    for expr.green.kind == .Paren_Expr {
        pe, _ := odinsyntax.as_paren_expr(expr)
        inner, ok := odinsyntax.paren_expr_expr(&pe)
        if !ok {
            return false
        }
        expr = inner
    }
    ce, is_call := odinsyntax.as_call_expr(expr)
    if !is_call {
        return false
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    if !has_callee {
        return false
    }
    if _, is_directive := odinsyntax.as_directive(callee); is_directive {
        return false
    }
    fn := expr_type(c, file, callee)
    #partial switch fn.mode {
    case .Value, .Const, .Builtin:
        #partial switch v in type_get(&c.table, type_base(&c.table, fn.type)) {
        case Proc_Type:
            return v.diverging
        case Proc_Group_Type:
            return true
        }
        return fn.mode == .Builtin || fn.type == INVALID_TYPE
    case .Type:
        return false
    }
    return true
}

// What the `when` condition `cond` gives for the snapshot's target; a condition on a constant goes
// through const_eval.
@(private = "file")
when_state :: proc(c: ^Checker, file: File_Id, cond: odinsyntax.Syntax_Node) -> Tri {
    if state := when_condition(cond, c.snap.target); state != .Unknown {
        return state
    }
    v, ok := const_eval(c, file, cond)
    if !ok {
        return .Unknown
    }
    b, is_bool := v.(bool)
    if !is_bool {
        return .Unknown
    }
    return b ? .True : .False
}

@(private = "file")
label_text :: proc(l: odinsyntax.Label) -> string {
    l := l
    name, ok := odinsyntax.label_name(&l)
    return ok ? odinsyntax.node_text(odinsyntax.Syntax_Node(name)) : ""
}
