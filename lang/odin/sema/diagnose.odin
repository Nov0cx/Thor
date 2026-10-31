package odinsema

import "core:mem"
import "core:strings"

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
    // A base:builtin procedure is checked by its own rules (arity_problem).
    if _, is_builtin := builtin_callee(c, file, callee); is_builtin {
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
// member gets too few or too many of them, a `$` parameter no argument fits, or an argument that it
// cannot take. False when the callee is not a group or an argument type is not known.
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
    for a in with {
        if (a.op.mode != .Value && a.op.mode != .Const && a.op.mode != .Type) || a.op.type == INVALID_TYPE || has_poly(c, a.op.type, 0) {
            return false
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
        if len(g.members) > 1 && p.generic && empty_poly_variadic(c, p, slots) {
            continue
        }
        params := p.params
        declares: []bool
        if p.generic {
            // A `$` parameter that no argument fits rejects the member.
            if _, bound := bind_generic(c, p, with, slots); !bound {
                continue
            }
            params, declares = generic_params(c, p, with, slots)
            if params == nil {
                return false
            }
        }
        rejected := false
        for a, i in with {
            param := params[slots[i]]
            if .C_Vararg in param.flags {
                return false
            }
            if declares != nil && declares[slots[i]] {
                continue
            }
            if p.generic && (param.type == INVALID_TYPE || has_poly(c, param.type, 0)) {
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

// True when the polymorphic procedure `p` has a variadic parameter of a `$` element type that no
// argument goes to. The compiler never picks such a member of a group of several (`append(&a)`).
@(private = "file")
empty_poly_variadic :: proc(c: ^Checker, p: Proc_Type, slots: []int) -> bool {
    for param, k in p.params {
        if .Variadic not_in param.flags || !has_poly(c, param.type, 0) {
            continue
        }
        for s in slots {
            if s == k {
                return false
            }
        }
        return true
    }
    return false
}

// The builtins of base:builtin that take a fixed number of arguments.
@(private = "file", rodata)
BUILTIN_ARITY := [?]struct {
    name: string,
    n:    int,
} {
    {"len", 1}, {"cap", 1}, {"size_of", 1}, {"align_of", 1}, {"type_of", 1}, {"typeid_of", 1},
    {"type_info_of", 1}, {"real", 1}, {"imag", 1}, {"jmag", 1}, {"kmag", 1}, {"conj", 1}, {"abs", 1},
    {"clamp", 3}, {"expand_values", 1}, {"transpose", 1}, {"matrix_flatten", 1}, {"outer_product", 2},
    {"hadamard_product", 2}, {"raw_data", 1}, {"complex", 2}, {"soa_unzip", 1}, {"unreachable", 0},
}

Arity_Kind :: enum u8 {
    None,
    Too_Few,             // a builtin: `want` arguments, `got` given
    Too_Many,            // a builtin: `want` arguments, `got` given
    Two_Or_More,         // `min` or `max` with one value
    Conversion_Missing,  // `T()`
    Conversion_Too_Many, // `T(a, b)`
}

// A call of a builtin or a conversion with the wrong number of arguments.
Arity_Problem :: struct {
    kind:   Arity_Kind,
    offset: int,     // where the compiler reports it: the call, its `)` or the first extra argument
    name:   string,  // the builtin; borrows the parse
    type:   Type_Id, // a conversion: the type
    want:   int,
    got:    int,
}

// The argument count problem of a call of a builtin procedure or of a conversion `T(x)`. Kind None
// when the count fits, the callee is something else, or an argument is named or spread.
arity_problem :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node) -> Arity_Problem {
    ce, is_call := odinsyntax.as_call_expr(call)
    if !is_call {
        return {}
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list || !strings.has_suffix(odinsyntax.node_text(odinsyntax.Syntax_Node(list)), ")") {
        return {}
    }
    got := 0
    extra := -1
    al, _ := odinsyntax.as_arg_list(odinsyntax.Syntax_Node(list))
    it := odinsyntax.arg_list_args(&al)
    args: [2]odinsyntax.Syntax_Node
    for arg in odinsyntax.child_iter_next(&it) {
        if arg.green.kind == .Field_Value || arg.green.kind == .Spread_Expr {
            return {}
        }
        if got < len(args) {
            args[got] = arg
        }
        got += 1
    }
    _, list_end := odinsyntax.node_range(odinsyntax.Syntax_Node(list))
    close := int(list_end) - 1
    // `builtin.len` is named as written, `builtin.min` by its own name.
    if base, is_builtin := builtin_callee(c, file, callee); is_builtin {
        name := odinsyntax.node_text(callee)
        if base == "min" || base == "max" {
            if got == 0 {
                return {kind = .Too_Few, offset = close, name = name, want = 1}
            }
            if got == 1 && expr_type(c, file, args[0]).mode != .Type {
                return {kind = .Two_Or_More, offset = int(call.offset), name = base}
            }
            return {}
        }
        for b in BUILTIN_ARITY {
            if b.name != base {
                continue
            }
            if got < b.n {
                return {kind = .Too_Few, offset = close, name = name, want = b.n, got = got}
            }
            if got > b.n {
                extra = b.n
                break
            }
            return {}
        }
        if extra < 0 {
            return {}
        }
        // The first argument past the count.
        it = odinsyntax.arg_list_args(&al)
        i := 0
        for arg in odinsyntax.child_iter_next(&it) {
            if i == extra {
                return {kind = .Too_Many, offset = int(arg.offset), name = name, want = extra, got = got}
            }
            i += 1
        }
        return {}
    }
    fn := expr_type(c, file, callee)
    if fn.mode != .Type || fn.type == INVALID_TYPE || !plain_type(c, fn.type) {
        return {}
    }
    if got == 0 {
        return {kind = .Conversion_Missing, offset = int(call.offset), type = fn.type}
    }
    if got > 1 {
        return {kind = .Conversion_Too_Many, offset = int(call.offset), type = fn.type, got = got}
    }
    return {}
}

// The name of the base:builtin procedure `callee` names, bare or as `builtin.name`.
builtin_callee :: proc(c: ^Checker, file: File_Id, callee: odinsyntax.Syntax_Node) -> (string, bool) {
    if callee.green.kind == .Ident {
        name := odinsyntax.node_text(callee)
        r := lookup_name(c, file, name, int(callee.offset))
        if r.kind == .Item && r.builtin || r.kind == .None && is_builtin_proc(name) {
            return name, true
        }
        return "", false
    }
    sel, is_sel := odinsyntax.as_selector_expr(callee)
    if !is_sel {
        return "", false
    }
    operand, has_operand := odinsyntax.selector_expr_operand(&sel)
    field, has_field := odinsyntax.selector_expr_field(&sel)
    if !has_operand || !has_field {
        return "", false
    }
    pkg := expr_type(c, file, operand)
    if pkg.mode != .Package {
        return "", false
    }
    dir, _ := strings.replace_all(pkg.dir, "\\", "/", context.temp_allocator)
    if !strings.has_suffix(strings.trim_right(dir, "/"), "base/builtin") {
        return "", false
    }
    return odinsyntax.node_text(odinsyntax.Syntax_Node(field)), true
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
        if b, is_basic := type_get(&c.table, type_base(&c.table, op.type)).(Basic_Type); is_basic && b.kind == .Any {
            return {missing = name != "data" && name != "id", owner = op.type}
        }
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

// The untyped constant of a conversion `T(x)` that `T` cannot take: an integer `T` cannot hold, a
// string into a type that is no string, or a number or bool into a string, or a number into a bool.
conversion_problem :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node) -> (Type_Problem, bool) {
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
    if const_overflows(c, fn.type, op) {
        return {value = arg, op = op, to = fn.type, overflow = true}, true
    }
    if op.mode == .Const && cast_refused(c, fn.type, op.type) || op.mode == .Value && typed_cast_refused(c, fn.type, op.type) {
        return {value = arg, op = op, to = fn.type}, true
    }
    return {}, false
}

// True when no value of the basic type `from` converts to `to`: a string to a number, bool, rune,
// enum or cstring, a cstring to a number, an integer or bool to a string.
@(private = "file")
typed_cast_refused :: proc(c: ^Checker, to, from: Type_Id) -> bool {
    fb, from_basic := type_get(&c.table, type_base(&c.table, from)).(Basic_Type)
    if !from_basic {
        return false
    }
    to_kind: Basic_Kind
    #partial switch v in type_get(&c.table, type_base(&c.table, to)) {
    case Basic_Type:
        to_kind = v.kind
    case Enum_Type:
        return fb.kind == .String
    case:
        return false
    }
    to_number := to_kind >= .Int && to_kind <= .F64be
    #partial switch fb.kind {
    case .String:
        #partial switch to_kind {
        case .String, .String16, .Cstring16, .Any, .Rawptr, .Typeid:
            return false
        }
        return true
    case .Cstring:
        return to_number
    case .Rune, .String16, .Cstring16, .Rawptr, .Typeid, .Any:
        return false
    }
    // An integer, float, complex, quaternion or bool.
    return to_kind == .String && fb.kind <= .U128be
}

// True when no constant of the untyped type `from` converts to `to`.
@(private = "file")
cast_refused :: proc(c: ^Checker, to, from: Type_Id) -> bool {
    u, is_untyped := type_get(&c.table, from).(Untyped_Type)
    if !is_untyped {
        return false
    }
    kind: Basic_Kind
    #partial switch v in type_get(&c.table, type_base(&c.table, to)) {
    case Basic_Type:
        kind = v.kind
    case Enum_Type:
        return u.kind == .String
    case:
        return false
    }
    #partial switch u.kind {
    case .String:
        #partial switch kind {
        case .String, .Cstring, .String16, .Cstring16, .Any:
            return false
        }
        return true
    case .Int, .Float, .Rune:
        return kind == .String || kind == .Bool
    case .Bool:
        return kind == .String
    }
    return false
}

