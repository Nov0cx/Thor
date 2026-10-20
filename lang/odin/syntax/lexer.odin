package odinsyntax

import "core:unicode"
import "core:unicode/utf8"

// A lexer over one source. Rules follow core:odin/tokenizer with semicolon insertion on.
Lexer :: struct {
    src:         string,
    pos:         int,
    insert_semi: bool,
}

// What a lexer carries across a token boundary; enough to restart there.
Lex_State :: struct {
    insert_semi: bool,
}

lexer_init :: proc(l: ^Lexer, src: string, offset := 0, state := Lex_State{}) {
    l.src = src
    l.pos = clamp(offset, 0, len(src))
    l.insert_semi = state.insert_semi
}

lexer_state :: #force_inline proc "contextless" (l: ^Lexer) -> Lex_State {
    return {insert_semi = l.insert_semi}
}

// Lexes all of `src`; the last token is always EOF.
lex_all :: proc(src: string, allocator := context.allocator) -> []Token {
    l: Lexer
    lexer_init(&l, src)
    return lex_rest(&l, allocator)
}

// Lexes from `offset`, which must be a token boundary lexed with `state` before it.
lex_from :: proc(src: string, offset: int, state: Lex_State, allocator := context.allocator) -> []Token {
    l: Lexer
    lexer_init(&l, src, offset, state)
    return lex_rest(&l, allocator)
}

@(private)
lex_rest :: proc(l: ^Lexer, allocator := context.allocator) -> []Token {
    toks := make([dynamic]Token, 0, (len(l.src) - l.pos) / 3 + 1, allocator)
    for {
        tok := lex_next(l)
        append(&toks, tok)
        if tok.kind == .EOF {
            break
        }
    }
    shrink(&toks)
    return toks[:]
}

