package odinsema

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
