package odinsema

import "core:strings"

import odinsyntax "../syntax"

// False when a `where` constraint of the polymorphic procedure `p` is false with `env` bound.
// A constraint that cannot be evaluated holds.
@(private)
where_holds :: proc(c: ^Checker, p: Proc_Type, env: []Binding) -> bool {
    _, fails := where_failing(c, p, env)
    return !fails
}

// The first `where` constraint of the polymorphic procedure `p` that is false with `env` bound, in
// the parse of `p.file`. A constraint that cannot be evaluated holds.
@(private)
where_failing :: proc(c: ^Checker, p: Proc_Type, env: []Binding) -> (odinsyntax.Syntax_Node, bool) {
    node, ok := node_of_kind(c, p.file, p.offset, .Proc_Lit)
    if !ok {
        return {}, false
    }
    lit, _ := odinsyntax.as_proc_lit(node)
    clause, has_clause := odinsyntax.proc_lit_where_clause(&lit)
    if !has_clause {
        return {}, false
    }
    saved := c.env
    c.env = env
    defer c.env = saved
    it := odinsyntax.where_clause_constraints(&clause)
    for constraint in odinsyntax.child_iter_next(&it) {
        if v, known := where_value(c, p.file, constraint); known && !v {
            return constraint, true
        }
    }
    return {}, false
}

// The value of a `where` constraint: a constant, `!`, `&&`, `||`, `==` or `!=` of two types, or a
// `type_is_*` or `type_has_field` intrinsic. False `known` when it cannot be evaluated.
@(private)
where_value :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (value, known: bool) {
    if c.depth >= EXPR_DEPTH {
        return false, false
    }
    c.depth += 1
    defer c.depth -= 1
    n := n
    #partial switch n.green.kind {
    case .Paren_Expr:
        pe, _ := odinsyntax.as_paren_expr(n)
        inner, ok := odinsyntax.paren_expr_expr(&pe)
        if !ok {
            return false, false
        }
        return where_value(c, file, inner)
    case .Unary_Expr:
        u, _ := odinsyntax.as_unary_expr(n)
        op, has_op := odinsyntax.unary_expr_op(&u)
        operand, has_operand := odinsyntax.unary_expr_operand(&u)
        if has_op && has_operand && op.green.kind == .Not {
            v, ok := where_value(c, file, operand)
            return !v, ok
        }
    case .Binary_Expr:
        b, _ := odinsyntax.as_binary_expr(n)
        op, has_op := odinsyntax.binary_expr_op(&b)
        lhs, has_lhs := odinsyntax.binary_expr_lhs(&b)
        rhs, has_rhs := odinsyntax.binary_expr_rhs(&b)
        if !has_op || !has_lhs || !has_rhs {
            return false, false
        }
        #partial switch op.green.kind {
        case .Cmp_And:
            l, lok := where_value(c, file, lhs)
            if lok && !l {
                return false, true
            }
            r, rok := where_value(c, file, rhs)
            if rok && !r {
                return false, true
            }
            return true, lok && rok
        case .Cmp_Or:
            l, lok := where_value(c, file, lhs)
            if lok && l {
                return true, true
            }
            r, rok := where_value(c, file, rhs)
            if rok && r {
                return true, true
            }
            return false, lok && rok
        case .Cmp_Eq, .Not_Eq:
            lt, lok := where_type(c, file, lhs)
            rt, rok := where_type(c, file, rhs)
            if lok && rok {
                if lt == INVALID_TYPE || rt == INVALID_TYPE {
                    return false, false
                }
                equal := same_type(c, lt, rt)
                return op.green.kind == .Cmp_Eq ? equal : !equal, true
            }
        }
    case .Call_Expr:
        if v, ok := type_predicate(c, file, n); ok {
            return v, true
        }
    }
    v, ok := const_eval(c, file, n)
    if !ok {
        return false, false
    }
    b, is_bool := v.(bool)
    return b, is_bool
}

// The type an operand of a `where` constraint names: a type, or a type-valued intrinsic call.
// False when it is no type; INVALID_TYPE when it is a type that cannot be read.
@(private)
where_type :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (Type_Id, bool) {
    if name, args, is_call := intrinsic_call(c, n); is_call {
        if t, known := type_intrinsic(c, file, name, args); known {
            return t, true
        }
    }
    op := expr_type(c, file, n)
    return op.type, op.mode == .Type
}

