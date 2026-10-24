package odinsema

import "core:testing"

@(private = "file")
expect_string :: proc(t: ^testing.T, table: ^Type_Table, id: Type_Id, want: string, loc := #caller_location) {
    got := type_string(table, id)
    defer delete(got)
    testing.expect_value(t, got, want, loc = loc)
}

@(test)
test_types_interning :: proc(t: ^testing.T) {
    table: Type_Table
    testing.expect_value(t, type_table_init(&table), nil)
    defer type_table_destroy(&table)

    int_t, i32_t := type_basic(.Int), type_basic(.I32)
    a := type_slice(&table, int_t)
    testing.expect_value(t, type_slice(&table, int_t), a)
    testing.expect(t, type_slice(&table, i32_t) != a)
    testing.expect_value(t, type_pointer(&table, a), type_pointer(&table, type_slice(&table, int_t)))
    testing.expect(t, type_array(&table, 4, int_t) != type_array(&table, 5, int_t))
    testing.expect_value(t, type_map(&table, int_t, a), type_map(&table, int_t, a))
    testing.expect(t, type_map(&table, int_t, a) != type_map(&table, a, int_t))
    testing.expect(t, type_soa(&table, .Slice, int_t) != type_slice(&table, int_t))
    testing.expect(t, type_bit_set_range(&table, int_t, 0, 7) != type_bit_set(&table, int_t))
    testing.expect(t, type_matrix(&table, 2, 3, int_t) != type_matrix(&table, 2, 3, int_t, true))

    s1 := type_struct(&table, Struct_Type{fields = {{name = "x", type = int_t, name_offset = -1}}})
    s2 := type_struct(&table, Struct_Type{fields = {{name = "x", type = int_t, name_offset = -1}}})
    testing.expect(t, s1 != s2)
    testing.expect_value(t, type_kind(&table, s1), Type_Kind.Struct)
    testing.expect_value(t, type_kind(&table, INVALID_TYPE), Type_Kind.Invalid)
    testing.expect_value(t, type_kind(&table, type_untyped(.Nil)), Type_Kind.Untyped)
    testing.expect_value(t, table.err, nil)
}

@(test)
test_types_named_and_recursive :: proc(t: ^testing.T) {
    table: Type_Table
    testing.expect_value(t, type_table_init(&table), nil)
    defer type_table_destroy(&table)

    sym := Symbol{file = 1, item = 3, child = -1}
    node := type_named(&table, sym, "Node")
    testing.expect_value(t, type_named(&table, sym, "Node"), node)
    other := type_named(&table, Symbol{file = 1, item = 4, child = -1}, "Node")
    testing.expect(t, other != node)

    body := type_struct(&table, Struct_Type{fields = {{name = "next", type = type_pointer(&table, node), name_offset = 10}, {name = "value", type = type_basic(.Int), name_offset = 20}}})
    type_set_underlying(&table, node, body)
    testing.expect_value(t, type_underlying(&table, node), body)
    testing.expect_value(t, type_base(&table, node), body)
    expect_string(t, &table, node, "Node")
    expect_string(t, &table, body, "struct {next: ^Node, value: int}")

    s, ok := type_get(&table, type_underlying(&table, node)).(Struct_Type)
    if testing.expect(t, ok) {
        p, pok := type_get(&table, s.fields[0].type).(Pointer_Type)
        testing.expect(t, pok && p.elem == node)
    }

    id_sym := Symbol{file = 2, item = 0, child = -1}
    id := type_named(&table, id_sym, "Id", "pkg")
    dist := type_distinct(&table, id_sym, type_basic(.Int))
    testing.expect_value(t, type_distinct(&table, id_sym, type_basic(.Int)), dist)
    type_set_underlying(&table, id, dist)
    testing.expect_value(t, type_underlying(&table, id), dist)
    testing.expect_value(t, type_base(&table, id), type_basic(.Int))
    testing.expect(t, type_is_integer(&table, id))
    expect_string(t, &table, id, "pkg.Id")
    expect_string(t, &table, dist, "distinct int")

    loop_sym := Symbol{file = 3, item = 0, child = -1}
    loop := type_named(&table, loop_sym, "Loop")
    type_set_underlying(&table, loop, loop)
    testing.expect_value(t, type_underlying(&table, loop), INVALID_TYPE)
}

