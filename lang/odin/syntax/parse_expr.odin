package odinsyntax

// What a parse procedure built: the node kind, and for a paren or tag expression the
// kind inside it. `arrow` marks a `->` selector.
@(private)
Expr :: struct {
    kind:  Syntax_Kind,
    inner: Syntax_Kind,
    arrow: bool,
}

// The kind with parens and tags taken off.
@(private)
unparen :: #force_inline proc(e: Expr) -> Syntax_Kind {
    return e.inner if e.kind == .Paren_Expr || e.kind == .Tag_Expr else e.kind
}

// A node of `kind` holding the current token.
@(private)
leaf :: proc(p: ^Parser, kind: Syntax_Kind) -> Expr {
    open(p, kind)
    bump(p)
    close(p)
    return {kind = kind}
}

@(private)
parse_ident :: proc(p: ^Parser) -> bool {
    if at(p) == .Ident {
        leaf(p, .Ident)
        return true
    }
    error_here(p, .Expected_Token, .Ident)
    return false
}

// Identifiers separated by commas; `$T` names when `poly`.
@(private)
parse_ident_list :: proc(p: ^Parser, poly: bool) {
    for {
        if poly && at(p) == .Dollar {
            cp := mark(p)
            bump(p)
            parse_ident(p)
            wrap(p, cp, .Poly_Type)
        } else if !parse_ident(p) {
            return
        }
        if at(p) != .Comma {
            return
        }
        bump(p)
    }
}

// Takes `closer` at the end of a list; reports a ';' where a ',' belongs and skips stray
// tokens on the way.
@(private)
expect_closing :: proc(p: ^Parser, closer: Token_Kind) -> bool {
    if allow(p, closer) {
        return true
    }
    if at(p) == .Semicolon {
        newline := at_newline(p)
        if !newline {
            error_here(p, .Expected_Token, .Comma)
        }
        bump(p)
        if allow(p, closer) {
            return true
        }
        error_here(p, .Expected_Token, closer)
        return false
    }
    error_here(p, .Expected_Token, closer)
    if stops_closing(p, closer) {
        return allow(p, closer)
    }
    open(p, .Error)
    for !stops_closing(p, closer) {
        bump_balanced(p)
    }
    close(p)
    return allow(p, closer)
}

@(private)
stops_closing :: proc(p: ^Parser, closer: Token_Kind) -> bool {
    #partial switch k := at(p); k {
    case closer, .EOF, .Semicolon:
        return true
    case .Close_Paren, .Close_Bracket:
        return true
    case .Close_Brace:
        return closer != .Close_Brace || p.open_braces <= 0
    }
    return false
}

@(private)
parse_value :: proc(p: ^Parser) -> Expr {
    prev := p.allow_range
    p.allow_range = true
    defer p.allow_range = prev
    return parse_expr(p, false)
}

@(private)
parse_expr :: proc(p: ^Parser, lhs: bool) -> Expr {
    return parse_binary_expr(p, lhs, 1)
}

@(private)
token_precedence :: proc(p: ^Parser, kind: Token_Kind) -> int {
    #partial switch kind {
    case .Question, .If, .When, .Or_Else:
        return 1
    case .Ellipsis, .Range_Half, .Range_Full:
        return 2 if p.allow_range else 0
    case .Cmp_Or:
        return 3
    case .Cmp_And:
        return 4
    case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
        return 5
    case .In, .Not_In:
        if p.expr_level < 0 && !p.allow_in_expr {
            return 0
        }
        return 6
    case .Add, .Sub, .Or, .Xor:
        return 6
    case .Mul, .Quo, .Mod, .Mod_Mod, .And, .And_Not, .Shl, .Shr:
        return 7
    }
    return 0
}

