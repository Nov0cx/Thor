// Names that break the Odin naming style (`style/naming`).
package odinsema

import "core:strings"

import odinsyntax "../syntax"

// A spelling of a name.
Name_Style :: enum u8 {
    Snake_Case,
    Ada_Case,
    Screaming_Snake_Case,
}

// The spellings a rule accepts. An empty set switches the rule off.
Name_Styles :: bit_set[Name_Style]

// The spellings each kind of name accepts.
Naming_Rules :: struct {
    type:        Name_Styles, // struct, union, enum, bit_set, bit_field, distinct and proc types
    procedure:   Name_Styles, // `name :: proc`
    variable:    Name_Styles, // variables, parameters, fields and loop variables; a file-scope variable may be SCREAMING_SNAKE_CASE too
    constant:    Name_Styles, // constants with a literal value
    enum_member: Name_Styles,
}

DEFAULT_NAMING_RULES :: Naming_Rules {
    type        = {.Ada_Case},
    procedure   = {.Snake_Case},
    variable    = {.Snake_Case},
    constant    = {.Screaming_Snake_Case, .Ada_Case, .Snake_Case},
    enum_member = {.Ada_Case, .Snake_Case},
}

// A name that does not fit the rule of its kind.
Naming_Problem :: struct {
    offset: int,
    name:   string,
    want:   Name_Styles,
}

// The name of a style as the user writes it in a config file.
style_key :: proc(style: Name_Style) -> string {
    switch style {
    case .Snake_Case:           return "snake_case"
    case .Ada_Case:             return "ada_case"
    case .Screaming_Snake_Case: return "screaming_snake_case"
    }
    return ""
}

// The style a config file names with `key`.
style_from_key :: proc(key: string) -> (style: Name_Style, ok: bool) {
    for s in Name_Style {
        if style_key(s) == key {
            return s, true
        }
    }
    return
}

// `styles` as the text of a message: "Ada_Case or SCREAMING_SNAKE_CASE".
styles_text :: proc(styles: Name_Styles, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    first := true
    for s in Name_Style {
        if s not_in styles {
            continue
        }
        if !first {
            strings.write_string(&b, " or ")
        }
        first = false
        switch s {
        case .Snake_Case:           strings.write_string(&b, "snake_case")
        case .Ada_Case:             strings.write_string(&b, "Ada_Case")
        case .Screaming_Snake_Case: strings.write_string(&b, "SCREAMING_SNAKE_CASE")
        }
    }
    return strings.to_string(b)
}

// True when `name` is written in `style`. A name with a byte outside ASCII always fits.
name_has_style :: proc(name: string, style: Name_Style) -> bool {
    for i in 0 ..< len(name) {
        if name[i] >= 0x80 {
            return true
        }
    }
    switch style {
    case .Snake_Case:
        for i in 0 ..< len(name) {
            if name[i] >= 'A' && name[i] <= 'Z' {
                return false
            }
        }
        return true
    case .Screaming_Snake_Case:
        for i in 0 ..< len(name) {
            if name[i] >= 'a' && name[i] <= 'z' {
                return false
            }
        }
        return true
    case .Ada_Case:
        // Each word starts with a capital and a lower case letter never goes before a capital.
        start := true
        for i in 0 ..< len(name) {
            c := name[i]
            switch {
            case c == '_':
                start = true
            case start:
                if c >= 'a' && c <= 'z' {
                    return false
                }
                start = false
            case c >= 'A' && c <= 'Z':
                if p := name[i - 1]; p >= 'a' && p <= 'z' {
                    return false
                }
            }
        }
        return true
    }
    return true
}

// The names of the declaration or field `n` that do not fit `rules`. A name of one letter, one
// that starts with `_`, a polymorphic name, a name in a `foreign` block and a declaration with
// `link_name`, `link_prefix` or `export` are left out.
naming_problems :: proc(n: odinsyntax.Syntax_Node, rules: Naming_Rules, allocator := context.allocator) -> []Naming_Problem {
    out := make([dynamic]Naming_Problem, allocator)
    n := n
    #partial switch n.green.kind {
    case .Value_Decl:
        value_decl_naming(&n, rules, &out)
    case .Field:
        field_naming(&n, rules, &out)
    case .Range_Stmt:
        rs, _ := odinsyntax.as_range_stmt(n)
        if vars, ok := odinsyntax.range_stmt_vars(&rs); ok {
            it := odinsyntax.expr_list_items(&vars)
            for v in odinsyntax.child_iter_next(&it) {
                check_name(v, rules.variable, &out)
            }
        }
    case .Enum_Type:
        et, _ := odinsyntax.as_enum_type(n)
        it := odinsyntax.enum_type_members(&et)
        for member in odinsyntax.child_iter_next(&it) {
            member := member
            if fv, ok := odinsyntax.as_field_value(member); ok {
                member, _ = odinsyntax.field_value_name(&fv)
            }
            check_name(member, rules.enum_member, &out)
        }
    }
    return out[:]
}

