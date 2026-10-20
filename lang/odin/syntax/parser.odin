package odinsyntax

import "core:fmt"
import "core:mem"
import "core:strings"

// What a syntax error reports.
Error_Code :: enum u8 {
    Expected_Token,
    Expected_Expr,
    Expected_Type,
    Expected_Stmt,
    Expected_Decl,
    Expected_Package,
    Expected_Selector,
    Expected_Operand,
    Unexpected_Token,
    Too_Deep,
    Unterminated,
    Malformed,
    Bad_Directive,
    Not_Allowed,
}

// A syntax error over the byte range [offset, end).
Syntax_Error :: struct {
    offset:   u32,
    end:      u32,
    code:     Error_Code,
    expected: Token_Kind, // for Expected_Token
    found:    Token_Kind,
}

// A parsed file: the tree and its syntax errors. Both live in the tree arena.
Parse :: struct {
    tree:   ^Green_Tree,
    errors: []Syntax_Error,
}

// Parses `src`. Never fails on bad input; the error is an allocation failure only.
parse :: proc(src: string, allocator := context.allocator) -> (result: Parse, err: mem.Allocator_Error) {
    tree := tree_create(src, allocator) or_return
    toks := lex_all(src, context.temp_allocator)
    p: Parser
    parser_init(&p, src, toks, tree)
    defer parser_destroy(&p)
    parse_file(&p)
    if p.alloc_err == nil {
        result.errors, p.alloc_err = make([]Syntax_Error, len(p.errors), tree_allocator(tree))
        if p.alloc_err == nil {
            copy(result.errors, p.errors[:])
        }
    }
    if p.alloc_err != nil {
        tree_destroy(tree, allocator)
        return {}, p.alloc_err
    }
    result.tree = tree
    return result, nil
}

parse_destroy :: proc(result: ^Parse, allocator := context.allocator) {
    tree_destroy(result.tree, allocator)
    result^ = {}
}

// The text of a syntax error.
error_message :: proc(e: Syntax_Error, allocator := context.allocator) -> string {
    found := token_name(e.found)
    switch e.code {
    case .Expected_Token:    return fmt.aprintf("expected %s, got %s", token_name(e.expected), found, allocator = allocator)
    case .Expected_Expr:     return fmt.aprintf("expected an expression, got %s", found, allocator = allocator)
    case .Expected_Type:     return fmt.aprintf("expected a type, got %s", found, allocator = allocator)
    case .Expected_Stmt:     return fmt.aprintf("expected a statement, got %s", found, allocator = allocator)
    case .Expected_Decl:     return strings.clone("expected a declaration after an attribute", allocator)
    case .Expected_Package:  return strings.clone("expected a package declaration at the start of the file", allocator)
    case .Expected_Selector: return fmt.aprintf("expected a selector, got %s", found, allocator = allocator)
    case .Expected_Operand:  return fmt.aprintf("expected an operand, got %s", found, allocator = allocator)
    case .Unexpected_Token:  return fmt.aprintf("unexpected %s", found, allocator = allocator)
    case .Too_Deep:          return strings.clone("expression nested too deep", allocator)
    case .Unterminated:      return fmt.aprintf("unterminated %s", found, allocator = allocator)
    case .Malformed:         return fmt.aprintf("malformed %s", found, allocator = allocator)
    case .Bad_Directive:     return strings.clone("unknown or misplaced directive", allocator)
    case .Not_Allowed:       return fmt.aprintf("%s is not allowed here", found, allocator = allocator)
    }
    return ""
}

// The spelling of a token kind in a message.
token_name :: proc(kind: Token_Kind) -> string {
    #partial switch kind {
    case .Newline:      return "newline"
    case .EOF:          return "end of file"
    case .Ident:        return "identifier"
    case .Integer:      return "integer"
    case .Float:        return "float"
    case .Imag:         return "imaginary number"
    case .Rune:         return "rune"
    case .String:       return "string"
    case .File_Tag:     return "file tag"
    case .Error:        return "invalid character"
    case .Block_Comment: return "block comment"
    }
    if text := TOKEN_TEXT[kind]; text != "" {
        return fmt.tprintf("'%s'", text)
    }
    return fmt.tprint(kind)
}