@(test)
test_types_printing :: proc(t: ^testing.T) {
    table: Type_Table
    testing.expect_value(t, type_table_init(&table), nil)
    defer type_table_destroy(&table)

    int_t, f32_t, u8_t := type_basic(.Int), type_basic(.F32), type_basic(.U8)
    color := type_named(&table, Symbol{file = 0, item = 0, child = -1}, "Color")
    type_set_underlying(&table, color, type_enum(&table, Enum_Type{backing = u8_t, members = {{"Red", 0, 1}, {"Green", 2, 5}}}))

    expect_string(t, &table, int_t, "int")
    expect_string(t, &table, type_basic(.U128be), "u128be")
    expect_string(t, &table, type_untyped(.Int), "untyped int")
    expect_string(t, &table, type_pointer(&table, int_t), "^int")
    expect_string(t, &table, type_multi_pointer(&table, int_t), "[^]int")
    expect_string(t, &table, type_slice(&table, int_t), "[]int")
    expect_string(t, &table, type_array(&table, 4, int_t), "[4]int")
    expect_string(t, &table, type_array(&table, -1, int_t), "[?]int")
    expect_string(t, &table, type_enumerated_array(&table, color, f32_t), "[Color]f32")
    expect_string(t, &table, type_dynamic_array(&table, int_t), "[dynamic]int")
    expect_string(t, &table, type_map(&table, type_basic(.String), int_t), "map[string]int")
    expect_string(t, &table, type_bit_set(&table, color, u8_t), "bit_set[Color; u8]")
    expect_string(t, &table, type_bit_set(&table, color), "bit_set[Color]")
    expect_string(t, &table, type_bit_set_range(&table, type_untyped(.Int), 0, 7), "bit_set[0..=7]")
    expect_string(t, &table, type_bit_set_range(&table, type_basic(.Rune), 'a', 'z'), "bit_set['a'..='z']")
    expect_string(t, &table, type_matrix(&table, 2, 3, f32_t), "matrix[2, 3]f32")
    expect_string(t, &table, type_matrix(&table, 4, 4, f32_t, true), "#row_major matrix[4, 4]f32")
    expect_string(t, &table, type_simd(&table, 4, f32_t), "#simd[4]f32")
    expect_string(t, &table, type_soa(&table, .Slice, color), "#soa[]Color")
    expect_string(t, &table, type_soa(&table, .Array, color, 8), "#soa[8]Color")
    expect_string(t, &table, type_soa(&table, .Dynamic, color), "#soa[dynamic]Color")
    expect_string(t, &table, type_underlying(&table, color), "enum u8 {Red, Green}")
    expect_string(t, &table, type_tuple(&table, {int_t, type_basic(.Bool)}), "(int, bool)")
    expect_string(t, &table, INVALID_TYPE, "invalid")

    expect_string(t, &table, type_union(&table, Union_Type{variants = {int_t, f32_t}, flags = {.No_Nil}}), "union #no_nil {int, f32}")
    expect_string(t, &table, type_struct(&table, Struct_Type{
        fields = {{name = "base", type = color, is_using = true, name_offset = 0}, {name = "w", type = f32_t, tag = "`json:\"w\"`", name_offset = 9}},
        flags  = {.Packed},
    }), "struct #packed {using base: Color, w: f32}")
    many := make([]Struct_Field, 10)
    defer delete(many)
    for &f in many {
        f = {name = "f", type = u8_t}
    }
    expect_string(t, &table, type_struct(&table, Struct_Type{fields = many}), "struct {f: u8, f: u8, f: u8, f: u8, f: u8, f: u8, f: u8, f: u8, ...}")
    expect_string(t, &table, type_bit_field(&table, Bit_Field_Type{backing = type_basic(.U16), fields = {{"low", u8_t, 4, 0}}}), "bit_field u16 {low: u8 | 4}")

    add := type_proc(&table, Proc_Type{
        params  = {{name = "a", type = int_t, name_offset = 0}, {name = "b", type = int_t, default = "2", has_default = true, inferred = true, name_offset = 3}},
        results = {{type = int_t, name_offset = -1}, {type = type_basic(.Bool), name_offset = -1}},
    })
    expect_string(t, &table, add, "proc(a: int, b := 2) -> (int, bool)")
    expect_string(t, &table, type_proc(&table, Proc_Type{
        params     = {{name = "args", type = type_basic(.Any), flags = {.C_Vararg, .Variadic}, name_offset = 0}},
        results    = {{type = int_t, name_offset = -1}},
        convention = "c",
    }), "proc \"c\" (#c_vararg args: ..any) -> int")
    expect_string(t, &table, type_proc(&table, Proc_Type{diverging = true}), "proc() -> !")
    expect_string(t, &table, type_proc(&table, Proc_Type{results = {{name = "ok", type = type_basic(.Bool), name_offset = 0}}}), "proc() -> (ok: bool)")
    expect_string(t, &table, type_proc(&table, Proc_Type{params = {{name = "n", type = int_t, default = "1", has_default = true}}}), "proc(n: int = 1)")
    expect_string(t, &table, type_proc_group(&table, {add, type_proc(&table, Proc_Type{})}), "proc{proc(a: int, b := 2) -> (int, bool), proc()}")

    poly := type_poly_param(&table, "T", type_slice(&table, int_t))
    expect_string(t, &table, poly, "$T/[]int")
    expect_string(t, &table, type_struct(&table, Struct_Type{params = {{name = "T", type = type_basic(.Typeid), flags = {.Const}}}, fields = {{name = "items", type = type_slice(&table, poly)}}}), "struct(#const T: typeid) {items: []$T/[]int}")
    testing.expect_value(t, table.err, nil)
}

