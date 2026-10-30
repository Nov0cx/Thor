package odinsema

import "core:strings"

import odinsyntax "../syntax"

// The builtin procedures builtin_call types with no declaration. The magic ones of base:builtin come
// first; the rest are base:runtime procedures it falls back to when no universe package gives them.
@(private)
BUILTIN_PROCS := [?]string {
    "len", "cap", "size_of", "align_of", "offset_of", "offset_of_selector", "offset_of_member", "offset_of_by_string",
    "type_of", "typeid_of", "type_info_of", "swizzle", "complex", "quaternion", "real", "imag", "jmag", "kmag",
    "conj", "expand_values", "compress_values", "min", "max", "abs", "clamp", "soa_zip", "soa_unzip",
    "unreachable", "raw_data", "transpose", "outer_product", "hadamard_product", "matrix_flatten",
    "make", "new", "new_clone", "append", "delete", "free", "free_all", "clear", "resize", "reserve", "copy", "card",
    "panic", "assert", "unimplemented", "pop", "inject_at", "ordered_remove", "unordered_remove",
}

// True for a builtin procedure builtin_call knows.
@(private)
is_builtin_proc :: proc(name: string) -> bool {
    for b in BUILTIN_PROCS {
        if b == name {
            return true
        }
    }
    return false
}

