package odinsema

import "core:mem"
import "core:strings"

// A type in a Type_Table. INVALID_TYPE is the type of what could not be checked.
Type_Id :: distinct u32

INVALID_TYPE :: Type_Id(0)

// A declaration a named type or a member belongs to.
Symbol :: struct {
    file:  File_Id,
    item:  i32, // the index in Item_Tree.items
    child: i32, // the index in Item.children; -1 for the item itself
}

// The kind of a type.
Type_Kind :: enum u8 {
    Invalid,
    Basic,
    Untyped,
    Pointer,
    Multi_Pointer,
    Slice,
    Array,
    Enumerated_Array,
    Dynamic_Array,
    Map,
    Bit_Set,
    Bit_Field,
    Matrix,
    Simd,
    Soa,
    Struct,
    Union,
    Enum,
    Proc,
    Tuple,
    Named,
    Distinct,
    Poly_Param,
    Proc_Group,
}

// A built-in type.
Basic_Kind :: enum u8 {
    Bool, B8, B16, B32, B64,
    Int, Uint, I8, I16, I32, I64, I128, U8, U16, U32, U64, U128, Uintptr,
    I16le, I32le, I64le, I128le, U16le, U32le, U64le, U128le,
    I16be, I32be, I64be, I128be, U16be, U32be, U64be, U128be,
    F16, F32, F64, F16le, F32le, F64le, F16be, F32be, F64be,
    Complex32, Complex64, Complex128,
    Quaternion64, Quaternion128, Quaternion256,
    Rune, String, Cstring, String16, Cstring16, Rawptr, Typeid, Any,
}

BASIC_NAMES := [Basic_Kind]string {
    .Bool          = "bool",
    .B8            = "b8",
    .B16           = "b16",
    .B32           = "b32",
    .B64           = "b64",
    .Int           = "int",
    .Uint          = "uint",
    .I8            = "i8",
    .I16           = "i16",
    .I32           = "i32",
    .I64           = "i64",
    .I128          = "i128",
    .U8            = "u8",
    .U16           = "u16",
    .U32           = "u32",
    .U64           = "u64",
    .U128          = "u128",
    .Uintptr       = "uintptr",
    .I16le         = "i16le",
    .I32le         = "i32le",
    .I64le         = "i64le",
    .I128le        = "i128le",
    .U16le         = "u16le",
    .U32le         = "u32le",
    .U64le         = "u64le",
    .U128le        = "u128le",
    .I16be         = "i16be",
    .I32be         = "i32be",
    .I64be         = "i64be",
    .I128be        = "i128be",
    .U16be         = "u16be",
    .U32be         = "u32be",
    .U64be         = "u64be",
    .U128be        = "u128be",
    .F16           = "f16",
    .F32           = "f32",
    .F64           = "f64",
    .F16le         = "f16le",
    .F32le         = "f32le",
    .F64le         = "f64le",
    .F16be         = "f16be",
    .F32be         = "f32be",
    .F64be         = "f64be",
    .Complex32     = "complex32",
    .Complex64     = "complex64",
    .Complex128    = "complex128",
    .Quaternion64  = "quaternion64",
    .Quaternion128 = "quaternion128",
    .Quaternion256 = "quaternion256",
    .Rune          = "rune",
    .String        = "string",
    .Cstring       = "cstring",
    .String16      = "string16",
    .Cstring16     = "cstring16",
    .Rawptr        = "rawptr",
    .Typeid        = "typeid",
    .Any           = "any",
}

// The type of an untyped constant or of `nil` and `---`.
Untyped_Kind :: enum u8 {
    Int,
    Float,
    Complex,
    Quaternion,
    Rune,
    String,
    Bool,
    Nil,
    Uninit,
}

UNTYPED_NAMES := [Untyped_Kind]string {
    .Int        = "untyped int",
    .Float      = "untyped float",
    .Complex    = "untyped complex",
    .Quaternion = "untyped quaternion",
    .Rune       = "untyped rune",
    .String     = "untyped string",
    .Bool       = "untyped bool",
    .Nil        = "untyped nil",
    .Uninit     = "---",
}

Basic_Type :: struct {
    kind: Basic_Kind,
}

Untyped_Type :: struct {
    kind: Untyped_Kind,
}

Pointer_Type :: struct {
    elem: Type_Id,
}

Multi_Pointer_Type :: struct {
    elem: Type_Id,
}

Slice_Type :: struct {
    elem: Type_Id,
}

Array_Type :: struct {
    len:  i64, // -1 when not known or `?`
    elem: Type_Id,
}

Enumerated_Array_Type :: struct {
    index: Type_Id,
    elem:  Type_Id,
}

Dynamic_Array_Type :: struct {
    elem: Type_Id,
}

Map_Type :: struct {
    key:   Type_Id,
    value: Type_Id,
}

