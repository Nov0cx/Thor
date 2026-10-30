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