// A call of a builtin procedure. The constant ones give their value; one builtin_call does not know
// gives the result of its declaration.
@(private)
builtin_call :: proc(c: ^Checker, file: File_Id, name: string, callee: Type_Id, args: []odinsyntax.Syntax_Node, expected: Type_Id) -> Operand {
    t := &c.table
    switch name {
    case "len", "cap":
        if len(args) == 1 {
            if v, ok := const_eval(c, file, args[0]); ok {
                if s, is_string := v.(string); is_string && name == "len" {
                    return {mode = .Const, type = type_untyped(.Int), value = i64(len(s))}
                }
            }
            op := expr_type(c, file, args[0])
            if a, ok := type_get(t, deref_base(c, op.type)).(Array_Type); ok && a.len >= 0 {
                return {mode = .Const, type = type_untyped(.Int), value = a.len}
            }
        }
        return {mode = .Value, type = type_basic(.Int)}
    case "size_of", "align_of":
        if len(args) == 1 {
            ty := type_expr(c, file, args[0])
            if ty == INVALID_TYPE {
                ty = type_default(t, expr_type(c, file, args[0]).type)
            }
            if l, ok := layout_of(c, ty); ok {
                return {mode = .Const, type = type_untyped(.Int), value = name == "align_of" ? l.align : l.size}
            }
        }
        return {mode = .Const, type = type_untyped(.Int)}
    case "offset_of", "offset_of_selector", "offset_of_member", "offset_of_by_string":
        if offset, ok := offset_of_call(c, file, name, args); ok {
            return {mode = .Const, type = type_basic(.Uintptr), value = offset}
        }
        return {mode = .Const, type = type_basic(.Uintptr)}
    case "type_of":
        if len(args) == 1 {
            return {mode = .Type, type = type_default(t, expr_type(c, file, args[0]).type)}
        }
        return {}
    case "typeid_of":
        return {mode = .Value, type = type_basic(.Typeid)}
    case "type_info_of":
        return {mode = .Value, type = type_pointer(t, runtime_type(c, "Type_Info"))}
    case "min", "max":
        return min_max_call(c, file, name == "max", args)
    case "abs", "conj":
        if len(args) == 1 {
            return value_of(expr_type(c, file, args[0], expected))
        }
    case "clamp":
        return first_typed(c, file, args, expected)
    case "swizzle":
        if len(args) >= 2 {
            op := expr_type(c, file, args[0])
            if a, ok := type_get(t, type_base(t, op.type)).(Array_Type); ok {
                return {mode = .Value, type = type_array(t, i64(len(args) - 1), a.elem)}
            }
        }
    case "complex":
        f := first_typed(c, file, args, INVALID_TYPE)
        return {mode = f.mode, type = complex_of(c, f.type)}
    case "quaternion":
        f := first_typed(c, file, args, INVALID_TYPE)
        return {mode = f.mode, type = quaternion_of(c, f.type)}
    case "real", "imag", "jmag", "kmag":
        if len(args) == 1 {
            op := expr_type(c, file, args[0])
            return {mode = op.mode == .Const ? .Const : .Value, type = component_of(c, op.type)}
        }
    case "expand_values":
        if len(args) == 1 {
            return expand_values(c, expr_type(c, file, args[0]).type)
        }
    case "compress_values":
        if expected != INVALID_TYPE {
            return {mode = .Value, type = expected}
        }
    case "soa_zip":
        return soa_zip(c, file, args)
    case "soa_unzip":
        if len(args) == 1 {
            return soa_unzip(c, expr_type(c, file, args[0]).type)
        }
    case "unreachable", "panic", "unimplemented", "assert", "free_all", "clear":
        return {mode = .No_Value}
    case "raw_data":
        if len(args) == 1 {
            return {mode = .Value, type = raw_data_of(c, expr_type(c, file, args[0]).type)}
        }
    case "transpose":
        if len(args) == 1 {
            if m, ok := type_get(t, type_base(t, expr_type(c, file, args[0]).type)).(Matrix_Type); ok {
                return {mode = .Value, type = type_matrix(t, m.cols, m.rows, m.elem, m.row_major)}
            }
        }
    case "outer_product":
        if len(args) == 2 {
            a, aok := type_get(t, type_base(t, expr_type(c, file, args[0]).type)).(Array_Type)
            b, bok := type_get(t, type_base(t, expr_type(c, file, args[1]).type)).(Array_Type)
            if aok && bok {
                return {mode = .Value, type = type_matrix(t, a.len, b.len, a.elem)}
            }
        }
    case "hadamard_product":
        if len(args) >= 1 {
            return value_of(expr_type(c, file, args[0]))
        }
    case "matrix_flatten":
        if len(args) == 1 {
            if m, ok := type_get(t, type_base(t, expr_type(c, file, args[0]).type)).(Matrix_Type); ok {
                n := m.rows >= 0 && m.cols >= 0 ? m.rows * m.cols : -1
                return {mode = .Value, type = type_array(t, n, m.elem)}
            }
        }
    case "make":
        if len(args) >= 1 {
            return {mode = .Value, type = type_expr(c, file, args[0])}
        }
    case "new":
        if len(args) >= 1 {
            return {mode = .Value, type = type_pointer(t, type_expr(c, file, args[0]))}
        }
    case "new_clone":
        if len(args) >= 1 {
            return {mode = .Value, type = type_pointer(t, type_default(t, expr_type(c, file, args[0]).type))}
        }
    case "append", "copy", "card", "inject_at":
        return {mode = .Value, type = type_basic(.Int)}
    case "delete", "free", "resize", "reserve":
        if e := runtime_type(c, "Allocator_Error"); e != INVALID_TYPE {
            return {mode = .Value, type = e}
        }
        return {mode = .No_Value}
    case "pop":
        if len(args) == 1 {
            return index_operand(c, expr_type(c, file, args[0]).type)
        }
    case "ordered_remove", "unordered_remove":
        return {mode = .No_Value}
    }
    if callee == INVALID_TYPE {
        return {}
    }
    return single_value(c, call_result(c, callee))
}

// The operand as a value: a constant keeps its mode, a type gives none.
@(private)
value_of :: proc(op: Operand) -> Operand {
    if op.mode == .Type || op.mode == .Invalid {
        return {}
    }
    return {mode = op.mode == .Const ? .Const : .Value, type = op.type, value = op.value}
}

