package odinsema

import "core:mem"

import odinsyntax "../syntax"

// Why the arguments of a call do not fit its procedure.
Call_Problem :: struct {
    kind:   Call_Problem_Kind,
    offset: int,     // where the compiler reports it: the call, or the argument at fault
    name:   string,  // Missing: the parameter; Unknown_Name, Duplicate_Name: the argument name. Borrows the type table or the parse
    type:   Type_Id, // Missing: the type of the parameter
    least:  int,     // Too_Many: the parameters with no default
    want:   int,     // Too_Many: the parameter count
    got:    int,     // Too_Many: the argument count
}

// The first reason the arguments of `call` do not fit the procedure its callee names. Kind None when
// they fit, and when the callee is not one procedure (a group, a builtin, a type, a directive) or an
// argument may give several values.
call_problem :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node) -> Call_Problem {
    ce, is_call := odinsyntax.as_call_expr(call)
    if !is_call {
        return {}
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list {
        return {}
    }
    if _, is_directive := odinsyntax.as_directive(callee); is_directive {
        return {}
    }
    fn := expr_type(c, file, callee)
    if fn.mode != .Value && fn.mode != .Const {
        return {}
    }
    p, is_proc := type_get(&c.table, type_base(&c.table, fn.type)).(Proc_Type)
    if !is_proc {
        return {}
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    args := call_args(c, file, odinsyntax.Syntax_Node(list), {})
    if args == nil && odinsyntax.node_text(odinsyntax.Syntax_Node(list)) != "()" {
        return {}
    }
    offsets := make([dynamic]int, 0, len(args), c.tmp)
    al, _ := odinsyntax.as_arg_list(odinsyntax.Syntax_Node(list))
    it := odinsyntax.arg_list_args(&al)
    for arg in odinsyntax.child_iter_next(&it) {
        if _, err := append(&offsets, int(arg.offset)); !note_alloc(c, err) {
            return {}
        }
    }
    if len(offsets) != len(args) {
        return {}
    }
    for a in args {
        if a.name == "" && !a.spread && may_give_values(c, a) {
            return {}
        }
    }
    with, ok := with_receiver(c, file, callee, args)
    if !ok {
        return {}
    }
    first := len(with) - len(args)
    _, miss := match_slots(c, p, with)
    out := Call_Problem{kind = miss.kind, offset = int(call.offset)}
    switch miss.kind {
    case .None:
    case .Missing:
        param := p.params[miss.param]
        out.name = param.name
        if len(out.name) > 1 && out.name[0] == '$' {
            out.name = out.name[1:]
        }
        out.type = param.type
    case .Too_Many:
        out.want, out.got = len(p.params), len(with)
        for param in p.params {
            if !param.has_default {
                out.least += 1
            }
        }
    case .Unknown_Name, .Duplicate_Name, .Positional_After_Named:
        if miss.arg < first {
            return {}
        }
        out.offset = offsets[miss.arg - first]
        out.name = with[miss.arg].name
    }
    return out
}

// True when a positional argument may give more than one value: a call or an `or_*` whose type is
// a tuple or is not known.
@(private = "file")
may_give_values :: proc(c: ^Checker, a: Call_Arg) -> bool {
    if a.op.mode == .Invalid {
        #partial switch a.node.green.kind {
        case .Ident, .Literal, .Comp_Lit, .Selector_Expr, .Implicit_Selector, .Unary_Expr, .Binary_Expr, .Proc_Lit:
            return false
        }
        return true
    }
    if a.op.optional {
        return false
    }
    _, is_tuple := type_get(&c.table, a.op.type).(Tuple_Type)
    return is_tuple
}

// What a selector names no member of.
Member_Problem :: struct {
    missing: bool,
    is_type: bool,    // the operand is an enum type, not a value
    owner:   Type_Id, // the type of the operand
}

// Whether `x.y` names no field of the value `x` (a struct or bit_field, through one pointer) and no
// member of the enum type `x`. False when the operand type is not known in full.
member_problem :: proc(c: ^Checker, file: File_Id, selector: odinsyntax.Syntax_Node) -> Member_Problem {
    sel, is_sel := odinsyntax.as_selector_expr(selector)
    if !is_sel {
        return {}
    }
    if _, is_arrow := odinsyntax.selector_expr_arrow(&sel); is_arrow {
        return {}
    }
    operand, has_operand := odinsyntax.selector_expr_operand(&sel)
    field, has_field := odinsyntax.selector_expr_field(&sel)
    if !has_operand || !has_field {
        return {}
    }
    name := odinsyntax.node_text(odinsyntax.Syntax_Node(field))
    op := expr_type(c, file, operand)
    #partial switch op.mode {
    case .Type:
        e, is_enum := type_get(&c.table, type_base(&c.table, op.type)).(Enum_Type)
        if !is_enum {
            return {}
        }
        for m in e.members {
            if m.name == name {
                return {}
            }
        }
        return {missing = true, is_type = true, owner = op.type}
    case .Value, .Const:
        if !fields_known(c, op.type, 0) {
            return {}
        }
        if _, ok := find_field(c, op.type, name); ok {
            return {}
        }
        return {missing = true, owner = op.type}
    }
    return {}
}

