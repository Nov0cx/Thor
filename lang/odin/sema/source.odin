package odinsema

import "core:strings"

// `id` as source that names the type in `file`: a named type of the package of `file` bare, one of
// another package behind the alias `file` imports it with. An untyped constant type gives its default
// type. False when a named type's package is not imported, or the type is untyped nil, polymorphic,
// a tuple, a procedure group or an anonymous record.
type_source :: proc(c: ^Checker, file: File_Id, id: Type_Id, allocator := context.allocator) -> (string, bool) {
    sb := strings.builder_make(allocator)
    if !write_source(&sb, c, file, id) {
        strings.builder_destroy(&sb)
        return "", false
    }
    return strings.to_string(sb), true
}

@(private = "file")
write_source :: proc(sb: ^strings.Builder, c: ^Checker, file: File_Id, id: Type_Id) -> bool {
    t := &c.table
    #partial switch v in type_get(t, id) {
    case Basic_Type:
        strings.write_string(sb, BASIC_NAMES[v.kind])
    case Untyped_Type:
        switch v.kind {
        case .Int:        strings.write_string(sb, "int")
        case .Float:      strings.write_string(sb, "f64")
        case .Complex:    strings.write_string(sb, "complex128")
        case .Quaternion: strings.write_string(sb, "quaternion256")
        case .Rune:       strings.write_string(sb, "rune")
        case .String:     strings.write_string(sb, "string")
        case .Bool:       strings.write_string(sb, "bool")
        case .Nil, .Uninit:
            return false
        }
    case Pointer_Type:
        strings.write_byte(sb, '^')
        return write_source(sb, c, file, v.elem)
    case Multi_Pointer_Type:
        strings.write_string(sb, "[^]")
        return write_source(sb, c, file, v.elem)
    case Slice_Type:
        strings.write_string(sb, "[]")
        return write_source(sb, c, file, v.elem)
    case Array_Type:
        if v.len < 0 {
            return false
        }
        strings.write_byte(sb, '[')
        strings.write_i64(sb, v.len)
        strings.write_byte(sb, ']')
        return write_source(sb, c, file, v.elem)
    case Enumerated_Array_Type:
        strings.write_byte(sb, '[')
        if !write_source(sb, c, file, v.index) {
            return false
        }
        strings.write_byte(sb, ']')
        return write_source(sb, c, file, v.elem)
    case Dynamic_Array_Type:
        strings.write_string(sb, "[dynamic]")
        return write_source(sb, c, file, v.elem)
    case Map_Type:
        strings.write_string(sb, "map[")
        if !write_source(sb, c, file, v.key) {
            return false
        }
        strings.write_byte(sb, ']')
        return write_source(sb, c, file, v.value)
    case Bit_Set_Type:
        if v.range {
            return false
        }
        strings.write_string(sb, "bit_set[")
        if !write_source(sb, c, file, v.elem) {
            return false
        }
        if v.backing != INVALID_TYPE {
            strings.write_string(sb, "; ")
            if !write_source(sb, c, file, v.backing) {
                return false
            }
        }
        strings.write_byte(sb, ']')
    case Matrix_Type:
        if v.row_major {
            strings.write_string(sb, "#row_major ")
        }
        strings.write_string(sb, "matrix[")
        strings.write_i64(sb, v.rows)
        strings.write_string(sb, ", ")
        strings.write_i64(sb, v.cols)
        strings.write_byte(sb, ']')
        return write_source(sb, c, file, v.elem)
    case Simd_Type:
        strings.write_string(sb, "#simd[")
        strings.write_i64(sb, v.len)
        strings.write_byte(sb, ']')
        return write_source(sb, c, file, v.elem)
    case Proc_Type:
        return write_proc_source(sb, c, file, v)
    case Named_Type:
        alias, ok := package_alias(c, file, v.symbol)
        if !ok {
            return false
        }
        if alias != "" {
            strings.write_string(sb, alias)
            strings.write_byte(sb, '.')
        }
        strings.write_string(sb, v.name)
    case:
        return false
    }
    return true
}