// The string constant arguments of `min`, `max` or `clamp` that the numeric type of its first typed
// argument cannot take. The list is in `allocator`.
min_max_mismatches :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node, allocator := context.allocator) -> []Type_Problem {
    ce, is_call := odinsyntax.as_call_expr(call)
    if !is_call {
        return nil
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list || callee.green.kind != .Ident {
        return nil
    }
    switch odinsyntax.node_text(callee) {
    case "min", "max", "clamp":
    case:
        return nil
    }
    if expr_type(c, file, callee).mode != .Builtin {
        return nil
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    args := make([dynamic]odinsyntax.Syntax_Node, c.tmp)
    to := INVALID_TYPE
    it := odinsyntax.arg_list_args(&list)
    for arg in odinsyntax.child_iter_next(&it) {
        if arg.green.kind == .Field_Value || arg.green.kind == .Spread_Expr {
            return nil
        }
        if _, err := append(&args, arg); !note_alloc(c, err) {
            return nil
        }
        op := expr_type(c, file, arg)
        if op.mode == .Type {
            return nil
        }
        if to == INVALID_TYPE && op.mode == .Value && op.type != INVALID_TYPE && !type_is_untyped(&c.table, op.type) {
            to = op.type
        }
    }
    if to == INVALID_TYPE || !type_is_numeric(&c.table, to) {
        return nil
    }
    out := make([dynamic]Type_Problem, allocator)
    for arg in args {
        op := expr_type(c, file, arg, to)
        u, is_untyped := type_get(&c.table, op.type).(Untyped_Type)
        if op.mode == .Const && is_untyped && u.kind == .String {
            append(&out, Type_Problem{arg, op, to, false})
        }
    }
    return out[:]
}

// A boolean argument of `min`, `max` or `clamp`, which take ordered types only. `offset` is where the
// compiler reports it: the argument, or the call for the first argument and for `clamp`.
Order_Problem :: struct {
    offset: int,
    name:   string,  // the builtin; borrows the parse
    type:   Type_Id, // the type of the argument
}

min_max_order_problem :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node) -> (Order_Problem, bool) {
    ce, is_call := odinsyntax.as_call_expr(call)
    if !is_call {
        return {}, false
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list || callee.green.kind != .Ident {
        return {}, false
    }
    name := odinsyntax.node_text(callee)
    switch name {
    case "min", "max", "clamp":
    case:
        return {}, false
    }
    if expr_type(c, file, callee).mode != .Builtin {
        return {}, false
    }
    i := 0
    it := odinsyntax.arg_list_args(&list)
    for arg in odinsyntax.child_iter_next(&it) {
        if arg.green.kind == .Field_Value || arg.green.kind == .Spread_Expr {
            return {}, false
        }
        op := expr_type(c, file, arg)
        if (op.mode == .Value || op.mode == .Const) && type_is_boolean(c, op.type) {
            offset := int(arg.offset)
            if i == 0 || name == "clamp" {
                offset = int(call.offset)
            }
            return {offset, name, op.type}, true
        }
        i += 1
    }
    return {}, false
}

@(private = "file")
type_is_boolean :: proc(c: ^Checker, t: Type_Id) -> bool {
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Untyped_Type:
        return v.kind == .Bool
    case Basic_Type:
        #partial switch v.kind {
        case .Bool, .B8, .B16, .B32, .B64:
            return true
        }
    }
    return false
}

