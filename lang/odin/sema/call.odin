package odinsema

import "core:strings"

import odinsyntax "../syntax"

// An argument of a call and the operand it gives.
@(private)
Call_Arg :: struct {
    node:   odinsyntax.Syntax_Node,
    name:   string, // a named argument; "" when positional
    spread: bool,   // `..x`
    op:     Operand,
}

// The parameter of a procedure type as written: what binding a polymorphic call reads.
@(private)
Param_Info :: struct {
    type:        odinsyntax.Syntax_Node,
    has_type:    bool,
    poly_name:   bool, // the name is `$N` or `$T`
    name_offset: int,  // poly_name: the name after `$`
}

@(private)
call_operand :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, expected: Type_Id) -> Operand {
    call, _ := odinsyntax.as_call_expr(n)
    callee, has_callee := odinsyntax.call_expr_callee(&call)
    if !has_callee {
        return {}
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    args := make([dynamic]Call_Arg, c.tmp)
    values := make([dynamic]odinsyntax.Syntax_Node, c.tmp)
    if list, ok := odinsyntax.call_expr_args(&call); ok {
        it := odinsyntax.arg_list_args(&list)
        for arg in odinsyntax.child_iter_next(&it) {
            a := Call_Arg{node = arg}
            #partial switch arg.green.kind {
            case .Field_Value:
                fv, _ := odinsyntax.as_field_value(arg)
                name, nok := odinsyntax.field_value_name(&fv)
                value, vok := odinsyntax.field_value_value(&fv)
                if !nok || !vok {
                    continue
                }
                a.name = odinsyntax.node_text(name)
                a.node = value
            case .Spread_Expr:
                se, _ := odinsyntax.as_spread_expr(arg)
                inner, iok := odinsyntax.spread_expr_expr(&se)
                if !iok {
                    continue
                }
                a.node = inner
                a.spread = true
            }
            if _, err := append(&args, a); !note_alloc(c, err) {
                return {}
            }
            if _, err := append(&values, a.node); !note_alloc(c, err) {
                return {}
            }
        }
    }
    if d, is_directive := odinsyntax.as_directive(callee); is_directive {
        tok, _ := odinsyntax.directive_name(&d)
        return directive_call(c, file, odinsyntax.syntax_token_text(tok), values[:])
    }
    fn := expr_type(c, file, callee)
    #partial switch fn.mode {
    case .Type:
        #partial switch v in type_get(&c.table, type_base(&c.table, fn.type)) {
        case Struct_Type:
            if len(v.params) > 0 {
                eval_args(c, file, args[:], INVALID_TYPE)
                return instantiate(c, fn.type, args[:])
            }
        case Union_Type:
            if len(v.params) > 0 {
                eval_args(c, file, args[:], INVALID_TYPE)
                return instantiate(c, fn.type, args[:])
            }
        }
        if len(args) != 1 {
            return {mode = .Value, type = fn.type}
        }
        if v, ok := const_eval(c, file, args[0].node); ok {
            if converted, cok := const_convert(c, fn.type, v); cok {
                return {mode = .Const, type = fn.type, value = converted}
            }
        }
        return {mode = .Value, type = fn.type}
    case .Builtin:
        if item := checker_item(c, fn.symbol); item != nil {
            return builtin_call(c, file, item.name, fn.type, values[:], expected)
        }
        return builtin_call(c, file, odinsyntax.node_text(callee), fn.type, values[:], expected)
    case .Value, .Const:
        receiver: Maybe(Operand)
        if sel, is_sel := odinsyntax.as_selector_expr(callee); is_sel {
            if _, is_arrow := odinsyntax.selector_expr_arrow(&sel); is_arrow {
                if operand, ok := odinsyntax.selector_expr_operand(&sel); ok {
                    receiver = expr_type(c, file, operand)
                }
            }
        }
        if r, has_receiver := receiver.?; has_receiver {
            if _, err := inject_at(&args, 0, Call_Arg{op = r}); !note_alloc(c, err) {
                return {}
            }
            eval_args(c, file, args[1:], fn.type)
        } else {
            eval_args(c, file, args[:], fn.type)
        }
        return call_value(c, fn.type, args[:])
    }
    return {}
}

