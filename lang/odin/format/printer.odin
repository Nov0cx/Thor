// The formatter's entry point: parse with the compiler's own front end
// (core:odin/parser), refuse on any syntax error so a broken file is never
// mangled, then print a Doc from the AST and render it.
package odinfmt

import "base:runtime"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"

// core:odin/tokenizer fills its keyword table on the first tokenizer.init, under a
// double-checked lock that does not re-check: a second thread that arrives while the
// first fills asserts with the table spinlock held, and every later parse then spins
// on it forever. The table is filled here, before any thread runs.
@(init)
warm_keyword_table :: proc "contextless" () {
    context = runtime.default_context()
    t: tokenizer.Tokenizer
    tokenizer.init(&t, "", "<warm>", silent_handler)
}

// The nesting budget of a source the formatter takes. The parser recurses per
// bracket, a `(` or `[` costs it about two and a half times what a `{` costs,
// and a worker thread's stack holds about 65 parentheses in a debug build.
@(private)
MAX_NESTING :: 200
@(private)
PAREN_COST :: 5
@(private)
BRACE_COST :: 2

// The deepest the printer recurses into statements and expressions.
@(private)
MAX_DEPTH :: 300

// The UTF-8 byte order mark.
@(private)
BOM :: "\xef\xbb\xbf"

// format parses `source` (Odin source, LF-only — the lang seam's contract)
// and returns its canonical layout under `opts`. ok is false when the source
// has a syntax error; out is then empty and must not be used.
format :: proc(source: string, opts: Options, allocator := context.allocator) -> (out: string, ok: bool) {
    // The AST and the Doc tree are scratch, and core:odin/ast has no destructor:
    // one arena holds both and drops them together, so only the rendered string
    // reaches the caller.
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil {
        return "", false
    }
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)

    file: ast.File
    file.src = source
    file.fullpath = "<format>"

    p := parser.default_parser({.Optional_Semicolons})
    p.err = silent_handler
    p.warn = silent_handler

    if !nesting_ok(source) {
        return "", false
    }
    if !parser.parse_file(&p, &file) {
        return "", false
    }
    if file.syntax_error_count > 0 {
        return "", false
    }

    pr: Printer
    pr.opts = opts
    pr.src = source
    pr.comments = file.comments[:]
    pr.align_ids = make(map[rawptr]Align_Cell) // arena-backed, dropped with the AST

    doc := print_file(&pr, &file)
    if pr.too_deep {
        return "", false
    }
    rendered := render(doc, &pr.opts, allocator)
    // The parser skips a byte order mark, so it is put back.
    if strings.has_prefix(source, BOM) {
        with_bom := strings.concatenate({BOM, rendered}, allocator)
        delete(rendered, allocator)
        rendered = with_bom
    }
    return rendered, true
}

// format_window formats only the file-scope declarations that overlap
// [lo, hi), widened to the alignment runs they belong to, and returns the whole
// source with those declarations replaced. The rest of the file is returned as
// written. ok is false on a syntax error, as for format.
format_window :: proc(source: string, lo, hi: int, opts: Options, allocator := context.allocator) -> (out: string, ok: bool) {
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil {
        return "", false
    }
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)

    file: ast.File
    file.src = source
    file.fullpath = "<format>"

    p := parser.default_parser({.Optional_Semicolons})
    p.err = silent_handler
    p.warn = silent_handler

    if !nesting_ok(source) || !parser.parse_file(&p, &file) || file.syntax_error_count > 0 {
        return "", false
    }

    pr: Printer
    pr.opts = opts
    pr.src = source
    pr.comments = file.comments[:]
    pr.align_ids = make(map[rawptr]Align_Cell)

    decls := file.decls[:]
    first, last := -1, -1
    for d, i in decls {
        if d == nil {
            continue
        }
        if stmt_start_offset(d) < hi && d.end.offset > lo {
            if first < 0 {
                first = i
            }
            last = i
        }
    }
    if first < 0 {
        return strings.clone(source, allocator), true
    }

    // A run aligns as one, so a declaration in it is printed with the whole run.
    assign_decl_align_ids(&pr, decls)
    for first > 0 && same_run(&pr, decls[first - 1], decls[first]) {
        first -= 1
    }
    for last + 1 < len(decls) && same_run(&pr, decls[last], decls[last + 1]) {
        last += 1
    }
    clear(&pr.align_ids)

    start := stmt_start_offset(decls[first])
    end := decls[last].end.offset
    for pr.comment_idx < len(pr.comments) && pr.comments[pr.comment_idx].pos.offset < start {
        pr.comment_idx += 1
    }

    body: [dynamic]Doc
    print_stmt_list(&pr, &body, decls[first:last + 1], 0, false)
    if pr.too_deep {
        return "", false
    }
    rendered := render(concat_dynamic(body), &pr.opts, context.temp_allocator)
    return strings.concatenate({source[:start], rendered, source[end:]}, allocator), true
}

// Whether two neighbouring declarations sit in one alignment run.
@(private)
same_run :: proc(pr: ^Printer, a, b: ^ast.Stmt) -> bool {
    if a == nil || b == nil {
        return false
    }
    ca, aok := pr.align_ids[rawptr(a.derived_stmt.(^ast.Value_Decl) or_else nil)]
    cb, bok := pr.align_ids[rawptr(b.derived_stmt.(^ast.Value_Decl) or_else nil)]
    return aok && bok && ca.head == cb.head
}

// The offset a declaration starts at, its attributes included.
@(private)
stmt_start_offset :: proc(stmt: ^ast.Stmt) -> int {
    attrs: [dynamic]^ast.Attribute
    #partial switch s in stmt.derived_stmt {
    case ^ast.Value_Decl:
        attrs = s.attributes
    case ^ast.Import_Decl:
        attrs = s.attributes
    case ^ast.Foreign_Block_Decl:
        attrs = s.attributes
    case ^ast.Foreign_Import_Decl:
        attrs = s.attributes
    }
    offset := stmt.pos.offset
    for a in attrs {
        offset = min(offset, a.pos.offset)
    }
    return offset
}

@(private)
silent_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
}

// Whether the brackets in `source` stay inside MAX_NESTING.
@(private)
nesting_ok :: proc(source: string) -> bool {
    t: tokenizer.Tokenizer
    tokenizer.init(&t, source, "<format>", silent_handler)
    depth := 0
    for {
        tok := tokenizer.scan(&t)
        #partial switch tok.kind {
        case .EOF:
            return true
        case .Open_Paren, .Open_Bracket:
            depth += PAREN_COST
        case .Open_Brace:
            depth += BRACE_COST
        case .Close_Paren, .Close_Bracket:
            depth = max(depth - PAREN_COST, 0)
        case .Close_Brace:
            depth = max(depth - BRACE_COST, 0)
        }
        if depth > MAX_NESTING {
            return false
        }
    }
}
