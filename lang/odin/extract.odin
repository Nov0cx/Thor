// Extract variable and extract procedure: the selection becomes a named variable or procedure.
package odin

import "core:fmt"
import "core:slice"
import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

// The selection of a request without the white space at its ends.
@(private)
trimmed_selection :: proc(src: string, lo, hi: int) -> (int, int) {
    lo, hi := lo, hi
    for lo < hi && strings.is_space(rune(src[lo])) {
        lo += 1
    }
    for hi > lo && strings.is_space(rune(src[hi - 1])) {
        hi -= 1
    }
    return lo, hi
}

// `base`, or `base` with the first number that is not a name taken at `offset`.
@(private = "file")
free_name :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, base: string, offset: int) -> string {
    name := base
    for i := 2; i < 100; i += 1 {
        if !name_taken(rc, m, name, offset) {
            return name
        }
        name = fmt.tprintf("%s%d", base, i)
    }
    return name
}

// True when `name` is a local in reach at `offset`, a local of the procedure around it, or a
// declaration of the file.
@(private = "file")
name_taken :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, name: string, offset: int) -> bool {
    if _, visible := odinsema.visible_local(m, name, offset); visible || names_package_item(rc, name) {
        return true
    }
    tok, ok := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(offset), context.temp_allocator)
    if !ok {
        return false
    }
    for n := tok.parent; n != nil; n = n.parent {
        if n.green.kind != .Proc_Lit {
            continue
        }
        ps, pe := odinsyntax.node_range(n^)
        for l in m.locals {
            if l.name == name && l.name_offset >= int(ps) && l.name_offset < int(pe) {
                return true
            }
        }
        break
    }
    return false
}

@(private = "file")
names_package_item :: proc(rc: ^Request_Context, name: string) -> bool {
    for item in rc.live.tree.items {
        if item.name == name {
            return true
        }
    }
    return false
}

// Offers the extractions the selection allows.
@(private)
extract_actions :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, caret: Caret, res: ^lang.Result) {
    if caret.sel_end <= caret.offset {
        return
    }
    lo, hi := trimmed_selection(rc.req.source, caret.offset, caret.sel_end)
    if lo >= hi {
        return
    }
    var_name := free_name(rc, m, "value", lo)
    if _, reason := extract_variable_edits(rc, m, lo, hi, var_name); reason == "" {
        push_prompt_action(res, "Extract variable", ACTION_EXTRACT_VARIABLE, "Variable name", var_name)
    }
    proc_name := free_name(rc, m, "extracted", lo)
    if _, reason := extract_procedure_edits(rc, m, lo, hi, proc_name); reason == "" {
        push_prompt_action(res, "Extract procedure", ACTION_EXTRACT_PROCEDURE, "Procedure name", proc_name)
    }
}

// The outermost expression whose range is exactly [lo, hi).
@(private = "file")
expr_exact :: proc(rc: ^Request_Context, lo, hi: int) -> (^odinsyntax.Syntax_Node, bool) {
    tok, ok := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(lo), context.temp_allocator)
    if !ok {
        return nil, false
    }
    found: ^odinsyntax.Syntax_Node
    for n := tok.parent; n != nil; n = n.parent {
        s, e := odinsyntax.node_range(n^)
        if int(s) < lo || int(e) > hi {
            break
        }
        if int(s) == lo && int(e) == hi && n.green.kind in odinsyntax.KINDS_EXPR {
            found = n
        }
    }
    return found, found != nil
}

// The first child node of `n`.
@(private = "file")
first_child :: proc(n: odinsyntax.Syntax_Node) -> (odinsyntax.Syntax_Node, bool) {
    n := n
    return odinsyntax.find_child_node(&n, {kinds = ALL_NODES})
}