// The name and arguments of a call `intrinsics.name(...)` or `name(...)`; false when `n` is no call.
// The arguments are in `c.tmp`.
@(private = "file")
intrinsic_call :: proc(c: ^Checker, n: odinsyntax.Syntax_Node) -> (name: string, args: []odinsyntax.Syntax_Node, ok: bool) {
    call, is_call := odinsyntax.as_call_expr(n)
    if !is_call {
        return
    }
    callee, has_callee := odinsyntax.call_expr_callee(&call)
    list, has_list := odinsyntax.call_expr_args(&call)
    if !has_callee || !has_list {
        return
    }
    name = strings.trim_space(odinsyntax.node_text(callee))
    if dot := strings.last_index_byte(name, '.'); dot >= 0 {
        name = name[dot + 1:]
    }
    out := make([dynamic]odinsyntax.Syntax_Node, 0, 2, c.tmp)
    it := odinsyntax.arg_list_args(&list)
    for arg in odinsyntax.child_iter_next(&it) {
        if _, err := append(&out, arg); !note_alloc(c, err) {
            return "", nil, false
        }
    }
    return name, out[:], true
}

// The type a type-valued intrinsic gives; false `known` when it is not one or cannot be read.
@(private = "file")
type_intrinsic :: proc(c: ^Checker, file: File_Id, name: string, args: []odinsyntax.Syntax_Node) -> (type: Type_Id, known: bool) {
    if len(args) == 0 {
        return INVALID_TYPE, false
    }
    switch name {
    case "type_elem_type", "type_base_type", "type_core_type", "type_bit_set_elem_type", "type_bit_set_underlying_type", "type_field_type":
    case:
        return INVALID_TYPE, false
    }
    arg, is_type := where_type(c, file, args[0])
    if !is_type || arg == INVALID_TYPE {
        return INVALID_TYPE, false
    }
    t := &c.table
    base := type_base(t, arg)
    out := INVALID_TYPE
    switch name {
    case "type_base_type":
        out = base
    case "type_core_type":
        out = core_type(c, arg)
    case "type_elem_type":
        #partial switch v in type_get(t, base) {
        case Pointer_Type:           out = v.elem
        case Multi_Pointer_Type:     out = v.elem
        case Array_Type:             out = v.elem
        case Enumerated_Array_Type:  out = v.elem
        case Slice_Type:             out = v.elem
        case Dynamic_Array_Type:     out = v.elem
        case Simd_Type:              out = v.elem
        case Matrix_Type:            out = v.elem
        case Soa_Type:               out = v.elem
        case Basic_Type:
            out = component_of(c, base)
            if out == INVALID_TYPE {
                out = arg
            }
        }
    case "type_bit_set_elem_type":
        if b, ok := type_get(t, base).(Bit_Set_Type); ok {
            out = b.elem
        }
    case "type_bit_set_underlying_type":
        if b, ok := type_get(t, base).(Bit_Set_Type); ok {
            out = b.backing
            if out == INVALID_TYPE {
                if l, lok := layout_of(c, base); lok {
                    switch l.size {
                    case 1:  out = type_basic(.U8)
                    case 2:  out = type_basic(.U16)
                    case 4:  out = type_basic(.U32)
                    case 8:  out = type_basic(.U64)
                    case 16: out = type_basic(.U128)
                    }
                }
            }
        }
    case "type_field_type":
        if field, ok := const_string_arg(c, file, args, 1); ok {
            if hit, found := find_field(c, arg, field); found {
                out = hit.type
            }
        }
    }
    return out, out != INVALID_TYPE
}

// The value of the constant string argument `i`; false when there is none.
@(private = "file")
const_string_arg :: proc(c: ^Checker, file: File_Id, args: []odinsyntax.Syntax_Node, i: int) -> (string, bool) {
    if i >= len(args) {
        return "", false
    }
    v, ok := const_eval(c, file, args[i])
    if !ok {
        return "", false
    }
    s, is_string := v.(string)
    return s, is_string
}

// A type with named and distinct types followed, and an enum followed to its backing type.
@(private = "file")
core_type :: proc(c: ^Checker, t: Type_Id) -> Type_Id {
    base := type_base(&c.table, t)
    if e, is_enum := type_get(&c.table, base).(Enum_Type); is_enum {
        return e.backing != INVALID_TYPE ? type_base(&c.table, e.backing) : type_basic(.Int)
    }
    return base
}