// `bit_set[E; B]`, or `bit_set[lo..=hi; B]` when `range` is set.
Bit_Set_Type :: struct {
    elem:    Type_Id, // the enum, or the type of the range bounds
    backing: Type_Id, // INVALID_TYPE when none
    range:   bool,
    lo:      i64,
    hi:      i64, // inclusive
}

Bit_Field_Entry :: struct {
    name:        string,
    type:        Type_Id,
    bits:        i64, // -1 when not known
    name_offset: int,
}

Bit_Field_Type :: struct {
    backing: Type_Id,
    fields:  []Bit_Field_Entry,
}

Matrix_Type :: struct {
    rows:      i64, // -1 when not known
    cols:      i64,
    elem:      Type_Id,
    row_major: bool,
}

Simd_Type :: struct {
    len:  i64, // -1 when not known
    elem: Type_Id,
}

Soa_Kind :: enum u8 {
    Array,
    Slice,
    Dynamic,
}

// `#soa[N]T`, `#soa[]T` or `#soa[dynamic]T`.
Soa_Type :: struct {
    kind: Soa_Kind,
    len:  i64, // Array: -1 when not known
    elem: Type_Id,
}

Struct_Field :: struct {
    name:        string,
    type:        Type_Id,
    is_using:    bool,
    tag:         string, // with its quotes; "" when none
    name_offset: int,
}

Struct_Flag :: enum u8 {
    Packed,
    Raw_Union,
    No_Copy,
}

Struct_Type :: struct {
    fields: []Struct_Field,
    params: []Proc_Param, // the polymorphic parameters
    flags:  bit_set[Struct_Flag],
    align:  i64, // `#align(N)`; 0 when none
}

Union_Flag :: enum u8 {
    No_Nil,
    Shared_Nil,
}

Union_Type :: struct {
    variants: []Type_Id,
    params:   []Proc_Param, // the polymorphic parameters
    flags:    bit_set[Union_Flag],
    align:    i64, // `#align(N)`; 0 when none
}

Enum_Member :: struct {
    name:        string,
    value:       i64,
    name_offset: int,
}

Enum_Type :: struct {
    backing: Type_Id, // INVALID_TYPE when none
    members: []Enum_Member,
}

Param_Flag :: enum u8 {
    Using,
    Any_Int,
    C_Vararg,
    By_Ptr,
    No_Alias,
    Const,
    Variadic, // `..T`: `type` is T
}

// A parameter or a result of a procedure type.
Proc_Param :: struct {
    name:        string, // "" when unnamed
    type:        Type_Id,
    default:     string, // the default value text
    has_default: bool,
    inferred:    bool, // `name := default`: the type comes from the default
    flags:       bit_set[Param_Flag],
    name_offset: int, // -1 when unnamed
}

Proc_Type :: struct {
    params:     []Proc_Param,
    results:    []Proc_Param,
    convention: string, // the calling convention without quotes; "" when none
    diverging:  bool,   // `-> !`
}

// The values of a call to a procedure with more than one result.
Tuple_Type :: struct {
    types: []Type_Id,
}

// A declared type: `Name :: ...`. `underlying` is set after creation, so a type can refer to itself.
Named_Type :: struct {
    symbol:     Symbol,
    name:       string,
    qualifier:  string, // the package name printed before the name; "" when none
    underlying: Type_Id,
}

// `distinct base`: a new type with the representation of `base`.
Distinct_Type :: struct {
    symbol: Symbol,
    base:   Type_Id,
}

// `$T` or `$T/specialization`.
Poly_Param_Type :: struct {
    name:           string,
    specialization: Type_Id, // INVALID_TYPE when none
}

Proc_Group_Type :: struct {
    members: []Type_Id,
}

Type :: union {
    Basic_Type,
    Untyped_Type,
    Pointer_Type,
    Multi_Pointer_Type,
    Slice_Type,
    Array_Type,
    Enumerated_Array_Type,
    Dynamic_Array_Type,
    Map_Type,
    Bit_Set_Type,
    Bit_Field_Type,
    Matrix_Type,
    Simd_Type,
    Soa_Type,
    Struct_Type,
    Union_Type,
    Enum_Type,
    Proc_Type,
    Tuple_Type,
    Named_Type,
    Distinct_Type,
    Poly_Param_Type,
    Proc_Group_Type,
}

// The map hashes the bytes of a key, so it has no implicit padding.
@(private = "file")
Type_Key :: struct {
    n:    i64,
    m:    i64,
    a:    Type_Id,
    b:    Type_Id,
    kind: Type_Kind,
    flag: u8,
    pad:  [6]u8,
}