// The statement of a block that holds `expr`, when `expr` is evaluated once and before that
// statement runs, and is not a place, a callee or an address operand.
@(private = "file")
once_statement :: proc(expr: ^odinsyntax.Syntax_Node) -> (^odinsyntax.Syntax_Node, bool) {
    child := expr
    for p := expr.parent; p != nil; p = p.parent {
        #partial switch p.green.kind {
        case .Block, .Case_Clause:
            if child.green.kind not_in odinsyntax.KINDS_STMT {
                return nil, false
            }
            for q := p.parent; q != nil; q = q.parent {
                if q.green.kind == .Proc_Lit {
                    return child, true
                }
            }
            return nil, false
        case .Do_Body, .Defer_Stmt, .Proc_Lit, .Value_Decl:
            if p.green.kind == .Value_Decl {
                vd := odinsyntax.Value_Decl(p^)
                values, has := odinsyntax.value_decl_values(&vd)
                if has && values.offset == child.offset && !odinsema.is_constant_decl(p^) {
                    break
                }
            }
            return nil, false
        case .Binary_Expr:
            b := odinsyntax.Binary_Expr(p^)
            op, _ := odinsyntax.binary_expr_op(&b)
            if (op.green.kind == .Cmp_And || op.green.kind == .Cmp_Or) && child.offset > op.offset {
                return nil, false
            }
        case .Ternary_Expr, .Ternary_When_Expr, .Or_Else_Expr:
            if first, ok := first_child(p^); !ok || !same_node(first, child^) {
                return nil, false
            }
            if p.green.kind == .Ternary_When_Expr {
                return nil, false
            }
        case .Ternary_If_Expr:
            t := odinsyntax.Ternary_If_Expr(p^)
            cond, ok := odinsyntax.ternary_if_expr_cond(&t)
            if !ok || !same_node(cond, child^) {
                return nil, false
            }
        case .For_Stmt:
            f := odinsyntax.For_Stmt(p^)
            if init, ok := odinsyntax.for_stmt_init(&f); !ok || !same_node(init, child^) {
                return nil, false
            }
        case .If_Stmt:
            if p.parent != nil && p.parent.green.kind == .If_Stmt {
                return nil, false
            }
        case .Expr_List:
            if p.parent != nil && p.parent.green.kind == .Assign_Stmt {
                as := odinsyntax.Assign_Stmt(p.parent^)
                if lhs, ok := odinsyntax.assign_stmt_lhs(&as); ok && lhs.offset == p.offset {
                    return nil, false
                }
            }
            if p.parent != nil && p.parent.green.kind == .Range_Stmt {
                r := odinsyntax.Range_Stmt(p.parent^)
                if vars, ok := odinsyntax.range_stmt_vars(&r); ok && vars.offset == p.offset {
                    return nil, false
                }
            }
        case .Unary_Expr:
            u := odinsyntax.Unary_Expr(p^)
            if op, _ := odinsyntax.unary_expr_op(&u); op.green.kind == .And {
                return nil, false
            }
        case .Call_Expr:
            ce := odinsyntax.Call_Expr(p^)
            if callee, ok := odinsyntax.call_expr_callee(&ce); ok && same_node(callee, child^) {
                return nil, false
            }
        case .Field_Value:
            fv := odinsyntax.Field_Value(p^)
            if name, ok := odinsyntax.field_value_name(&fv); ok && same_node(name, child^) {
                return nil, false
            }
        case .Selector_Expr:
            s := odinsyntax.Selector_Expr(p^)
            if _, arrow := odinsyntax.selector_expr_arrow(&s); arrow {
                return nil, false
            }
        case .Name_List, .Field, .Param_List, .Result_List, .Label:
            return nil, false
        }
        child = p
    }
    return nil, false
}

// The edits that put the expression [lo, hi) in a variable `name` above its statement, or why not.
@(private)
extract_variable_edits :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, lo, hi: int, name: string) -> ([]File_Edit, string) {
    src := rc.req.source
    expr, ok := expr_exact(rc, lo, hi)
    if !ok {
        return nil, "the selection is not an expression"
    }
    if expr.green.kind in odinsyntax.KINDS_TYPE {
        return nil, "the selection is a type"
    }
    stmt, once := once_statement(expr)
    if !once {
        return nil, "the expression is not evaluated once before its statement"
    }
    ls := line_start(src, int(stmt.offset))
    if strings.trim_space(src[ls:int(stmt.offset)]) != "" {
        return nil, "the statement does not start its line"
    }
    c := request_checker(rc)
    if c == nil {
        return nil, "the file cannot be checked"
    }
    file := rc.live.id
    op := odinsema.expr_type(c, file, expr^)
    if op.mode != .Value && op.mode != .Const {
        return nil, "the selection is not a value"
    }
    head := strings.concatenate({name, " := "}, context.temp_allocator)
    untyped := op.type == odinsema.INVALID_TYPE || odinsema.type_is_untyped(&c.table, op.type)
    if untyped || expr.green.kind == .Implicit_Selector || expr.green.kind == .Comp_Lit {
        want := odinsema.expected_type_at(c, file, lo)
        if expr.green.kind == .Comp_Lit {
            want = odinsema.literal_type(c, file, expr^)
        }
        if want != odinsema.INVALID_TYPE && !odinsema.type_is_untyped(&c.table, want) {
            type, has := odinsema.type_source(c, file, want, context.temp_allocator)
            if !has {
                return nil, "the type of the expression cannot be written here"
            }
            head = strings.concatenate({name, ": ", type, " = "}, context.temp_allocator)
        } else if expr.green.kind == .Implicit_Selector || op.type == odinsema.INVALID_TYPE {
            return nil, "the type of the expression is not known"
        } else if b, is_basic := odinsema.type_get(&c.table, op.type).(odinsema.Untyped_Type); is_basic && b.kind == .Nil {
            return nil, "nil has no type"
        }
    }
    if !odinsema.is_identifier(name) {
        return nil, "not an identifier"
    }
    if name_taken(rc, m, name, int(stmt.offset)) {
        return nil, fmt.tprintf("'%s' is already declared", name)
    }
    edits := make([]File_Edit, 2, context.temp_allocator)
    edits[0] = {rc.req.path, src, ls, ls, strings.concatenate({line_indent(src, ls), head, src[lo:hi], "\n"}, context.temp_allocator)}
    edits[1] = {rc.req.path, src, lo, hi, name}
    return edits, ""
}