// The arguments of `call` that its one procedure cannot take. Nil for the calls call_problem leaves
// out and for C variadic parameters; of a polymorphic procedure only the parameters that declare no
// `$` name count, typed with the names the others bind. The list is in `allocator`.
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
    if !is_proc {
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
    params := p.params
    declares: []bool // a polymorphic procedure: the parameters up to the last that declares a `$` name
    if p.generic {
        params, declares = generic_params(c, p, with, slots)
        if params == nil {
            return nil
        }
    }
    out := make([dynamic]Type_Problem, allocator)
    for a, i in with {
        if i < first || a.spread || a.node.green == nil {
            continue
        }
        param := params[slots[i]]
        if .C_Vararg in param.flags || declares != nil && declares[slots[i]] {
            continue
        }
        if builtin_call(c, file, a.node) {
            continue
        }
        to := param.type
        if p.generic && (to == INVALID_TYPE || has_poly(c, to, 0)) {
            continue
        }
        op := expr_type(c, file, a.node, to)
        if assignable(c, to, op, .Any_Int in param.flags) == .No {
            append(&out, Type_Problem{a.node, op, to, false})
        } else if const_overflows(c, to, op) {
            append(&out, Type_Problem{a.node, op, to, true})
        }
    }
    return out[:]
}

// The parameters of the polymorphic procedure `p` read with the names `with` binds, and for each
// whether it is left out: it declares a `$` name or comes before one that does. Nil when a binding cannot be read or comes from an untyped
// argument, whose default type the compiler may not take.
@(private = "file")
generic_params :: proc(c: ^Checker, p: Proc_Type, with: []Call_Arg, slots: []int) -> ([]Proc_Param, []bool) {
    node, ok := node_of_kind(c, p.file, p.offset, .Proc_Type)
    if !ok {
        return nil, nil
    }
    pt, _ := odinsyntax.as_proc_type(node)
    list, has_params := odinsyntax.proc_type_params(&pt)
    if !has_params {
        return nil, nil
    }
    infos := param_infos(c, odinsyntax.Syntax_Node(list))
    if len(infos) != len(p.params) {
        return nil, nil
    }
    // A parameter before the last `$` declaration may name a type the `$` name shadows only later.
    declares := make([]bool, len(infos), c.tmp)
    last := -1
    for info, k in infos {
        if info.poly_name || info.has_type && strings.contains_rune(odinsyntax.node_text(info.type), '$') {
            last = k
        }
    }
    for k in 0 ..= last {
        declares[k] = true
    }
    for a, i in with {
        if declares[slots[i]] && (a.op.mode != .Value && a.op.mode != .Const && a.op.mode != .Type || type_is_untyped(&c.table, a.op.type)) {
            return nil, nil
        }
    }
    env, bound := bind_generic(c, p, with, slots)
    if !bound || len(env) == 0 {
        return nil, nil
    }
    params := bound_params(c, p, env)
    if params == nil {
        return nil, nil
    }
    return params, declares
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
        if !has_op || !has_lhs || !has_rhs {
            return nil
        }
        if op.green.kind != .Eq {
            return op_assign_mismatches(c, file, op.green.kind, lhs, rhs, allocator)
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

// The untyped constant of `x op= v` that a basic `x` cannot take; a shift takes an integer.
@(private = "file")
op_assign_mismatches :: proc(c: ^Checker, file: File_Id, op: odinsyntax.Token_Kind, lhs, rhs: odinsyntax.Expr_List, allocator: mem.Allocator) -> []Type_Problem {
    lhs, rhs := lhs, rhs
    place, value: odinsyntax.Syntax_Node
    count := 0
    it := odinsyntax.expr_list_items(&lhs)
    for n in odinsyntax.child_iter_next(&it) {
        place = n
        count += 1
    }
    it = odinsyntax.expr_list_items(&rhs)
    for n in odinsyntax.child_iter_next(&it) {
        value = n
        count += 1
    }
    if count != 2 {
        return nil
    }
    lop := expr_type(c, file, place)
    if lop.mode != .Value {
        return nil
    }
    basic, is_basic := type_get(&c.table, type_base(&c.table, lop.type)).(Basic_Type)
    if !is_basic {
        return nil
    }
    #partial switch basic.kind {
    case .String, .Cstring, .String16, .Cstring16, .Rawptr, .Typeid, .Any:
        return nil
    }
    vop := expr_type(c, file, value, lop.type)
    u, is_untyped := type_get(&c.table, vop.type).(Untyped_Type)
    if vop.mode != .Const || !is_untyped {
        return nil
    }
    #partial switch op {
    case .Shl_Eq, .Shr_Eq:
        if u.kind != .String && u.kind != .Bool {
            return nil
        }
        out := make([]Type_Problem, 1, allocator)
        out[0] = {value, vop, type_untyped(.Int), false}
        return out
    case .Add_Eq, .Sub_Eq, .Mul_Eq, .Quo_Eq, .Mod_Eq, .Mod_Mod_Eq, .And_Eq, .Or_Eq, .Xor_Eq, .And_Not_Eq, .Cmp_And_Eq, .Cmp_Or_Eq:
        if assignable(c, lop.type, vop) != .No {
            return nil
        }
        out := make([]Type_Problem, 1, allocator)
        out[0] = {value, vop, lop.type, false}
        return out
    }
    return nil
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

// Why an `x or_return` does not fit the procedure around it.
Or_Return_Kind :: enum u8 {
    None,
    No_Results,      // the procedure has no results
    Unnamed_Results, // the procedure has more than one result and they have no names
    Single_Value,    // `x` gives one value; `end` is its type
    End_Mismatch,    // the last value of `x`, of type `end`, cannot go into the last result `to`
}

Or_Return_Problem :: struct {
    kind: Or_Return_Kind,
    end:  Type_Id,
    to:   Type_Id,
}

// The first reason the `or_return` expression `n` does not fit the innermost procedure around it.
// Kind None when it fits or a type is not known.
or_return_problem :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> Or_Return_Problem {
    oe, is_or := odinsyntax.as_or_return_expr(n)
    if !is_or {
        return {}
    }
    operand, has_operand := odinsyntax.or_return_expr_operand(&oe)
    if !has_operand {
        return {}
    }
    lit: odinsyntax.Syntax_Node
    found := false
    path := node_path(c, file, int(n.offset))
    #reverse for p in path {
        if p.green.kind == .Proc_Lit {
            lit, found = p, true
            break
        }
    }
    if !found {
        return {}
    }
    pl, _ := odinsyntax.as_proc_lit(lit)
    pt, has_type := odinsyntax.proc_lit_type(&pl)
    if !has_type {
        return {}
    }
    p, is_proc := type_get(&c.table, type_base(&c.table, type_expr(c, file, odinsyntax.Syntax_Node(pt)))).(Proc_Type)
    if !is_proc || p.diverging {
        return {}
    }
    if len(p.results) == 0 {
        return {kind = .No_Results}
    }
    if len(p.results) > 1 && p.results[0].name == "" {
        return {kind = .Unnamed_Results}
    }
    to := p.results[len(p.results) - 1].type
    op := expr_values(c, file, operand, INVALID_TYPE)
    if op.mode != .Value || op.type == INVALID_TYPE {
        return {}
    }
    tuple, is_tuple := type_get(&c.table, op.type).(Tuple_Type)
    if !is_tuple {
        if single_result_call(c, file, operand) && never_nil(c, op.type) {
            return {kind = .Single_Value, end = op.type, to = to}
        }
        return {}
    }
    if p.generic || len(tuple.types) < 2 {
        return {}
    }
    end := tuple.types[len(tuple.types) - 1]
    if assignable(c, to, {mode = .Value, type = end}) == .No {
        return {kind = .End_Mismatch, end = end, to = to}
    }
    return {}
}