// The types of one analysis. Structural types are interned; a named or distinct type is unique by
// its symbol. Every slice and string a type holds is a copy in `allocator`. A failed allocation sets
// `err` and gives INVALID_TYPE.
Type_Table :: struct {
    allocator: mem.Allocator,
    types:     [dynamic]Type,
    interned:  map[Type_Key]Type_Id,
    named:     map[Symbol]Type_Id,
    distincts: map[Symbol]Type_Id,
    err:       mem.Allocator_Error,
}

@(private = "file")
FIRST_UNTYPED :: 1 + len(Basic_Kind)

type_table_init :: proc(t: ^Type_Table, allocator := context.allocator) -> mem.Allocator_Error {
    t^ = Type_Table {
        allocator = allocator,
        types     = make([dynamic]Type, 0, FIRST_UNTYPED + len(Untyped_Kind), allocator) or_return,
        interned  = make(map[Type_Key]Type_Id, allocator),
        named     = make(map[Symbol]Type_Id, allocator),
        distincts = make(map[Symbol]Type_Id, allocator),
    }
    append(&t.types, nil) or_return
    for kind in Basic_Kind {
        append(&t.types, Basic_Type{kind}) or_return
    }
    for kind in Untyped_Kind {
        append(&t.types, Untyped_Type{kind}) or_return
    }
    return nil
}

type_table_destroy :: proc(t: ^Type_Table) {
    for &entry in t.types {
        free_type(t, &entry)
    }
    delete(t.types)
    delete(t.interned)
    delete(t.named)
    delete(t.distincts)
    t^ = {}
}

@(private = "file")
free_type :: proc(t: ^Type_Table, entry: ^Type) {
    a := t.allocator
    #partial switch &v in entry {
    case Bit_Field_Type:
        for f in v.fields {
            delete(f.name, a)
        }
        delete(v.fields, a)
    case Struct_Type:
        for f in v.fields {
            delete(f.name, a)
            delete(f.tag, a)
        }
        delete(v.fields, a)
        free_params(v.params, a)
    case Union_Type:
        delete(v.variants, a)
        free_params(v.params, a)
    case Enum_Type:
        for m in v.members {
            delete(m.name, a)
        }
        delete(v.members, a)
    case Proc_Type:
        free_params(v.params, a)
        free_params(v.results, a)
        delete(v.convention, a)
    case Tuple_Type:
        delete(v.types, a)
    case Named_Type:
        delete(v.name, a)
        delete(v.qualifier, a)
    case Poly_Param_Type:
        delete(v.name, a)
    case Proc_Group_Type:
        delete(v.members, a)
    }
}

@(private = "file")
free_params :: proc(params: []Proc_Param, a: mem.Allocator) {
    for p in params {
        delete(p.name, a)
        delete(p.default, a)
    }
    delete(params, a)
}

@(private = "file")
note :: proc(t: ^Type_Table, err: mem.Allocator_Error) -> bool {
    if err != nil {
        if t.err == nil {
            t.err = err
        }
        return false
    }
    return true
}

@(private = "file")
push :: proc(t: ^Type_Table, entry: Type) -> Type_Id {
    if _, err := append(&t.types, entry); !note(t, err) {
        entry := entry
        free_type(t, &entry)
        return INVALID_TYPE
    }
    return Type_Id(len(t.types) - 1)
}

@(private = "file")
intern :: proc(t: ^Type_Table, key: Type_Key, entry: Type) -> Type_Id {
    if id, ok := t.interned[key]; ok {
        return id
    }
    id := push(t, entry)
    if id == INVALID_TYPE {
        return id
    }
    _, value, _, err := map_entry(&t.interned, key)
    if !note(t, err) {
        return INVALID_TYPE
    }
    value^ = id
    return id
}

@(private = "file")
clone_string :: proc(t: ^Type_Table, s: string) -> string {
    if s == "" {
        return ""
    }
    out, err := strings.clone(s, t.allocator)
    note(t, err)
    return out
}

@(private = "file")
clone_slice :: proc(t: ^Type_Table, s: []$E) -> []E {
    if len(s) == 0 {
        return nil
    }
    out, err := make([]E, len(s), t.allocator)
    if !note(t, err) {
        return nil
    }
    copy(out, s)
    return out
}

@(private = "file")
clone_params :: proc(t: ^Type_Table, params: []Proc_Param) -> []Proc_Param {
    out := clone_slice(t, params)
    for &p in out {
        p.name = clone_string(t, p.name)
        p.default = clone_string(t, p.default)
    }
    return out
}

// The entry of `id`; nil for INVALID_TYPE or an id the table does not hold.
type_get :: proc(t: ^Type_Table, id: Type_Id) -> Type {
    if int(id) >= len(t.types) {
        return nil
    }
    return t.types[id]
}

