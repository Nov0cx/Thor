package odinsyntax

// Which field list is parsed; it decides what a field may hold.
@(private)
Field_Mode :: enum {
    Params,
    Results,
    Struct,
    Poly_Params,
}

// `proc{...}` group, `proc(...)` type, or a procedure literal with its body.
@(private)
parse_proc_operand :: proc(p: ^Parser) -> Expr {
    cp := mark(p)
    bump(p)
    if at(p) == .Open_Brace {
        parse_group(p, cp, .Proc_Group)
        return {kind = .Proc_Group}
    }
    parse_signature(p)
    sig_end := mark_end(p)
    skipped := skip_newline_for_literal(p)
    has_where := false
    if at(p) == .Where {
        wrap_range(p, cp, sig_end, .Proc_Type)
        parse_where_clause(p)
        has_where = true
        parse_proc_tags(p)
    } else if skipped {
        wrap_range(p, cp, sig_end, .Proc_Type)
    } else {
        parse_proc_tags(p)
        wrap(p, cp, .Proc_Type)
    }
    if p.allow_type && p.expr_level < 0 {
        if has_where {
            error_at(p, p.prev_end, p.prev_end, .Not_Allowed)
        }
        return {kind = .Proc_Type}
    }
    skip_newline_for_literal(p)
    #partial switch at(p) {
    case .Undef:
        bump(p)
    case .Open_Brace:
        p.in_proc += 1
        parse_body(p)
        p.in_proc -= 1
    case .Do:
        p.in_proc += 1
        parse_do_body(p)
        p.in_proc -= 1
        wrap_range(p, cp, nested_end(p, cp), .Proc_Lit)
        return {kind = .Proc_Lit}
    case:
        return {kind = .Proc_Type}
    }
    wrap(p, cp, .Proc_Lit)
    return {kind = .Proc_Lit}
}

// `{a, b where c}` after `proc` or `asm`; the keyword is taken.
@(private)
parse_group :: proc(p: ^Parser, cp: int, kind: Syntax_Kind) {
    bump(p)
    count := 0
    for at(p) != .Close_Brace && at(p) != .EOF {
        ecp := mark(p)
        parse_expr(p, false)
        count += 1
        if allow(p, .Where) {
            parse_expr(p, false)
            wrap(p, ecp, .Binary_Expr)
        }
        if !allow(p, .Comma) {
            break
        }
    }
    if count == 0 {
        error_here(p, .Expected_Expr)
    }
    expect_closing(p, .Close_Brace)
    wrap(p, cp, kind)
}

// Calling convention, parameters and results; `proc` is taken.
@(private)
parse_signature :: proc(p: ^Parser) {
    if at(p) == .String {
        bump(p)
    }
    open(p, .Param_List)
    if expect(p, .Open_Paren) {
        p.expr_level += 1
        parse_field_list(p, .Close_Paren, .Params)
        p.expr_level -= 1
        expect_closing(p, .Close_Paren)
    }
    close(p)
    parse_results(p)
}

// `-> T`, `-> (fields)` or `-> !`.
@(private)
parse_results :: proc(p: ^Parser) {
    if at(p) != .Arrow_Right {
        return
    }
    open(p, .Result_List)
    defer close(p)
    bump(p)
    if allow(p, .Not) {
        return
    }
    prev_level := p.expr_level
    defer p.expr_level = prev_level
    if at(p) != .Open_Paren {
        cp := mark(p)
        parse_type(p)
        wrap(p, cp, .Field)
        return
    }
    bump(p)
    parse_field_list(p, .Close_Paren, .Results)
    expect(p, .Close_Paren)
}

@(private)
parse_proc_tags :: proc(p: ^Parser) {
    for at(p) == .Hash {
        parse_directive(p)
    }
}

@(private)
parse_where_clause :: proc(p: ^Parser) {
    cp := mark(p)
    bump(p)
    prev_level := p.expr_level
    p.expr_level = -1
    parse_expr_list(p, false)
    p.expr_level = prev_level
    wrap(p, cp, .Where_Clause)
}

// A list item before it is known to be a name or a type.
@(private)
Field_Item :: struct {
    start: int, // before its prefixes
    type:  int, // after its prefixes
    end:   int,
}

