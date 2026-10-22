package odinsyntax

@(private)
Stmt_Flag :: enum {
    In,    // `a, b in x` is a range clause
    Label, // `name:` before a block, `if`, `for` or `switch` is a label
}

@(private)
Stmt_Flags :: distinct bit_set[Stmt_Flag]

// Root: file tags, the package clause, then declarations until EOF.
@(private)
parse_file :: proc(p: ^Parser) {
    builder_start_node(&p.b, .Root)
    for at(p) == .File_Tag {
        leaf(p, .File_Tag)
    }
    if at(p) == .Package {
        cp := mark(p)
        bump(p)
        parse_ident(p)
        finish_stmt(p, cp, .Package_Decl)
        expect_semicolon(p, false)
    } else if at(p) != .EOF {
        error_here(p, .Expected_Package)
    }
    for at(p) != .EOF {
        before := progress(p)
        parse_stmt(p)
        if progress(p) == before {
            error_here(p, .Expected_Stmt)
            bump_error(p, force = true)
        }
    }
    for p.emitted < len(p.toks) {
        emit(p, p.emitted)
        p.emitted += 1
    }
    close(p)
}

// Where the cursor is, to tell whether a parse took a token.
@(private)
progress :: proc(p: ^Parser) -> [2]int {
    return {p.cur, int(p.kind) | (int(p.eof_semi) << 8)}
}

// Statements until `case`, `}` or EOF.
@(private)
parse_stmt_list :: proc(p: ^Parser) {
    for at(p) != .Case && at(p) != .Close_Brace && at(p) != .EOF {
        before := progress(p)
        parse_stmt(p)
        if progress(p) == before {
            error_here(p, .Expected_Stmt)
            bump_error(p)
        }
    }
}

// Closes a statement node from `cp`; `end` defaults to everything taken so far.
@(private)
finish_stmt :: proc(p: ^Parser, cp: int, kind: Syntax_Kind, end := -1) {
    stop := mark_end(p) if end < 0 else end
    wrap_range(p, cp, stop, kind)
    p.last_stmt_end = cp + 1
}

// The end of a statement whose last part is a nested statement or body.
@(private)
nested_end :: proc(p: ^Parser, cp: int) -> int {
    return clamp(p.last_stmt_end, cp + 1, mark_end(p))
}

// Takes the ';' after a statement. `strict` statements need one on the same line.
@(private)
expect_semicolon :: proc(p: ^Parser, strict: bool) -> bool {
    if allow(p, .Semicolon) || p.prev_kind == .Semicolon || at(p) == .EOF {
        return true
    }
    #partial switch at(p) {
    case .Close_Brace, .Close_Paren, .Else:
        return true
    }
    if !strict || newline_before(p) {
        return true
    }
    error_here(p, .Expected_Token, .Semicolon)
    recover_stmt(p)
    return false
}

