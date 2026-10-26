package odinsema

// The size and the alignment of a type in bytes.
Layout :: struct {
    size:  i64,
    align: i64,
}

@(private = "file")
LAYOUT_DEPTH_MAX :: 64

// The greatest alignment of a basic type for `target`; 0 when not known.
max_align :: proc(target: Target) -> i64 {
    switch target.arch {
    case .amd64, .i386, .arm64, .riscv64:
        return 16
    case .arm32, .wasm32, .wasm64p32:
        return 8
    case .Unknown:
    }
    return 0
}

// The greatest alignment of a `#simd` vector for `target`; 0 when there is no limit.
@(private = "file")
max_simd_align :: proc(target: Target) -> i64 {
    #partial switch target.arch {
    case .arm64:
        return 16
    case .arm32:
        return 8
    }
    return 0
}

// `n` rounded up to a multiple of `align`.
@(private = "file")
align_up :: proc(n, align: i64) -> i64 {
    if align <= 1 {
        return n
    }
    return (n + align - 1) / align * align
}

// The layout of fields placed one after the other with natural padding; false when one is not known.
@(private = "file")
layout_seq :: proc(fields: ..Layout) -> (l: Layout, ok: bool) {
    end, align := i64(0), i64(1)
    for f in fields {
        if f.align <= 0 {
            return {}, false
        }
        end = align_up(end, f.align) + f.size
        align = max(align, f.align)
    }
    return {align_up(end, align), align}, true
}

// The layout of a basic type for `target`; false when not known.
basic_layout :: proc(kind: Basic_Kind, target: Target) -> (Layout, bool) {
    ptr := type_size("rawptr", target)
    word := type_size("int", target)
    if ptr <= 0 || word <= 0 {
        return {}, false
    }
    #partial switch kind {
    case .String, .String16:
        return layout_seq({ptr, ptr}, {word, word})
    case .Cstring, .Cstring16, .Rawptr:
        return {ptr, ptr}, true
    case .Any:
        return layout_seq({ptr, ptr}, {8, min(8, max_align(target))})
    case .Complex32 ..= .Complex128:
        size := type_size(BASIC_NAMES[kind], target)
        return {size, size / 2}, true
    case .Quaternion64 ..= .Quaternion256:
        size := type_size(BASIC_NAMES[kind], target)
        return {size, size / 4}, true
    }
    size := type_size(BASIC_NAMES[kind], target)
    if size <= 0 {
        return {}, false
    }
    return {size, min(size, max_align(target))}, true
}

// The layout of `t` for the target of the snapshot; false when not known. A type that holds itself
// by value has no layout.
layout_of :: proc(c: ^Checker, t: Type_Id) -> (Layout, bool) {
    base := type_base(&c.table, t)
    if base == INVALID_TYPE {
        return {}, false
    }
    if l, ok := c.layouts[base]; ok {
        return l, true
    }
    if base in c.laying_out || len(c.laying_out) >= LAYOUT_DEPTH_MAX {
        return {}, false
    }
    if _, _, _, err := map_entry(&c.laying_out, base); !note_alloc(c, err) {
        return {}, false
    }
    l, ok := layout_uncached(c, base)
    delete_key(&c.laying_out, base)
    if !ok {
        return {}, false
    }
    _, entry, _, err := map_entry(&c.layouts, base)
    if !note_alloc(c, err) {
        return {}, false
    }
    entry^ = l
    return l, true
}