// Reads the operand of each argument. A procedure callee gives a positional argument the parameter type as expected.
@(private)
eval_args :: proc(c: ^Checker, file: File_Id, args: []Call_Arg, callee: Type_Id) {
    p, is_proc := type_get(&c.table, type_base(&c.table, callee)).(Proc_Type)
    for &a, i in args {
        expected := INVALID_TYPE
        if is_proc && a.name == "" && !a.spread && i < len(p.params) {
            expected = p.params[i].type
        }
        a.op = expr_type(c, file, a.node, expected)
    }
}

// The result of calling a value of type `callee`; no arguments when `args` is nil.
@(private)
call_result :: proc(c: ^Checker, callee: Type_Id) -> Operand {
    return call_value(c, callee, nil)
}

@(private)
call_value :: proc(c: ^Checker, callee: Type_Id, args: []Call_Arg) -> Operand {
    base := type_base(&c.table, callee)
    #partial switch v in type_get(&c.table, base) {
    case Proc_Type:
        return proc_call(c, v, base, args)
    case Proc_Group_Type:
        chosen := choose_member(c, v, args)
        if chosen == INVALID_TYPE {
            if r, ok := group_result(c, v); ok {
                return r
            }
            if len(v.members) == 0 {
                return {}
            }
            chosen = v.members[0]
        }
        p, ok := type_get(&c.table, type_base(&c.table, chosen)).(Proc_Type)
        if !ok {
            return {}
        }
        return proc_call(c, p, type_base(&c.table, chosen), args)
    }
    return {}
}

// The member of a procedure group a call picks: one that takes the arguments, the best match first.
// A member that takes them all but matches none exactly is kept as the first that fits.
@(private)
choose_member :: proc(c: ^Checker, g: Proc_Group_Type, args: []Call_Arg) -> Type_Id {
    best, first_fit := INVALID_TYPE, INVALID_TYPE
    best_score := -1
    for m in g.members {
        p, ok := type_get(&c.table, type_base(&c.table, m)).(Proc_Type)
        if !ok {
            continue
        }
        slots, fits := match_args(c, p, args)
        if !fits {
            continue
        }
        if first_fit == INVALID_TYPE {
            first_fit = m
        }
        if s := score_call(c, p, args, slots); s > best_score {
            best, best_score = m, s
        }
    }
    return best != INVALID_TYPE ? best : first_fit
}

// The result the members of a group agree on; false when they differ.
@(private)
group_result :: proc(c: ^Checker, g: Proc_Group_Type) -> (Operand, bool) {
    result := Operand{}
    for m, i in g.members {
        p, ok := type_get(&c.table, type_base(&c.table, m)).(Proc_Type)
        if !ok {
            return {}, false
        }
        r := proc_result(c, p, type_base(&c.table, m))
        if r.optional {
            r = single_value(c, r)
        }
        if i == 0 {
            result = r
        } else if r.mode != result.mode || r.type != result.type {
            return {}, false
        }
    }
    return result, len(g.members) > 0
}

@(private)
proc_call :: proc(c: ^Checker, p: Proc_Type, pid: Type_Id, args: []Call_Arg) -> Operand {
    if !p.generic {
        return proc_result(c, p, pid)
    }
    slots, fits := match_args(c, p, args)
    if !fits {
        return proc_result(c, p, pid)
    }
    env, ok := bind_generic(c, p, args, slots)
    if !ok || len(env) == 0 {
        return proc_result(c, p, pid)
    }
    return generic_result(c, p, env)
}