// One local of the enclosing procedure the extracted statements read.
@(private = "file")
Extract_Input :: struct {
    name:    string,
    decl:    int,
    type:    string,
    mutated: bool,
}

// One local the extracted statements declare and a later statement reads.
@(private = "file")
Extract_Output :: struct {
    name: string,
    type: string,
}

// The statements of the innermost block that lie wholly in [lo, hi). False when one only overlaps it.
@(private = "file")
selected_statements :: proc(rc: ^Request_Context, lo, hi: int) -> (block: ^odinsyntax.Syntax_Node, first, last: odinsyntax.Syntax_Node, ok: bool) {
    tok, found := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(lo), context.temp_allocator)
    if !found {
        return
    }
    for n := tok.parent; n != nil; n = n.parent {
        if n.green.kind != .Block && n.green.kind != .Case_Clause {
            continue
        }
        bs, be := odinsyntax.node_range(n^)
        if int(bs) > lo || int(be) < hi {
            continue
        }
        count := 0
        it := odinsyntax.child_iter(n, {kinds = odinsyntax.KINDS_STMT})
        for s in odinsyntax.child_iter_next(&it) {
            ss, se := odinsyntax.node_range(s)
            if int(se) <= lo || int(ss) >= hi {
                continue
            }
            if int(ss) < lo || int(se) > hi {
                return
            }
            if count == 0 {
                first = s
            }
            last = s
            count += 1
        }
        if count == 0 {
            return
        }
        fs, _ := odinsyntax.node_range(first)
        _, le := odinsyntax.node_range(last)
        if int(fs) != lo || int(le) != hi {
            return
        }
        return n, first, last, true
    }
    return
}

// True when the statements under `n` leave the selection: a `return`, `defer` at its top, `context`
// assignment, `using`, an `or_return`, or a branch whose target is outside it.
@(private = "file")
leaves_selection :: proc(n: odinsyntax.Syntax_Node, in_loop, in_switch: bool) -> bool {
    n := n
    #partial switch n.green.kind {
    case .Proc_Lit:
        return false
    case .Return_Stmt, .Or_Return_Expr, .Using_Stmt, .Defer_Stmt:
        return true
    case .Or_Branch_Expr:
        ob := odinsyntax.Or_Branch_Expr(n)
        if _, labelled := odinsyntax.or_branch_expr_label(&ob); labelled {
            return true
        }
        return !in_loop
    case .Branch_Stmt:
        b := odinsyntax.Branch_Stmt(n)
        kw, _ := odinsyntax.branch_stmt_keyword(&b)
        if _, labelled := odinsyntax.branch_stmt_label(&b); labelled {
            return true
        }
        #partial switch kw.green.kind {
        case .Break:
            return !in_loop && !in_switch
        case .Continue:
            return !in_loop
        case .Fallthrough:
            return true
        }
    case .Assign_Stmt:
        as := odinsyntax.Assign_Stmt(n)
        if lhs, ok := odinsyntax.assign_stmt_lhs(&as); ok {
            l := odinsyntax.Syntax_Node(lhs)
            if holds_kind(l, {.Context_Expr}) {
                return true
            }
        }
    }
    loop := in_loop || n.green.kind == .For_Stmt || n.green.kind == .Range_Stmt
    sw := in_switch || n.green.kind == .Switch_Stmt || n.green.kind == .Type_Switch_Stmt
    it := odinsyntax.child_iter(&n, {kinds = ALL_NODES})
    for c in odinsyntax.child_iter_next(&it) {
        if leaves_selection(c, loop, sw) {
            return true
        }
    }
    return false
}