// The value of a `type_is_*`, `type_has_field` or two-type intrinsic call; false `known` for
// others and for a type it cannot judge.
@(private)
type_predicate :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node) -> (value, known: bool) {
    temp := scratch_begin(c)
    defer scratch_end(temp)
    name, args, is_call := intrinsic_call(c, n)
    if !is_call || len(args) == 0 || !strings.has_prefix(name, "type_") {
        return false, false
    }
    arg, is_type := where_type(c, file, args[0])
    if !is_type || arg == INVALID_TYPE {
        return false, false
    }
    t := &c.table
    base := type_base(t, arg)
    shape := type_get(t, base)
    switch name {
    case "type_has_field":
        field, ok := const_string_arg(c, file, args, 1)
        if !ok {
            return false, false
        }
        _, found := find_field(c, arg, field)
        return found, true
    case "type_is_subtype_of", "type_is_variant_of", "type_is_specialization_of":
        if len(args) < 2 {
            return false, false
        }
        other, other_type := where_type(c, file, args[1])
        if !other_type || other == INVALID_TYPE {
            return false, false
        }
        switch name {
        case "type_is_subtype_of":
            return same_type(c, arg, other) || embeds(c, arg, other, 0), true
        case "type_is_variant_of":
            u, is_union := shape.(Union_Type)
            if !is_union {
                return false, true
            }
            for variant in u.variants {
                if same_type(c, variant, other) {
                    return true, true
                }
            }
            return false, true
        case "type_is_specialization_of":
            inst, is_instance := c.instances[arg]
            if !is_instance {
                return false, true
            }
            return inst.generic == other || type_underlying(t, inst.generic) == type_underlying(t, other), true
        }
    }
    if !strings.has_prefix(name, "type_is_") {
        return false, false
    }
    basic, is_basic := shape.(Basic_Type)
    switch name[len("type_is_"):] {
    case "integer":          return type_is_integer(t, base), true
    case "unsigned":         return basic_unsigned(c, base), true
    case "float":            return type_is_float(t, base), true
    case "complex":          return type_is_complex(t, base), true
    case "quaternion":       return type_is_quaternion(t, base), true
    case "numeric":          return type_is_numeric(t, base), true
    case "string":           return type_is_string(t, base), true
    case "boolean":          return type_is_boolean(t, base), true
    case "cstring":          return is_basic && (basic.kind == .Cstring || basic.kind == .Cstring16), true
    case "string16":         return is_basic && basic.kind == .String16, true
    case "cstring16":        return is_basic && basic.kind == .Cstring16, true
    case "rune":             return is_basic && basic.kind == .Rune, true
    case "rawptr":           return is_basic && basic.kind == .Rawptr, true
    case "any":              return is_basic && basic.kind == .Any, true
    case "typeid":           return is_basic && basic.kind == .Typeid, true
    case "named":            return arg != base, true
    case "pointer":          _, ok := shape.(Pointer_Type); return ok, true
    case "multi_pointer":    _, ok := shape.(Multi_Pointer_Type); return ok, true
    case "slice":            _, ok := shape.(Slice_Type); return ok, true
    case "dynamic_array":    _, ok := shape.(Dynamic_Array_Type); return ok, true
    case "array":            _, ok := shape.(Array_Type); return ok, true
    case "enumerated_array": _, ok := shape.(Enumerated_Array_Type); return ok, true
    case "map":              _, ok := shape.(Map_Type); return ok, true
    case "struct":           _, ok := shape.(Struct_Type); return ok, true
    case "union":            _, ok := shape.(Union_Type); return ok, true
    case "enum":             _, ok := shape.(Enum_Type); return ok, true
    case "bit_set":          _, ok := shape.(Bit_Set_Type); return ok, true
    case "bit_field":        _, ok := shape.(Bit_Field_Type); return ok, true
    case "proc":             _, ok := shape.(Proc_Type); return ok, true
    case "matrix":           _, ok := shape.(Matrix_Type); return ok, true
    case "simd_vector":      _, ok := shape.(Simd_Type); return ok, true
    case "dereferenceable":  _, ok := shape.(Pointer_Type); return ok, true
    case "matrix_row_major":
        m, ok := shape.(Matrix_Type)
        return ok && m.row_major, ok
    case "matrix_column_major":
        m, ok := shape.(Matrix_Type)
        return ok && !m.row_major, ok
    case "ordered":          return type_ordered(c, arg, false)
    case "ordered_numeric":  return type_ordered(c, arg, true)
    case "comparable":       return type_comparable(c, arg, 0)
    case "valid_map_key":    return type_comparable(c, arg, 0)
    case "simple_compare":   return type_simple_compare(c, arg, 0)
    case "sliceable":
        #partial switch v in shape {
        case Basic_Type:                                    return v.kind == .String || v.kind == .String16, true
        case Array_Type, Slice_Type, Dynamic_Array_Type, Multi_Pointer_Type: return true, true
        }
        return false, true
    case "indexable":
        #partial switch v in shape {
        case Basic_Type:
            if v.kind == .Cstring || v.kind == .Cstring16 {
                return false, false
            }
            return v.kind == .String || v.kind == .String16, true
        case Array_Type, Enumerated_Array_Type, Slice_Type, Dynamic_Array_Type, Map_Type, Multi_Pointer_Type, Matrix_Type, Soa_Type:
            return true, true
        }
        return false, true
    case "endian_little", "endian_big", "endian_platform":
        if !is_basic || !(type_is_integer(t, base) || type_is_float(t, base)) {
            return false, false
        }
        little, big := basic_endian(basic.kind)
        switch name {
        case "type_is_endian_little": return little, true
        case "type_is_endian_big":    return big, true
        }
        return !little && !big, true
    case "specialized_polymorphic_record":
        _, is_instance := c.instances[arg]
        return is_instance, true
    case "unspecialized_polymorphic_record":
        if _, is_instance := c.instances[arg]; is_instance {
            return false, true
        }
        #partial switch v in shape {
        case Struct_Type: return len(v.params) > 0, true
        case Union_Type:  return len(v.params) > 0, true
        }
        return false, true
    }
    return false, false
}