type_kind :: proc(t: ^Type_Table, id: Type_Id) -> Type_Kind {
    switch _ in type_get(t, id) {
    case Basic_Type:            return .Basic
    case Untyped_Type:          return .Untyped
    case Pointer_Type:          return .Pointer
    case Multi_Pointer_Type:    return .Multi_Pointer
    case Slice_Type:            return .Slice
    case Array_Type:            return .Array
    case Enumerated_Array_Type: return .Enumerated_Array
    case Dynamic_Array_Type:    return .Dynamic_Array
    case Map_Type:              return .Map
    case Bit_Set_Type:          return .Bit_Set
    case Bit_Field_Type:        return .Bit_Field
    case Matrix_Type:           return .Matrix
    case Simd_Type:             return .Simd
    case Soa_Type:              return .Soa
    case Struct_Type:           return .Struct
    case Union_Type:            return .Union
    case Enum_Type:             return .Enum
    case Proc_Type:             return .Proc
    case Tuple_Type:            return .Tuple
    case Named_Type:            return .Named
    case Distinct_Type:         return .Distinct
    case Poly_Param_Type:       return .Poly_Param
    case Proc_Group_Type:       return .Proc_Group
    }
    return .Invalid
}

type_basic :: proc(kind: Basic_Kind) -> Type_Id {
    return Type_Id(1 + int(kind))
}

type_untyped :: proc(kind: Untyped_Kind) -> Type_Id {
    return Type_Id(FIRST_UNTYPED + int(kind))
}

// The basic type spelled `name`.
basic_from_name :: proc(name: string) -> (kind: Basic_Kind, ok: bool) {
    for spelling, k in BASIC_NAMES {
        if spelling == name {
            return k, true
        }
    }
    return {}, false
}

type_pointer :: proc(t: ^Type_Table, elem: Type_Id) -> Type_Id {
    return intern(t, {kind = .Pointer, a = elem}, Pointer_Type{elem})
}

type_multi_pointer :: proc(t: ^Type_Table, elem: Type_Id) -> Type_Id {
    return intern(t, {kind = .Multi_Pointer, a = elem}, Multi_Pointer_Type{elem})
}

type_slice :: proc(t: ^Type_Table, elem: Type_Id) -> Type_Id {
    return intern(t, {kind = .Slice, a = elem}, Slice_Type{elem})
}

// `[len]elem`; `len` is -1 when not known.
type_array :: proc(t: ^Type_Table, len: i64, elem: Type_Id) -> Type_Id {
    return intern(t, {kind = .Array, a = elem, n = len}, Array_Type{len, elem})
}

type_enumerated_array :: proc(t: ^Type_Table, index, elem: Type_Id) -> Type_Id {
    return intern(t, {kind = .Enumerated_Array, a = index, b = elem}, Enumerated_Array_Type{index, elem})
}

type_dynamic_array :: proc(t: ^Type_Table, elem: Type_Id) -> Type_Id {
    return intern(t, {kind = .Dynamic_Array, a = elem}, Dynamic_Array_Type{elem})
}

type_map :: proc(t: ^Type_Table, key, value: Type_Id) -> Type_Id {
    return intern(t, {kind = .Map, a = key, b = value}, Map_Type{key, value})
}

// `bit_set[elem; backing]`; `backing` is INVALID_TYPE when none.
type_bit_set :: proc(t: ^Type_Table, elem: Type_Id, backing := INVALID_TYPE) -> Type_Id {
    return intern(t, {kind = .Bit_Set, a = elem, b = backing}, Bit_Set_Type{elem = elem, backing = backing})
}

// `bit_set[lo..=hi; backing]`; `elem` is the type of the bounds.
type_bit_set_range :: proc(t: ^Type_Table, elem: Type_Id, lo, hi: i64, backing := INVALID_TYPE) -> Type_Id {
    key := Type_Key{kind = .Bit_Set, flag = 1, a = elem, b = backing, n = lo, m = hi}
    return intern(t, key, Bit_Set_Type{elem = elem, backing = backing, range = true, lo = lo, hi = hi})
}

type_matrix :: proc(t: ^Type_Table, rows, cols: i64, elem: Type_Id, row_major := false) -> Type_Id {
    key := Type_Key{kind = .Matrix, flag = u8(row_major), a = elem, n = rows, m = cols}
    return intern(t, key, Matrix_Type{rows, cols, elem, row_major})
}

type_simd :: proc(t: ^Type_Table, len: i64, elem: Type_Id) -> Type_Id {
    return intern(t, {kind = .Simd, a = elem, n = len}, Simd_Type{len, elem})
}

// `#soa` of `kind`; `len` is read for Array only.
type_soa :: proc(t: ^Type_Table, kind: Soa_Kind, elem: Type_Id, len: i64 = -1) -> Type_Id {
    n := kind == .Array ? len : 0
    return intern(t, {kind = .Soa, flag = u8(kind), a = elem, n = n}, Soa_Type{kind, n, elem})
}