// The edits that move the statements [lo, hi) into a procedure `name` and call it, or why not.
@(private)
extract_procedure_edits :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, lo, hi: int, name: string) -> ([]File_Edit, string) {
    src := rc.req.source
    block, first, last, ok := selected_statements(rc, lo, hi)
    if !ok {
        return nil, "the selection is not whole statements of one block"
    }
    lit: ^odinsyntax.Syntax_Node
    for p := block; p != nil; p = p.parent {
        if p.green.kind == .Proc_Lit {
            lit = p
            break
        }
    }
    if lit == nil {
        return nil, "the statements are not in a procedure"
    }
    fs, _ := odinsyntax.node_range(first)
    _, le := odinsyntax.node_range(last)
    s0, s1 := int(fs), int(le)
    ls := line_start(src, s0)
    if strings.trim_space(src[ls:s0]) != "" || strings.trim_space(src[s1:line_end(src, s1)]) != "" {
        return nil, "the statements share a line with others"
    }
    it := odinsyntax.child_iter(block, {kinds = odinsyntax.KINDS_STMT})
    for s in odinsyntax.child_iter_next(&it) {
        ss, se := odinsyntax.node_range(s)
        if int(ss) >= s0 && int(se) <= s1 && leaves_selection(s, false, false) {
            return nil, "a statement returns, defers or branches out of the selection"
        }
    }
    c := request_checker(rc)
    if c == nil {
        return nil, "the file cannot be checked"
    }
    file := rc.live.id
    ps, pe := odinsyntax.node_range(lit^)
    for l in m.locals {
        if l.is_using && l.name_offset >= int(ps) && l.name_offset < int(pe) {
            return nil, "the procedure has a 'using' local"
        }
    }
    inputs := make([dynamic]Extract_Input, context.temp_allocator)
    outputs := make([dynamic]Extract_Output, context.temp_allocator)
    for r in m.refs {
        if r.kind != .Local || r.start < s0 || r.end > s1 || r.is_decl || (r.decl >= s0 && r.decl < s1) {
            continue
        }
        if r.decl < int(ps) || r.decl >= int(pe) {
            continue
        }
        #partial switch r.decl_kind {
        case .Var, .Param, .Result, .Loop_Var, .Switch_Var:
        case:
            return nil, fmt.tprintf("'%s' is not a variable", r.name)
        }
        index := -1
        for in_, i in inputs {
            if in_.decl == r.decl {
                index = i
            }
        }
        if index < 0 {
            type, has := odinsema.type_source(c, file, odinsema.decl_type(c, odinsema.local_symbol(file, r.decl)), context.temp_allocator)
            if !has {
                return nil, fmt.tprintf("the type of '%s' cannot be written here", r.name)
            }
            append(&inputs, Extract_Input{name = r.name, decl = r.decl, type = type})
            index = len(inputs) - 1
        }
        if r.is_store || !plain_read(rc, r.start) {
            inputs[index].mutated = true
        }
    }
    for l in m.locals {
        if l.name_offset < s0 || l.name_offset >= s1 || l.kind != .Var {
            continue
        }
        used_after := false
        for r in m.refs {
            if r.kind == .Local && r.decl == l.name_offset && r.start >= s1 && r.start < int(pe) {
                used_after = true
                break
            }
        }
        if !used_after {
            continue
        }
        if !declared_at_top(block, l.name_offset) {
            return nil, fmt.tprintf("'%s' is read after the selection but declared in a nested block", l.name)
        }
        type, has := odinsema.type_source(c, file, odinsema.decl_type(c, odinsema.local_symbol(file, l.name_offset)), context.temp_allocator)
        if !has {
            return nil, fmt.tprintf("the type of '%s' cannot be written here", l.name)
        }
        append(&outputs, Extract_Output{name = l.name, type = type})
    }
    if !odinsema.is_identifier(name) {
        return nil, "not an identifier"
    }
    if names_package_item(rc, name) {
        return nil, fmt.tprintf("'%s' is already declared", name)
    }
    body := body_with_pointers(rc, m, inputs[:], s0, s1)
    unit := indent_unit(rc.req)
    params := make([dynamic]string, context.temp_allocator)
    args := make([dynamic]string, context.temp_allocator)
    for in_ in inputs {
        if in_.mutated {
            append(&params, fmt.tprintf("%s: ^%s", in_.name, in_.type))
            append(&args, strings.concatenate({"&", in_.name}, context.temp_allocator))
        } else {
            append(&params, fmt.tprintf("%s: %s", in_.name, in_.type))
            append(&args, in_.name)
        }
    }
    results := ""
    ret := ""
    lhs := ""
    if len(outputs) > 0 {
        types := make([dynamic]string, context.temp_allocator)
        names := make([dynamic]string, context.temp_allocator)
        for o in outputs {
            append(&types, o.type)
            append(&names, o.name)
        }
        joined := strings.join(types[:], ", ", context.temp_allocator)
        results = fmt.tprintf(" -> %s", joined) if len(outputs) == 1 else fmt.tprintf(" -> (%s)", joined)
        ret = strings.concatenate({unit, "return ", strings.join(names[:], ", ", context.temp_allocator), "\n"}, context.temp_allocator)
        lhs = strings.concatenate({strings.join(names[:], ", ", context.temp_allocator), " := "}, context.temp_allocator)
    }
    decl := strings.concatenate({
        "\n\n", name, " :: proc(", strings.join(params[:], ", ", context.temp_allocator), ")", results, " {\n",
        reindent(strings.concatenate({src[ls:s0], body}, context.temp_allocator), unit), "\n", ret, "}",
    }, context.temp_allocator)
    call := strings.concatenate({lhs, name, "(", strings.join(args[:], ", ", context.temp_allocator), ")"}, context.temp_allocator)
    at := item_end_at(rc, s0)
    edits := make([]File_Edit, 2, context.temp_allocator)
    edits[0] = {rc.req.path, src, s0, s1, call}
    edits[1] = {rc.req.path, src, at, at, decl}
    return edits, ""
}