// The results of procedure type `p`: no value, one, or a Tuple of all of them.
@(private)
proc_result :: proc(c: ^Checker, p: Proc_Type, pid: Type_Id) -> Operand {
    if p.diverging || len(p.results) == 0 {
        return {mode = .No_Value}
    }
    if len(p.results) == 1 {
        return {mode = .Value, type = p.results[0].type}
    }
    optional := p.tags != {}
    if t, ok := c.results[pid]; ok {
        return {mode = .Value, type = t, optional = optional}
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    types := make([]Type_Id, len(p.results), c.tmp)
    for r, i in p.results {
        types[i] = r.type
    }
    t := type_tuple(&c.table, types)
    if _, entry, _, err := map_entry(&c.results, pid); note_alloc(c, err) {
        entry^ = t
    }
    return {mode = .Value, type = t, optional = optional}
}

// The results of a polymorphic procedure, read again with its parameters bound.
@(private)
generic_result :: proc(c: ^Checker, p: Proc_Type, env: []Binding) -> Operand {
    node, ok := node_of_kind(c, p.file, p.offset, .Proc_Type)
    if !ok {
        return {}
    }
    pt, _ := odinsyntax.as_proc_type(node)
    results, has_results := odinsyntax.proc_type_results(&pt)
    if p.diverging || !has_results {
        return {mode = .No_Value}
    }
    saved := c.env
    c.env = env
    params := read_params(c, p.file, odinsyntax.Syntax_Node(results))
    c.env = saved
    switch len(params) {
    case 0:
        return {mode = .No_Value}
    case 1:
        return {mode = .Value, type = params[0].type}
    }
    types := make([]Type_Id, len(params), c.tmp)
    for r, i in params {
        types[i] = r.type
    }
    return {mode = .Value, type = type_tuple(&c.table, types), optional = p.tags != {}}
}

// The parameter each argument goes to; false when the arguments do not fit the parameters.
@(private)
match_args :: proc(c: ^Checker, p: Proc_Type, args: []Call_Arg) -> ([]int, bool) {
    slots := make([]int, len(args), c.tmp)
    covered := make([]bool, len(p.params), c.tmp)
    pos := 0
    for a, i in args {
        k := -1
        if a.name != "" {
            for param, j in p.params {
                if param.name == a.name || (len(param.name) == len(a.name) + 1 && param.name[0] == '$' && param.name[1:] == a.name) {
                    k = j
                    break
                }
            }
        } else if pos < len(p.params) {
            k = pos
            if .Variadic not_in p.params[pos].flags {
                pos += 1
            }
        } else if len(p.params) > 0 && (.Variadic in p.params[len(p.params) - 1].flags || .C_Vararg in p.params[len(p.params) - 1].flags) {
            k = len(p.params) - 1
        }
        if k < 0 {
            return nil, false
        }
        slots[i] = k
        covered[k] = true
    }
    for param, j in p.params {
        if !covered[j] && !param.has_default && .Variadic not_in param.flags && .C_Vararg not_in param.flags {
            return nil, false
        }
    }
    return slots, true
}

// How well arguments match the parameters they go to; -1 when one cannot be passed.
@(private)
score_call :: proc(c: ^Checker, p: Proc_Type, args: []Call_Arg, slots: []int) -> int {
    if p.generic {
        if _, ok := bind_generic(c, p, args, slots); !ok {
            return -1
        }
    }
    score := 0
    for a, i in args {
        param := p.params[slots[i]]
        if p.generic && has_poly(c, param.type, 0) {
            score += 1
            continue
        }
        s := assign_score(c, param.type, a.op, .Any_Int in param.flags, a.spread)
        if s < 0 {
            return -1
        }
        score += s
    }
    return score
}

// True when a type has a polymorphic parameter in it.
@(private)
has_poly :: proc(c: ^Checker, t: Type_Id, depth: int) -> bool {
    if depth > 16 {
        return false
    }
    #partial switch v in type_get(&c.table, t) {
    case Poly_Param_Type:       return true
    case Pointer_Type:          return has_poly(c, v.elem, depth + 1)
    case Multi_Pointer_Type:    return has_poly(c, v.elem, depth + 1)
    case Slice_Type:            return has_poly(c, v.elem, depth + 1)
    case Array_Type:            return v.len < 0 || has_poly(c, v.elem, depth + 1)
    case Enumerated_Array_Type: return has_poly(c, v.index, depth + 1) || has_poly(c, v.elem, depth + 1)
    case Dynamic_Array_Type:    return has_poly(c, v.elem, depth + 1)
    case Map_Type:              return has_poly(c, v.key, depth + 1) || has_poly(c, v.value, depth + 1)
    case Bit_Set_Type:          return has_poly(c, v.elem, depth + 1)
    case Matrix_Type:           return has_poly(c, v.elem, depth + 1)
    case Simd_Type:             return has_poly(c, v.elem, depth + 1)
    case Soa_Type:              return has_poly(c, v.elem, depth + 1)
    case Named_Type:
        if inst, ok := c.instances[t]; ok {
            for a in inst.args {
                if a.mode == .Type && has_poly(c, a.type, depth + 1) {
                    return true
                }
            }
        }
    }
    return false
}