@(private)
parse_binary_expr :: proc(p: ^Parser, lhs: bool, prec_in: int) -> Expr {
    cp := mark(p)
    expr := parse_unary_expr(p, lhs)
    if expr.kind == .None {
        return expr
    }
    links := 0
    defer p.depth -= links
    outer: for prec := token_precedence(p, at(p)); prec >= prec_in; prec -= 1 {
        for {
            op := at(p)
            if token_precedence(p, op) != prec {
                break
            }
            if (op == .If || op == .When) && p.expr_level <= 0 && newline_before(p) {
                break
            }
            bump(p)
            #partial switch op {
            case .Question:
                parse_expr(p, lhs)
                expect(p, .Colon)
                parse_expr(p, lhs)
                expr = {kind = .Ternary_Expr}
            case .If:
                parse_expr(p, lhs)
                expect(p, .Else)
                parse_expr(p, lhs)
                expr = {kind = .Ternary_If_Expr}
            case .When:
                parse_expr(p, lhs)
                skip_newline(p)
                expect(p, .Else)
                parse_expr(p, lhs)
                expr = {kind = .Ternary_When_Expr}
            case .Or_Else:
                parse_expr(p, lhs)
                expr = {kind = .Or_Else_Expr}
            case:
                if parse_binary_expr(p, false, prec + 1).kind == .None {
                    error_here(p, .Expected_Expr)
                }
                expr = {kind = .Binary_Expr}
            }
            wrap(p, cp, expr.kind)
            if !chain_link(p, &links) {
                break outer
            }
        }
    }
    return expr
}

@(private)
parse_unary_expr :: proc(p: ^Parser, lhs: bool) -> Expr {
    if !enter(p) {
        return {kind = .Error}
    }
    defer leave(p)
    cp := mark(p)
    #partial switch at(p) {
    case .Transmute, .Cast:
        bump(p)
        expect(p, .Open_Paren)
        parse_type(p)
        expect(p, .Close_Paren)
        parse_unary_expr(p, lhs)
        wrap(p, cp, .Cast_Expr)
        return {kind = .Cast_Expr}
    case .Auto_Cast:
        bump(p)
        parse_unary_expr(p, lhs)
        wrap(p, cp, .Auto_Cast_Expr)
        return {kind = .Auto_Cast_Expr}
    case .Add, .Sub, .Not, .Xor, .And, .Mul_Mul:
        bump(p)
        parse_unary_expr(p, lhs)
        wrap(p, cp, .Unary_Expr)
        return {kind = .Unary_Expr}
    case .Increment, .Decrement:
        error_here(p, .Not_Allowed)
        bump(p)
        parse_unary_expr(p, lhs)
        wrap(p, cp, .Unary_Expr)
        return {kind = .Unary_Expr}
    case .Period:
        bump(p)
        parse_ident(p)
        wrap(p, cp, .Implicit_Selector)
        return {kind = .Implicit_Selector}
    }
    return parse_atom_expr(p, parse_operand(p, lhs), lhs, cp)
}

// A type or a name, in a context where a bare `{` does not start a literal.
@(private)
parse_type_or_ident :: proc(p: ^Parser) -> Expr {
    if !enter(p) {
        return {kind = .Error}
    }
    defer leave(p)
    prev_type, prev_level := p.allow_type, p.expr_level
    p.allow_type = true
    p.expr_level = -1
    defer {
        p.allow_type = prev_type
        p.expr_level = prev_level
    }
    cp := mark(p)
    return parse_atom_expr(p, parse_operand(p, true), true, cp)
}

@(private)
parse_type :: proc(p: ^Parser) -> Expr {
    t := parse_type_or_ident(p)
    if t.kind == .None {
        error_here(p, .Expected_Type)
        return {kind = .Error}
    }
    return t
}

// Tokens an expression can never start with; a missing operand there takes nothing.
@(private)
ends_operand :: proc(kind: Token_Kind) -> bool {
    #partial switch kind {
    case .Close_Paren, .Close_Bracket, .Close_Brace, .Comma, .Semicolon, .Colon, .EOF,
         .Eq, .Do, .Else, .Case, .In, .Where, .Arrow_Right, .Open_Brace:
        return true
    }
    return is_assignment_op(kind) || is_stmt_sync(kind)
}