// One statement. `start` is a checkpoint before attributes, a label or directives that
// belong to it, or -1. Returns the kind of the node built.
@(private)
parse_stmt :: proc(p: ^Parser, start := -1) -> Syntax_Kind {
    if !enter(p) {
        return .Error
    }
    defer leave(p)

    #partial switch at(p) {
    case .Context, .Proc, .Ident, .Integer, .Float, .Imag, .Rune, .String, .Open_Paren, .Pointer, .Asm,
         .Add, .Sub, .Xor, .Not, .And, .Increment, .Decrement:
        cp := start if start >= 0 else mark(p)
        kind := parse_simple_stmt(p, {.Label}, cp)
        #partial switch kind {
        case .Expr_Stmt:
            finish_stmt(p, cp, .Expr_Stmt)
            expect_semicolon(p, false)
        case .Assign_Stmt:
            expect_semicolon(p, false)
        case .Value_Decl:
            expect_semicolon(p, false)
        }
        return kind

    case .Foreign: return parse_foreign_decl(p, start)
    case .Import:  return parse_import_decl(p, start)
    case .If:      return parse_if_stmt(p, start)
    case .When:    return parse_when_stmt(p, start)
    case .For:     return parse_for_stmt(p, start)
    case .Switch:  return parse_switch_stmt(p, start)

    case .Defer:
        cp := start if start >= 0 else mark(p)
        bump(p)
        #partial switch at(p) {
        case .Semicolon, .Defer, .Return:
            error_here(p, .Not_Allowed)
        }
        p.last_stmt_end = -1
        parse_stmt(p)
        finish_stmt(p, cp, .Defer_Stmt, nested_end(p, cp))
        return .Defer_Stmt

    case .Return:
        cp := start if start >= 0 else mark(p)
        if p.expr_level > 0 {
            error_here(p, .Not_Allowed)
        }
        bump(p)
        if at(p) != .Semicolon && at(p) != .Close_Brace && at(p) != .EOF {
            lcp := mark(p)
            for {
                parse_expr(p, false)
                if !allow(p, .Comma) || at(p) == .Semicolon || at(p) == .Close_Brace {
                    break
                }
            }
            wrap(p, lcp, .Expr_List)
        }
        finish_stmt(p, cp, .Return_Stmt)
        expect_semicolon(p, false)
        return .Return_Stmt

    case .Break, .Continue, .Fallthrough:
        cp := start if start >= 0 else mark(p)
        fallthrough_tok := at(p) == .Fallthrough
        bump(p)
        if !fallthrough_tok && at(p) == .Ident {
            parse_ident(p)
        }
        finish_stmt(p, cp, .Branch_Stmt)
        expect_semicolon(p, false)
        return .Branch_Stmt

    case .Using:
        cp := start if start >= 0 else mark(p)
        bump(p)
        if at(p) == .Import {
            return parse_import_decl(p, cp)
        }
        lcp := mark(p)
        parse_expr_list(p, true)
        if at(p) != .Colon {
            wrap(p, lcp, .Expr_List)
            finish_stmt(p, cp, .Using_Stmt)
            expect_semicolon(p, false)
            return .Using_Stmt
        }
        names_end := mark_end(p)
        bump(p)
        parse_value_decl(p, cp, lcp, names_end)
        return .Value_Decl

    case .At:
        cp := start if start >= 0 else mark(p)
        parse_attribute(p)
        skip_newline(p)
        kind := parse_stmt(p, cp)
        #partial switch kind {
        case .Value_Decl, .Foreign_Block, .Foreign_Import_Decl, .Import_Decl, .Error:
        case:
            error_at(p, p.prev_end, p.prev_end, .Expected_Decl)
        }
        return kind

    case .Hash:
        return parse_directive_stmt(p, start)

    case .Open_Brace:
        if p.in_proc == 0 {
            error_here(p, .Not_Allowed)
        }
        return parse_body(p, start)

    case .Semicolon:
        bump(p)
        if start >= 0 {
            finish_stmt(p, start, .Error)
            return .Error
        }
        return .None

    case .Else:
        error_here(p, .Unexpected_Token)
        cp := start if start >= 0 else mark(p)
        bump(p)
        #partial switch at(p) {
        case .If:         parse_if_stmt(p)
        case .When:       parse_when_stmt(p)
        case .Open_Brace: parse_body(p)
        case .Do:         parse_do_body(p)
        case:             recover_stmt(p)
        }
        finish_stmt(p, cp, .Error, nested_end(p, cp))
        return .Error
    }

    error_here(p, .Expected_Stmt)
    cp := start if start >= 0 else mark(p)
    bump_error(p)
    recover_stmt(p)
    if mark_end(p) > cp {
        finish_stmt(p, cp, .Error)
    }
    return .Error
}