// The element type a spread argument passes.
@(private)
spread_elem :: proc(c: ^Checker, t: Type_Id) -> Type_Id {
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Slice_Type:         return v.elem
    case Array_Type:         return v.elem
    case Dynamic_Array_Type: return v.elem
    }
    return INVALID_TYPE
}

// How well an operand can be passed to a parameter of type `to`: 3 for the same type, 2 for an
// untyped constant or the same underlying type, 1 for a conversion Odin does for a call, -1 for none.
@(private)
assign_score :: proc(c: ^Checker, to: Type_Id, op: Operand, any_int, spread: bool) -> int {
    t := &c.table
    from := op.type
    if spread {
        from = spread_elem(c, from)
    }
    if to == INVALID_TYPE || op.mode == .Invalid {
        return 1
    }
    tb := type_base(t, to)
    if op.mode == .Type {
        if b, ok := type_get(t, tb).(Basic_Type); ok && b.kind == .Typeid {
            return 2
        }
        return -1
    }
    if from == INVALID_TYPE {
        return 1
    }
    if from == to {
        return 3
    }
    fb := type_base(t, from)
    if u, ok := type_get(t, from).(Untyped_Type); ok {
        switch u.kind {
        case .Int, .Rune:
            if type_is_numeric(t, to) {
                return 2
            }
        case .Float:
            if type_is_float(t, to) || type_is_complex(t, to) || type_is_quaternion(t, to) {
                return 2
            }
        case .Complex, .Quaternion:
            if type_is_complex(t, to) || type_is_quaternion(t, to) {
                return 2
            }
        case .String:
            if type_is_string(t, to) {
                return 2
            }
        case .Bool:
            if type_is_boolean(t, to) {
                return 2
            }
        case .Nil:
            #partial switch v in type_get(t, tb) {
            case Pointer_Type, Multi_Pointer_Type, Slice_Type, Dynamic_Array_Type, Map_Type, Proc_Type, Union_Type:
                return 2
            case Basic_Type:
                #partial switch v.kind {
                case .Rawptr, .Cstring, .Cstring16, .Any, .Typeid:
                    return 2
                }
            }
        case .Uninit:
            return 2
        }
        if b, is_basic := type_get(t, tb).(Basic_Type); is_basic && b.kind == .Any {
            return 1
        }
        return -1
    }
    if type_underlying(t, to) == type_underlying(t, from) {
        return 2
    }
    if any_int && type_is_integer(t, to) && type_is_integer(t, from) {
        return 1
    }
    #partial switch v in type_get(t, tb) {
    case Basic_Type:
        #partial switch v.kind {
        case .Any:
            return 1
        case .Rawptr:
            #partial switch _ in type_get(t, fb) {
            case Pointer_Type, Multi_Pointer_Type:
                return 1
            }
        }
    case Union_Type:
        for variant in v.variants {
            if variant == from || type_underlying(t, variant) == type_underlying(t, from) {
                return 1
            }
        }
    case Proc_Type:
        if _, ok := type_get(t, fb).(Proc_Type); ok {
            return 1
        }
    case Pointer_Type:
        if f, ok := type_get(t, fb).(Pointer_Type); ok && embeds(c, f.elem, v.elem, 0) {
            return 1
        }
    }
    return -1
}

// True when a struct embeds `inner` through `using` fields.
@(private)
embeds :: proc(c: ^Checker, outer, inner: Type_Id, depth: int) -> bool {
    if depth > USING_DEPTH {
        return false
    }
    s, ok := type_get(&c.table, deref_base(c, outer)).(Struct_Type)
    if !ok {
        return false
    }
    for f in s.fields {
        if !f.is_using {
            continue
        }
        if f.type == inner || type_underlying(&c.table, f.type) == type_underlying(&c.table, inner) {
            return true
        }
        if p, is_ptr := type_get(&c.table, type_base(&c.table, f.type)).(Pointer_Type); is_ptr && p.elem == inner {
            return true
        }
        if embeds(c, f.type, inner, depth + 1) {
            return true
        }
    }
    return false
}