// Fields up to `follow`, as Field nodes. Mirrors core:odin/parser `parse_field_list`:
// the items are read as types, and become the names of the first field on a ':'.
@(private)
parse_field_list :: proc(p: ^Parser, follow: Token_Kind, mode: Field_Mode) {
    typeid_ok := mode == .Params || mode == .Poly_Params
    ellipsis_ok := mode == .Params || mode == .Results
    items := make([dynamic]Field_Item, 0, 8, context.temp_allocator)
    for at(p) != follow && at(p) != .Colon && at(p) != .EOF {
        item := Field_Item{start = mark(p)}
        parse_field_prefixes(p)
        item.type = mark(p)
        parse_var_type(p, ellipsis_ok, typeid_ok)
        item.end = mark_end(p)
        append(&items, item)
        if !allow(p, .Comma) {
            break
        }
    }
    if at(p) != .Colon {
        #reverse for item in items {
            wrap_range(p, item.start, item.end, .Field)
        }
        return
    }
    start := mark(p)
    if len(items) > 0 {
        start = items[0].start
        wrap_range(p, items[0].type, items[len(items) - 1].end, .Name_List)
    } else {
        error_here(p, .Expected_Token, .Ident)
    }
    if !parse_field_rest(p, start, mode, follow) {
        return
    }
    for at(p) != follow && at(p) != .EOF {
        before := progress(p)
        fcp := mark(p)
        parse_field_prefixes(p)
        ncp := mark(p)
        parse_ident_list(p, typeid_ok)
        wrap(p, ncp, .Name_List)
        if !parse_field_rest(p, fcp, mode, follow) || progress(p) == before {
            return
        }
    }
}

// `: type [= default] [tag]` and the separator; wraps the field from `start`.
@(private)
parse_field_rest :: proc(p: ^Parser, start: int, mode: Field_Mode, follow: Token_Kind) -> bool {
    expect(p, .Colon)
    has_type := false
    if at(p) != .Eq {
        has_type = parse_var_type(p, mode == .Params || mode == .Results, mode == .Params || mode == .Poly_Params).kind != .None
    }
    has_default := false
    if allow(p, .Eq) {
        if mode == .Struct {
            error_at(p, p.prev_end, p.prev_end, .Not_Allowed)
        }
        parse_expr(p, false)
        has_default = true
    }
    if has_type && !has_default && at(p) == .String {
        if mode != .Struct {
            error_here(p, .Not_Allowed)
        }
        bump(p)
    }
    end := mark_end(p)
    ok := allow(p, .Comma)
    if !ok && at(p) == .Semicolon {
        if next, _ := lookahead(p, 1); !at_newline(p) || next != follow {
            error_at(p, p.prev_end, p.prev_end, .Expected_Token, .Comma, .Newline if at_newline(p) else .Semicolon)
        }
        bump(p)
        ok = true
    }
    wrap_range(p, start, end, .Field)
    return ok
}

// `using` and `#flag` prefixes of a field.
@(private)
parse_field_prefixes :: proc(p: ^Parser) {
    for {
        #partial switch at(p) {
        case .Using:
            bump(p)
            continue
        case .Hash:
            kind, tok := lookahead(p, 1)
            name := token_text(p.src, tok) if kind == .Ident else ""
            switch name {
            case "simd", "type", "row_major", "column_major", "sparse", "soa":
                return
            case "no_alias", "c_vararg", "const", "any_int", "subtype", "by_ptr", "no_broadcast", "no_capture":
                parse_directive(p)
            case:
                error_here(p, .Bad_Directive)
                parse_directive(p)
            }
            continue
        }
        return
    }
}

// A field type: `..T` when `ellipsis`, `typeid/T` when `typeid_ok`, else a type.
@(private)
parse_var_type :: proc(p: ^Parser, ellipsis, typeid_ok: bool) -> Expr {
    if ellipsis && at(p) == .Ellipsis {
        cp := mark(p)
        bump(p)
        if parse_type_or_ident(p).kind == .None {
            error_here(p, .Expected_Type)
        }
        wrap(p, cp, .Ellipsis_Type)
        return {kind = .Ellipsis_Type}
    }
    if typeid_ok && at(p) == .Typeid {
        open(p, .Typeid_Type)
        bump(p)
        if allow(p, .Quo) {
            parse_type(p)
        }
        close(p)
        return {kind = .Typeid_Type}
    }
    return parse_type(p)
}

