package odinsyntax

import "core:testing"

// The non-trivia kinds of `src`, EOF excluded.
@(private = "file")
kinds_of :: proc(src: string, allocator := context.temp_allocator) -> []Token_Kind {
    toks := lex_all(src, context.temp_allocator)
    out := make([dynamic]Token_Kind, 0, len(toks), allocator)
    for tok in toks {
        if !token_is_trivia(tok.kind) && tok.kind != .EOF {
            append(&out, tok.kind)
        }
    }
    return out[:]
}

// The offsets where the lexer reads an implicit ';'.
@(private = "file")
semis_of :: proc(src: string) -> []u32 {
    toks := lex_all(src, context.temp_allocator)
    out := make([dynamic]u32, 0, 8, context.temp_allocator)
    for tok in toks {
        if .Implicit_Semi in tok.flags {
            append(&out, tok.offset)
        }
    }
    return out[:]
}

@(private = "file")
expect_kinds :: proc(t: ^testing.T, src: string, want: []Token_Kind, loc := #caller_location) {
    got := kinds_of(src)
    if len(got) != len(want) {
        testing.expectf(t, false, "%q: got %v, want %v", src, got, want, loc = loc)
        return
    }
    for k, i in want {
        if got[i] != k {
            testing.expectf(t, false, "%q: got %v, want %v", src, got, want, loc = loc)
            return
        }
    }
}

@(private = "file")
expect_single :: proc(t: ^testing.T, src: string, kind: Token_Kind, flags: Token_Flags = {}, loc := #caller_location) {
    toks := lex_all(src, context.temp_allocator)
    if !testing.expectf(t, len(toks) == 2, "%q: got %d tokens, want one and EOF", src, len(toks) - 1, loc = loc) {
        return
    }
    testing.expectf(t, toks[0].kind == kind, "%q: got %v, want %v", src, toks[0].kind, kind, loc = loc)
    testing.expectf(t, toks[0].flags - {.Implicit_Semi} == flags, "%q: flags %v, want %v", src, toks[0].flags, flags, loc = loc)
    testing.expectf(t, int(toks[0].len) == len(src), "%q: token length %d", src, toks[0].len, loc = loc)
}

@(test)
test_token_size :: proc(t: ^testing.T) {
    testing.expect_value(t, size_of(Token), 12)
    testing.expect_value(t, size_of(Green_Element), 8)
    testing.expect_value(t, size_of(Green_Node), 8)
}

@(test)
test_every_fixed_spelling :: proc(t: ^testing.T) {
    for kind in Token_Kind {
        text := TOKEN_TEXT[kind]
        if text == "" || token_is_trivia(kind) {
            continue
        }
        expect_single(t, text, kind)
    }
}

@(test)
test_keyword_prefix_is_ident :: proc(t: ^testing.T) {
    expect_single(t, "procs", .Ident)
    expect_single(t, "_if", .Ident)
    expect_single(t, "Struct", .Ident)
    expect_single(t, "x1_y", .Ident)
}

@(test)
test_unicode_ident :: proc(t: ^testing.T) {
    expect_single(t, "größe", .Ident)
    expect_kinds(t, "αβ := 1", {.Ident, .Colon, .Eq, .Integer})
}

@(test)
test_numbers :: proc(t: ^testing.T) {
    expect_single(t, "0", .Integer)
    expect_single(t, "1_000", .Integer)
    expect_single(t, "0x1F", .Integer)
    expect_single(t, "0b1010", .Integer)
    expect_single(t, "0o17", .Integer)
    expect_single(t, "0z1A", .Integer)
    expect_single(t, "1.5", .Float)
    expect_single(t, ".5", .Float)
    expect_single(t, "1e10", .Float)
    expect_single(t, "1.5e-3", .Float)
    expect_single(t, "2i", .Imag)
    expect_single(t, "1.5k", .Imag)
    expect_single(t, "0h3C00", .Float)
    expect_single(t, "0x", .Integer, {.Malformed})
    expect_single(t, "1e", .Float, {.Malformed})
    expect_single(t, "0h3C", .Float, {.Malformed})
    expect_kinds(t, "1..2", {.Integer, .Ellipsis, .Integer})
    expect_kinds(t, "0..<n", {.Integer, .Range_Half, .Ident})
    expect_kinds(t, "x.y", {.Ident, .Period, .Ident})
}

@(test)
test_strings_and_runes :: proc(t: ^testing.T) {
    expect_single(t, `"abc"`, .String)
    expect_single(t, `"a\n\t\"\\"`, .String)
    expect_single(t, `"\x41é\U0001F600\101"`, .String)
    expect_single(t, `"\q"`, .String, {.Malformed})
    expect_single(t, `"\uD800"`, .String, {.Malformed})
    expect_single(t, "`raw\n\\n`", .String)
    expect_single(t, "\"\"\"a\n\"b\" \\\"\"\"\n c\"\"\"", .String)
    expect_single(t, `""""""`, .String)
    expect_single(t, "\"\"\"\n\\q\"\"\"", .String, {.Malformed})
    expect_single(t, "\"\"\"open\n\n", .String, {.Unterminated})
    expect_kinds(t, `"" x`, {.String, .Ident})
    expect_single(t, "```a\n`b` ``\n```", .String)
    expect_single(t, "``````", .String)
    expect_single(t, "```open\n`", .String, {.Unterminated})
    expect_kinds(t, "`` x", {.String, .Ident})
    expect_single(t, `'a'`, .Rune)
    expect_single(t, `'\n'`, .Rune)
    expect_single(t, `'é'`, .Rune)
    expect_single(t, `'ab'`, .Rune, {.Malformed})
    expect_single(t, `''`, .Rune, {.Malformed})
}