// The parameters of a Param_List as written, in the order read_params gives them.
@(private)
param_infos :: proc(c: ^Checker, list: odinsyntax.Syntax_Node) -> []Param_Info {
    list := list
    out := make([dynamic]Param_Info, c.tmp)
    it := odinsyntax.child_iter(&list, {kinds = {.Field}})
    for field in odinsyntax.child_iter_next(&it) {
        f, _ := odinsyntax.as_field(field)
        base := Param_Info{name_offset = -1}
        base.type, base.has_type = odinsyntax.field_type(&f)
        names, has_names := odinsyntax.field_names(&f)
        if !has_names {
            if _, err := append(&out, base); !note_alloc(c, err) {
                return nil
            }
            continue
        }
        nit := odinsyntax.name_list_names(&names)
        for name in odinsyntax.child_iter_next(&nit) {
            info := base
            if pt, is_poly := odinsyntax.as_poly_type(name); is_poly {
                if ident, ok := odinsyntax.poly_type_name(&pt); ok {
                    info.poly_name = true
                    info.name_offset = int(ident.offset)
                }
            }
            if _, err := append(&out, info); !note_alloc(c, err) {
                return nil
            }
        }
    }
    return out[:]
}

// Binds the polymorphic parameters of `p` from the arguments. False when an argument does not fit
// the shape of its parameter: `[]$T` against a map.
@(private)
bind_generic :: proc(c: ^Checker, p: Proc_Type, args: []Call_Arg, slots: []int) -> ([]Binding, bool) {
    node, ok := node_of_kind(c, p.file, p.offset, .Proc_Type)
    if !ok {
        return nil, true
    }
    pt, _ := odinsyntax.as_proc_type(node)
    params, has_params := odinsyntax.proc_type_params(&pt)
    if !has_params {
        return nil, true
    }
    infos := param_infos(c, odinsyntax.Syntax_Node(params))
    env := make([dynamic]Binding, c.tmp)
    saved := c.env
    defer c.env = saved
    for a, i in args {
        k := slots[i]
        if k >= len(infos) {
            continue
        }
        info := infos[k]
        if info.poly_name {
            bound := Operand{}
            #partial switch a.op.mode {
            case .Type:
                bound = {mode = .Type, type = a.op.type}
            case .Const:
                bound = {mode = .Const, type = a.op.type, value = a.op.value}
            case .Value:
                bound = {mode = .Const, type = type_default(&c.table, a.op.type)}
            case:
                continue
            }
            if _, err := append(&env, Binding{local_symbol(p.file, info.name_offset), bound}); !note_alloc(c, err) {
                return nil, false
            }
            if info.has_type && a.op.mode == .Type {
                if spec, has_spec := typeid_specialization(info.type); has_spec {
                    if !unify(c, p.file, spec, a.op.type, &env) {
                        return nil, false
                    }
                }
            }
            continue
        }
        if !info.has_type || !strings.contains_rune(odinsyntax.node_text(info.type), '$') {
            continue
        }
        type_node := info.type
        arg := type_default(&c.table, a.op.type)
        if e, is_ellipsis := odinsyntax.as_ellipsis_type(type_node); is_ellipsis {
            elem, eok := odinsyntax.ellipsis_type_elem(&e)
            if !eok {
                continue
            }
            type_node = elem
            if a.spread {
                arg = spread_elem(c, arg)
            }
        }
        if a.op.mode == .Type || !unify(c, p.file, type_node, arg, &env) {
            return nil, false
        }
    }
    return env[:], true
}

// The type after `/` in `typeid/T`.
@(private)
typeid_specialization :: proc(n: odinsyntax.Syntax_Node) -> (odinsyntax.Syntax_Node, bool) {
    n := n
    if t, ok := odinsyntax.as_typeid_type(n); ok {
        return odinsyntax.typeid_type_specialization(&t)
    }
    if b, ok := odinsyntax.as_binary_expr(n); ok {
        if lhs, lok := odinsyntax.binary_expr_lhs(&b); lok && lhs.green.kind == .Typeid_Type {
            return odinsyntax.binary_expr_rhs(&b)
        }
    }
    return {}, false
}

// True when type `a` and type `b` are the same for a parameter with no polymorphic part.
@(private)
same_type :: proc(c: ^Checker, a, b: Type_Id) -> bool {
    return a == b || type_underlying(&c.table, a) == type_underlying(&c.table, b)
}