@(private)
MAX_DEPTH :: 400

@(private)
FUEL :: 4096

@(private)
Parser :: struct {
    src:           string,
    toks:          []Token,
    b:             Green_Builder,
    errors:        [dynamic]Syntax_Error, // owned
    alloc_err:     mem.Allocator_Error,
    cur:           int,        // index of the current significant token
    kind:          Token_Kind, // its kind; .Semicolon for an implicit one
    emitted:       int,        // toks[:emitted] are in the tree
    prev_end:      u32,        // end of the last significant token taken
    prev_kind:     Token_Kind, // kind of the last significant token taken
    last_stmt_end: int,        // child index after the last statement node
    eof_semi:      bool,       // the implicit ';' at EOF is taken
    open_braces:   int,        // '{' taken minus '}' taken
    fuel:          int,        // peeks left before the parser counts as stuck
    depth:         int,        // nesting and chain links, against MAX_DEPTH
    expr_level:    int,        // >= 0 in an expression, < 0 in a control clause
    allow_range:   bool,
    allow_in_expr: bool,
    allow_type:    bool,
    in_proc:       int, // procedure bodies the parser is inside
}

@(private)
parser_init :: proc(p: ^Parser, src: string, toks: []Token, tree: ^Green_Tree) {
    p.src = src
    p.toks = toks
    builder_init(&p.b, tree)
    p.errors = make([dynamic]Syntax_Error, 0, 16)
    p.cur = -1
    p.fuel = FUEL
    find_next(p, 0)
}

@(private)
parser_destroy :: proc(p: ^Parser) {
    builder_destroy(&p.b)
    delete(p.errors)
}

// Sets `cur` to the first significant token at or after `from`.
@(private)
find_next :: proc(p: ^Parser, from: int) {
    for i := from; i < len(p.toks); i += 1 {
        t := p.toks[i]
        #partial switch t.kind {
        case .EOF:
            p.cur = i
            p.kind = .EOF
            if .Implicit_Semi in t.flags && !p.eof_semi {
                if p.expr_level > 0 {
                    p.eof_semi = true
                } else {
                    p.kind = .Semicolon
                }
            }
            return
        case .Newline:
            if .Implicit_Semi in t.flags && p.expr_level <= 0 {
                p.cur = i
                p.kind = .Semicolon
                return
            }
        case:
            if !token_is_trivia(t.kind) {
                p.cur = i
                p.kind = t.kind
                return
            }
        }
    }
    p.cur = len(p.toks) - 1
    p.kind = .EOF
}

// The kind of the current token.
@(private)
at :: #force_inline proc(p: ^Parser) -> Token_Kind {
    when ODIN_DEBUG {
        p.fuel -= 1
        assert(p.fuel > 0, "odinsyntax: the parser makes no progress")
    }
    return p.kind
}

@(private)
cur_text :: proc(p: ^Parser) -> string {
    if p.kind == .Semicolon && p.toks[p.cur].kind != .Semicolon {
        return "\n"
    }
    return token_text(p.src, p.toks[p.cur])
}

// Reports whether the current token is a ';' the lexer inserted.
@(private)
at_newline :: proc(p: ^Parser) -> bool {
    return p.kind == .Semicolon && p.toks[p.cur].kind != .Semicolon
}

// The kind of the significant token `n` places after the current one.
@(private)
lookahead :: proc(p: ^Parser, n := 1) -> (kind: Token_Kind, tok: Token) {
    save_cur, save_kind, save_eof := p.cur, p.kind, p.eof_semi
    defer {
        p.cur, p.kind, p.eof_semi = save_cur, save_kind, save_eof
    }
    for _ in 0 ..< n {
        if p.kind == .EOF {
            break
        }
        if p.kind == .Semicolon && p.toks[p.cur].kind == .EOF {
            p.eof_semi = true
            find_next(p, p.cur)
        } else {
            find_next(p, p.cur + 1)
        }
    }
    return p.kind, p.toks[p.cur]
}

// Adds token i to the open node.
@(private)
emit :: proc(p: ^Parser, i: int) {
    if p.alloc_err != nil {
        return
    }
    tok := p.toks[i]
    if tok.flags & {.Unterminated, .Malformed} != {} {
        code := Error_Code.Unterminated if .Unterminated in tok.flags else .Malformed
        error_at(p, tok.offset, token_end(tok), code, found = tok.kind)
    }
    builder_token(&p.b, tok.kind, tok.flags, tok.len)
}