// True when `t` is a number or a string: no boolean and no value that compares against `nil`.
@(private = "file")
never_nil :: proc(c: ^Checker, t: Type_Id) -> bool {
    if type_is_numeric(&c.table, t) {
        return true
    }
    b, is_basic := type_get(&c.table, type_base(&c.table, t)).(Basic_Type)
    return is_basic && (b.kind == .String || b.kind == .String16)
}

// True when `n` calls one procedure that has one result and no `#optional_ok` tag.
@(private = "file")
single_result_call :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> bool {
    ce, is_call := odinsyntax.as_call_expr(n)
    if !is_call {
        return false
    }
    callee, ok := odinsyntax.call_expr_callee(&ce)
    if !ok {
        return false
    }
    fn := expr_type(c, file, callee)
    if fn.mode != .Value && fn.mode != .Const {
        return false
    }
    p, is_proc := type_get(&c.table, type_base(&c.table, fn.type)).(Proc_Type)
    return is_proc && !p.generic && !p.diverging && len(p.results) == 1 && p.tags == {}
}

// The text of the first `where` constraint that is false for the arguments of `call`, a call of one
// polymorphic procedure. It borrows the parse of the procedure's file. False when every constraint
// holds or cannot be evaluated.
where_problem :: proc(c: ^Checker, file: File_Id, call: odinsyntax.Syntax_Node) -> (string, bool) {
    ce, is_call := odinsyntax.as_call_expr(call)
    if !is_call {
        return "", false
    }
    callee, has_callee := odinsyntax.call_expr_callee(&ce)
    list, has_list := odinsyntax.call_expr_args(&ce)
    if !has_callee || !has_list {
        return "", false
    }
    if _, is_directive := odinsyntax.as_directive(callee); is_directive {
        return "", false
    }
    fn := expr_type(c, file, callee)
    if fn.mode != .Value && fn.mode != .Const {
        return "", false
    }
    p, is_proc := type_get(&c.table, type_base(&c.table, fn.type)).(Proc_Type)
    if !is_proc || !p.generic {
        return "", false
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    args := call_args(c, file, odinsyntax.Syntax_Node(list), {})
    for a in args {
        if a.name == "" && !a.spread && may_give_values(c, a) {
            return "", false
        }
    }
    with, ok := with_receiver(c, file, callee, args)
    if !ok {
        return "", false
    }
    slots, miss := match_slots(c, p, with)
    if miss.kind != .None {
        return "", false
    }
    env, bound := bind_generic(c, p, with, slots)
    if !bound || len(env) == 0 {
        return "", false
    }
    constraint, fails := where_failing(c, p, env)
    if !fails {
        return "", false
    }
    return odinsyntax.node_text(constraint), true
}

// True when `v` gives one value whatever its type: a literal, `.Member`, an operator or a call of a
// builtin or a conversion.
@(private = "file")
one_value :: proc(c: ^Checker, file: File_Id, v: odinsyntax.Syntax_Node) -> bool {
    #partial switch v.green.kind {
    case .Literal, .Comp_Lit, .Implicit_Selector, .Binary_Expr, .Ternary_Expr, .Ternary_If_Expr,
         .Ternary_When_Expr, .Proc_Lit, .Cast_Expr, .Auto_Cast_Expr, .Slice_Expr:
        return true
    case .Call_Expr:
        ce, _ := odinsyntax.as_call_expr(v)
        callee, ok := odinsyntax.call_expr_callee(&ce)
        if !ok {
            return false
        }
        fn := expr_type(c, file, callee)
        if fn.mode == .Type {
            return true
        }
        name := odinsyntax.node_text(callee)
        return fn.mode == .Builtin && callee.green.kind == .Ident && name != "soa_unzip" && name != "expand_values"
    }
    return false
}