// The type of the first typed argument; the first one when all are untyped.
@(private)
first_typed :: proc(c: ^Checker, file: File_Id, args: []odinsyntax.Syntax_Node, expected: Type_Id) -> Operand {
    first: Operand
    for arg, i in args {
        op := expr_type(c, file, arg, expected)
        if i == 0 {
            first = value_of(op)
        }
        if op.mode != .Invalid && op.type != INVALID_TYPE && !type_is_untyped(&c.table, op.type) {
            return {mode = .Value, type = op.type}
        }
    }
    first.value = nil
    return first
}

// The complex type with components of float type `f`.
@(private)
complex_of :: proc(c: ^Checker, f: Type_Id) -> Type_Id {
    b, ok := type_get(&c.table, type_base(&c.table, f)).(Basic_Type)
    if !ok {
        return type_untyped(.Complex)
    }
    #partial switch b.kind {
    case .F16, .F16le, .F16be: return type_basic(.Complex32)
    case .F32, .F32le, .F32be: return type_basic(.Complex64)
    }
    return type_basic(.Complex128)
}

// The quaternion type with components of float type `f`.
@(private)
quaternion_of :: proc(c: ^Checker, f: Type_Id) -> Type_Id {
    b, ok := type_get(&c.table, type_base(&c.table, f)).(Basic_Type)
    if !ok {
        return type_untyped(.Quaternion)
    }
    #partial switch b.kind {
    case .F16, .F16le, .F16be: return type_basic(.Quaternion64)
    case .F32, .F32le, .F32be: return type_basic(.Quaternion128)
    }
    return type_basic(.Quaternion256)
}

// The float type of a component of a complex or quaternion type.
@(private)
component_of :: proc(c: ^Checker, t: Type_Id) -> Type_Id {
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Basic_Type:
        #partial switch v.kind {
        case .Complex32, .Quaternion64:  return type_basic(.F16)
        case .Complex64, .Quaternion128: return type_basic(.F32)
        case .Complex128, .Quaternion256: return type_basic(.F64)
        }
    case Untyped_Type:
        return type_untyped(.Float)
    }
    return INVALID_TYPE
}

// The most array elements `expand_values` gives.
@(private)
MAX_EXPAND :: 256

// `expand_values(x)`: the fields of a struct or the elements of an array, as a Tuple.
@(private)
expand_values :: proc(c: ^Checker, t: Type_Id) -> Operand {
    temp := scratch_begin(c)
    defer scratch_end(temp)
    types := make([dynamic]Type_Id, c.tmp)
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Struct_Type:
        for f in v.fields {
            if _, err := append(&types, f.type); !note_alloc(c, err) {
                return {}
            }
        }
    case Array_Type:
        if v.len < 0 || v.len > MAX_EXPAND {
            return {}
        }
        for _ in 0 ..< v.len {
            if _, err := append(&types, v.elem); !note_alloc(c, err) {
                return {}
            }
        }
    case:
        return {}
    }
    if len(types) == 1 {
        return {mode = .Value, type = types[0]}
    }
    return {mode = .Value, type = type_tuple(&c.table, types[:])}
}

// `soa_zip(a = xs, b = ys)`: an `#soa[]` of a struct with one field per slice.
@(private)
soa_zip :: proc(c: ^Checker, file: File_Id, args: []odinsyntax.Syntax_Node) -> Operand {
    temp := scratch_begin(c)
    defer scratch_end(temp)
    fields := make([dynamic]Struct_Field, c.tmp)
    for arg, i in args {
        elem := INVALID_TYPE
        #partial switch v in type_get(&c.table, type_base(&c.table, expr_type(c, file, arg).type)) {
        case Slice_Type:         elem = v.elem
        case Dynamic_Array_Type: elem = v.elem
        case Array_Type:         elem = v.elem
        }
        name := strings.concatenate({"_", soa_index(i)}, c.tmp)
        if _, err := append(&fields, Struct_Field{name = name, type = elem, name_offset = -1}); !note_alloc(c, err) {
            return {}
        }
    }
    s := type_struct(&c.table, Struct_Type{fields = fields[:], file = file, offset = -1})
    return {mode = .Value, type = type_soa(&c.table, .Slice, s)}
}