@(private)
is_literal_type :: proc(e: Expr) -> bool {
    #partial switch unparen(e) {
    case .Error, .Ident, .Selector_Expr, .Array_Type, .Struct_Type, .Union_Type, .Enum_Type,
         .Dynamic_Array_Type, .Map_Type, .Bit_Set_Type, .Matrix_Type, .Call_Expr, .Bit_Field_Type:
        return true
    }
    return false
}

// The postfix chain after an operand that starts at checkpoint `cp`.
@(private)
parse_atom_expr :: proc(p: ^Parser, value: Expr, lhs: bool, cp: int) -> Expr {
    operand := value
    if operand.kind == .None {
        if p.allow_type {
            return operand
        }
        error_here(p, .Expected_Operand)
        if !ends_operand(at(p)) {
            bump_error(p)
        }
        return {kind = .Error}
    }
    is_lhs := lhs
    links := 0
    defer p.depth -= links
    loop: for {
        #partial switch at(p) {
        case .Open_Paren:
            operand = parse_call_expr(p, cp, operand)

        case .Open_Bracket:
            operand = parse_index_expr(p, cp)

        case .Period:
            bump(p)
            #partial switch at(p) {
            case .Ident:
                if newline_before(p) {
                    error_at(p, p.prev_end, p.prev_end, .Expected_Selector, found = .Newline)
                    wrap(p, cp, .Selector_Expr)
                    return {kind = .Selector_Expr}
                }
                parse_ident(p)
                operand = {kind = .Selector_Expr}
            case .Open_Paren:
                bump(p)
                parse_type(p)
                expect(p, .Close_Paren)
                operand = {kind = .Type_Assertion}
            case .Question:
                bump(p)
                operand = {kind = .Type_Assertion}
            case:
                error_here(p, .Expected_Selector)
                operand = {kind = .Selector_Expr}
            }
            wrap(p, cp, operand.kind)

        case .Arrow_Right:
            bump(p)
            if at(p) == .Ident && !newline_before(p) {
                parse_ident(p)
            } else {
                error_here(p, .Expected_Selector)
            }
            wrap(p, cp, .Selector_Expr)
            operand = {kind = .Selector_Expr, arrow = true}

        case .Pointer:
            bump(p)
            wrap(p, cp, .Deref_Expr)
            operand = {kind = .Deref_Expr}

        case .Or_Return:
            bump(p)
            wrap(p, cp, .Or_Return_Expr)
            operand = {kind = .Or_Return_Expr}

        case .Or_Break, .Or_Continue:
            bump(p)
            if at(p) == .Ident {
                parse_ident(p)
            }
            wrap(p, cp, .Or_Branch_Expr)
            operand = {kind = .Or_Branch_Expr}

        case .Open_Brace:
            if is_lhs || !is_literal_type(operand) || p.expr_level < 0 {
                break loop
            }
            operand = parse_literal_value(p, cp)

        case .Increment, .Decrement:
            if lhs {
                break loop
            }
            error_here(p, .Not_Allowed)
            bump(p)

        case:
            break loop
        }
        is_lhs = false
        if !chain_link(p, &links) {
            break loop
        }
    }
    return operand
}

// `operand(args)`; the operand starts at `cp`.
@(private)
parse_call_expr :: proc(p: ^Parser, cp: int, operand: Expr) -> Expr {
    prev_level := p.expr_level
    p.expr_level = 0
    open(p, .Arg_List)
    if !expect(p, .Open_Paren) {
        p.expr_level = prev_level
        close(p)
        wrap(p, cp, .Call_Expr)
        return {kind = .Call_Expr}
    }
    for at(p) != .Close_Paren && at(p) != .EOF {
        acp := mark(p)
        spread := allow(p, .Ellipsis)
        parse_expr(p, false)
        if allow(p, .Eq) {
            if spread {
                error_at(p, p.prev_end, p.prev_end, .Not_Allowed)
            }
            parse_value(p)
            wrap(p, acp, .Field_Value)
        } else if spread {
            wrap(p, acp, .Spread_Expr)
        }
        if !allow(p, .Comma) {
            break
        }
    }
    p.expr_level = prev_level
    expect_closing(p, .Close_Paren)
    close(p)
    wrap(p, cp, .Call_Expr)
    if operand.arrow || (operand.kind == .Paren_Expr && operand.arrow) {
        wrap(p, cp, .Selector_Call_Expr)
        return {kind = .Selector_Call_Expr}
    }
    return {kind = .Call_Expr}
}