// A new struct type. Struct, union, enum, bit_field, proc and tuple types are not interned: two literals are two types.
type_struct :: proc(t: ^Type_Table, s: Struct_Type) -> Type_Id {
    s := s
    s.fields = clone_slice(t, s.fields)
    for &f in s.fields {
        f.name = clone_string(t, f.name)
        f.tag = clone_string(t, f.tag)
    }
    s.params = clone_params(t, s.params)
    return checked_push(t, s)
}

type_union :: proc(t: ^Type_Table, u: Union_Type) -> Type_Id {
    u := u
    u.variants = clone_slice(t, u.variants)
    u.params = clone_params(t, u.params)
    return checked_push(t, u)
}

type_enum :: proc(t: ^Type_Table, e: Enum_Type) -> Type_Id {
    e := e
    e.members = clone_slice(t, e.members)
    for &m in e.members {
        m.name = clone_string(t, m.name)
    }
    return checked_push(t, e)
}

type_bit_field :: proc(t: ^Type_Table, b: Bit_Field_Type) -> Type_Id {
    b := b
    b.fields = clone_slice(t, b.fields)
    for &f in b.fields {
        f.name = clone_string(t, f.name)
    }
    return checked_push(t, b)
}

type_proc :: proc(t: ^Type_Table, p: Proc_Type) -> Type_Id {
    p := p
    p.params = clone_params(t, p.params)
    p.results = clone_params(t, p.results)
    p.convention = clone_string(t, p.convention)
    return checked_push(t, p)
}

type_tuple :: proc(t: ^Type_Table, types: []Type_Id) -> Type_Id {
    return checked_push(t, Tuple_Type{clone_slice(t, types)})
}

type_proc_group :: proc(t: ^Type_Table, members: []Type_Id) -> Type_Id {
    return checked_push(t, Proc_Group_Type{clone_slice(t, members)})
}

type_poly_param :: proc(t: ^Type_Table, name: string, specialization := INVALID_TYPE) -> Type_Id {
    return checked_push(t, Poly_Param_Type{clone_string(t, name), specialization})
}

// Pushes `entry` when every copy it holds was made; frees it otherwise.
@(private = "file")
checked_push :: proc(t: ^Type_Table, entry: Type) -> Type_Id {
    if t.err != nil {
        entry := entry
        free_type(t, &entry)
        return INVALID_TYPE
    }
    return push(t, entry)
}

// The named type of `symbol`; made with no underlying type the first time.
type_named :: proc(t: ^Type_Table, symbol: Symbol, name: string, qualifier := "") -> Type_Id {
    if id, ok := t.named[symbol]; ok {
        return id
    }
    id := checked_push(t, Named_Type{symbol = symbol, name = clone_string(t, name), qualifier = clone_string(t, qualifier)})
    if id == INVALID_TYPE {
        return id
    }
    _, value, _, err := map_entry(&t.named, symbol)
    if !note(t, err) {
        return INVALID_TYPE
    }
    value^ = id
    return id
}

type_set_underlying :: proc(t: ^Type_Table, named, underlying: Type_Id) {
    if int(named) >= len(t.types) {
        return
    }
    if n, ok := &t.types[named].(Named_Type); ok {
        n.underlying = underlying
    }
}

// The distinct type of `symbol` over `base`; the first base given stays.
type_distinct :: proc(t: ^Type_Table, symbol: Symbol, base: Type_Id) -> Type_Id {
    if id, ok := t.distincts[symbol]; ok {
        return id
    }
    id := push(t, Distinct_Type{symbol, base})
    if id == INVALID_TYPE {
        return id
    }
    _, value, _, err := map_entry(&t.distincts, symbol)
    if !note(t, err) {
        return INVALID_TYPE
    }
    value^ = id
    return id
}

@(private = "file")
STRIP_LIMIT :: 64

// `id` with named types followed to their underlying type. A distinct type is kept.
type_underlying :: proc(t: ^Type_Table, id: Type_Id) -> Type_Id {
    id := id
    for _ in 0 ..< STRIP_LIMIT {
        n, ok := type_get(t, id).(Named_Type)
        if !ok {
            return id
        }
        id = n.underlying
    }
    return INVALID_TYPE
}

// `id` with named and distinct types followed to the type they are made from.
type_base :: proc(t: ^Type_Table, id: Type_Id) -> Type_Id {
    id := id
    for _ in 0 ..< STRIP_LIMIT {
        #partial switch v in type_get(t, id) {
        case Named_Type:
            id = v.underlying
        case Distinct_Type:
            id = v.base
        case:
            return id
        }
    }
    return INVALID_TYPE
}

