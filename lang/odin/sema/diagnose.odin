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

// Whether no member of the procedure group the callee of `call` names takes its arguments: every
// member gets too few or too many of them, or, for a known argument type, one that it cannot take.
// False when the callee is not a group, a member is polymorphic or an argument type is not known.
group_no_match :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node) -> bool {
    ce, is_call := odinsyntax.as_call_expr(call)
    if !is_call {
        return false
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list {
        return false
    }
    fn := expr_type(c, file, callee)
    if fn.mode != .Value && fn.mode != .Const {
        return false
    }
    g, is_group := type_get(&c.table, type_base(&c.table, fn.type)).(Proc_Group_Type)
    if !is_group || len(g.members) == 0 {
        return false
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    args := call_args(c, file, odinsyntax.Syntax_Node(list), {})
    if args == nil && odinsyntax.node_text(odinsyntax.Syntax_Node(list)) != "()" {
        return false
    }
    for a in args {
        if a.spread || (a.name == "" && may_give_values(c, a)) {
            return false
        }
    }
    with, ok := with_receiver(c, file, callee, args)
    if !ok {
        return false
    }
    typed := true
    for a in with {
        if (a.op.mode != .Value && a.op.mode != .Const) || a.op.type == INVALID_TYPE || type_is_untyped(&c.table, a.op.type) {
            typed = false
        }
    }
    for m in g.members {
        p, is_proc := type_get(&c.table, type_base(&c.table, m)).(Proc_Type)
        if !is_proc {
            return false
        }
        slots, miss := match_slots(c, p, with)
        if miss.kind != .None {
            continue
        }
        if p.generic || !typed {
            return false
        }
        rejected := false
        for a, i in with {
            param := p.params[slots[i]]
            if .C_Vararg in param.flags {
                return false
            }
            switch assignable(c, param.type, a.op, .Any_Int in param.flags) {
            case .Yes:
            case .No:
                rejected = true
            case .Unknown:
                return false
            }
        }
        if !rejected {
            return false
        }
    }
    return true
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

// Whether `call` is `#assert(cond)` or `#assert(cond, message)` with a condition the checker
// evaluates to false. `cond` is the condition; `message` the message argument when there is one.
static_assert_fails :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node) -> (cond, message: odinsyntax.Syntax_Node, has_message, fails: bool) {
    ce, is_call := odinsyntax.as_call_expr(call)
    if !is_call {
        return
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list {
        return
    }
    d, is_directive := odinsyntax.as_directive(callee)
    if !is_directive {
        return
    }
    name, has_name := odinsyntax.directive_name(&d)
    if !has_name || odinsyntax.syntax_token_text(name) != "assert" {
        return
    }
    it := odinsyntax.arg_list_args(&list)
    has_cond: bool
    if cond, has_cond = odinsyntax.child_iter_next(&it); !has_cond {
        return
    }
    message, has_message = odinsyntax.child_iter_next(&it)
    v, ok := const_eval(c, file, cond)
    if !ok {
        return
    }
    b, is_bool := v.(bool)
    fails = is_bool && !b
    return
}

// Whether a value can be assigned to a type.
Assignable :: enum u8 {
    Yes,
    No,
    Unknown, // a type is not known, or a rule the checker does not model may apply
}

// Whether `op` can be assigned to a value of type `to`, by the compiler's rules. No only for types
// whose rules are modelled in full; an untyped number into a number is left to the constant checks.
assignable :: proc(c: ^Checker, to: Type_Id, op: Operand, any_int := false) -> Assignable {
    t := &c.table
    if to == INVALID_TYPE || op.type == INVALID_TYPE || (op.mode != .Value && op.mode != .Const) {
        return .Unknown
    }
    if _, is_tuple := type_get(t, op.type).(Tuple_Type); is_tuple {
        return .Unknown
    }
    if has_poly(c, to, 0) || has_poly(c, op.type, 0) {
        return .Unknown
    }
    if assign_distance(c, to, op, any_int, false) >= 0 {
        return .Yes
    }
    if !plain_type(c, to) || !plain_type(c, op.type) {
        return .Unknown
    }
    tb := type_get(t, type_base(t, to))
    fb := type_get(t, type_base(t, op.type))
    if u, is_untyped := fb.(Untyped_Type); is_untyped {
        #partial switch u.kind {
        case .Int, .Float, .Rune, .Complex, .Quaternion:
            if type_is_numeric(t, to) {
                return .Unknown
            }
        case .Uninit:
            return .Unknown
        case .Nil:
            if _, is_basic := tb.(Basic_Type); !is_basic {
                return .Unknown
            }
        }
        if _, is_union := tb.(Union_Type); is_union {
            return .Unknown
        }
    }
    #partial switch _ in tb {
    case Array_Type, Enumerated_Array_Type:
        return .Unknown
    case Pointer_Type:
        if _, ok := fb.(Multi_Pointer_Type); ok {
            return .Unknown
        }
    case Multi_Pointer_Type:
        if _, ok := fb.(Pointer_Type); ok {
            return .Unknown
        }
    }
    // An unnamed record is unique by position here, the compiler compares it by structure.
    temp := scratch_begin(c)
    defer scratch_end(temp)
    if type_string(t, to, c.tmp) == type_string(t, op.type, c.tmp) {
        return .Unknown
    }
    return .No
}

// True when the assignment rules of `t` are modelled in full: a basic, untyped, pointer, slice,
// array, dynamic array, map, bit_set, enum, or a struct or union with no parameters.
@(private = "file")
plain_type :: proc(c: ^Checker, t: Type_Id) -> bool {
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Basic_Type, Untyped_Type, Pointer_Type, Multi_Pointer_Type, Slice_Type, Enumerated_Array_Type,
         Dynamic_Array_Type, Map_Type, Bit_Set_Type, Enum_Type:
        return true
    case Array_Type:
        return v.len >= 0
    case Struct_Type:
        return len(v.params) == 0
    case Union_Type:
        return len(v.params) == 0
    }
    return false
}