// `(poly params)` after `struct` or `union`.
@(private)
parse_poly_params :: proc(p: ^Parser) {
    open(p, .Param_List)
    bump(p)
    parse_field_list(p, .Close_Paren, .Poly_Params)
    expect(p, .Close_Paren)
    close(p)
}

// `#tag` and `#tag expr` after `struct` or `union`; returns after the last one.
@(private)
parse_record_tags :: proc(p: ^Parser, is_union: bool) {
    prev_level := p.expr_level
    p.expr_level = -1
    defer p.expr_level = prev_level
    for at(p) == .Hash {
        name := parse_directive(p)
        switch name {
        case "align":
            parse_expr(p, true)
        case "field_align", "min_field_align", "max_field_align":
            if is_union {
                error_at(p, p.prev_end, p.prev_end, .Bad_Directive)
            }
            parse_expr(p, true)
        case "packed", "raw_union", "no_copy", "all_or_none", "simple":
            if is_union {
                error_at(p, p.prev_end, p.prev_end, .Bad_Directive)
            }
        case "no_nil", "shared_nil":
            if !is_union {
                error_at(p, p.prev_end, p.prev_end, .Bad_Directive)
            }
        case:
            error_at(p, p.prev_end, p.prev_end, .Bad_Directive)
        }
    }
}

@(private)
parse_struct_type :: proc(p: ^Parser) -> Expr {
    cp := mark(p)
    bump(p)
    if at(p) == .Open_Paren {
        parse_poly_params(p)
    }
    parse_record_tags(p, false)
    skip_newline_for_literal(p)
    if at(p) == .Where {
        parse_where_clause(p)
    }
    skip_newline_for_literal(p)
    open(p, .Field_List)
    if expect(p, .Open_Brace) {
        parse_field_list(p, .Close_Brace, .Struct)
        expect_closing(p, .Close_Brace)
    }
    close(p)
    wrap(p, cp, .Struct_Type)
    return {kind = .Struct_Type}
}

@(private)
parse_union_type :: proc(p: ^Parser) -> Expr {
    cp := mark(p)
    bump(p)
    if at(p) == .Open_Paren {
        parse_poly_params(p)
    }
    parse_record_tags(p, true)
    skip_newline_for_literal(p)
    if at(p) == .Where {
        parse_where_clause(p)
    }
    skip_newline_for_literal(p)
    if expect(p, .Open_Brace) {
        for at(p) != .Close_Brace && at(p) != .EOF {
            parse_type(p)
            if !list_separator(p, .Close_Brace) {
                break
            }
        }
        expect_closing(p, .Close_Brace)
    }
    wrap(p, cp, .Union_Type)
    return {kind = .Union_Type}
}

@(private)
parse_enum_type :: proc(p: ^Parser) -> Expr {
    cp := mark(p)
    bump(p)
    if at(p) != .Open_Brace {
        parse_type(p)
    }
    skip_newline_for_literal(p)
    if expect(p, .Open_Brace) {
        parse_elem_list(p)
        expect_closing(p, .Close_Brace)
    }
    wrap(p, cp, .Enum_Type)
    return {kind = .Enum_Type}
}

@(private)
parse_bit_field_type :: proc(p: ^Parser) -> Expr {
    cp := mark(p)
    bump(p)
    if parse_type_or_ident(p).kind == .None {
        error_here(p, .Expected_Type)
        if !ends_operand(at(p)) {
            bump_error(p)
        }
    }
    skip_newline_for_literal(p)
    if expect(p, .Open_Brace) {
        for at(p) != .Close_Brace && at(p) != .EOF {
            fcp := mark(p)
            parse_ident(p)
            expect(p, .Colon)
            parse_type(p)
            expect(p, .Or)
            parse_expr(p, true)
            if at(p) == .String {
                bump(p)
            }
            end := mark_end(p)
            ok := list_separator(p, .Close_Brace)
            wrap_range(p, fcp, end, .Bit_Field_Field)
            if !ok {
                break
            }
        }
        expect_closing(p, .Close_Brace)
    }
    wrap(p, cp, .Bit_Field_Type)
    return {kind = .Bit_Field_Type}
}