// `#name` before a statement: a prefix of it, or a directive call.
@(private)
parse_directive_stmt :: proc(p: ^Parser, start: int) -> Syntax_Kind {
    dcp := mark(p)
    cp := start if start >= 0 else dcp
    name := parse_directive(p)
    switch name {
    case "bounds_check", "no_bounds_check", "type_assert", "no_type_assert":
        return parse_stmt(p, cp)
    case "partial":
        kind := parse_stmt(p, cp)
        if kind != .Switch_Stmt && kind != .Type_Switch_Stmt && kind != .Error {
            error_at(p, p.prev_end, p.prev_end, .Bad_Directive)
        }
        return kind
    case "reverse":
        kind := parse_stmt(p, cp)
        if kind != .Range_Stmt && kind != .Error {
            error_at(p, p.prev_end, p.prev_end, .Bad_Directive)
        }
        return kind
    case "assert", "panic":
        parse_call_expr(p, dcp, {kind = .Directive})
        finish_stmt(p, cp, .Expr_Stmt)
        expect_semicolon(p, false)
        return .Expr_Stmt
    case "force_inline", "force_no_inline", "must_tail":
        parse_unary_expr(p, true)
        wrap(p, dcp, .Tag_Expr)
        finish_stmt(p, cp, .Expr_Stmt)
        expect_semicolon(p, false)
        return .Expr_Stmt
    case "unroll":
        return parse_unrolled_for(p, cp)
    case "include":
        error_at(p, p.prev_end, p.prev_end, .Bad_Directive)
        finish_stmt(p, cp, .Error)
        return .Error
    }
    return parse_stmt(p, cp)
}

// `#name` as a Directive node; returns the name, "" when it is missing.
@(private)
parse_directive :: proc(p: ^Parser) -> string {
    open(p, .Directive)
    bump(p)
    name := ""
    if at(p) == .Ident {
        name = cur_text(p)
    }
    expect(p, .Ident)
    close(p)
    return name
}

// A lhs expression list and what follows it: assignment, declaration, label, range clause
// or a bare expression. A bare expression is left unwrapped (.Expr_Stmt) for the caller;
// a range clause (.Range_Stmt) is left unwrapped too.
@(private)
parse_simple_stmt :: proc(p: ^Parser, flags: Stmt_Flags, stmt_cp: int) -> Syntax_Kind {
    lcp := mark(p)
    n := parse_expr_list(p, true)
    op := at(p)
    switch {
    case is_assignment_op(op):
        wrap(p, lcp, .Expr_List)
        bump(p)
        rcp := mark(p)
        if at(p) == .Semicolon || at(p) == .EOF || at(p) == .Close_Brace {
            error_here(p, .Expected_Expr)
        } else {
            parse_expr_list(p, false)
            wrap(p, rcp, .Expr_List)
        }
        finish_stmt(p, stmt_cp, .Assign_Stmt)
        return .Assign_Stmt

    case op == .In && .In in flags:
        wrap(p, lcp, .Expr_List)
        bump(p)
        prev_range := p.allow_range
        p.allow_range = true
        parse_expr(p, false)
        p.allow_range = prev_range
        return .Range_Stmt

    case op == .Colon:
        names_end := mark_end(p)
        bump(p)
        if .Label in flags && n == 1 {
            label_end := mark_end(p)
            if at(p) == .Hash {
                name_kind, name_tok := lookahead(p, 1)
                next, _ := lookahead(p, 2)
                if name_kind == .Ident {
                    name := token_text(p.src, name_tok)
                    if (name == "partial" && next == .Switch) || (name == "reverse" && next == .For) {
                        parse_directive(p)
                    }
                }
            }
            #partial switch at(p) {
            case .Open_Brace, .If, .For, .Switch:
                wrap_range(p, lcp, label_end, .Label)
                return parse_stmt(p, stmt_cp)
            }
        }
        parse_value_decl(p, stmt_cp, lcp, names_end)
        return .Value_Decl
    }

    if n > 1 {
        error_here(p, .Expected_Token, .Eq)
        wrap(p, lcp, .Expr_List)
    }
    #partial switch op {
    case .Increment, .Decrement:
        error_here(p, .Not_Allowed)
        bump(p)
    }
    return .Expr_Stmt
}

@(private)
is_assignment_op :: proc(kind: Token_Kind) -> bool {
    #partial switch kind {
    case .Eq, .Add_Eq, .Sub_Eq, .Mul_Eq, .Quo_Eq, .Mod_Eq, .Mod_Mod_Eq, .And_Eq, .Or_Eq,
         .Xor_Eq, .And_Not_Eq, .Shl_Eq, .Shr_Eq, .Cmp_And_Eq, .Cmp_Or_Eq:
        return true
    }
    return false
}