@(private)
bind_poly :: proc(c: ^Checker, file: File_Id, ident: odinsyntax.Syntax_Node, op: Operand, env: ^[dynamic]Binding) -> bool {
    sym := local_symbol(file, int(ident.offset))
    for b in env {
        if b.symbol == sym {
            return true
        }
    }
    _, err := append(env, Binding{sym, op})
    return note_alloc(c, err)
}

// Matches a parameter type expression against an argument type and binds its `$T` and `$N`.
// False when the shapes differ.
@(private)
unify :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, arg: Type_Id, env: ^[dynamic]Binding) -> bool {
    if arg == INVALID_TYPE || c.depth >= EXPR_DEPTH {
        return true
    }
    c.depth += 1
    defer c.depth -= 1
    n := n
    t := &c.table
    if !strings.contains_rune(odinsyntax.node_text(n), '$') {
        c.env = env[:]
        want := type_expr(c, file, n)
        return want == INVALID_TYPE || has_poly(c, want, 0) || same_type(c, want, arg)
    }
    base := type_base(t, arg)
    #partial switch n.green.kind {
    case .Poly_Type:
        pt, _ := odinsyntax.as_poly_type(n)
        ident, ok := odinsyntax.poly_type_name(&pt)
        if !ok {
            return true
        }
        if !bind_poly(c, file, odinsyntax.Syntax_Node(ident), {mode = .Type, type = arg}, env) {
            return false
        }
        if spec, has_spec := odinsyntax.poly_type_specialization(&pt); has_spec {
            return unify(c, file, spec, arg, env)
        }
        return true
    case .Paren_Expr:
        p, _ := odinsyntax.as_paren_expr(n)
        inner, ok := odinsyntax.paren_expr_expr(&p)
        return !ok || unify(c, file, inner, arg, env)
    case .Pointer_Type:
        v, ok := type_get(t, base).(Pointer_Type)
        p, _ := odinsyntax.as_pointer_type(n)
        elem, eok := odinsyntax.pointer_type_elem(&p)
        return ok && (!eok || unify(c, file, elem, v.elem, env))
    case .Multi_Pointer_Type:
        v, ok := type_get(t, base).(Multi_Pointer_Type)
        p, _ := odinsyntax.as_multi_pointer_type(n)
        elem, eok := odinsyntax.multi_pointer_type_elem(&p)
        return ok && (!eok || unify(c, file, elem, v.elem, env))
    case .Dynamic_Array_Type:
        v, ok := type_get(t, base).(Dynamic_Array_Type)
        d, _ := odinsyntax.as_dynamic_array_type(n)
        elem, eok := odinsyntax.dynamic_array_type_elem(&d)
        return ok && (!eok || unify(c, file, elem, v.elem, env))
    case .Array_Type:
        a, _ := odinsyntax.as_array_type(n)
        elem, eok := odinsyntax.array_type_elem(&a)
        len_node, has_len := odinsyntax.array_type_len(&a)
        #partial switch v in type_get(t, base) {
        case Slice_Type:
            return !has_len && (!eok || unify(c, file, elem, v.elem, env))
        case Array_Type:
            if !has_len {
                return false
            }
            if lp, is_poly := odinsyntax.as_poly_type(len_node); is_poly && v.len >= 0 {
                if ident, iok := odinsyntax.poly_type_name(&lp); iok {
                    if !bind_poly(c, file, odinsyntax.Syntax_Node(ident), {mode = .Const, type = type_basic(.Int), value = v.len}, env) {
                        return false
                    }
                }
            }
            return !eok || unify(c, file, elem, v.elem, env)
        case Enumerated_Array_Type:
            return has_len && unify(c, file, len_node, v.index, env) && (!eok || unify(c, file, elem, v.elem, env))
        }
        return false
    case .Map_Type:
        v, ok := type_get(t, base).(Map_Type)
        if !ok {
            return false
        }
        m, _ := odinsyntax.as_map_type(n)
        if key, kok := odinsyntax.map_type_key(&m); kok && !unify(c, file, key, v.key, env) {
            return false
        }
        value, vok := odinsyntax.map_type_value(&m)
        return !vok || unify(c, file, value, v.value, env)
    case .Bit_Set_Type:
        v, ok := type_get(t, base).(Bit_Set_Type)
        if !ok {
            return false
        }
        b, _ := odinsyntax.as_bit_set_type(n)
        if elem, eok := odinsyntax.bit_set_type_elem(&b); eok && !v.range && !unify(c, file, elem, v.elem, env) {
            return false
        }
        backing, bok := odinsyntax.bit_set_type_backing(&b)
        return !bok || v.backing == INVALID_TYPE || unify(c, file, backing, v.backing, env)
    case .Matrix_Type:
        v, ok := type_get(t, base).(Matrix_Type)
        if !ok {
            return false
        }
        m, _ := odinsyntax.as_matrix_type(n)
        if rows, rok := odinsyntax.matrix_type_rows(&m); rok {
            bind_length(c, file, rows, v.rows, env)
        }
        if cols, cok := odinsyntax.matrix_type_columns(&m); cok {
            bind_length(c, file, cols, v.cols, env)
        }
        elem, eok := odinsyntax.matrix_type_elem(&m)
        return !eok || unify(c, file, elem, v.elem, env)
    case .Tag_Expr:
        tag, _ := odinsyntax.as_tag_expr(n)
        inner, ok := odinsyntax.tag_expr_expr(&tag)
        if !ok {
            return true
        }
        #partial switch v in type_get(t, base) {
        case Soa_Type:
            #partial switch inner.green.kind {
            case .Array_Type:
                a, _ := odinsyntax.as_array_type(inner)
                elem, eok := odinsyntax.array_type_elem(&a)
                return !eok || unify(c, file, elem, v.elem, env)
            case .Dynamic_Array_Type:
                d, _ := odinsyntax.as_dynamic_array_type(inner)
                elem, eok := odinsyntax.dynamic_array_type_elem(&d)
                return v.kind == .Dynamic && (!eok || unify(c, file, elem, v.elem, env))
            }
            return false
        case Simd_Type:
            a, is_array := odinsyntax.as_array_type(inner)
            if !is_array {
                return false
            }
            if len_node, has_len := odinsyntax.array_type_len(&a); has_len {
                bind_length(c, file, len_node, v.len, env)
            }
            elem, eok := odinsyntax.array_type_elem(&a)
            return !eok || unify(c, file, elem, v.elem, env)
        }
        return unify(c, file, inner, arg, env)
    case .Call_Expr:
        inst, ok := c.instances[arg]
        if !ok {
            return false
        }
        call, _ := odinsyntax.as_call_expr(n)
        callee, cok := odinsyntax.call_expr_callee(&call)
        if !cok {
            return true
        }
        c.env = env[:]
        if g := expr_type(c, file, callee); g.mode != .Type || g.type != inst.generic {
            return false
        }
        list, lok := odinsyntax.call_expr_args(&call)
        if !lok {
            return true
        }
        it := odinsyntax.arg_list_args(&list)
        i := 0
        for a in odinsyntax.child_iter_next(&it) {
            defer i += 1
            if i >= len(inst.args) {
                break
            }
            ia := inst.args[i]
            if pt, is_poly := odinsyntax.as_poly_type(a); is_poly && ia.mode == .Const {
                if ident, iok := odinsyntax.poly_type_name(&pt); iok && !bind_poly(c, file, odinsyntax.Syntax_Node(ident), ia, env) {
                    return false
                }
                continue
            }
            if ia.mode == .Type && !unify(c, file, a, ia.type, env) {
                return false
            }
        }
        return true
    }
    return true
}