@(private)
SOA_INDEX := [?]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}

@(private)
soa_index :: proc(i: int) -> string {
    return i < len(SOA_INDEX) ? SOA_INDEX[i] : "n"
}

// `soa_unzip(s)`: a slice for each field of the elements.
@(private)
soa_unzip :: proc(c: ^Checker, t: Type_Id) -> Operand {
    soa, ok := type_get(&c.table, type_base(&c.table, t)).(Soa_Type)
    if !ok {
        return {}
    }
    s, is_struct := type_get(&c.table, type_base(&c.table, soa.elem)).(Struct_Type)
    if !is_struct {
        return {}
    }
    temp := scratch_begin(c)
    defer scratch_end(temp)
    types, err := make([]Type_Id, len(s.fields), c.tmp)
    if !note_alloc(c, err) {
        return {}
    }
    for f, i in s.fields {
        types[i] = type_slice(&c.table, f.type)
    }
    if len(types) == 1 {
        return {mode = .Value, type = types[0]}
    }
    return {mode = .Value, type = type_tuple(&c.table, types)}
}

// `raw_data(x)`: a multi-pointer to the elements of a slice, a dynamic array, a string or a pointed-to array.
@(private)
raw_data_of :: proc(c: ^Checker, t: Type_Id) -> Type_Id {
    tt := &c.table
    #partial switch v in type_get(tt, type_base(tt, t)) {
    case Slice_Type:
        return type_multi_pointer(tt, v.elem)
    case Dynamic_Array_Type:
        return type_multi_pointer(tt, v.elem)
    case Pointer_Type:
        if a, ok := type_get(tt, type_base(tt, v.elem)).(Array_Type); ok {
            return type_multi_pointer(tt, a.elem)
        }
    case Basic_Type:
        #partial switch v.kind {
        case .String, .Cstring:
            return type_multi_pointer(tt, type_basic(.U8))
        case .String16, .Cstring16:
            return type_multi_pointer(tt, type_basic(.U16))
        }
    case Untyped_Type:
        if v.kind == .String {
            return type_multi_pointer(tt, type_basic(.U8))
        }
    }
    return type_basic(.Rawptr)
}

// `min(T)`, `max(T)` of an integer type, or the least or greatest of constant arguments.
@(private)
min_max_call :: proc(c: ^Checker, file: File_Id, greatest: bool, args: []odinsyntax.Syntax_Node) -> Operand {
    if len(args) == 0 {
        return {}
    }
    first := expr_type(c, file, args[0])
    if first.mode == .Type {
        if len(args) != 1 {
            return {}
        }
        lo, hi, ok := integer_bounds(c, first.type)
        if !ok {
            return {mode = .Const, type = first.type}
        }
        return {mode = .Const, type = first.type, value = greatest ? hi : lo}
    }
    best := first
    typed := !type_is_untyped(&c.table, first.type) ? first.type : INVALID_TYPE
    for arg in args[1:] {
        op := expr_type(c, file, arg)
        if typed == INVALID_TYPE && op.type != INVALID_TYPE && !type_is_untyped(&c.table, op.type) {
            typed = op.type
        }
        if op.mode != .Const || best.mode != .Const || op.value == nil || best.value == nil {
            best.mode = .Value
            best.value = nil
            continue
        }
        cmp, cok := const_binary(c, .Lt, op.value, best.value)
        less, is_bool := cmp.(bool)
        if !cok || !is_bool {
            best.value = nil
            continue
        }
        if less != greatest {
            best = op
        }
    }
    if typed != INVALID_TYPE {
        best.type = typed
    }
    return best
}