@(private = "file")
layout_uncached :: proc(c: ^Checker, base: Type_Id) -> (l: Layout, ok: bool) {
    target := c.snap.target
    ptr := type_size("rawptr", target)
    word := type_size("int", target)
    if ptr <= 0 || word <= 0 {
        return {}, false
    }
    allocator := Layout{2 * ptr, ptr}
    #partial switch v in type_get(&c.table, base) {
    case Basic_Type:
        return basic_layout(v.kind, target)
    case Pointer_Type, Multi_Pointer_Type, Proc_Type:
        return {ptr, ptr}, true
    case Slice_Type:
        return layout_seq({ptr, ptr}, {word, word})
    case Dynamic_Array_Type:
        return layout_seq({ptr, ptr}, {word, word}, {word, word}, allocator)
    case Map_Type:
        return layout_seq({ptr, ptr}, {ptr, ptr}, allocator)
    case Array_Type:
        elem := layout_of(c, v.elem) or_return
        if v.len < 0 {
            return {}, false
        }
        return {v.len * elem.size, elem.align}, true
    case Enumerated_Array_Type:
        lo, hi := enum_range(c, v.index) or_return
        elem := layout_of(c, v.elem) or_return
        return {(hi - lo + 1) * elem.size, elem.align}, true
    case Enum_Type:
        if v.backing == INVALID_TYPE {
            return {word, word}, true
        }
        return layout_of(c, v.backing)
    case Bit_Set_Type:
        return bit_set_layout(c, v)
    case Bit_Field_Type:
        return layout_of(c, v.backing)
    case Matrix_Type:
        elem := layout_of(c, v.elem) or_return
        if v.rows < 0 || v.cols < 0 {
            return {}, false
        }
        return {v.rows * v.cols * elem.size, elem.align}, true
    case Simd_Type:
        elem := layout_of(c, v.elem) or_return
        if v.len < 0 {
            return {}, false
        }
        size := v.len * elem.size
        align := max(size, 1)
        if limit := max_simd_align(target); limit > 0 {
            align = min(align, limit)
        }
        return {size, align}, true
    case Soa_Type:
        return soa_layout(c, v, word, allocator)
    case Struct_Type:
        return struct_layout(c, v, nil)
    case Union_Type:
        return union_layout(c, v)
    case Tuple_Type:
        temp := scratch_begin(c)
        defer scratch_end(temp)
        fields := make([]Layout, len(v.types), c.tmp)
        for e, i in v.types {
            fields[i] = layout_of(c, e) or_return
        }
        return layout_seq(..fields)
    }
    return {}, false
}

// The least and the greatest member value of enum `t`; false when `t` is not an enum or has no member.
@(private = "file")
enum_range :: proc(c: ^Checker, t: Type_Id) -> (lo, hi: i64, ok: bool) {
    e, is_enum := type_get(&c.table, type_base(&c.table, t)).(Enum_Type)
    if !is_enum || len(e.members) == 0 {
        return 0, 0, false
    }
    lo, hi = e.members[0].value, e.members[0].value
    for m in e.members[1:] {
        lo = min(lo, m.value)
        hi = max(hi, m.value)
    }
    return lo, hi, true
}

// A bit_set has the size of its backing type, else of the smallest unsigned integer that holds one bit per value.
@(private = "file")
bit_set_layout :: proc(c: ^Checker, b: Bit_Set_Type) -> (l: Layout, ok: bool) {
    if b.backing != INVALID_TYPE {
        return layout_of(c, b.backing)
    }
    lo, hi := b.lo, b.hi
    if !b.range {
        e, is_enum := type_get(&c.table, type_base(&c.table, b.elem)).(Enum_Type)
        if !is_enum {
            return {}, false
        }
        lo, hi = 0, 0
        if len(e.members) > 0 {
            lo, hi, _ = enum_range(c, b.elem)
        }
    }
    bits := hi - lo + 1
    switch {
    case bits <= 0:   return {}, false
    case bits <= 8:   return {1, 1}, true
    case bits <= 16:  return {2, 2}, true
    case bits <= 32:  return {4, 4}, true
    case bits <= 64:  return {8, 8}, true
    case bits <= 128: return {16, 16}, true
    }
    return {}, false
}

// A `#soa` type is a struct with one field per field of its element: an array of it, or a pointer
// to it followed by `len`, then `cap` and `allocator` for `#soa[dynamic]`.
@(private = "file")
soa_layout :: proc(c: ^Checker, s: Soa_Type, word: i64, allocator: Layout) -> (layout: Layout, ok: bool) {
    st, is_struct := type_get(&c.table, type_base(&c.table, s.elem)).(Struct_Type)
    if !is_struct {
        return {}, false
    }
    ptr := type_size("rawptr", c.snap.target)
    temp := scratch_begin(c)
    defer scratch_end(temp)
    fields := make([dynamic]Layout, 0, len(st.fields) + 4, c.tmp)
    for f in st.fields {
        l := layout_of(c, f.type) or_return
        switch s.kind {
        case .Array:
            if s.len < 0 {
                return {}, false
            }
            l.size *= s.len
        case .Slice, .Dynamic:
            l = {ptr, ptr}
        }
        if _, err := append(&fields, l); !note_alloc(c, err) {
            return {}, false
        }
    }
    switch s.kind {
    case .Array:
    case .Slice:
        if _, err := append(&fields, Layout{word, word}); !note_alloc(c, err) {
            return {}, false
        }
    case .Dynamic:
        if _, err := append(&fields, Layout{word, word}, Layout{word, word}, allocator); !note_alloc(c, err) {
            return {}, false
        }
    }
    return layout_seq(..fields[:])
}