type_is_integer :: proc(t: ^Type_Table, id: Type_Id) -> bool {
    #partial switch v in type_get(t, type_base(t, id)) {
    case Basic_Type:
        #partial switch v.kind {
        case .Int ..= .U128be, .Rune:
            return true
        }
    case Untyped_Type:
        return v.kind == .Int || v.kind == .Rune
    }
    return false
}

type_is_float :: proc(t: ^Type_Table, id: Type_Id) -> bool {
    #partial switch v in type_get(t, type_base(t, id)) {
    case Basic_Type:
        return v.kind >= .F16 && v.kind <= .F64be
    case Untyped_Type:
        return v.kind == .Float
    }
    return false
}

type_is_complex :: proc(t: ^Type_Table, id: Type_Id) -> bool {
    #partial switch v in type_get(t, type_base(t, id)) {
    case Basic_Type:
        return v.kind >= .Complex32 && v.kind <= .Complex128
    case Untyped_Type:
        return v.kind == .Complex
    }
    return false
}

type_is_quaternion :: proc(t: ^Type_Table, id: Type_Id) -> bool {
    #partial switch v in type_get(t, type_base(t, id)) {
    case Basic_Type:
        return v.kind >= .Quaternion64 && v.kind <= .Quaternion256
    case Untyped_Type:
        return v.kind == .Quaternion
    }
    return false
}

type_is_numeric :: proc(t: ^Type_Table, id: Type_Id) -> bool {
    return type_is_integer(t, id) || type_is_float(t, id) || type_is_complex(t, id) || type_is_quaternion(t, id)
}

type_is_string :: proc(t: ^Type_Table, id: Type_Id) -> bool {
    #partial switch v in type_get(t, type_base(t, id)) {
    case Basic_Type:
        #partial switch v.kind {
        case .String, .Cstring, .String16, .Cstring16:
            return true
        }
    case Untyped_Type:
        return v.kind == .String
    }
    return false
}

type_is_boolean :: proc(t: ^Type_Table, id: Type_Id) -> bool {
    #partial switch v in type_get(t, type_base(t, id)) {
    case Basic_Type:
        return v.kind >= .Bool && v.kind <= .B64
    case Untyped_Type:
        return v.kind == .Bool
    }
    return false
}

type_is_untyped :: proc(t: ^Type_Table, id: Type_Id) -> bool {
    _, ok := type_get(t, id).(Untyped_Type)
    return ok
}

// The type an untyped constant takes when nothing else gives one. `nil` and `---` keep theirs.
type_default :: proc(t: ^Type_Table, id: Type_Id) -> Type_Id {
    u, ok := type_get(t, id).(Untyped_Type)
    if !ok {
        return id
    }
    switch u.kind {
    case .Int:        return type_basic(.Int)
    case .Float:      return type_basic(.F64)
    case .Complex:    return type_basic(.Complex128)
    case .Quaternion: return type_basic(.Quaternion256)
    case .Rune:       return type_basic(.Rune)
    case .String:     return type_basic(.String)
    case .Bool:       return type_basic(.Bool)
    case .Nil, .Uninit:
    }
    return id
}

// The size of a basic type for `target`; 0 when not known.
basic_size :: proc(kind: Basic_Kind, target: Target) -> i64 {
    #partial switch kind {
    case .String, .String16:
        return 2 * type_size("rawptr", target)
    case .Cstring16:
        return type_size("rawptr", target)
    case .Any:
        if ptr := type_size("rawptr", target); ptr > 0 {
            return ptr + type_size("typeid", target)
        }
        return 0
    }
    return type_size(BASIC_NAMES[kind], target)
}

// The alignment of a basic type for `target`; 0 when not known.
basic_align :: proc(kind: Basic_Kind, target: Target) -> i64 {
    #partial switch kind {
    case .String, .String16, .Cstring16:
        return type_size("rawptr", target)
    case .Any:
        return max(type_size("rawptr", target), type_size("typeid", target))
    case .Complex32 ..= .Complex128:
        return basic_size(kind, target) / 2
    case .Quaternion64 ..= .Quaternion256:
        return basic_size(kind, target) / 4
    }
    return basic_size(kind, target)
}

@(private = "file")
STRING_MEMBERS_MAX :: 8

// `id` as Odin source: `^T`, `[]T`, `map[K]V`, `proc(a: int) -> bool`. A named type prints its name.
type_string :: proc(t: ^Type_Table, id: Type_Id, allocator := context.allocator) -> string {
    sb := strings.builder_make(allocator)
    write_type(&sb, t, id)
    return strings.to_string(sb)
}