// The rest of `names : [type] [(=|:) values]`; the ':' is taken. Names are [lcp, names_end).
@(private)
parse_value_decl :: proc(p: ^Parser, stmt_cp, lcp, names_end: int) {
    wrap_range(p, lcp, names_end, .Name_List)
    has_type := parse_type_or_ident(p).kind != .None
    mutable := true
    values := 0
    missing_value := false
    #partial switch at(p) {
    case .Eq, .Colon:
        mutable = at(p) != .Colon
        bump(p)
        if at(p) == .Semicolon || at(p) == .EOF || at(p) == .Close_Brace || at(p) == .Close_Paren || starts_decl_on_next_line(p) {
            error_at(p, p.prev_end, p.prev_end, .Expected_Expr, found = .Newline if newline_before(p) else at(p))
            missing_value = true
        } else {
            vcp := mark(p)
            values = parse_expr_list(p, false)
            wrap(p, vcp, .Expr_List)
        }
    }
    if !has_type && values == 0 && !missing_value && at(p) != .Semicolon && at(p) != .EOF && !newline_before(p) {
        error_here(p, .Expected_Type)
    }
    finish_stmt(p, stmt_cp, .Value_Decl)
    if p.expr_level >= 0 {
        if at(p) == .Close_Brace && !newline_before(p) {
            return
        }
        expect_semicolon(p, mutable || values == 0)
    }
}

// Reports whether the current token starts `name :` on a later line: a declaration after
// a value that was never written, not the value.
@(private)
starts_decl_on_next_line :: proc(p: ^Parser) -> bool {
    if at(p) != .Ident || !newline_before(p) {
        return false
    }
    next, _ := lookahead(p, 1)
    return next == .Colon
}

// Expressions separated by commas; returns how many.
@(private)
parse_expr_list :: proc(p: ^Parser, lhs: bool) -> int {
    n := 0
    for {
        parse_expr(p, lhs)
        n += 1
        if at(p) != .Comma {
            break
        }
        bump(p)
    }
    return n
}

// `@(name, name = value)` or `@name`.
@(private)
parse_attribute :: proc(p: ^Parser) {
    open(p, .Attribute)
    bump(p)
    if at(p) == .Ident {
        parse_ident(p)
    } else if expect(p, .Open_Paren) {
        p.expr_level += 1
        for at(p) != .Close_Paren && at(p) != .EOF {
            ecp := mark(p)
            if !parse_ident(p) {
                break
            }
            if allow(p, .Eq) {
                parse_value(p)
                wrap(p, ecp, .Field_Value)
            }
            if !allow(p, .Comma) {
                break
            }
        }
        p.expr_level -= 1
        expect_closing(p, .Close_Paren)
    }
    close(p)
}

@(private)
parse_import_decl :: proc(p: ^Parser, start: int) -> Syntax_Kind {
    cp := start if start >= 0 else mark(p)
    if p.in_proc > 0 {
        error_here(p, .Not_Allowed)
    }
    bump(p)
    if at(p) == .Ident {
        parse_ident(p)
    }
    expect(p, .String)
    finish_stmt(p, cp, .Import_Decl)
    expect_semicolon(p, false)
    return .Import_Decl
}

// `foreign import ...` or a `foreign [lib] { ... }` block.
@(private)
parse_foreign_decl :: proc(p: ^Parser, start: int) -> Syntax_Kind {
    cp := start if start >= 0 else mark(p)
    bump(p)
    #partial switch at(p) {
    case .Ident, .Open_Brace:
        if at(p) == .Ident {
            parse_ident(p)
        }
        skip_newline_for_literal(p)
        open(p, .Block)
        if expect(p, .Open_Brace) {
            for at(p) != .Close_Brace && at(p) != .EOF {
                before := progress(p)
                #partial switch kind := parse_stmt(p); kind {
                case .None, .Error, .When_Stmt, .Value_Decl:
                case:
                    error_at(p, p.prev_end, p.prev_end, .Not_Allowed)
                }
                if progress(p) == before {
                    error_here(p, .Expected_Decl)
                    bump_error(p)
                }
            }
            expect(p, .Close_Brace)
        }
        close(p)
        finish_stmt(p, cp, .Foreign_Block)
        return .Foreign_Block

    case .Import:
        bump(p)
        if at(p) == .Ident {
            parse_ident(p)
        }
        if allow(p, .Open_Brace) {
            for at(p) != .Close_Brace && at(p) != .EOF {
                parse_expr(p, false)
                if !allow(p, .Comma) {
                    break
                }
            }
            expect(p, .Close_Brace)
        } else {
            expect(p, .String)
        }
        finish_stmt(p, cp, .Foreign_Import_Decl)
        expect_semicolon(p, false)
        return .Foreign_Import_Decl
    }
    error_here(p, .Expected_Token, .Import)
    finish_stmt(p, cp, .Error)
    return .Error
}