// Whether the places and the values of an `=` assignment or a variable declaration differ in count.
// `at` is the first place. False when a value count is not known, or a value may give one or two
// values (`m[k]`, `x.(T)`, `#optional_ok`).
assign_count :: proc(c: ^Checker, file: File_Id, stmt: odinsyntax.Syntax_Node) -> (at, places, values: int, mismatch: bool) {
    list: odinsyntax.Expr_List
    #partial switch stmt.green.kind {
    case .Assign_Stmt:
        as, _ := odinsyntax.as_assign_stmt(stmt)
        op, has_op := odinsyntax.assign_stmt_op(&as)
        lhs, has_lhs := odinsyntax.assign_stmt_lhs(&as)
        rhs, has_rhs := odinsyntax.assign_stmt_rhs(&as)
        if !has_op || !has_lhs || !has_rhs || op.green.kind != .Eq {
            return
        }
        at = int(lhs.offset)
        it := odinsyntax.expr_list_items(&lhs)
        for _ in odinsyntax.child_iter_next(&it) {
            places += 1
        }
        list = rhs
    case .Value_Decl:
        if is_constant_decl(stmt) {
            return
        }
        vd, _ := odinsyntax.as_value_decl(stmt)
        names, has_names := odinsyntax.value_decl_names(&vd)
        rhs, has_values := odinsyntax.value_decl_values(&vd)
        if !has_names || !has_values {
            return
        }
        at = int(names.offset)
        it := odinsyntax.name_list_names(&names)
        for _ in odinsyntax.child_iter_next(&it) {
            places += 1
        }
        list = rhs
    case:
        return
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    nodes := make([dynamic]odinsyntax.Syntax_Node, c.tmp)
    it := odinsyntax.expr_list_items(&list)
    for v in odinsyntax.child_iter_next(&it) {
        if v.green.kind == .Field_Value {
            return
        }
        if _, err := append(&nodes, v); !note_alloc(c, err) {
            return
        }
    }
    if len(nodes) == 0 || places == 0 {
        return
    }
    for v in nodes {
        // Beside other values only a call, also under `or_*` or parentheses, can give more than one.
        #partial switch v.green.kind {
        case .Call_Expr, .Or_Return_Expr, .Or_Else_Expr, .Or_Branch_Expr, .Paren_Expr:
        case:
            if len(nodes) > 1 {
                values += 1
                continue
            }
        }
        op := expr_values(c, file, v, INVALID_TYPE)
        if (op.mode != .Value && op.mode != .Const) || op.type == INVALID_TYPE {
            if !one_value(c, file, v) {
                return
            }
            values += 1
            continue
        }
        // An optional value gives one value beside others, one or two alone.
        if op.optional {
            if len(nodes) == 1 {
                return
            }
            values += 1
            continue
        }
        _, is_tuple := type_get(&c.table, op.type).(Tuple_Type)
        if is_tuple && len(nodes) > 1 {
            return
        }
        if is_tuple {
            values = len(tuple_types(c, &op.type))
        } else {
            values += 1
        }
    }
    return at, places, values, places != values
}