// Binds `$N` of a length to `value`.
@(private)
bind_length :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, value: i64, env: ^[dynamic]Binding) {
    pt, is_poly := odinsyntax.as_poly_type(n)
    if !is_poly || value < 0 {
        return
    }
    if ident, ok := odinsyntax.poly_type_name(&pt); ok {
        bind_poly(c, file, odinsyntax.Syntax_Node(ident), {mode = .Const, type = type_basic(.Int), value = value}, env)
    }
}

// `List(int)`: the instance of a polymorphic record, made once per checker for each list of arguments.
@(private)
instantiate :: proc(c: ^Checker, generic: Type_Id, args: []Call_Arg) -> Operand {
    named, is_named := type_get(&c.table, generic).(Named_Type)
    if !is_named {
        return {mode = .Type, type = generic}
    }
    params: []Proc_Param
    record_file: File_Id
    record_offset: int
    kind: odinsyntax.Syntax_Kind
    #partial switch v in type_get(&c.table, type_underlying(&c.table, generic)) {
    case Struct_Type:
        params, record_file, record_offset, kind = v.params, v.file, v.offset, .Struct_Type
    case Union_Type:
        params, record_file, record_offset, kind = v.params, v.file, v.offset, .Union_Type
    case:
        return {mode = .Type, type = generic}
    }
    ops := make([]Operand, len(params), c.tmp)
    bindings := make([dynamic]Binding, c.tmp)
    pos := 0
    for a in args {
        k := -1
        if a.name != "" {
            for p, j in params {
                if p.name == a.name || (len(p.name) > 0 && p.name[0] == '$' && p.name[1:] == a.name) {
                    k = j
                }
            }
        } else {
            k = pos
            pos += 1
        }
        if k < 0 || k >= len(params) {
            continue
        }
        op: Operand
        #partial switch a.op.mode {
        case .Type:
            op = {mode = .Type, type = a.op.type}
        case .Const:
            op = {mode = .Const, type = a.op.type, value = a.op.value}
        case:
            continue
        }
        ops[k] = op
        if params[k].name_offset >= 0 {
            if _, err := append(&bindings, Binding{local_symbol(record_file, params[k].name_offset), op}); !note_alloc(c, err) {
                return {}
            }
        }
    }
    key := strings.builder_make(c.tmp)
    strings.write_int(&key, int(named.symbol.file))
    strings.write_byte(&key, ':')
    strings.write_int(&key, int(named.symbol.item))
    strings.write_byte(&key, ':')
    strings.write_int(&key, int(named.symbol.child))
    for op in ops {
        strings.write_byte(&key, op.mode == .Type ? 't' : 'c')
        strings.write_int(&key, int(op.type))
        write_const(&key, op.value)
    }
    if id, ok := c.inst_cache[strings.to_string(key)]; ok {
        return {mode = .Type, type = id}
    }
    name := strings.builder_make(c.tmp)
    strings.write_string(&name, named.name)
    strings.write_byte(&name, '(')
    for op, i in ops {
        if i > 0 {
            strings.write_string(&name, ", ")
        }
        switch {
        case op.mode == .Type:
            strings.write_string(&name, type_string(&c.table, op.type, c.tmp))
        case op.value != nil:
            write_const(&name, op.value)
        case:
            strings.write_string(&name, params[i].name)
        }
    }
    strings.write_byte(&name, ')')
    inst := type_named_instance(&c.table, named.symbol, strings.to_string(name), named.qualifier)
    if inst == INVALID_TYPE {
        return {}
    }
    stored_key, kerr := strings.clone(strings.to_string(key), c.alloc)
    stored_args, aerr := make([]Operand, len(ops), c.alloc)
    if !note_alloc(c, kerr) || !note_alloc(c, aerr) {
        return {}
    }
    copy(stored_args, ops)
    if _, entry, _, err := map_entry(&c.inst_cache, stored_key); note_alloc(c, err) {
        entry^ = inst
    }
    if _, entry, _, err := map_entry(&c.instances, inst); note_alloc(c, err) {
        entry^ = Instance{generic, stored_args}
    }
    if node, ok := node_of_kind(c, record_file, record_offset, kind); ok {
        saved := c.env
        c.env = bindings[:]
        underlying := kind == .Struct_Type ? struct_type(c, record_file, node) : union_type(c, record_file, node)
        c.env = saved
        if int(underlying) < len(c.table.types) && underlying != INVALID_TYPE {
            #partial switch &v in c.table.types[underlying] {
            case Struct_Type:
                v.params = nil
            case Union_Type:
                v.params = nil
            }
        }
        type_set_underlying(&c.table, inst, underlying)
    }
    return {mode = .Type, type = inst}
}

@(private)
write_const :: proc(sb: ^strings.Builder, v: Const_Value) {
    switch x in v {
    case i64:    strings.write_i64(sb, x)
    case f64:    strings.write_f64(sb, x, 'g')
    case string: strings.write_quoted_string(sb, x)
    case bool:   strings.write_string(sb, x ? "true" : "false")
    case rune:   strings.write_quoted_rune(sb, x)
    }
}