// Returns the next token, trivia included. Never fails.
lex_next :: proc(l: ^Lexer) -> Token {
    start := l.pos
    tok := Token{offset = u32(start)}
    if start >= len(l.src) {
        tok.kind = .EOF
        if l.insert_semi {
            tok.flags += {.Implicit_Semi}
            l.insert_semi = false
        }
        return tok
    }

    c := l.src[start]
    switch c {
    case ' ', '\t', '\r':
        l.pos += 1
        for l.pos < len(l.src) {
            b := l.src[l.pos]
            if b != ' ' && b != '\t' && b != '\r' {
                break
            }
            l.pos += 1
        }
        return finish(l, &tok, .Whitespace, trivia = true)
    case '\n':
        l.pos += 1
        if l.insert_semi {
            tok.flags += {.Implicit_Semi}
            l.insert_semi = false
        }
        return finish(l, &tok, .Newline, trivia = true)
    case '\\':
        l.pos += 1
        l.insert_semi = false
        return finish(l, &tok, .Line_Continuation, trivia = true)
    case '/':
        if n := peek(l, 1); n == '/' {
            scan_line_comment(l)
            return finish(l, &tok, .Line_Comment, trivia = true)
        } else if n == '*' {
            if !scan_block_comment(l) {
                tok.flags += {.Unterminated}
            }
            return finish(l, &tok, .Block_Comment, trivia = true)
        }
    case '#':
        if n := peek(l, 1); n == '!' {
            scan_line_comment(l)
            return finish(l, &tok, .Line_Comment, trivia = true)
        } else if n == '+' {
            scan_file_tag(l)
            return finish(l, &tok, .File_Tag)
        }
    case 0xEF:
        if peek(l, 1) == 0xBB && peek(l, 2) == 0xBF {
            l.pos += 3
            if start != 0 {
                tok.flags += {.Malformed}
            }
            return finish(l, &tok, .Bom, trivia = true)
        }
    }

    switch {
    case c == '_' || (c | 0x20 >= 'a' && c | 0x20 <= 'z'):
        scan_identifier(l)
        return finish(l, &tok, keyword_kind(l.src[start:l.pos]))
    case c >= '0' && c <= '9':
        kind := scan_number(l, &tok.flags, false)
        return finish(l, &tok, kind)
    case c >= utf8.RUNE_SELF:
        r, w := utf8.decode_rune_in_string(l.src[start:])
        if r != utf8.RUNE_ERROR && unicode.is_letter(r) {
            scan_identifier(l)
            return finish(l, &tok, .Ident)
        }
        l.pos += w
        return finish(l, &tok, .Error, trivia = true)
    }

    l.pos += 1
    kind := Token_Kind.Error
    switch c {
    case '"':
        kind = .String
        scan_string(l, &tok.flags)
    case '`':
        kind = .String
        scan_raw_string(l, &tok.flags)
    case '\'':
        kind = .Rune
        scan_rune(l, &tok.flags)
    case '.':
        kind = .Period
        switch cur(l) {
        case '0' ..= '9':
            kind = scan_number(l, &tok.flags, true)
        case '.':
            l.pos += 1
            kind = .Ellipsis
            switch cur(l) {
            case '<':
                l.pos += 1
                kind = .Range_Half
            case '=':
                l.pos += 1
                kind = .Range_Full
            }
        }
    case '@': kind = .At
    case '$': kind = .Dollar
    case '?': kind = .Question
    case '^': kind = .Pointer
    case ';': kind = .Semicolon
    case ',': kind = .Comma
    case ':': kind = .Colon
    case '(': kind = .Open_Paren
    case ')': kind = .Close_Paren
    case '[': kind = .Open_Bracket
    case ']': kind = .Close_Bracket
    case '{': kind = .Open_Brace
    case '}': kind = .Close_Brace
    case '#': kind = .Hash
    case '%':
        kind = .Mod
        switch cur(l) {
        case '=':
            l.pos += 1
            kind = .Mod_Eq
        case '%':
            l.pos += 1
            kind = .Mod_Mod
            if accept(l, '=') {
                kind = .Mod_Mod_Eq
            }
        }
    case '*':
        kind = .Mul
        if accept(l, '=') {
            kind = .Mul_Eq
        } else if accept(l, '*') {
            kind = .Mul_Mul
        }
    case '=':
        kind = accept(l, '=') ? .Cmp_Eq : .Eq
    case '~':
        kind = accept(l, '=') ? .Xor_Eq : .Xor
    case '!':
        kind = accept(l, '=') ? .Not_Eq : .Not
    case '+':
        kind = .Add
        if accept(l, '=') {
            kind = .Add_Eq
        } else if accept(l, '+') {
            kind = .Increment
        }
    case '-':
        kind = .Sub
        switch cur(l) {
        case '-':
            l.pos += 1
            kind = .Decrement
            if accept(l, '-') {
                kind = .Undef
            }
        case '>':
            l.pos += 1
            kind = .Arrow_Right
        case '=':
            l.pos += 1
            kind = .Sub_Eq
        }
    case '/':
        kind = accept(l, '=') ? .Quo_Eq : .Quo
    case '<':
        kind = .Lt
        if accept(l, '=') {
            kind = .Lt_Eq
        } else if accept(l, '<') {
            kind = accept(l, '=') ? .Shl_Eq : .Shl
        }
    case '>':
        kind = .Gt
        if accept(l, '=') {
            kind = .Gt_Eq
        } else if accept(l, '>') {
            kind = accept(l, '=') ? .Shr_Eq : .Shr
        }
    case '&':
        kind = .And
        switch cur(l) {
        case '~':
            l.pos += 1
            kind = accept(l, '=') ? .And_Not_Eq : .And_Not
        case '=':
            l.pos += 1
            kind = .And_Eq
        case '&':
            l.pos += 1
            kind = accept(l, '=') ? .Cmp_And_Eq : .Cmp_And
        }
    case '|':
        kind = .Or
        switch cur(l) {
        case '=':
            l.pos += 1
            kind = .Or_Eq
        case '|':
            l.pos += 1
            kind = accept(l, '=') ? .Cmp_Or_Eq : .Cmp_Or
        }
    case:
        return finish(l, &tok, .Error, trivia = true)
    }
    return finish(l, &tok, kind)
}