// True when `t` is a struct or bit_field, through one pointer, whose fields are all known: not
// polymorphic, and every `using` field is such a record too.
@(private = "file")
fields_known :: proc(c: ^Checker, t: Type_Id, depth: int) -> bool {
    if t == INVALID_TYPE || depth > USING_DEPTH {
        return false
    }
    #partial switch v in type_get(&c.table, deref_base(c, t)) {
    case Struct_Type:
        if len(v.params) > 0 {
            return false
        }
        for f in v.fields {
            if f.is_using && !fields_known(c, f.type, depth + 1) {
                return false
            }
        }
        return true
    case Bit_Field_Type:
        return true
    }
    return false
}

// The cases a switch without `#partial` leaves out: the members of the enum a value switch reads, or
// the variants of the union a type switch reads. Nil when it covers them all, has a `case:`, or a
// case or the subject is not known. The list and variant names are in `allocator`; member names
// borrow the type table.
switch_missing :: proc(c: ^Checker, file: File_Id, sw: odinsyntax.Syntax_Node, allocator := context.allocator) -> []string {
    sw := sw
    it := odinsyntax.child_iter(&sw, {kinds = {.Directive}})
    for d in odinsyntax.child_iter_next(&it) {
        dv, _ := odinsyntax.as_directive(d)
        if name, ok := odinsyntax.directive_name(&dv); ok && odinsyntax.syntax_token_text(name) == "partial" {
            return nil
        }
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    #partial switch sw.green.kind {
    case .Switch_Stmt:
        s, _ := odinsyntax.as_switch_stmt(sw)
        tag, has_tag := odinsyntax.switch_stmt_tag(&s)
        body, has_body := odinsyntax.switch_stmt_body(&s)
        if !has_tag || !has_body {
            return nil
        }
        return enum_missing(c, file, expr_type(c, file, tag).type, odinsyntax.Syntax_Node(body), allocator)
    case .Type_Switch_Stmt:
        s, _ := odinsyntax.as_type_switch_stmt(sw)
        subject, has_subject := odinsyntax.type_switch_stmt_subject(&s)
        body, has_body := odinsyntax.type_switch_stmt_body(&s)
        if !has_subject || !has_body {
            return nil
        }
        return union_missing(c, file, expr_type(c, file, subject).type, odinsyntax.Syntax_Node(body), allocator)
    }
    return nil
}

// The case value lists of a switch body; false when a clause is `case:`.
@(private = "file")
case_lists :: proc(c: ^Checker, body: odinsyntax.Syntax_Node) -> ([]odinsyntax.Syntax_Node, bool) {
    body := body
    lists := make([dynamic]odinsyntax.Syntax_Node, c.tmp)
    it := odinsyntax.child_iter(&body, {kinds = {.Case_Clause}})
    for clause in odinsyntax.child_iter_next(&it) {
        cc, _ := odinsyntax.as_case_clause(clause)
        values, ok := odinsyntax.case_clause_values(&cc)
        if !ok {
            return nil, false
        }
        if _, err := append(&lists, odinsyntax.Syntax_Node(values)); !note_alloc(c, err) {
            return nil, false
        }
    }
    return lists[:], true
}