@(test)
test_types_predicates_and_defaults :: proc(t: ^testing.T) {
    table: Type_Table
    testing.expect_value(t, type_table_init(&table), nil)
    defer type_table_destroy(&table)

    testing.expect_value(t, type_default(&table, type_untyped(.Int)), type_basic(.Int))
    testing.expect_value(t, type_default(&table, type_untyped(.Float)), type_basic(.F64))
    testing.expect_value(t, type_default(&table, type_untyped(.Rune)), type_basic(.Rune))
    testing.expect_value(t, type_default(&table, type_untyped(.String)), type_basic(.String))
    testing.expect_value(t, type_default(&table, type_untyped(.Bool)), type_basic(.Bool))
    testing.expect_value(t, type_default(&table, type_untyped(.Nil)), type_untyped(.Nil))
    testing.expect_value(t, type_default(&table, type_basic(.U8)), type_basic(.U8))

    testing.expect(t, type_is_integer(&table, type_basic(.U64be)))
    testing.expect(t, type_is_integer(&table, type_untyped(.Rune)))
    testing.expect(t, !type_is_integer(&table, type_basic(.F32)))
    testing.expect(t, type_is_float(&table, type_basic(.F16le)))
    testing.expect(t, type_is_numeric(&table, type_basic(.Complex64)))
    testing.expect(t, type_is_numeric(&table, type_untyped(.Float)))
    testing.expect(t, !type_is_numeric(&table, type_basic(.String)))
    testing.expect(t, type_is_string(&table, type_basic(.Cstring)))
    testing.expect(t, type_is_boolean(&table, type_basic(.B32)))
    testing.expect(t, type_is_untyped(&table, type_untyped(.Bool)))

    kind, ok := basic_from_name("quaternion128")
    testing.expect(t, ok && kind == .Quaternion128)
    _, ok = basic_from_name("Int")
    testing.expect(t, !ok)

    amd64 := Target{os = .Windows, arch = .amd64}
    testing.expect_value(t, basic_size(.Int, amd64), 8)
    testing.expect_value(t, basic_size(.String, amd64), 16)
    testing.expect_value(t, basic_size(.Any, amd64), 16)
    testing.expect_value(t, basic_size(.U16, amd64), 2)
    testing.expect_value(t, basic_align(.Complex128, amd64), 8)
    testing.expect_value(t, basic_size(.Int, Target{arch = .i386}), 4)
    testing.expect_value(t, basic_size(.Int, Target{}), 0)
}