// A value that cannot be assigned to the type its place takes.
Type_Problem :: struct {
    value:    odinsyntax.Syntax_Node,
    op:       Operand, // the value as typed against `to`
    to:       Type_Id,
    overflow: bool,    // an untyped integer constant the integer type `to` cannot hold
}

// True when `op` is an untyped integer or rune constant that the integer type `to` cannot hold.
const_overflows :: proc(c: ^Checker, to: Type_Id, op: Operand) -> bool {
    t := &c.table
    if op.mode != .Const || to == INVALID_TYPE {
        return false
    }
    u, is_untyped := type_get(t, op.type).(Untyped_Type)
    if !is_untyped || (u.kind != .Int && u.kind != .Rune) {
        return false
    }
    if _, is_basic := type_get(t, type_base(t, to)).(Basic_Type); !is_basic || !type_is_integer(t, to) {
        return false
    }
    #partial switch _ in op.value {
    case i64, rune:
        return !integer_holds(c, to, op.value)
    }
    return false
}

// The untyped integer constant of a conversion `T(x)` that the integer type `T` cannot hold.
conversion_overflow :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node) -> (Type_Problem, bool) {
    ce, is_call := odinsyntax.as_call_expr(call)
    if !is_call {
        return {}, false
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list {
        return {}, false
    }
    it := odinsyntax.arg_list_args(&list)
    arg, has_arg := odinsyntax.child_iter_next(&it)
    if _, more := odinsyntax.child_iter_next(&it); !has_arg || more || arg.green.kind == .Field_Value || arg.green.kind == .Spread_Expr {
        return {}, false
    }
    fn := expr_type(c, file, callee)
    if fn.mode != .Type {
        return {}, false
    }
    op := expr_type(c, file, arg)
    if !const_overflows(c, fn.type, op) {
        return {}, false
    }
    return {value = arg, op = op, to = fn.type, overflow = true}, true
}

// The arguments of `call` that its one procedure cannot take. Nil for the calls call_problem leaves
// out, and for polymorphic procedures and C variadic parameters. The list is in `allocator`.
argument_mismatches :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node, allocator := context.allocator) -> []Type_Problem {
    ce, is_call := odinsyntax.as_call_expr(call)
    if !is_call {
        return nil
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list {
        return nil
    }
    if _, is_directive := odinsyntax.as_directive(callee); is_directive {
        return nil
    }
    fn := expr_type(c, file, callee)
    if fn.mode != .Value && fn.mode != .Const {
        return nil
    }
    p, is_proc := type_get(&c.table, type_base(&c.table, fn.type)).(Proc_Type)
    if !is_proc || p.generic {
        return nil
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    args := call_args(c, file, odinsyntax.Syntax_Node(list), {})
    if len(args) == 0 {
        return nil
    }
    for a in args {
        if a.name == "" && !a.spread && may_give_values(c, a) {
            return nil
        }
    }
    with, ok := with_receiver(c, file, callee, args)
    if !ok {
        return nil
    }
    first := len(with) - len(args)
    slots, miss := match_slots(c, p, with)
    if miss.kind != .None {
        return nil
    }
    out := make([dynamic]Type_Problem, allocator)
    for a, i in with {
        if i < first || a.spread || a.node.green == nil {
            continue
        }
        param := p.params[slots[i]]
        if .C_Vararg in param.flags {
            continue
        }
        if builtin_call(c, file, a.node) {
            continue
        }
        to := param.type
        op := expr_type(c, file, a.node, to)
        if assignable(c, to, op, .Any_Int in param.flags) == .No {
            append(&out, Type_Problem{a.node, op, to, false})
        } else if const_overflows(c, to, op) {
            append(&out, Type_Problem{a.node, op, to, true})
        }
    }
    return out[:]
}

// The values of an `=` assignment or a variable declaration with a type that cannot be assigned to
// their places, and the integer constants a constant declaration with a type cannot hold. Nil when
// the counts differ. The list is in `allocator`.
assign_mismatches :: proc(c: ^Checker, file: File_Id, stmt: odinsyntax.Syntax_Node, allocator := context.allocator) -> []Type_Problem {
    temp := scratch_begin(c)
    defer scratch_end(temp)
    places := make([dynamic]Type_Id, c.tmp)
    values: odinsyntax.Expr_List
    overflow_only := false
    #partial switch stmt.green.kind {
    case .Assign_Stmt:
        as, _ := odinsyntax.as_assign_stmt(stmt)
        op, has_op := odinsyntax.assign_stmt_op(&as)
        lhs, has_lhs := odinsyntax.assign_stmt_lhs(&as)
        rhs, has_rhs := odinsyntax.assign_stmt_rhs(&as)
        if !has_op || !has_lhs || !has_rhs || op.green.kind != .Eq {
            return nil
        }
        it := odinsyntax.expr_list_items(&lhs)
        for place in odinsyntax.child_iter_next(&it) {
            to := INVALID_TYPE
            if !(place.green.kind == .Ident && odinsyntax.node_text(place) == "_") {
                if lop := expr_type(c, file, place); lop.mode == .Value {
                    to = lop.type
                }
            }
            if _, err := append(&places, to); !note_alloc(c, err) {
                return nil
            }
        }
        values = rhs
    case .Value_Decl:
        overflow_only = is_constant_decl(stmt)
        vd, _ := odinsyntax.as_value_decl(stmt)
        type_node, has_type := odinsyntax.value_decl_type(&vd)
        names, has_names := odinsyntax.value_decl_names(&vd)
        list, has_values := odinsyntax.value_decl_values(&vd)
        if !has_type || !has_names || !has_values {
            return nil
        }
        to := type_expr(c, file, type_node)
        it := odinsyntax.name_list_names(&names)
        for _ in odinsyntax.child_iter_next(&it) {
            if _, err := append(&places, to); !note_alloc(c, err) {
                return nil
            }
        }
        values = list
    case:
        return nil
    }
    return value_mismatches(c, file, places[:], values, overflow_only, allocator)
}

// The values of `return` that the results of the innermost procedure around it cannot take. Nil
// when the counts differ. The list is in `allocator`.
return_mismatches :: proc(c: ^Checker, file: File_Id, ret: odinsyntax.Syntax_Node, allocator := context.allocator) -> []Type_Problem {
    rs, is_return := odinsyntax.as_return_stmt(ret)
    if !is_return {
        return nil
    }
    values, has_values := odinsyntax.return_stmt_values(&rs)
    if !has_values {
        return nil
    }
    lit: odinsyntax.Syntax_Node
    found := false
    path := node_path(c, file, int(ret.offset))
    #reverse for n in path {
        if n.green.kind == .Proc_Lit {
            lit, found = n, true
            break
        }
    }
    if !found {
        return nil
    }
    pl, _ := odinsyntax.as_proc_lit(lit)
    pt, has_type := odinsyntax.proc_lit_type(&pl)
    if !has_type {
        return nil
    }
    p, is_proc := type_get(&c.table, type_base(&c.table, type_expr(c, file, odinsyntax.Syntax_Node(pt)))).(Proc_Type)
    if !is_proc || p.generic || p.diverging {
        return nil
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    places, err := make([]Type_Id, len(p.results), c.tmp)
    if !note_alloc(c, err) {
        return nil
    }
    for r, i in p.results {
        places[i] = r.type
    }
    return value_mismatches(c, file, places, values, false, allocator)
}

// The values of `list` that cannot be assigned to the place of the same index; with
// `overflow_only` only the integer constants their places cannot hold.
@(private = "file")
value_mismatches :: proc(c: ^Checker, file: File_Id, places: []Type_Id, list: odinsyntax.Expr_List, overflow_only: bool, allocator: mem.Allocator) -> []Type_Problem {
    list := list
    nodes := make([dynamic]odinsyntax.Syntax_Node, c.tmp)
    it := odinsyntax.expr_list_items(&list)
    for v in odinsyntax.child_iter_next(&it) {
        if v.green.kind == .Field_Value {
            return nil
        }
        if _, err := append(&nodes, v); !note_alloc(c, err) {
            return nil
        }
    }
    if len(nodes) != len(places) {
        return nil
    }
    out := make([dynamic]Type_Problem, allocator)
    for v, i in nodes {
        to := places[i]
        if to == INVALID_TYPE || builtin_call(c, file, v) {
            continue
        }
        op := expr_type(c, file, v, to)
        if !overflow_only && assignable(c, to, op) == .No {
            append(&out, Type_Problem{v, op, to, false})
        } else if const_overflows(c, to, op) {
            append(&out, Type_Problem{v, op, to, true})
        }
    }
    return out[:]
}

// True when `n` calls a builtin procedure, whose result the compiler converts by rules of its own
// (`len(s)` goes into a `uint`).
@(private = "file")
builtin_call :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> bool {
    ce, is_call := odinsyntax.as_call_expr(n)
    if !is_call {
        return false
    }
    callee, ok := odinsyntax.call_expr_callee(&ce)
    return ok && expr_type(c, file, callee).mode == .Builtin
}