// `operand[i]`, `operand[lo:hi]` or `operand[r, c]`.
@(private)
parse_index_expr :: proc(p: ^Parser, cp: int) -> Expr {
    prev_range := p.allow_range
    p.allow_range = false
    defer p.allow_range = prev_range
    p.expr_level += 1
    bump(p)
    #partial switch at(p) {
    case .Colon, .Ellipsis, .Range_Half, .Range_Full:
    case:
        parse_expr(p, false)
    }
    kind := Syntax_Kind.Index_Expr
    #partial switch at(p) {
    case .Ellipsis, .Range_Half, .Range_Full:
        error_here(p, .Expected_Token, .Colon)
        fallthrough
    case .Colon, .Comma:
        kind = .Matrix_Index_Expr if at(p) == .Comma else .Slice_Expr
        bump(p)
        if at(p) != .Close_Bracket && at(p) != .EOF {
            parse_expr(p, false)
        }
    }
    p.expr_level -= 1
    expect(p, .Close_Bracket)
    wrap(p, cp, kind)
    return {kind = kind}
}

// `{elems}`, with the type before it from checkpoint `cp`, or none when `cp` is -1.
@(private)
parse_literal_value :: proc(p: ^Parser, cp: int) -> Expr {
    start := cp if cp >= 0 else mark(p)
    bump(p)
    prev_level := p.expr_level
    p.expr_level = 0
    if at(p) != .Close_Brace {
        parse_elem_list(p)
    }
    p.expr_level = prev_level
    skip_newline(p)
    expect_closing(p, .Close_Brace)
    wrap(p, start, .Comp_Lit)
    return {kind = .Comp_Lit}
}

// Values or `name = value` pairs separated by commas, up to '}'.
@(private)
parse_elem_list :: proc(p: ^Parser) {
    for at(p) != .Close_Brace && at(p) != .EOF {
        ecp := mark(p)
        parse_value(p)
        if allow(p, .Eq) {
            parse_value(p)
            wrap(p, ecp, .Field_Value)
        }
        if !list_separator(p, .Close_Brace) {
            return
        }
    }
}

// Takes the ',' after a list element. A newline before the next element on its own line is
// taken too, as the comma the compiler reports missing.
@(private)
list_separator :: proc(p: ^Parser, closer: Token_Kind) -> bool {
    if allow(p, .Comma) {
        return true
    }
    if !at_newline(p) || p.toks[p.cur].kind == .EOF {
        return false
    }
    next, _ := lookahead(p, 1)
    if next == closer || next == .EOF || next == .Close_Paren || next == .Close_Bracket || next == .Close_Brace {
        return false
    }
    error_at(p, p.prev_end, p.prev_end, .Expected_Token, .Comma, .Newline)
    bump(p)
    return true
}

