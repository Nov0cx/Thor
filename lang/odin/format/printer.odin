// The formatter's entry point: parse with Thor's lossless parser
// (lang/odin/syntax), refuse on any syntax error so a broken file is never
// mangled, then print a Doc from the tree and render it.
package odinfmt

import "core:mem"
import "core:mem/virtual"
import "core:strings"

import syn "../syntax"

// The nesting budget of a source the formatter takes, kept from the
// recursive-descent parser it used before: a `(` or `[` costs five, a `{` two.
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
    // The tree, the indexes and the Doc tree are scratch: one arena holds them
    // and drops them together, so only the rendered string reaches the caller.
    arena: virtual.Arena
    if virtual.arena_init_growing(&arena) != nil {
        return "", false
    }
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    context.temp_allocator = context.allocator

    pr: Printer
    parsed, root := parse_source(&pr, source, opts) or_return
    defer syn.parse_destroy(&parsed)

    doc := print_file(&pr, root)
    if pr.too_deep {
        return "", false
    }
    rendered := render(doc, &pr.opts, allocator)
    // The printer drops a byte order mark, so it is put back.
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
    context.temp_allocator = context.allocator

    pr: Printer
    parsed, root := parse_source(&pr, source, opts) or_return
    defer syn.parse_destroy(&parsed)

    decls := stmt_kids(kids(root))
    first, last := -1, -1
    for d, i in decls {
        if d.start < hi && d.end > lo {
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

    start := decls[first].start
    end := decls[last].end
    for pr.comment_idx < len(pr.comments) && pr.comments[pr.comment_idx].start < start {
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

// Parses `source` into the printer's indexes. False on a syntax error or a
// nesting deeper than MAX_NESTING. The caller destroys `parsed` when ok.
@(private)
parse_source :: proc(pr: ^Printer, source: string, opts: Options) -> (parsed: syn.Parse, root: Node, ok: bool) {
    if !nesting_ok(source) {
        return {}, {}, false
    }
    err: mem.Allocator_Error
    parsed, err = syn.parse(source)
    if err != nil {
        return {}, {}, false
    }
    if len(parsed.errors) > 0 || parsed.tree.root == nil {
        syn.parse_destroy(&parsed)
        return {}, {}, false
    }
    pr.opts = opts
    pr.src = source
    pr.align_ids = make(map[u64]Align_Cell)
    index_source(pr, parsed.tree)
    return parsed, node_from_root(parsed.tree), true
}

// Whether two neighbouring declarations sit in one alignment run.
@(private)
same_run :: proc(pr: ^Printer, a, b: Node) -> bool {
    ca, aok := pr.align_ids[align_key(a)]
    cb, bok := pr.align_ids[align_key(b)]
    return aok && bok && ca.head == cb.head
}

// Whether the brackets in `source` stay inside MAX_NESTING.
@(private)
nesting_ok :: proc(source: string) -> bool {
    l: syn.Lexer
    syn.lexer_init(&l, source)
    depth := 0
    for {
        tok := syn.lex_next(&l)
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