// The explicit byte order of a basic type.
@(private = "file")
basic_endian :: proc(kind: Basic_Kind) -> (little, big: bool) {
    #partial switch kind {
    case .I16le ..= .U128le, .F16le ..= .F64le: return true, false
    case .I16be ..= .U128be, .F16be ..= .F64be: return false, true
    }
    return false, false
}

// True for a type `<` orders: integers, floats, runes, strings, pointers and enums. With `numeric`
// only the numbers and enums.
@(private = "file")
type_ordered :: proc(c: ^Checker, t: Type_Id, numeric: bool) -> (value, known: bool) {
    core := core_type(c, t)
    #partial switch v in type_get(&c.table, core) {
    case Basic_Type:
        if type_is_integer(&c.table, core) || type_is_float(&c.table, core) {
            return true, true
        }
        #partial switch v.kind {
        case .String, .Cstring, .String16, .Cstring16:
            return !numeric, true
        case .Rawptr:
            return false, false
        }
        return false, true
    case Pointer_Type, Multi_Pointer_Type:
        return !numeric, true
    case Untyped_Type:
        return false, false
    }
    return false, true
}

// True for a type `==` compares. False `known` for a type the checker cannot judge.
@(private = "file")
type_comparable :: proc(c: ^Checker, t: Type_Id, depth: int) -> (value, known: bool) {
    if depth > USING_DEPTH || t == INVALID_TYPE {
        return false, false
    }
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Basic_Type:
        return v.kind != .Any, true
    case Pointer_Type, Multi_Pointer_Type, Enum_Type, Bit_Set_Type, Bit_Field_Type, Proc_Type, Simd_Type, Matrix_Type:
        return true, true
    case Slice_Type, Dynamic_Array_Type, Map_Type, Soa_Type:
        return false, true
    case Array_Type:
        return type_comparable(c, v.elem, depth + 1)
    case Enumerated_Array_Type:
        return type_comparable(c, v.elem, depth + 1)
    case Struct_Type:
        if len(v.params) > 0 || .Raw_Union in v.flags {
            return false, false
        }
        for f in v.fields {
            ok, fknown := type_comparable(c, f.type, depth + 1)
            if !fknown {
                return false, false
            }
            if !ok {
                return false, true
            }
        }
        return true, true
    case Union_Type:
        if len(v.params) > 0 {
            return false, false
        }
        for variant in v.variants {
            ok, vknown := type_comparable(c, variant, depth + 1)
            if !vknown {
                return false, false
            }
            if !ok {
                return false, true
            }
        }
        return true, true
    }
    return false, false
}

// True for a type whose values compare as bytes: booleans, integers, pointers, enums and bit_sets,
// and arrays of them. False `known` for records, which hang on their padding.
@(private = "file")
type_simple_compare :: proc(c: ^Checker, t: Type_Id, depth: int) -> (value, known: bool) {
    if depth > USING_DEPTH || t == INVALID_TYPE {
        return false, false
    }
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Basic_Type:
        #partial switch v.kind {
        case .Bool ..= .B64, .Int ..= .U128be, .Rune, .Rawptr, .Typeid:
            return true, true
        }
        return false, true
    case Pointer_Type, Multi_Pointer_Type, Enum_Type, Bit_Set_Type, Proc_Type:
        return true, true
    case Slice_Type, Dynamic_Array_Type, Map_Type:
        return false, true
    case Array_Type:
        return type_simple_compare(c, v.elem, depth + 1)
    case Enumerated_Array_Type:
        return type_simple_compare(c, v.elem, depth + 1)
    case Simd_Type:
        return type_simple_compare(c, v.elem, depth + 1)
    }
    return false, false
}