// `{ statements }`. A missing '{' parses no statements, so one typo cannot take the file.
// A body parses the same in any context but `in_proc`, which lets `reparse` parse one alone.
@(private)
parse_body :: proc(p: ^Parser, start := -1) -> Syntax_Kind {
    prev_level, prev_range, prev_in, prev_type := p.expr_level, p.allow_range, p.allow_in_expr, p.allow_type
    p.expr_level = 0
    p.allow_range, p.allow_in_expr, p.allow_type = false, false, false
    defer {
        p.expr_level, p.allow_range, p.allow_in_expr, p.allow_type = prev_level, prev_range, prev_in, prev_type
    }
    cp := start if start >= 0 else mark(p)
    if expect(p, .Open_Brace) {
        parse_stmt_list(p)
        expect(p, .Close_Brace)
    }
    finish_stmt(p, cp, .Block)
    return .Block
}

// Parses the tokens as one body alone, for `reparse`; false when they are not one whole body.
// Leaves the builder empty.
@(private)
parse_block_only :: proc(p: ^Parser, in_proc: bool) -> (block: Green_Element, ok: bool) {
    p.in_proc = 1 if in_proc else 0
    // An open frame, as in parse_file, so the nodes inside the body go to their parents.
    builder_start_node(&p.b, .Root)
    parse_body(p)
    ok = p.alloc_err == nil && len(p.b.stack) == 1 && len(p.b.children) == 1
    if ok {
        block = p.b.children[0]
    }
    clear(&p.b.stack)
    clear(&p.b.children)
    return
}

@(private)
parse_block_stmt :: proc(p: ^Parser, is_when: bool) {
    skip_newline_for_literal(p)
    if !is_when && p.in_proc == 0 && at(p) == .Open_Brace {
        error_here(p, .Not_Allowed)
    }
    parse_body(p)
}

// `do` and one statement.
@(private)
parse_do_body :: proc(p: ^Parser) {
    cp := mark(p)
    bump(p)
    #partial switch at(p) {
    case .Open_Brace, .Semicolon:
        error_here(p, .Expected_Stmt)
    }
    p.last_stmt_end = -1
    if at(p) != .Semicolon {
        parse_stmt(p)
    }
    finish_stmt(p, cp, .Do_Body, nested_end(p, cp))
}

// Takes the ';' between a control clause's init statement and its condition.
@(private)
control_separator :: proc(p: ^Parser) -> bool {
    next, _ := lookahead(p, 1)
    if next != .Open_Brace {
        return allow(p, .Semicolon)
    }
    if at(p) == .Semicolon && !at_newline(p) {
        return allow(p, .Semicolon)
    }
    return false
}