// Sets kind and length; a non-trivia token decides whether the next newline is a ';'.
@(private)
finish :: #force_inline proc "contextless" (l: ^Lexer, tok: ^Token, kind: Token_Kind, trivia := false) -> Token {
    tok.kind = kind
    tok.len = u32(l.pos) - tok.offset
    if !trivia {
        l.insert_semi = ends_statement(kind)
    }
    return tok^
}

@(private)
cur :: #force_inline proc "contextless" (l: ^Lexer) -> byte {
    return l.pos < len(l.src) ? l.src[l.pos] : 0
}

@(private)
peek :: #force_inline proc "contextless" (l: ^Lexer, n: int) -> byte {
    return l.pos + n < len(l.src) ? l.src[l.pos + n] : 0
}

@(private)
accept :: #force_inline proc "contextless" (l: ^Lexer, b: byte) -> bool {
    if l.pos < len(l.src) && l.src[l.pos] == b {
        l.pos += 1
        return true
    }
    return false
}

@(private)
digit_val :: #force_inline proc "contextless" (b: byte) -> int {
    switch b {
    case '0' ..= '9': return int(b - '0')
    case 'A' ..= 'F': return int(b - 'A' + 10)
    case 'a' ..= 'f': return int(b - 'a' + 10)
    }
    return 16
}

@(private)
scan_line_comment :: proc "contextless" (l: ^Lexer) {
    for l.pos < len(l.src) && l.src[l.pos] != '\n' {
        l.pos += 1
    }
}

// Scans a nested block comment; false when it runs to the end of the source.
@(private)
scan_block_comment :: proc "contextless" (l: ^Lexer) -> bool {
    l.pos += 2
    depth := 1
    for l.pos < len(l.src) {
        b := l.src[l.pos]
        if b == '/' && peek(l, 1) == '*' {
            depth += 1
            l.pos += 2
        } else if b == '*' && peek(l, 1) == '/' {
            depth -= 1
            l.pos += 2
            if depth == 0 {
                return true
            }
        } else {
            l.pos += 1
        }
    }
    return false
}

// Scans a file tag to the end of the line or the start of a comment.
@(private)
scan_file_tag :: proc "contextless" (l: ^Lexer) {
    l.pos += 2
    for l.pos < len(l.src) {
        b := l.src[l.pos]
        if b == '\n' || (b == '/' && (peek(l, 1) == '/' || peek(l, 1) == '*')) {
            break
        }
        l.pos += 1
    }
}

@(private)
scan_identifier :: proc(l: ^Lexer) {
    for l.pos < len(l.src) {
        b := l.src[l.pos]
        if b < utf8.RUNE_SELF {
            if b == '_' || (b | 0x20 >= 'a' && b | 0x20 <= 'z') || (b >= '0' && b <= '9') {
                l.pos += 1
                continue
            }
            return
        }
        r, w := utf8.decode_rune_in_string(l.src[l.pos:])
        if r == utf8.RUNE_ERROR || !(unicode.is_letter(r) || unicode.is_digit(r)) {
            return
        }
        l.pos += w
    }
}

@(private)
scan_string :: proc "contextless" (l: ^Lexer, flags: ^Token_Flags) {
    for {
        if l.pos >= len(l.src) || l.src[l.pos] == '\n' {
            flags^ += {.Unterminated}
            return
        }
        b := l.src[l.pos]
        l.pos += 1
        if b == '"' {
            return
        }
        if b == '\\' && !scan_escape(l) {
            flags^ += {.Malformed}
        }
    }
}

@(private)
scan_raw_string :: proc "contextless" (l: ^Lexer, flags: ^Token_Flags) {
    for l.pos < len(l.src) {
        b := l.src[l.pos]
        l.pos += 1
        if b == '`' {
            return
        }
    }
    flags^ += {.Unterminated}
}