// The least and greatest value of an integer type; false when they do not fit i64.
@(private)
integer_bounds :: proc(c: ^Checker, t: Type_Id) -> (lo, hi: i64, ok: bool) {
    b, is_basic := type_get(&c.table, type_base(&c.table, t)).(Basic_Type)
    if !is_basic || !type_is_integer(&c.table, t) {
        return 0, 0, false
    }
    bits := 8 * basic_size(b.kind, c.snap.target)
    if bits <= 0 || bits > 64 {
        return 0, 0, false
    }
    if basic_unsigned(c, t) {
        if bits == 64 {
            return 0, 0, false
        }
        return 0, (i64(1) << u64(bits)) - 1, true
    }
    if bits == 64 {
        return min(i64), max(i64), true
    }
    return -(i64(1) << u64(bits - 1)), (i64(1) << u64(bits - 1)) - 1, true
}

// The field offset `offset_of(T, f)`, `offset_of(x.f)` or `offset_of_by_string(T, "f")` names.
@(private)
offset_of_call :: proc(c: ^Checker, file: File_Id, name: string, args: []odinsyntax.Syntax_Node) -> (i64, bool) {
    switch len(args) {
    case 1:
        sel, ok := odinsyntax.as_selector_expr(args[0])
        if !ok {
            return 0, false
        }
        lhs, has_lhs := odinsyntax.selector_expr_operand(&sel)
        field, has_field := odinsyntax.selector_expr_field(&sel)
        if !has_lhs || !has_field {
            return 0, false
        }
        return field_offset_by_name(c, deref_base(c, expr_type(c, file, lhs).type), odinsyntax.node_text(odinsyntax.Syntax_Node(field)))
    case 2:
        ty := type_expr(c, file, args[0])
        if ty == INVALID_TYPE {
            return 0, false
        }
        if name == "offset_of_by_string" {
            v, ok := const_eval(c, file, args[1])
            field, is_string := v.(string)
            if !ok || !is_string {
                return 0, false
            }
            return field_offset_by_name(c, ty, field)
        }
        return field_offset_by_name(c, ty, odinsyntax.node_text(args[1]))
    }
    return 0, false
}

// `#config(NAME, default)`, `#defined(name)`, `#load(path)` and the other directive calls.
@(private)
directive_call :: proc(c: ^Checker, file: File_Id, name: string, args: []odinsyntax.Syntax_Node) -> Operand {
    switch name {
    case "config":
        if len(args) != 2 {
            return {}
        }
        if d, ok := target_define(c.snap.target, odinsyntax.node_text(args[0])); ok {
            switch v in d {
            case bool:   return {mode = .Const, type = type_untyped(.Bool), value = v}
            case i64:    return {mode = .Const, type = type_untyped(.Int), value = v}
            case string: return {mode = .Const, type = type_untyped(.String), value = v}
            }
        }
        return expr_type(c, file, args[1])
    case "defined":
        return {mode = .Const, type = type_untyped(.Bool)}
    case "load":
        if len(args) == 2 {
            return {mode = .Value, type = type_expr(c, file, args[1])}
        }
        return {mode = .Value, type = type_slice(&c.table, type_basic(.U8))}
    case "location", "caller_location":
        return {mode = .Value, type = runtime_type(c, "Source_Code_Location")}
    case "load_directory":
        return {mode = .Value, type = type_slice(&c.table, runtime_type(c, "Load_Directory_File"))}
    case "file", "procedure", "directory", "caller_expression":
        return {mode = .Const, type = type_untyped(.String)}
    case "line", "hash", "load_hash":
        return {mode = .Const, type = type_untyped(.Int)}
    case "exists":
        return {mode = .Const, type = type_untyped(.Bool)}
    }
    return {}
}

// A type the compiler declares for a build constant: an enum, or a bit_set of one.
@(private)
Compiler_Type :: struct {
    constant: string,
    name:     string, // the base:runtime declaration that names it; "" when none
    backing:  Basic_Kind,
    first:    i64, // the value of the first member
    members:  []string, // "_" holds a value with no name
    is_set:   bool, // a bit_set of the enum
}