@(private)
parse_if_stmt :: proc(p: ^Parser, start := -1) -> Syntax_Kind {
    cp := start if start >= 0 else mark(p)
    bump(p)
    prev_level, prev_in := p.expr_level, p.allow_in_expr
    p.expr_level = -1
    p.allow_in_expr = true
    has_cond := false
    if allow(p, .Semicolon) {
        has_cond = parse_expr(p, false).kind != .None
    } else {
        icp := mark(p)
        kind := parse_simple_stmt(p, {}, icp)
        if control_separator(p) {
            if kind == .Expr_Stmt {
                finish_stmt(p, icp, .Expr_Stmt)
            }
            has_cond = parse_expr(p, false).kind != .None
        } else {
            has_cond = true
            if kind != .Expr_Stmt {
                error_here(p, .Expected_Expr)
            }
        }
    }
    p.expr_level, p.allow_in_expr = prev_level, prev_in
    if !has_cond {
        error_here(p, .Expected_Expr)
    }
    parse_if_body(p)
    skip_newline_for_literal(p)
    if allow(p, .Else) {
        #partial switch at(p) {
        case .If:         parse_if_stmt(p)
        case .Open_Brace: parse_block_stmt(p, false)
        case .Do:         parse_do_body(p)
        case:             error_here(p, .Expected_Stmt)
        }
    }
    finish_stmt(p, cp, .If_Stmt, nested_end(p, cp))
    return .If_Stmt
}

@(private)
parse_if_body :: proc(p: ^Parser, is_when := false) {
    if at(p) == .Do {
        parse_do_body(p)
    } else {
        parse_block_stmt(p, is_when)
    }
}

@(private)
parse_when_stmt :: proc(p: ^Parser, start := -1) -> Syntax_Kind {
    cp := start if start >= 0 else mark(p)
    bump(p)
    prev_level, prev_in := p.expr_level, p.allow_in_expr
    p.expr_level = -1
    p.allow_in_expr = true
    cond := parse_expr(p, false)
    p.expr_level, p.allow_in_expr = prev_level, prev_in
    if cond.kind == .None {
        error_here(p, .Expected_Expr)
    }
    parse_if_body(p, true)
    skip_newline_for_literal(p)
    if allow(p, .Else) {
        #partial switch at(p) {
        case .When:       parse_when_stmt(p)
        case .Open_Brace: parse_block_stmt(p, true)
        case .Do:         parse_do_body(p)
        case:             error_here(p, .Expected_Stmt)
        }
    }
    finish_stmt(p, cp, .When_Stmt, nested_end(p, cp))
    return .When_Stmt
}

@(private)
parse_for_stmt :: proc(p: ^Parser, start := -1) -> Syntax_Kind {
    if p.in_proc == 0 {
        error_here(p, .Not_Allowed)
    }
    cp := start if start >= 0 else mark(p)
    bump(p)
    is_range := false
    cond_kind := Syntax_Kind.None

    general: if at(p) != .Open_Brace && at(p) != .Do {
        prev_level := p.expr_level
        defer p.expr_level = prev_level
        p.expr_level = -1

        if at(p) == .In {
            bump(p)
            prev_range := p.allow_range
            p.allow_range = true
            parse_expr(p, false)
            p.allow_range = prev_range
            p.expr_level = prev_level
            parse_loop_body(p, false)
            finish_stmt(p, cp, .Range_Stmt, nested_end(p, cp))
            return .Range_Stmt
        }

        ccp := mark(p)
        if at(p) != .Semicolon {
            cond_kind = parse_simple_stmt(p, {.In}, ccp)
            is_range = cond_kind == .Range_Stmt
        }
        if !is_range && control_separator(p) {
            if cond_kind == .Expr_Stmt {
                finish_stmt(p, ccp, .Expr_Stmt)
            }
            cond_kind = .None
            if at(p) == .Open_Brace || at(p) == .Do {
                error_here(p, .Expected_Token, .Semicolon)
                break general
            }
            if at(p) != .Semicolon {
                if at(p) == .Ident {
                    next, _ := lookahead(p, 1)
                    if next == .In || next == .Comma {
                        cond_kind = parse_simple_stmt(p, {.In}, mark(p))
                        is_range = cond_kind == .Range_Stmt
                        break general
                    }
                }
                cond_kind = parse_simple_stmt(p, {}, mark(p))
            }
            if at(p) != .Semicolon || at_newline(p) {
                error_here(p, .Expected_Token, .Semicolon)
            } else {
                bump(p)
            }
            if at(p) != .Open_Brace && at(p) != .Do {
                pcp := mark(p)
                if parse_simple_stmt(p, {}, pcp) == .Expr_Stmt {
                    finish_stmt(p, pcp, .Expr_Stmt)
                }
            }
        }
    }

    if !is_range && cond_kind != .None && cond_kind != .Expr_Stmt {
        error_at(p, p.prev_end, p.prev_end, .Expected_Expr)
    }
    parse_loop_body(p, true)
    finish_stmt(p, cp, .Range_Stmt if is_range else .For_Stmt, nested_end(p, cp))
    return .Range_Stmt if is_range else .For_Stmt
}

