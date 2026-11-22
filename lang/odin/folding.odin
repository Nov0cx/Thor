// Folding ranges: bracket pairs, comment runs and import runs that span lines.
package odin

import "core:slice"

import lang ".."
import odinsyntax "syntax"

// Fills `res.ranges` from the tokens of the request's buffer. A range starts at its opening token
// and ends on its last line.
@(private)
folding_range :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    text  := req.source
    toks  := odinsyntax.lex_all(text, context.temp_allocator)
    lines := fold_line_starts(text)

    Open :: struct {
        kind:   odinsyntax.Token_Kind,
        offset: int,
    }
    stack     := make([dynamic]Open, context.temp_allocator)
    // The current run of line comments or imports, each the first token of its line.
    run_kind  := odinsyntax.Token_Kind.EOF
    run_start := -1
    run_end   := -1
    run_line  := -1

    flush :: proc(res: ^lang.Result, lines: []int, start, end: int) {
        if start >= 0 && fold_line(lines, end) > fold_line(lines, start) {
            append(&res.ranges, lang.Text_Range{start = start, end = end})
        }
    }

    first_on_line := true
    for tok in toks {
        if tok.kind == .EOF || lang.request_cancelled(req) {
            break
        }
        if tok.kind == .Newline {
            first_on_line = true
            continue
        }
        if tok.kind == .Whitespace {
            continue
        }
        offset := int(tok.offset)
        if first_on_line {
            first_on_line = false
            line  := fold_line(lines, offset)
            heads := tok.kind == .Line_Comment || tok.kind == .Import
            if heads && tok.kind == run_kind && line == run_line + 1 {
                run_end, run_line = offset, line
            } else {
                flush(res, lines, run_start, run_end)
                run_kind, run_start, run_end, run_line = .EOF, -1, -1, -1
                if heads {
                    run_kind, run_start, run_end, run_line = tok.kind, offset, offset, line
                }
            }
        }

        #partial switch tok.kind {
        case .Open_Brace, .Open_Paren, .Open_Bracket:
            append(&stack, Open{tok.kind, offset})
        case .Close_Brace, .Close_Paren, .Close_Bracket:
            want: odinsyntax.Token_Kind = tok.kind == .Close_Brace ? .Open_Brace : tok.kind == .Close_Paren ? .Open_Paren : .Open_Bracket
            for len(stack) > 0 {
                top := pop(&stack)
                if top.kind == want {
                    flush(res, lines, top.offset, offset)
                    break
                }
            }
        case .Block_Comment:
            flush(res, lines, offset, offset + int(tok.len) - 1)
        }
    }
    flush(res, lines, run_start, run_end)
    slice.stable_sort_by(res.ranges[:], proc(a, b: lang.Text_Range) -> bool {
        return a.start < b.start
    })
    res.ok = len(res.ranges) > 0
}

// The byte offset each line starts at.
@(private = "file")
fold_line_starts :: proc(text: string) -> []int {
    starts := make([dynamic]int, 0, len(text) / 32 + 1, context.temp_allocator)
    append(&starts, 0)
    for i in 0 ..< len(text) {
        if text[i] == '\n' {
            append(&starts, i + 1)
        }
    }
    return starts[:]
}

// The 0-based line of `offset`.
@(private = "file")
fold_line :: proc(starts: []int, offset: int) -> int {
    index, found := slice.binary_search(starts, offset)
    return found ? index : index - 1
}