// Puts the trivia before the current token into the open node.
@(private)
flush_trivia :: proc(p: ^Parser) {
    for p.emitted < p.cur {
        emit(p, p.emitted)
        p.emitted += 1
    }
}

// Takes the current token into the open node.
@(private)
bump :: proc(p: ^Parser) {
    p.fuel = FUEL
    tok := p.toks[p.cur]
    if tok.kind == .EOF {
        if p.kind == .Semicolon {
            p.eof_semi = true
            p.prev_end = tok.offset
            p.prev_kind = .Semicolon
            find_next(p, p.cur)
        }
        return
    }
    flush_trivia(p)
    emit(p, p.cur)
    p.emitted = p.cur + 1
    #partial switch tok.kind {
    case .Open_Brace:  p.open_braces += 1
    case .Close_Brace: p.open_braces -= 1
    }
    p.prev_end = token_end(tok)
    p.prev_kind = p.kind
    find_next(p, p.cur + 1)
}

// Takes the current token when it is `kind`.
@(private)
allow :: proc(p: ^Parser, kind: Token_Kind) -> bool {
    if at(p) == kind {
        bump(p)
        return true
    }
    return false
}

// Takes `kind`, or reports it missing and takes nothing.
@(private)
expect :: proc(p: ^Parser, kind: Token_Kind) -> bool {
    if allow(p, kind) {
        return true
    }
    error_here(p, .Expected_Token, kind)
    return false
}

// Skips an implicit ';' (core:odin/parser `skip_possible_newline`).
@(private)
skip_newline :: proc(p: ^Parser) -> bool {
    if at_newline(p) {
        bump(p)
        return true
    }
    return false
}

// Skips an implicit ';' that has `{`, `else` or `where` on the next line.
@(private)
skip_newline_for_literal :: proc(p: ^Parser) -> bool {
    if !at_newline(p) || p.toks[p.cur].kind == .EOF {
        return false
    }
    kind, tok := lookahead(p)
    #partial switch kind {
    case .Open_Brace, .Else, .Where:
        line_end := token_end(p.toks[p.cur])
        if tok.offset >= line_end && strings.index_byte(p.src[line_end:tok.offset], '\n') < 0 {
            bump(p)
            return true
        }
    }
    return false
}

// Reports whether a newline separates the last token taken from the current one.
@(private)
newline_before :: proc(p: ^Parser) -> bool {
    start := p.toks[p.cur].offset
    if start <= p.prev_end {
        return false
    }
    return strings.index_byte(p.src[p.prev_end:start], '\n') >= 0
}

// Opens a node at the current token; leading trivia stays in the parent.
@(private)
open :: proc(p: ^Parser, kind: Syntax_Kind) {
    flush_trivia(p)
    builder_start_node(&p.b, kind)
}

// Opens a node at `start` when it is a checkpoint, else at the current token.
@(private)
open_at :: proc(p: ^Parser, start: int, kind: Syntax_Kind) {
    if start < 0 {
        open(p, kind)
    } else {
        builder_start_node_at(&p.b, start, kind)
    }
}

@(private)
close :: proc(p: ^Parser) {
    if err := builder_finish_node(&p.b); err != nil && p.alloc_err == nil {
        p.alloc_err = err
    }
}

// A checkpoint at the current token.
@(private)
mark :: proc(p: ^Parser) -> int {
    flush_trivia(p)
    return builder_checkpoint(&p.b)
}

// The end of what is in the open node so far, for `wrap`.
@(private)
mark_end :: #force_inline proc(p: ^Parser) -> int {
    return builder_checkpoint(&p.b)
}

// Puts everything taken since checkpoint `start` into one node.
@(private)
wrap :: proc(p: ^Parser, start: int, kind: Syntax_Kind) {
    wrap_range(p, start, builder_checkpoint(&p.b), kind)
}

@(private)
wrap_range :: proc(p: ^Parser, start, end: int, kind: Syntax_Kind) {
    if err := builder_wrap(&p.b, start, end, kind); err != nil && p.alloc_err == nil {
        p.alloc_err = err
    }
}