@(private = "file")
write_type :: proc(sb: ^strings.Builder, t: ^Type_Table, id: Type_Id) {
    switch v in type_get(t, id) {
    case nil:
        strings.write_string(sb, "invalid")
    case Basic_Type:
        strings.write_string(sb, BASIC_NAMES[v.kind])
    case Untyped_Type:
        strings.write_string(sb, UNTYPED_NAMES[v.kind])
    case Pointer_Type:
        strings.write_byte(sb, '^')
        write_type(sb, t, v.elem)
    case Multi_Pointer_Type:
        strings.write_string(sb, "[^]")
        write_type(sb, t, v.elem)
    case Slice_Type:
        strings.write_string(sb, "[]")
        write_type(sb, t, v.elem)
    case Array_Type:
        write_len(sb, "[", v.len, "]")
        write_type(sb, t, v.elem)
    case Enumerated_Array_Type:
        strings.write_byte(sb, '[')
        write_type(sb, t, v.index)
        strings.write_byte(sb, ']')
        write_type(sb, t, v.elem)
    case Dynamic_Array_Type:
        strings.write_string(sb, "[dynamic]")
        write_type(sb, t, v.elem)
    case Map_Type:
        strings.write_string(sb, "map[")
        write_type(sb, t, v.key)
        strings.write_byte(sb, ']')
        write_type(sb, t, v.value)
    case Bit_Set_Type:
        strings.write_string(sb, "bit_set[")
        if v.range {
            write_bound(sb, t, v.elem, v.lo)
            strings.write_string(sb, "..=")
            write_bound(sb, t, v.elem, v.hi)
        } else {
            write_type(sb, t, v.elem)
        }
        if v.backing != INVALID_TYPE {
            strings.write_string(sb, "; ")
            write_type(sb, t, v.backing)
        }
        strings.write_byte(sb, ']')
    case Bit_Field_Type:
        strings.write_string(sb, "bit_field ")
        write_type(sb, t, v.backing)
        strings.write_string(sb, " {")
        for f, i in v.fields {
            if !write_separator(sb, i) {
                break
            }
            strings.write_string(sb, f.name)
            strings.write_string(sb, ": ")
            write_type(sb, t, f.type)
            if f.bits >= 0 {
                strings.write_string(sb, " | ")
                strings.write_i64(sb, f.bits)
            }
        }
        strings.write_byte(sb, '}')
    case Matrix_Type:
        if v.row_major {
            strings.write_string(sb, "#row_major ")
        }
        write_len(sb, "matrix[", v.rows, ", ")
        write_len(sb, "", v.cols, "]")
        write_type(sb, t, v.elem)
    case Simd_Type:
        write_len(sb, "#simd[", v.len, "]")
        write_type(sb, t, v.elem)
    case Soa_Type:
        switch v.kind {
        case .Array:   write_len(sb, "#soa[", v.len, "]")
        case .Slice:   strings.write_string(sb, "#soa[]")
        case .Dynamic: strings.write_string(sb, "#soa[dynamic]")
        }
        write_type(sb, t, v.elem)
    case Struct_Type:
        strings.write_string(sb, "struct")
        write_poly_params(sb, t, v.params)
        if .Packed in v.flags {
            strings.write_string(sb, " #packed")
        }
        if .Raw_Union in v.flags {
            strings.write_string(sb, " #raw_union")
        }
        if .No_Copy in v.flags {
            strings.write_string(sb, " #no_copy")
        }
        if v.align > 0 {
            write_len(sb, " #align(", v.align, ")")
        }
        strings.write_string(sb, " {")
        for f, i in v.fields {
            if !write_separator(sb, i) {
                break
            }
            if f.is_using {
                strings.write_string(sb, "using ")
            }
            strings.write_string(sb, f.name)
            strings.write_string(sb, ": ")
            write_type(sb, t, f.type)
        }
        strings.write_byte(sb, '}')
    case Union_Type:
        strings.write_string(sb, "union")
        write_poly_params(sb, t, v.params)
        if .No_Nil in v.flags {
            strings.write_string(sb, " #no_nil")
        }
        if .Shared_Nil in v.flags {
            strings.write_string(sb, " #shared_nil")
        }
        if v.align > 0 {
            write_len(sb, " #align(", v.align, ")")
        }
        strings.write_string(sb, " {")
        for variant, i in v.variants {
            if !write_separator(sb, i) {
                break
            }
            write_type(sb, t, variant)
        }
        strings.write_byte(sb, '}')
    case Enum_Type:
        strings.write_string(sb, "enum ")
        if v.backing != INVALID_TYPE {
            write_type(sb, t, v.backing)
            strings.write_byte(sb, ' ')
        }
        strings.write_byte(sb, '{')
        for m, i in v.members {
            if !write_separator(sb, i) {
                break
            }
            strings.write_string(sb, m.name)
        }
        strings.write_byte(sb, '}')
    case Proc_Type:
        write_proc(sb, t, v)
    case Tuple_Type:
        strings.write_byte(sb, '(')
        for elem, i in v.types {
            if i > 0 {
                strings.write_string(sb, ", ")
            }
            write_type(sb, t, elem)
        }
        strings.write_byte(sb, ')')
    case Named_Type:
        if v.qualifier != "" {
            strings.write_string(sb, v.qualifier)
            strings.write_byte(sb, '.')
        }
        strings.write_string(sb, v.name)
    case Distinct_Type:
        strings.write_string(sb, "distinct ")
        write_type(sb, t, v.base)
    case Poly_Param_Type:
        strings.write_byte(sb, '$')
        strings.write_string(sb, v.name)
        if v.specialization != INVALID_TYPE {
            strings.write_byte(sb, '/')
            write_type(sb, t, v.specialization)
        }
    case Proc_Group_Type:
        strings.write_string(sb, "proc{")
        for m, i in v.members {
            if !write_separator(sb, i) {
                break
            }
            write_type(sb, t, m)
        }
        strings.write_byte(sb, '}')
    }
}