@(private)
scan_rune :: proc "contextless" (l: ^Lexer, flags: ^Token_Flags) {
    n := 0
    for {
        if l.pos >= len(l.src) || l.src[l.pos] == '\n' {
            flags^ += {.Unterminated}
            return
        }
        b := l.src[l.pos]
        if b == '\'' {
            l.pos += 1
            break
        }
        n += 1
        if b == '\\' {
            l.pos += 1
            if !scan_escape(l) {
                flags^ += {.Malformed}
            }
        } else if b < utf8.RUNE_SELF {
            l.pos += 1
        } else {
            _, w := utf8.decode_rune_in_string(l.src[l.pos:])
            l.pos += w
        }
    }
    if n != 1 {
        flags^ += {.Malformed}
    }
}

// Scans the escape after a backslash; false when it is not valid.
@(private)
scan_escape :: proc "contextless" (l: ^Lexer) -> bool {
    n: int
    base, limit: u32
    switch cur(l) {
    case 'a', 'b', 'e', 'f', 'n', 't', 'v', 'r', '\\', '\'', '"':
        l.pos += 1
        return true
    case '0' ..= '7':
        n, base, limit = 3, 8, 255
    case 'x':
        l.pos += 1
        n, base, limit = 2, 16, 255
    case 'u':
        l.pos += 1
        n, base, limit = 4, 16, utf8.MAX_RUNE
    case 'U':
        l.pos += 1
        n, base, limit = 8, 16, utf8.MAX_RUNE
    case:
        return false
    }
    x: u32
    for ; n > 0; n -= 1 {
        d := u32(digit_val(cur(l)))
        if d >= base {
            return false
        }
        x = x * base + d
        l.pos += 1
    }
    return x <= limit && !(0xd800 <= x && x <= 0xdfff)
}

// Scans a number literal; `seen_point` when a leading '.' is already consumed.
@(private)
scan_number :: proc "contextless" (l: ^Lexer, flags: ^Token_Flags, seen_point: bool) -> Token_Kind {
    mantissa :: proc "contextless" (l: ^Lexer, base: int) {
        for digit_val(cur(l)) < base || cur(l) == '_' {
            l.pos += 1
        }
    }
    exponent :: proc "contextless" (l: ^Lexer, kind: ^Token_Kind, flags: ^Token_Flags) {
        if c := cur(l); c == 'e' || c == 'E' {
            kind^ = .Float
            l.pos += 1
            if c2 := cur(l); c2 == '-' || c2 == '+' {
                l.pos += 1
            }
            if digit_val(cur(l)) < 10 {
                mantissa(l, 10)
            } else {
                flags^ += {.Malformed}
            }
        }
        switch cur(l) {
        case 'i', 'j', 'k':
            kind^ = .Imag
            l.pos += 1
        }
    }
    // Scans a fraction; true when the '.' starts a range instead.
    fraction :: proc "contextless" (l: ^Lexer, kind: ^Token_Kind) -> bool {
        if cur(l) != '.' {
            return false
        }
        if peek(l, 1) == '.' {
            return true
        }
        kind^ = .Float
        l.pos += 1
        mantissa(l, 10)
        return false
    }

    kind := Token_Kind.Integer
    if seen_point {
        kind = .Float
        mantissa(l, 10)
        exponent(l, &kind, flags)
        return kind
    }
    if cur(l) == '0' {
        l.pos += 1
        base := 0
        switch cur(l) {
        case 'b': base = 2
        case 'o': base = 8
        case 'd': base = 10
        case 'z': base = 12
        case 'x': base = 16
        case 'h':
            kind = .Float
            prev := l.pos
            l.pos += 1
            mantissa(l, 16)
            digits := 0
            for i in prev + 1 ..< l.pos {
                if l.src[i] != '_' {
                    digits += 1
                }
            }
            if digits != 4 && digits != 8 && digits != 16 {
                flags^ += {.Malformed}
            }
        case:
            mantissa(l, 10)
            if fraction(l, &kind) {
                return kind
            }
            exponent(l, &kind, flags)
            return kind
        }
        if base != 0 {
            prev := l.pos
            l.pos += 1
            mantissa(l, base)
            if l.pos - prev <= 1 {
                flags^ += {.Malformed}
            }
        }
    }
    mantissa(l, 10)
    if fraction(l, &kind) {
        return kind
    }
    exponent(l, &kind, flags)
    return kind
}