@(private)
COMPILER_TYPES := [?]Compiler_Type {
    {"ODIN_OS", "Odin_OS_Type", .Int, 0, {"Unknown", "Windows", "Darwin", "Linux", "FreeBSD", "OpenBSD", "NetBSD", "WASI", "JS", "Orca", "Freestanding"}, false},
    {"ODIN_ARCH", "Odin_Arch_Type", .Int, 0, {"Unknown", "amd64", "i386", "arm32", "arm64", "wasm32", "wasm64p32", "riscv64"}, false},
    {"ODIN_BUILD_MODE", "Odin_Build_Mode_Type", .Int, 0, {"Executable", "Dynamic", "Static", "Object", "Assembly", "LLVM_IR"}, false},
    {"ODIN_ENDIAN", "Odin_Endian_Type", .Int, 0, {"Little", "Big"}, false},
    {"ODIN_PLATFORM_SUBTARGET", "Odin_Platform_Subtarget_Type", .Int, 0, {"Default", "iPhone", "iPhoneSimulator", "Android"}, false},
    {"ODIN_OPTIMIZATION_MODE", "Odin_Optimization_Mode", .Int, -1, {"None", "Minimal", "Size", "Speed", "Aggressive"}, false},
    {"ODIN_DEFAULT_CALLING_CONVENTION", "Calling_Convention", .U8, 0, {"Invalid", "Odin", "Contextless", "CDecl", "Std_Call", "Fast_Call", "None", "Naked", "_", "Win64", "SysV", "Preserve_None", "Preserve_Most", "Preserve_All"}, false},
    {"ODIN_ERROR_POS_STYLE", "", .Int, 0, {"Default", "Unix"}, false},
    {"ODIN_WINDOWS_SUBSYSTEM", "", .Int, 0, {"Unknown", "Console", "Windows"}, false},
    {"ODIN_SANITIZER_FLAGS", "Odin_Sanitizer_Flags", .U32, 0, {"Address", "Memory", "Thread"}, true},
}

// The type of a build constant whose value the compiler types itself, made once per checker; INVALID_TYPE for another name.
@(private)
compiler_type :: proc(c: ^Checker, constant: string) -> Type_Id {
    if memo, ok := c.odin_types[constant]; ok {
        dep_use(c, memo.node)
        return memo.type
    }
    spec: ^Compiler_Type
    for &k in COMPILER_TYPES {
        if k.constant == constant {
            spec = &k
        }
    }
    if spec == nil {
        return INVALID_TYPE
    }
    node, saved := dep_enter(c)
    defer dep_leave(c, saved)
    temp := scratch_begin(c)
    defer scratch_end(temp)
    members := make([dynamic]Enum_Member, c.tmp)
    for name, i in spec.members {
        if name == "_" {
            continue
        }
        if _, err := append(&members, Enum_Member{name = name, value = spec.first + i64(i), name_offset = -1}); !note_alloc(c, err) {
            return INVALID_TYPE
        }
    }
    t := type_enum(&c.table, Enum_Type{backing = type_basic(spec.backing), members = members[:], file = NO_FILE})
    if spec.is_set {
        t = type_bit_set(&c.table, t, type_basic(spec.backing))
    }
    if spec.name != "" {
        for u in c.universe {
            if u.all {
                continue
            }
            if sym, ok := member_lookup(c, u.dir, spec.name, NO_FILE, true); ok {
                named := type_named(&c.table, sym, spec.name, qualifier(c, sym.file))
                type_set_underlying(&c.table, named, t)
                t = named
                break
            }
        }
    }
    if _, entry, _, err := map_entry(&c.odin_types, constant); note_alloc(c, err) {
        entry^ = Memo_Type{t, node}
    }
    return t
}