@(private = "file")
enum_missing :: proc(c: ^Checker, file: File_Id, t: Type_Id, body: odinsyntax.Syntax_Node, allocator: mem.Allocator) -> []string {
    e, is_enum := type_get(&c.table, type_base(&c.table, t)).(Enum_Type)
    if !is_enum || len(e.members) == 0 {
        return nil
    }
    lists, ok := case_lists(c, body)
    if !ok {
        return nil
    }
    covered, err := make([]bool, len(e.members), c.tmp)
    if !note_alloc(c, err) {
        return nil
    }
    for list in lists {
        list := list
        el, _ := odinsyntax.as_expr_list(list)
        items := odinsyntax.expr_list_items(&el)
        for v in odinsyntax.child_iter_next(&items) {
            lo, hi: i64
            if b, is_binary := odinsyntax.as_binary_expr(v); is_binary {
                op, _ := odinsyntax.binary_expr_op(&b)
                lhs, has_lhs := odinsyntax.binary_expr_lhs(&b)
                rhs, has_rhs := odinsyntax.binary_expr_rhs(&b)
                if op.green.kind != .Range_Full && op.green.kind != .Range_Half {
                    return nil
                }
                l, lok := enum_value(c, file, lhs, has_lhs, t)
                r, rok := enum_value(c, file, rhs, has_rhs, t)
                if !lok || !rok {
                    return nil
                }
                lo, hi = l, op.green.kind == .Range_Full ? r : r - 1
            } else {
                value, vok := enum_value(c, file, v, true, t)
                if !vok {
                    return nil
                }
                lo, hi = value, value
            }
            for m, i in e.members {
                if lo <= m.value && m.value <= hi {
                    covered[i] = true
                }
            }
        }
    }
    missing := make([dynamic]string, allocator)
    for m, i in e.members {
        if !covered[i] {
            append(&missing, m.name)
        }
    }
    if len(missing) == 0 {
        delete(missing)
        return nil
    }
    return missing[:]
}

// The value of a case of an enum switch; false when it is not a known constant.
@(private = "file")
enum_value :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, has: bool, t: Type_Id) -> (i64, bool) {
    if !has {
        return 0, false
    }
    op := expr_type(c, file, n, t)
    if op.mode != .Const {
        return 0, false
    }
    v, ok := op.value.(i64)
    return v, ok
}

@(private = "file")
union_missing :: proc(c: ^Checker, file: File_Id, t: Type_Id, body: odinsyntax.Syntax_Node, allocator: mem.Allocator) -> []string {
    u, is_union := type_get(&c.table, type_base(&c.table, t)).(Union_Type)
    if !is_union || len(u.params) > 0 || len(u.variants) == 0 {
        return nil
    }
    lists, ok := case_lists(c, body)
    if !ok {
        return nil
    }
    covered, err := make([]bool, len(u.variants), c.tmp)
    if !note_alloc(c, err) {
        return nil
    }
    for list in lists {
        list := list
        el, _ := odinsyntax.as_expr_list(list)
        items := odinsyntax.expr_list_items(&el)
        for v in odinsyntax.child_iter_next(&items) {
            if v.green.kind == .Ident && odinsyntax.node_text(v) == "nil" {
                continue
            }
            ct := type_expr(c, file, v)
            if ct == INVALID_TYPE {
                return nil
            }
            hit := false
            for variant, i in u.variants {
                if variant == ct {
                    covered[i] = true
                    hit = true
                }
            }
            if !hit {
                return nil
            }
        }
    }
    missing := make([dynamic]string, allocator)
    for variant, i in u.variants {
        if !covered[i] {
            append(&missing, type_string(&c.table, variant, allocator))
        }
    }
    if len(missing) == 0 {
        delete(missing)
        return nil
    }
    return missing[:]
}