@(private)
error_at :: proc(p: ^Parser, offset, end: u32, code: Error_Code, expected := Token_Kind.Error, found := Token_Kind.Error) {
    if n := len(p.errors); n > 0 && p.errors[n - 1].offset == offset {
        return
    }
    append(&p.errors, Syntax_Error{offset, end, code, expected, found})
}

// Reports an error at the current token; an implicit ';' reports right after the last token.
@(private)
error_here :: proc(p: ^Parser, code: Error_Code, expected := Token_Kind.Error) {
    tok := p.toks[p.cur]
    if p.kind == .Semicolon && tok.kind != .Semicolon || tok.kind == .EOF {
        found := Token_Kind.EOF if tok.kind == .EOF else Token_Kind.Newline
        error_at(p, p.prev_end, p.prev_end, code, expected, found)
        return
    }
    error_at(p, tok.offset, token_end(tok), code, expected, tok.kind)
}

// Takes the current token into an Error node; never EOF, and a '}' that closes an open brace only when orce.
@(private)
bump_error :: proc(p: ^Parser, force := false) {
    if p.kind == .EOF || (p.kind == .Close_Brace && p.open_braces > 0 && !force) {
        return
    }
    open(p, .Error)
    bump_balanced(p)
    close(p)
}

// Takes the current token, and a whole bracket group when it opens one.
@(private)
bump_balanced :: proc(p: ^Parser) {
    depth := 0
    for p.kind != .EOF {
        #partial switch p.kind {
        case .Open_Paren, .Open_Bracket, .Open_Brace:
            depth += 1
        case .Close_Paren, .Close_Bracket, .Close_Brace:
            if depth == 0 {
                bump(p)
                return
            }
            depth -= 1
        }
        bump(p)
        if depth == 0 {
            return
        }
    }
}

// Reports whether `kind` can start a statement after a bad one.
@(private)
is_stmt_sync :: proc(kind: Token_Kind) -> bool {
    #partial switch kind {
    case .Package, .Foreign, .Import, .If, .For, .When, .Return, .Switch,
         .Defer, .Using, .Break, .Continue, .Fallthrough, .Hash, .At:
        return true
    }
    return false
}

// Skips to the next ';', statement keyword or closing '}', into one Error node.
@(private)
recover_stmt :: proc(p: ^Parser) {
    if done_recovering(p) {
        return
    }
    open(p, .Error)
    for !done_recovering(p) {
        bump_balanced(p)
    }
    close(p)
}

@(private)
done_recovering :: proc(p: ^Parser) -> bool {
    #partial switch p.kind {
    case .EOF, .Semicolon:
        return true
    case .Close_Brace:
        return p.open_braces > 0
    }
    return is_stmt_sync(p.kind)
}

// Enters one level of nesting; false (with an error and a token skipped) when too deep.
@(private)
enter :: proc(p: ^Parser) -> bool {
    p.depth += 1
    if p.depth > MAX_DEPTH {
        error_here(p, .Too_Deep)
        skip_deep(p)
        p.depth -= 1
        return false
    }
    return true
}

// Counts one more link of a postfix or operator chain against the nesting limit, so the
// tree stays as shallow as the limit; false (with the rest skipped) past it.
@(private)
chain_link :: proc(p: ^Parser, links: ^int) -> bool {
    links^ += 1
    p.depth += 1
    if p.depth > MAX_DEPTH {
        error_here(p, .Too_Deep)
        skip_deep(p)
        return false
    }
    return true
}

// Skips the rest of an expression nested too deep, up to a ',', ';' or closing bracket.
@(private)
skip_deep :: proc(p: ^Parser) {
    if deep_stop(p) {
        return
    }
    open(p, .Error)
    for !deep_stop(p) {
        bump_balanced(p)
    }
    close(p)
}

@(private)
deep_stop :: proc(p: ^Parser) -> bool {
    #partial switch p.kind {
    case .EOF, .Semicolon, .Comma, .Close_Paren, .Close_Bracket:
        return true
    case .Close_Brace:
        return p.open_braces > 0
    }
    return false
}

@(private)
leave :: #force_inline proc(p: ^Parser) {
    p.depth -= 1
}