@(private = "file")
write_proc_source :: proc(sb: ^strings.Builder, c: ^Checker, file: File_Id, p: Proc_Type) -> bool {
    if p.generic {
        return false
    }
    strings.write_string(sb, "proc")
    if p.convention != "" {
        strings.write_string(sb, " \"")
        strings.write_string(sb, p.convention)
        strings.write_string(sb, "\" ")
    }
    strings.write_byte(sb, '(')
    for param, i in p.params {
        if i > 0 {
            strings.write_string(sb, ", ")
        }
        if param.name != "" {
            strings.write_string(sb, param.name)
            strings.write_string(sb, ": ")
        }
        if .Variadic in param.flags {
            strings.write_string(sb, "..")
        }
        if !write_source(sb, c, file, param.type) {
            return false
        }
    }
    strings.write_byte(sb, ')')
    if p.diverging {
        strings.write_string(sb, " -> !")
        return true
    }
    if len(p.results) == 0 {
        return true
    }
    strings.write_string(sb, " -> ")
    named := p.results[0].name != ""
    if len(p.results) > 1 || named {
        strings.write_byte(sb, '(')
    }
    for r, i in p.results {
        if i > 0 {
            strings.write_string(sb, ", ")
        }
        if named {
            strings.write_string(sb, r.name)
            strings.write_string(sb, ": ")
        }
        if !write_source(sb, c, file, r.type) {
            return false
        }
    }
    if len(p.results) > 1 || named {
        strings.write_byte(sb, ')')
    }
    return true
}

// The qualifier `file` names a declaration of `sym` with: "" in its own package and for the universe.
// False when `file` does not import the package.
@(private = "file")
package_alias :: proc(c: ^Checker, file: File_Id, sym: Symbol) -> (string, bool) {
    if sym.file == NO_FILE {
        return "", true
    }
    own, decl := file_cache(c, file), file_cache(c, sym.file)
    if own == nil || decl == nil {
        return "", false
    }
    if own.dir_key == decl.dir_key {
        return "", true
    }
    for imp in checker_imports(c, file) {
        if imp.dir == "" || !imp.alias_valid || imp.alias == "_" || imp.is_foreign {
            continue
        }
        if path_key(imp.dir) == decl.dir_key {
            return imp.alias, true
        }
    }
    return "", false
}

// The zero value of `id` as source in `file`: `0`, `false`, `""`, `nil`, `{}` or an enum member.
// A literal is static; an enum value is in `allocator`. False when the type is not known.
zero_value :: proc(c: ^Checker, file: File_Id, id: Type_Id, allocator := context.temp_allocator) -> (string, bool) {
    t := &c.table
    if id == INVALID_TYPE {
        return "", false
    }
    base := type_base(t, id)
    #partial switch v in type_get(t, base) {
    case Basic_Type:
        #partial switch v.kind {
        case .Bool, .B8, .B16, .B32, .B64:
            return "false", true
        case .String, .Cstring, .String16, .Cstring16:
            return "\"\"", true
        case .Rawptr, .Typeid, .Any:
            return "nil", true
        }
        return "0", true
    case Untyped_Type:
        #partial switch v.kind {
        case .Bool:   return "false", true
        case .String: return "\"\"", true
        case .Nil:    return "nil", true
        case .Uninit: return "", false
        }
        return "0", true
    case Pointer_Type, Multi_Pointer_Type, Slice_Type, Dynamic_Array_Type, Map_Type, Proc_Type, Soa_Type:
        return "nil", true
    case Union_Type:
        if .No_Nil in v.flags {
            return "{}", true
        }
        return "nil", true
    case Struct_Type, Array_Type, Enumerated_Array_Type, Bit_Set_Type, Bit_Field_Type, Matrix_Type, Simd_Type:
        return "{}", true
    case Enum_Type:
        for m in v.members {
            if m.value == 0 {
                out, err := strings.concatenate({".", m.name}, allocator)
                return out, err == nil
            }
        }
        name, ok := type_source(c, file, id, context.temp_allocator)
        if !ok {
            return "", false
        }
        out, err := strings.concatenate({name, "(0)"}, allocator)
        return out, err == nil
    }
    return "", false
}