// The layout of a struct; false for a polymorphic one. `offsets`, when not nil, gets the offset
// of each field and must have one slot per field.
@(private = "file")
struct_layout :: proc(c: ^Checker, s: Struct_Type, offsets: []i64) -> (layout: Layout, ok: bool) {
    if len(s.params) > 0 {
        return {}, false
    }
    end, align := i64(0), i64(1)
    for f, i in s.fields {
        l := layout_of(c, f.type) or_return
        field_align := l.align
        if .Packed in s.flags {
            field_align = 1
        } else {
            if s.min_field_align > 0 {
                field_align = max(field_align, s.min_field_align)
            }
            if s.max_field_align > 0 {
                field_align = min(field_align, s.max_field_align)
            }
        }
        align = max(align, field_align)
        offset := i64(0)
        if .Raw_Union in s.flags {
            end = max(end, l.size)
        } else {
            offset = align_up(end, field_align)
            end = offset + l.size
        }
        if offsets != nil {
            offsets[i] = offset
        }
    }
    if s.align > 0 {
        align = s.align
    }
    return {align_up(end, align), align}, true
}

// True for a type the nil value of a pointer can stand for: a pointer, a procedure, rawptr or cstring.
@(private = "file")
pointer_like :: proc(c: ^Checker, t: Type_Id) -> bool {
    #partial switch v in type_get(&c.table, type_base(&c.table, t)) {
    case Pointer_Type, Multi_Pointer_Type, Proc_Type:
        return true
    case Basic_Type:
        return v.kind == .Rawptr || v.kind == .Cstring || v.kind == .Cstring16
    }
    return false
}

// A union holds its largest variant, then a tag. A union of one pointer-like variant has no tag;
// a polymorphic one has no layout.
@(private = "file")
union_layout :: proc(c: ^Checker, u: Union_Type) -> (layout: Layout, ok: bool) {
    if len(u.params) > 0 {
        return {}, false
    }
    if len(u.variants) == 0 {
        return {0, u.align > 0 ? u.align : 1}, true
    }
    size, align := i64(0), i64(1)
    for v in u.variants {
        l := layout_of(c, v) or_return
        size = max(size, l.size)
        align = max(align, l.align)
    }
    if len(u.variants) == 1 && pointer_like(c, u.variants[0]) {
        return {size, u.align > 0 ? u.align : align}, true
    }
    count_bytes := i64(1)
    switch {
    case len(u.variants) >= 1 << 16: count_bytes = 4
    case len(u.variants) >= 1 << 8:  count_bytes = 2
    }
    tag := min(max(count_bytes, align), 8)
    if u.align > 0 {
        tag = max(count_bytes, min(tag, u.align))
        align = u.align
    }
    return {align_up(align_up(size, tag) + tag, align), align}, true
}

// The byte offset of field `index` of struct `t`; false when the layout is not known.
field_offset :: proc(c: ^Checker, t: Type_Id, index: int) -> (offset: i64, ok: bool) {
    s, is_struct := type_get(&c.table, type_base(&c.table, t)).(Struct_Type)
    if !is_struct || index < 0 || index >= len(s.fields) {
        return 0, false
    }
    layout_of(c, t) or_return
    temp := scratch_begin(c)
    defer scratch_end(temp)
    offsets, err := make([]i64, len(s.fields), c.tmp)
    if !note_alloc(c, err) {
        return 0, false
    }
    struct_layout(c, s, offsets) or_return
    return offsets[index], true
}

// The byte offset of the field `name` of struct `t`, also of a field a `using` field brings in.
field_offset_by_name :: proc(c: ^Checker, t: Type_Id, name: string) -> (i64, bool) {
    return field_offset_depth(c, t, name, 0)
}

@(private = "file")
field_offset_depth :: proc(c: ^Checker, t: Type_Id, name: string, depth: int) -> (offset: i64, ok: bool) {
    s, is_struct := type_get(&c.table, type_base(&c.table, t)).(Struct_Type)
    if !is_struct || depth >= LAYOUT_DEPTH_MAX {
        return 0, false
    }
    for f, i in s.fields {
        if f.name == name {
            return field_offset(c, t, i)
        }
    }
    for f, i in s.fields {
        if !f.is_using {
            continue
        }
        if _, is_inner := type_get(&c.table, type_base(&c.table, f.type)).(Struct_Type); !is_inner {
            continue
        }
        if inner, found := field_offset_depth(c, f.type, name, depth + 1); found {
            outer := field_offset(c, t, i) or_return
            return outer + inner, true
        }
    }
    return 0, false
}
