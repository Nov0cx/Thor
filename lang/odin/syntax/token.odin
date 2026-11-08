// Lexer, lossless syntax tree and tree views for Odin source.
package odinsyntax

// The kind of a token. Trivia kinds come first, so `token_is_trivia` is one compare.
Token_Kind :: enum u8 {
    Whitespace,        // spaces, tabs and carriage returns
    Newline,           // one '\n'; carries Implicit_Semi where the compiler inserts a ';'
    Line_Comment,      // `//` or `#!`, to the end of the line, newline excluded
    Block_Comment,     // nested `/* */`
    Line_Continuation, // `\` that joins the next line
    Bom,               // byte order mark at the start of the file

    Error, // a byte no token starts with
    EOF,   // zero width; carries Implicit_Semi when the last line needs a ';'

    Ident,
    Integer,
    Float,
    Imag,
    Rune,
    String,
    File_Tag, // `#+build ...` to the end of the line

    Eq,
    Not,
    Hash,
    At,
    Dollar,
    Pointer,
    Question,
    Add,
    Sub,
    Mul,
    Quo,
    Mod,
    Mod_Mod,
    And,
    Or,
    Xor,
    And_Not,
    Shl,
    Shr,
    Cmp_And,
    Cmp_Or,
    Mul_Mul,

    Add_Eq,
    Sub_Eq,
    Mul_Eq,
    Quo_Eq,
    Mod_Eq,
    Mod_Mod_Eq,
    And_Eq,
    Or_Eq,
    Xor_Eq,
    And_Not_Eq,
    Shl_Eq,
    Shr_Eq,
    Cmp_And_Eq,
    Cmp_Or_Eq,

    Increment,
    Decrement,
    Arrow_Right,
    Undef,

    Cmp_Eq,
    Not_Eq,
    Lt,
    Gt,
    Lt_Eq,
    Gt_Eq,

    Open_Paren,
    Close_Paren,
    Open_Bracket,
    Close_Bracket,
    Open_Brace,
    Close_Brace,
    Colon,
    Semicolon,
    Period,
    Comma,
    Ellipsis,
    Range_Half,
    Range_Full,

    Import,
    Foreign,
    Package,
    Typeid,
    When,
    Where,
    If,
    Else,
    For,
    Switch,
    In,
    Not_In,
    Do,
    Case,
    Break,
    Continue,
    Fallthrough,
    Defer,
    Return,
    Proc,
    Struct,
    Union,
    Enum,
    Bit_Set,
    Bit_Field,
    Map,
    Dynamic,
    Auto_Cast,
    Cast,
    Transmute,
    Distinct,
    Using,
    Context,
    Or_Else,
    Or_Return,
    Or_Break,
    Or_Continue,
    Asm,
    Matrix,
}

FIRST_KEYWORD :: Token_Kind.Import
LAST_KEYWORD :: Token_Kind.Matrix

Token_Flag :: enum u8 {
    Implicit_Semi, // the compiler reads a ';' here
    Unterminated,  // string, rune or block comment that does not close
    Malformed,     // bad escape, number with no digits, rune of the wrong length
}

Token_Flags :: distinct bit_set[Token_Flag; u8]

// One token: a byte range of the source.
Token :: struct {
    kind:   Token_Kind,
    flags:  Token_Flags,
    offset: u32,
    len:    u32,
}