@(private = "file")
value_decl_naming :: proc(n: ^odinsyntax.Syntax_Node, rules: Naming_Rules, out: ^[dynamic]Naming_Problem) {
    if in_foreign_block(n^) {
        return
    }
    v, _ := odinsyntax.as_value_decl(n^)
    attrs := odinsyntax.value_decl_attributes(&v)
    for attr in odinsyntax.child_iter_next(&attrs) {
        text := odinsyntax.node_text(attr)
        if strings.contains(text, "link_name") || strings.contains(text, "link_prefix") || strings.contains(text, "export") {
            return
        }
    }
    names, has := odinsyntax.value_decl_names(&v)
    if !has {
        return
    }
    styles: Name_Styles
    if colon_count(n^) < 2 {
        styles = rules.variable
        if styles != {} && !in_proc_body(n^) {
            styles += {.Screaming_Snake_Case}
        }
    } else if _, typed := odinsyntax.value_decl_type(&v); typed {
        styles = rules.constant
    } else {
        values, vok := odinsyntax.value_decl_values(&v)
        if !vok {
            return
        }
        it := odinsyntax.expr_list_items(&values)
        first, fok := odinsyntax.child_iter_next(&it)
        if !fok {
            return
        }
        #partial switch first.green.kind {
        case .Struct_Type, .Union_Type, .Enum_Type, .Bit_Set_Type, .Bit_Field_Type, .Distinct_Type, .Proc_Type:
            styles = rules.type
        case .Proc_Lit, .Proc_Group:
            styles = rules.procedure
        case .Literal:
            styles = rules.constant
        case:
            // An alias or a computed value can stand for anything.
            return
        }
    }
    it := odinsyntax.name_list_names(&names)
    for name in odinsyntax.child_iter_next(&it) {
        check_name(name, styles, out)
    }
}

// A parameter, a result or a field: it has a name only when a colon follows the names.
@(private = "file")
field_naming :: proc(n: ^odinsyntax.Syntax_Node, rules: Naming_Rules, out: ^[dynamic]Naming_Problem) {
    if colon_count(n^) == 0 || in_foreign_block(n^) {
        return
    }
    f, _ := odinsyntax.as_field(n^)
    names, has := odinsyntax.field_names(&f)
    if !has {
        return
    }
    it := odinsyntax.name_list_names(&names)
    for name in odinsyntax.child_iter_next(&it) {
        check_name(name, rules.variable, out)
    }
}

@(private = "file")
check_name :: proc(name: odinsyntax.Syntax_Node, styles: Name_Styles, out: ^[dynamic]Naming_Problem) {
    if styles == {} || name.green.kind != .Ident {
        return
    }
    text := odinsyntax.node_text(name)
    if len(text) < 2 || text[0] == '_' {
        return
    }
    for style in styles {
        if name_has_style(text, style) {
            return
        }
    }
    append(out, Naming_Problem{offset = int(name.offset), name = text, want = styles})
}

// The number of `:` tokens that are direct children of `n`.
@(private = "file")
colon_count :: proc(n: odinsyntax.Syntax_Node) -> int {
    count := 0
    for child in odinsyntax.green_children(n.green) {
        if tok, ok := odinsyntax.element_token(child); ok && tok.kind == .Colon {
            count += 1
        }
    }
    return count
}

@(private = "file")
in_proc_body :: proc(n: odinsyntax.Syntax_Node) -> bool {
    for p := n.parent; p != nil; p = p.parent {
        if p.green.kind == .Proc_Lit {
            return true
        }
    }
    return false
}

@(private = "file")
in_foreign_block :: proc(n: odinsyntax.Syntax_Node) -> bool {
    for p := n.parent; p != nil; p = p.parent {
        if p.green.kind == .Foreign_Block {
            return true
        }
    }
    return false
}