@(test)
test_unterminated :: proc(t: ^testing.T) {
    toks := lex_all("\"abc\nx", context.temp_allocator)
    testing.expect_value(t, toks[0].kind, Token_Kind.String)
    testing.expect_value(t, toks[0].len, 4)
    testing.expect(t, .Unterminated in toks[0].flags)
    testing.expect_value(t, toks[1].kind, Token_Kind.Newline)

    expect_single(t, "'a", .Rune, {.Unterminated})
    expect_single(t, "`abc\ndef", .String, {.Unterminated})
    expect_single(t, "/* a /* b */", .Block_Comment, {.Unterminated})
}

@(test)
test_comments :: proc(t: ^testing.T) {
    expect_single(t, "/* a /* b */ c */", .Block_Comment)
    expect_single(t, "// line", .Line_Comment)
    expect_single(t, "#!shebang", .Line_Comment)
    expect_kinds(t, "a /* x */ b // y\nc", {.Ident, .Ident, .Ident})
    expect_kinds(t, "a /= b", {.Ident, .Quo_Eq, .Ident})
}

@(test)
test_file_tag :: proc(t: ^testing.T) {
    toks := lex_all("#+build windows // c\npackage p", context.temp_allocator)
    testing.expect_value(t, toks[0].kind, Token_Kind.File_Tag)
    testing.expect_value(t, token_text("#+build windows // c\npackage p", toks[0]), "#+build windows ")
    testing.expect_value(t, toks[1].kind, Token_Kind.Line_Comment)
    testing.expect_value(t, toks[2].kind, Token_Kind.Newline)
    testing.expect(t, .Implicit_Semi not_in toks[2].flags)
    expect_kinds(t, "#force_inline", {.Hash, .Ident})
}

@(test)
test_semicolon_insertion :: proc(t: ^testing.T) {
    Case :: struct {
        src:  string,
        want: []u32,
    }
    cases := []Case {
        {"x\n", {1}},
        {"x", {1}},
        {"x +\ny\n", {5}},
        {"return\n", {6}},
        {"break\ncontinue\nfallthrough\n", {5, 14, 26}},
        {"f()\n", {3}},
        {"a[0]\n", {4}},
        {"}\n", {1}},
        {"p^\n", {2}},
        {"x: int = ---\n", {12}},
        {"i += 1\n", {6}},
        {"i++\n", {3}},
        {"v or_return\n", {11}},
        {"x // c\n", {6}},
        {"x /* c */\n", {9}},
        {"x /* a\nb */\n", {11}},
        {"x \\\n+ y\n", {7}},
        {"x\r\n", {2}},
        {"x := 1\n\n", {6}},
        {"{\n", {}},
        {"x :=\n", {}},
        {"proc\n", {}},
        {"#+build windows\n", {}},
        {"x \x01\n", {3}},
    }
    for c in cases {
        got := semis_of(c.src)
        ok := len(got) == len(c.want)
        for w, i in c.want {
            ok = ok && got[i] == w
        }
        testing.expectf(t, ok, "%q: semicolons at %v, want %v", c.src, got, c.want)
    }
}

@(test)
test_crlf_carriage_return_is_whitespace :: proc(t: ^testing.T) {
    toks := lex_all("x\r\n", context.temp_allocator)
    testing.expect_value(t, toks[1].kind, Token_Kind.Whitespace)
    testing.expect_value(t, toks[2].kind, Token_Kind.Newline)
}

@(test)
test_error_bytes :: proc(t: ^testing.T) {
    expect_single(t, "\x01", .Error)
    expect_single(t, "\xff", .Error)
    expect_single(t, "→", .Error)
}

@(test)
test_bom :: proc(t: ^testing.T) {
    toks := lex_all("\xef\xbb\xbfpackage p", context.temp_allocator)
    testing.expect_value(t, toks[0].kind, Token_Kind.Bom)
    testing.expect_value(t, toks[0].flags, Token_Flags{})
    testing.expect_value(t, toks[1].kind, Token_Kind.Package)

    late := lex_all("x\xef\xbb\xbf", context.temp_allocator)
    testing.expect_value(t, late[1].kind, Token_Kind.Bom)
    testing.expect(t, .Malformed in late[1].flags)
}

@(test)
test_lossless_small :: proc(t: ^testing.T) {
    srcs := []string {
        "",
        "package p\n\nmain :: proc() {\n\tx := 1 /* c */\n}\n",
        "\"unterminated\n`raw",
        "\x00\x01\xff\xfe x",
        "/* /* */",
    }
    for src in srcs {
        toks := lex_all(src, context.temp_allocator)
        pos: u32
        for tok in toks {
            testing.expectf(t, tok.offset == pos, "%q: gap at %d", src, pos)
            pos = token_end(tok)
        }
        testing.expectf(t, int(pos) == len(src), "%q: tokens end at %d of %d", src, pos, len(src))
        testing.expect_value(t, toks[len(toks) - 1].kind, Token_Kind.EOF)
    }
}

@(test)
test_restart_matches_cold :: proc(t: ^testing.T) {
    src := "package p\n\nf :: proc(x: int) -> int {\n\treturn x + 1 // c\n}\n/* a\n */ y := `r\n`\n"
    cold := lex_all(src, context.temp_allocator)
    l: Lexer
    lexer_init(&l, src)
    for i in 0 ..< len(cold) {
        state := lexer_state(&l)
        tail := lex_from(src, int(l.pos), state, context.temp_allocator)
        ok := len(tail) == len(cold) - i
        for tok, j in tail {
            ok = ok && tok == cold[i + j]
        }
        testing.expectf(t, ok, "restart at token %d (offset %d) differs", i, l.pos)
        _ = lex_next(&l)
    }
}