@(private)
parse_loop_body :: proc(p: ^Parser, allow_semi: bool) {
    if at(p) == .Do {
        parse_do_body(p)
        return
    }
    if allow_semi {
        allow(p, .Semicolon)
    }
    parse_body(p)
}

// `#unroll[(args)] for a[, b] in x body`; the directive is taken.
@(private)
parse_unrolled_for :: proc(p: ^Parser, cp: int) -> Syntax_Kind {
    if at(p) == .Open_Paren {
        open(p, .Arg_List)
        bump(p)
        p.expr_level += 1
        for at(p) != .Close_Paren && at(p) != .EOF {
            acp := mark(p)
            parse_value(p)
            if allow(p, .Eq) {
                parse_value(p)
                wrap(p, acp, .Field_Value)
            }
            if !allow(p, .Comma) {
                break
            }
        }
        p.expr_level -= 1
        expect(p, .Close_Paren)
        close(p)
    }
    expect(p, .For)
    if at(p) != .In {
        lcp := mark(p)
        parse_ident_list(p, false)
        wrap(p, lcp, .Expr_List)
    }
    expect(p, .In)
    prev_range, prev_level := p.allow_range, p.expr_level
    p.allow_range = true
    p.expr_level = -1
    parse_expr(p, false)
    p.expr_level = prev_level
    p.allow_range = prev_range
    if at(p) == .Do {
        parse_do_body(p)
    } else {
        parse_block_stmt(p, false)
    }
    finish_stmt(p, cp, .Range_Stmt, nested_end(p, cp))
    return .Range_Stmt
}

@(private)
parse_switch_stmt :: proc(p: ^Parser, start := -1) -> Syntax_Kind {
    cp := start if start >= 0 else mark(p)
    bump(p)
    is_type := false
    if at(p) != .Open_Brace {
        prev_level := p.expr_level
        p.expr_level = -1
        if at(p) == .In {
            bump(p)
            is_type = true
            parse_expr(p, true)
        } else {
            tcp := mark(p)
            kind := parse_simple_stmt(p, {.In}, tcp)
            if kind == .Range_Stmt {
                is_type = true
            } else if control_separator(p) {
                if kind == .Expr_Stmt {
                    finish_stmt(p, tcp, .Expr_Stmt)
                }
                if at(p) != .Open_Brace {
                    parse_simple_stmt(p, {}, mark(p))
                }
            }
        }
        p.expr_level = prev_level
    }
    skip_newline(p)
    bcp := mark(p)
    if expect(p, .Open_Brace) {
        for at(p) != .Close_Brace && at(p) != .EOF {
            if at(p) == .Case {
                parse_case_clause(p, is_type)
                continue
            }
            error_here(p, .Expected_Token, .Case)
            before := progress(p)
            recover_stmt(p)
            if progress(p) == before {
                bump_error(p)
            }
        }
        expect(p, .Close_Brace)
    }
    finish_stmt(p, bcp, .Block)
    kind := Syntax_Kind.Type_Switch_Stmt if is_type else .Switch_Stmt
    finish_stmt(p, cp, kind)
    return kind
}

@(private)
parse_case_clause :: proc(p: ^Parser, is_type: bool) {
    open(p, .Case_Clause)
    bump(p)
    if at(p) != .Colon {
        prev_range, prev_in := p.allow_range, p.allow_in_expr
        p.allow_range, p.allow_in_expr = !is_type, !is_type
        lcp := mark(p)
        parse_expr_list(p, false)
        wrap(p, lcp, .Expr_List)
        p.allow_range, p.allow_in_expr = prev_range, prev_in
    }
    expect(p, .Colon)
    parse_stmt_list(p)
    close(p)
}