// `[N]T`, `[?]T`, `[]T`, `[^]T`, `[dynamic]T` and `[dynamic; N]T`.
@(private)
parse_array_type :: proc(p: ^Parser) -> Expr {
    cp := mark(p)
    bump(p)
    kind := Syntax_Kind.Array_Type
    #partial switch at(p) {
    case .Pointer:
        bump(p)
        kind = .Multi_Pointer_Type
    case .Dynamic:
        bump(p)
        kind = .Dynamic_Array_Type
        if allow(p, .Semicolon) {
            parse_expr(p, false)
        }
    case .Question:
        bump(p)
    case .Close_Bracket:
    case:
        p.expr_level += 1
        parse_expr(p, false)
        p.expr_level -= 1
    }
    expect(p, .Close_Bracket)
    parse_type(p)
    wrap(p, cp, kind)
    return {kind = kind}
}

// `asm {...}` group or an `asm(...) [specs] {instructions}` template.
@(private)
parse_asm :: proc(p: ^Parser) -> Expr {
    cp := mark(p)
    if next, _ := lookahead(p, 1); next == .Open_Brace {
        bump(p)
        parse_group(p, cp, .Asm_Group)
        return {kind = .Asm_Group}
    }
    bump(p)
    open(p, .Param_List)
    if expect(p, .Open_Paren) {
        p.expr_level += 1
        parse_field_list(p, .Close_Paren, .Params)
        p.expr_level -= 1
        expect(p, .Close_Paren)
    }
    close(p)
    parse_results(p)
    if at(p) == .Open_Bracket {
        parse_asm_specs(p)
    }
    if at(p) != .Open_Brace {
        error_here(p, .Expected_Token, .Open_Brace)
    } else {
        open(p, .Asm_Body)
        bump(p)
        for at(p) != .Close_Brace && at(p) != .EOF {
            before := progress(p)
            parse_asm_instruction(p)
            if progress(p) == before {
                bump_error(p)
            }
        }
        expect(p, .Close_Brace)
        close(p)
    }
    wrap(p, cp, .Asm_Template)
    return {kind = .Asm_Template}
}

@(private)
parse_asm_specs :: proc(p: ^Parser) {
    open(p, .Asm_Spec_List)
    bump(p)
    for at(p) != .Close_Bracket && at(p) != .EOF {
        #partial switch at(p) {
        case .Ident:
            parse_asm_spec(p)
        case .Hash:
            ccp := mark(p)
            name := parse_directive(p)
            switch name {
            case "volatile", "align_stack", "pure":
            case "clobber":
                parse_asm_operand(p, false)
            case:
                error_at(p, p.prev_end, p.prev_end, .Bad_Directive)
            }
            wrap(p, ccp, .Asm_Clobber)
        case:
            error_here(p, .Unexpected_Token)
            bump_error(p)
        }
        if !allow(p, .Comma) {
            break
        }
    }
    expect(p, .Close_Bracket)
    close(p)
}

// `name [-> tied] [: type] [= value] #directives`.
@(private)
parse_asm_spec :: proc(p: ^Parser) {
    cp := mark(p)
    parse_ident(p)
    if allow(p, .Arrow_Right) {
        parse_ident(p)
    }
    if allow(p, .Colon) {
        parse_type(p)
    }
    if allow(p, .Eq) {
        #partial switch at(p) {
        case .Ident: parse_ident(p)
        case .Mod:   parse_asm_register(p)
        case:
            error_here(p, .Expected_Operand)
            parse_expr(p, true)
        }
    }
    for at(p) == .Hash {
        parse_directive(p)
    }
    wrap(p, cp, .Asm_Spec)
}