// Writes ", " before member `i`, or ", ..." once the members are too many. False when it stops.
@(private = "file")
write_separator :: proc(sb: ^strings.Builder, i: int) -> bool {
    if i >= STRING_MEMBERS_MAX {
        strings.write_string(sb, ", ...")
        return false
    }
    if i > 0 {
        strings.write_string(sb, ", ")
    }
    return true
}

// Writes `open`, the length or `?` when it is not known, and `close`.
@(private = "file")
write_len :: proc(sb: ^strings.Builder, open: string, n: i64, close: string) {
    strings.write_string(sb, open)
    if n < 0 {
        strings.write_byte(sb, '?')
    } else {
        strings.write_i64(sb, n)
    }
    strings.write_string(sb, close)
}

// Writes a bit_set bound: a quoted character when the bounds are runes.
@(private = "file")
write_bound :: proc(sb: ^strings.Builder, t: ^Type_Table, elem: Type_Id, n: i64) {
    is_rune := false
    #partial switch v in type_get(t, type_base(t, elem)) {
    case Basic_Type:
        is_rune = v.kind == .Rune
    case Untyped_Type:
        is_rune = v.kind == .Rune
    }
    if is_rune && n >= 0x20 && n < 0x7f && n != '\'' && n != '\\' {
        strings.write_byte(sb, '\'')
        strings.write_byte(sb, u8(n))
        strings.write_byte(sb, '\'')
        return
    }
    strings.write_i64(sb, n)
}

@(private = "file")
write_poly_params :: proc(sb: ^strings.Builder, t: ^Type_Table, params: []Proc_Param) {
    if len(params) == 0 {
        return
    }
    strings.write_byte(sb, '(')
    write_params(sb, t, params)
    strings.write_byte(sb, ')')
}

@(private = "file")
write_params :: proc(sb: ^strings.Builder, t: ^Type_Table, params: []Proc_Param) {
    for p, i in params {
        if i > 0 {
            strings.write_string(sb, ", ")
        }
        if .Using in p.flags {
            strings.write_string(sb, "using ")
        }
        if .Any_Int in p.flags {
            strings.write_string(sb, "#any_int ")
        }
        if .C_Vararg in p.flags {
            strings.write_string(sb, "#c_vararg ")
        }
        if .By_Ptr in p.flags {
            strings.write_string(sb, "#by_ptr ")
        }
        if .No_Alias in p.flags {
            strings.write_string(sb, "#no_alias ")
        }
        if .Const in p.flags {
            strings.write_string(sb, "#const ")
        }
        if p.name != "" {
            strings.write_string(sb, p.name)
            if p.inferred && p.has_default {
                strings.write_string(sb, " := ")
                strings.write_string(sb, p.default)
                continue
            }
            strings.write_string(sb, ": ")
        }
        if .Variadic in p.flags {
            strings.write_string(sb, "..")
        }
        write_type(sb, t, p.type)
        if p.has_default {
            strings.write_string(sb, " = ")
            strings.write_string(sb, p.default)
        }
    }
}

@(private = "file")
write_proc :: proc(sb: ^strings.Builder, t: ^Type_Table, p: Proc_Type) {
    strings.write_string(sb, "proc")
    if p.convention != "" {
        strings.write_string(sb, " \"")
        strings.write_string(sb, p.convention)
        strings.write_string(sb, "\" ")
    }
    strings.write_byte(sb, '(')
    write_params(sb, t, p.params)
    strings.write_byte(sb, ')')
    if p.diverging {
        strings.write_string(sb, " -> !")
        return
    }
    if len(p.results) == 0 {
        return
    }
    strings.write_string(sb, " -> ")
    if len(p.results) == 1 && p.results[0].name == "" {
        write_type(sb, t, p.results[0].type)
        return
    }
    strings.write_byte(sb, '(')
    write_params(sb, t, p.results)
    strings.write_byte(sb, ')')
}