// The fixed spelling of a keyword or operator, "" for kinds with variable text.
TOKEN_TEXT := [Token_Kind]string {
    .Whitespace        = "",
    .Newline           = "\n",
    .Line_Comment      = "",
    .Block_Comment     = "",
    .Line_Continuation = "\\",
    .Bom               = "\xef\xbb\xbf",
    .Error             = "",
    .EOF               = "",
    .Ident             = "",
    .Integer           = "",
    .Float             = "",
    .Imag              = "",
    .Rune              = "",
    .String            = "",
    .File_Tag          = "",
    .Eq                = "=",
    .Not               = "!",
    .Hash              = "#",
    .At                = "@",
    .Dollar            = "$",
    .Pointer           = "^",
    .Question          = "?",
    .Add               = "+",
    .Sub               = "-",
    .Mul               = "*",
    .Quo               = "/",
    .Mod               = "%",
    .Mod_Mod           = "%%",
    .And               = "&",
    .Or                = "|",
    .Xor               = "~",
    .And_Not           = "&~",
    .Shl               = "<<",
    .Shr               = ">>",
    .Cmp_And           = "&&",
    .Cmp_Or            = "||",
    .Mul_Mul           = "**",
    .Add_Eq            = "+=",
    .Sub_Eq            = "-=",
    .Mul_Eq            = "*=",
    .Quo_Eq            = "/=",
    .Mod_Eq            = "%=",
    .Mod_Mod_Eq        = "%%=",
    .And_Eq            = "&=",
    .Or_Eq             = "|=",
    .Xor_Eq            = "~=",
    .And_Not_Eq        = "&~=",
    .Shl_Eq            = "<<=",
    .Shr_Eq            = ">>=",
    .Cmp_And_Eq        = "&&=",
    .Cmp_Or_Eq         = "||=",
    .Increment         = "++",
    .Decrement         = "--",
    .Arrow_Right       = "->",
    .Undef             = "---",
    .Cmp_Eq            = "==",
    .Not_Eq            = "!=",
    .Lt                = "<",
    .Gt                = ">",
    .Lt_Eq             = "<=",
    .Gt_Eq             = ">=",
    .Open_Paren        = "(",
    .Close_Paren       = ")",
    .Open_Bracket      = "[",
    .Close_Bracket     = "]",
    .Open_Brace        = "{",
    .Close_Brace       = "}",
    .Colon             = ":",
    .Semicolon         = ";",
    .Period            = ".",
    .Comma             = ",",
    .Ellipsis          = "..",
    .Range_Half        = "..<",
    .Range_Full        = "..=",
    .Import            = "import",
    .Foreign           = "foreign",
    .Package           = "package",
    .Typeid            = "typeid",
    .When              = "when",
    .Where             = "where",
    .If                = "if",
    .Else              = "else",
    .For               = "for",
    .Switch            = "switch",
    .In                = "in",
    .Not_In            = "not_in",
    .Do                = "do",
    .Case              = "case",
    .Break             = "break",
    .Continue          = "continue",
    .Fallthrough       = "fallthrough",
    .Defer             = "defer",
    .Return            = "return",
    .Proc              = "proc",
    .Struct            = "struct",
    .Union             = "union",
    .Enum              = "enum",
    .Bit_Set           = "bit_set",
    .Bit_Field         = "bit_field",
    .Map               = "map",
    .Dynamic           = "dynamic",
    .Auto_Cast         = "auto_cast",
    .Cast              = "cast",
    .Transmute         = "transmute",
    .Distinct          = "distinct",
    .Using             = "using",
    .Context           = "context",
    .Or_Else           = "or_else",
    .Or_Return         = "or_return",
    .Or_Break          = "or_break",
    .Or_Continue       = "or_continue",
    .Asm               = "asm",
    .Matrix            = "matrix",
}

token_is_trivia :: #force_inline proc "contextless" (kind: Token_Kind) -> bool {
    return kind <= .Bom
}

token_is_keyword :: #force_inline proc "contextless" (kind: Token_Kind) -> bool {
    return FIRST_KEYWORD <= kind && kind <= LAST_KEYWORD
}

token_text :: #force_inline proc "contextless" (src: string, tok: Token) -> string {
    return src[tok.offset:][:tok.len]
}

token_end :: #force_inline proc "contextless" (tok: Token) -> u32 {
    return tok.offset + tok.len
}

// The keyword spelled by `s`, or .Ident.
keyword_kind :: proc "contextless" (s: string) -> Token_Kind {
    if len(s) < 2 || len(s) > 11 || s[0] < 'a' || s[0] > 'w' {
        return .Ident
    }
    switch s {
    case "import":      return .Import
    case "foreign":     return .Foreign
    case "package":     return .Package
    case "typeid":      return .Typeid
    case "when":        return .When
    case "where":       return .Where
    case "if":          return .If
    case "else":        return .Else
    case "for":         return .For
    case "switch":      return .Switch
    case "in":          return .In
    case "not_in":      return .Not_In
    case "do":          return .Do
    case "case":        return .Case
    case "break":       return .Break
    case "continue":    return .Continue
    case "fallthrough": return .Fallthrough
    case "defer":       return .Defer
    case "return":      return .Return
    case "proc":        return .Proc
    case "struct":      return .Struct
    case "union":       return .Union
    case "enum":        return .Enum
    case "bit_set":     return .Bit_Set
    case "bit_field":   return .Bit_Field
    case "map":         return .Map
    case "dynamic":     return .Dynamic
    case "auto_cast":   return .Auto_Cast
    case "cast":        return .Cast
    case "transmute":   return .Transmute
    case "distinct":    return .Distinct
    case "using":       return .Using
    case "context":     return .Context
    case "or_else":     return .Or_Else
    case "or_return":   return .Or_Return
    case "or_break":    return .Or_Break
    case "or_continue": return .Or_Continue
    case "asm":         return .Asm
    case "matrix":      return .Matrix
    }
    return .Ident
}

// Reports whether a newline after `kind` ends the statement.
ends_statement :: proc "contextless" (kind: Token_Kind) -> bool {
    #partial switch kind {
    case .Ident, .Context, .Typeid, .Break, .Continue, .Fallthrough, .Return,
         .Integer, .Float, .Imag, .Rune, .String, .Undef,
         .Question, .Pointer, .Close_Paren, .Close_Bracket, .Close_Brace,
         .Increment, .Decrement, .Or_Return, .Or_Break, .Or_Continue:
        return true
    }
    return false
}