// True when the local declared at `offset` belongs to `block` itself, not to a block inside it.
@(private = "file")
declared_at_top :: proc(block: ^odinsyntax.Syntax_Node, offset: int) -> bool {
    it := odinsyntax.child_iter(block, {kinds = odinsyntax.KINDS_STMT})
    for s in odinsyntax.child_iter_next(&it) {
        ss, se := odinsyntax.node_range(s)
        if offset < int(ss) || offset >= int(se) {
            continue
        }
        return s.green.kind == .Value_Decl
    }
    return false
}

// The text of [s0, s1) with each use of a mutated input read through its pointer: `&x` becomes `x`,
// an index or slice operand `x^`, a selector operand stays, any other use `x^`.
@(private = "file")
body_with_pointers :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, inputs: []Extract_Input, s0, s1: int) -> string {
    src := rc.req.source
    Rewrite :: struct {
        start, end: int,
        text:       string,
    }
    rewrites := make([dynamic]Rewrite, context.temp_allocator)
    for r in m.refs {
        if r.kind != .Local || r.start < s0 || r.end > s1 {
            continue
        }
        mutated := false
        for in_ in inputs {
            if in_.decl == r.decl && in_.mutated {
                mutated = true
            }
        }
        if !mutated {
            continue
        }
        ident, ok := node_at(rc, r.start)
        if !ok || ident.parent == nil {
            continue
        }
        p := ident.parent
        #partial switch p.green.kind {
        case .Unary_Expr:
            u := odinsyntax.Unary_Expr(p^)
            if op, _ := odinsyntax.unary_expr_op(&u); op.green.kind == .And {
                us, ue := odinsyntax.node_range(p^)
                append(&rewrites, Rewrite{int(us), int(ue), r.name})
                continue
            }
        case .Selector_Expr:
            s := odinsyntax.Selector_Expr(p^)
            if operand, has := odinsyntax.selector_expr_operand(&s); has && same_node(operand, ident^) {
                continue
            }
        }
        append(&rewrites, Rewrite{r.start, r.end, strings.concatenate({r.name, "^"}, context.temp_allocator)})
    }
    slice.sort_by(rewrites[:], proc(a, b: Rewrite) -> bool {
        return a.start < b.start
    })
    sb := strings.builder_make(context.temp_allocator)
    at := s0
    for w in rewrites {
        if w.start < at {
            continue
        }
        strings.write_string(&sb, src[at:w.start])
        strings.write_string(&sb, w.text)
        at = w.end
    }
    strings.write_string(&sb, src[at:s1])
    return strings.to_string(sb)
}