@(private)
parse_operand :: proc(p: ^Parser, lhs: bool) -> Expr {
    #partial switch at(p) {
    case .Ident:
        parse_ident(p)
        return {kind = .Ident}
    case .Undef:
        return leaf(p, .Undef_Expr)
    case .Context:
        return leaf(p, .Context_Expr)
    case .Integer, .Float, .Imag, .Rune, .String:
        return leaf(p, .Literal)
    case .Open_Brace:
        if !lhs {
            return parse_literal_value(p, -1)
        }
    case .Open_Paren:
        open(p, .Paren_Expr)
        bump(p)
        prev_level := p.expr_level
        p.expr_level = max(p.expr_level, 0) + 1
        inner := parse_expr(p, false)
        p.expr_level = prev_level
        expect(p, .Close_Paren)
        close(p)
        return {kind = .Paren_Expr, inner = unparen(inner), arrow = inner.arrow}
    case .Distinct:
        open(p, .Distinct_Type)
        bump(p)
        parse_type(p)
        close(p)
        return {kind = .Distinct_Type}
    case .Hash:
        return parse_directive_operand(p, lhs)
    case .Proc:
        return parse_proc_operand(p)
    case .Dollar:
        open(p, .Poly_Type)
        bump(p)
        parse_ident(p)
        if allow(p, .Quo) {
            parse_type(p)
        }
        close(p)
        return {kind = .Poly_Type}
    case .Typeid:
        return leaf(p, .Typeid_Type)
    case .Pointer:
        open(p, .Pointer_Type)
        bump(p)
        parse_type(p)
        close(p)
        return {kind = .Pointer_Type}
    case .Open_Bracket:
        return parse_array_type(p)
    case .Map:
        open(p, .Map_Type)
        bump(p)
        expect(p, .Open_Bracket)
        parse_type(p)
        expect(p, .Close_Bracket)
        parse_type(p)
        close(p)
        return {kind = .Map_Type}
    case .Struct:
        return parse_struct_type(p)
    case .Union:
        return parse_union_type(p)
    case .Enum:
        return parse_enum_type(p)
    case .Bit_Set:
        open(p, .Bit_Set_Type)
        bump(p)
        expect(p, .Open_Bracket)
        prev_range := p.allow_range
        p.allow_range = true
        parse_expr(p, false)
        p.allow_range = prev_range
        if allow(p, .Semicolon) {
            parse_type(p)
        }
        expect(p, .Close_Bracket)
        close(p)
        return {kind = .Bit_Set_Type}
    case .Matrix:
        open(p, .Matrix_Type)
        bump(p)
        expect(p, .Open_Bracket)
        parse_expr(p, false)
        expect(p, .Comma)
        parse_expr(p, false)
        expect(p, .Close_Bracket)
        parse_type(p)
        close(p)
        return {kind = .Matrix_Type}
    case .Bit_Field:
        return parse_bit_field_type(p)
    case .Asm:
        return parse_asm(p)
    }
    return {}
}

// `#name ...` in an expression.
@(private)
parse_directive_operand :: proc(p: ^Parser, lhs: bool) -> Expr {
    cp := mark(p)
    name := parse_directive(p)
    switch name {
    case "type":
        parse_type(p)
        wrap(p, cp, .Helper_Type)
        return {kind = .Helper_Type}
    case "file", "directory", "line", "procedure", "caller_location":
        return {kind = .Directive}
    case "caller_expression":
        if at(p) == .Open_Paren {
            return parse_call_expr(p, cp, {kind = .Directive})
        }
        return {kind = .Directive}
    case "location", "exists", "load", "load_or", "load_directory", "load_hash", "hash", "assert", "panic",
         "defined", "config":
        return parse_call_expr(p, cp, {kind = .Directive})
    case "soa", "simd", "sparse":
        t := parse_type(p)
        wrap(p, cp, .Tag_Expr)
        return {kind = .Tag_Expr, inner = unparen(t)}
    case "relative":
        parse_call_expr(p, cp, {kind = .Directive})
        t := parse_type(p)
        wrap(p, cp, .Tag_Expr)
        return {kind = .Tag_Expr, inner = unparen(t)}
    case "force_inline", "force_no_inline":
        e := parse_unary_expr(p, lhs)
        wrap(p, cp, .Tag_Expr)
        return {kind = .Tag_Expr, inner = unparen(e)}
    }
    e := parse_expr(p, lhs)
    wrap(p, cp, .Tag_Expr)
    return {kind = .Tag_Expr, inner = unparen(e)}
}