// `%name[.flag]`.
@(private)
parse_asm_register :: proc(p: ^Parser) {
    cp := mark(p)
    expect(p, .Mod)
    expect(p, .Ident)
    if allow(p, .Period) {
        expect(p, .Ident)
    }
    wrap(p, cp, .Asm_Register)
}

// One operand of an instruction; false when there is none.
@(private)
parse_asm_operand :: proc(p: ^Parser, allow_memory: bool) -> bool {
    cp := mark(p)
    #partial switch at(p) {
    case .Period:
        bump(p)
        parse_ident(p)
        wrap(p, cp, .Asm_Label)
        return true
    case .Ident:
        parse_ident(p)
    case .Mod:
        parse_asm_register(p)
    case .Integer, .Float, .Rune:
        leaf(p, .Literal)
        return true
    case .Add, .Sub, .Xor:
        bump(p)
        parse_asm_operand(p, false)
        wrap(p, cp, .Unary_Expr)
        return true
    case .Open_Paren:
        parse_expr(p, false)
        return true
    case .Hash:
        name := parse_directive(p)
        if name == "pre" || name == "post" {
            parse_asm_operand(p, allow_memory)
        } else {
            error_at(p, p.prev_end, p.prev_end, .Bad_Directive)
        }
        wrap(p, cp, .Tag_Expr)
        return true
    case .Open_Bracket:
        if !allow_memory {
            break
        }
        bump(p)
        parse_asm_operand(p, false)
        if allow(p, .Colon) {
            parse_asm_operand(p, false)
        }
        if allow(p, .Add) || allow(p, .Sub) {
            parse_asm_operand(p, false)
            if allow(p, .Mul) || allow(p, .Shl) || allow(p, .Shr) {
                parse_asm_operand(p, false)
            }
            if allow(p, .Add) || allow(p, .Sub) {
                parse_asm_operand(p, false)
            }
        }
        expect(p, .Close_Bracket)
        if allow(p, .Colon) {
            parse_type(p)
        }
        wrap(p, cp, .Asm_Memory_Operand)
        return true
    case .Open_Brace:
        if !allow_memory {
            break
        }
        bump(p)
        parse_asm_operand(p, false)
        if at(p) == .Range_Half || at(p) == .Range_Full {
            bump(p)
            parse_asm_operand(p, false)
            allow(p, .Comma)
        } else {
            allow(p, .Comma)
            for at(p) != .Close_Brace && at(p) != .EOF {
                if !parse_asm_operand(p, false) || !allow(p, .Comma) {
                    break
                }
            }
        }
        expect(p, .Close_Brace)
        if allow(p, .Colon) {
            parse_type(p)
        }
        wrap(p, cp, .Asm_Register_Group)
        return true
    }
    if mark_end(p) == cp {
        error_here(p, .Expected_Operand)
        bump_error(p)
        return false
    }
    if at(p) == .Open_Bracket {
        p.expr_level += 1
        bump(p)
        parse_asm_operand(p, false)
        expect(p, .Close_Bracket)
        p.expr_level -= 1
        wrap(p, cp, .Index_Expr)
    }
    return true
}

@(private)
parse_asm_operands :: proc(p: ^Parser) {
    for at(p) != .Semicolon && at(p) != .Close_Brace && at(p) != .EOF {
        if !parse_asm_operand(p, true) || !allow(p, .Comma) {
            break
        }
    }
}

@(private)
parse_asm_instruction :: proc(p: ^Parser) {
    if allow(p, .Semicolon) {
        return
    }
    cp := mark(p)
    kind := at(p)
    switch {
    case kind == .Ident || token_is_keyword(kind):
        leaf(p, .Ident)
        parse_asm_operands(p)
        wrap(p, cp, .Asm_Instruction)
    case kind == .Period:
        bump(p)
        parse_ident(p)
        wrap(p, cp, .Asm_Label)
        expect(p, .Colon)
        wrap(p, cp, .Asm_Label_Decl)
        return
    case kind == .Hash:
        parse_directive(p)
        parse_asm_operands(p)
        wrap(p, cp, .Asm_Directive)
    case:
        error_here(p, .Unexpected_Token)
        bump_error(p)
        return
    }
    allow(p, .Semicolon)
}
