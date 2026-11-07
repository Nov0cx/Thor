// Selection ranges: the syntax ranges around the caret or selection, innermost first.
package odin

import "core:strings"

import lang ".."
import odinsyntax "syntax"

// Fills `res.ranges` with the token under [req.offset, req.end) and each enclosing node, trimmed of
// leading and trailing whitespace. A range equal to the one before is dropped.
@(private)
selection_range :: proc(e: ^Engine, req: ^lang.Request, res: ^lang.Result) {
    ctx: Request_Context
    opened := request_open(e, req, &ctx)
    defer request_close(&ctx)
    if !opened || ctx.parsed.tree == nil || ctx.parsed.tree.root == nil {
        return
    }
    text := ctx.parsed.tree.text
    lo := clamp(min(req.offset, req.end), 0, len(text))
    hi := clamp(max(req.offset, req.end), lo, len(text))
    if lo == hi && len(text) > 0 {
        // A caret selects the byte after it, else the identifier it ends.
        if lo >= len(text) || (!is_word_byte(text[lo]) && lo > 0 && is_word_byte(text[lo - 1])) {
            lo -= 1
        }
        hi = lo + 1
    }
    root := odinsyntax.node_root(ctx.parsed.tree)
    found, ok := odinsyntax.node_covering(root, u32(lo), u32(hi), context.temp_allocator)
    if !ok {
        return
    }
    node: ^odinsyntax.Syntax_Node
    switch &v in found {
    case odinsyntax.Syntax_Token:
        if !odinsyntax.token_is_trivia(v.green.kind) && v.green.kind != .EOF {
            add_range(res, text, int(v.offset), int(v.offset) + int(v.green.len))
        }
        node = v.parent
    case odinsyntax.Syntax_Node:
        node = &v
    }
    for node != nil {
        start, end := odinsyntax.node_range(node^)
        add_range(res, text, int(start), int(end))
        node = node.parent
    }
    res.ok = len(res.ranges) > 0
}

// Appends [start, end) trimmed of whitespace unless it repeats the last range or is empty.
@(private = "file")
add_range :: proc(res: ^lang.Result, text: string, start, end: int) {
    start, end := start, end
    for start < end && strings.is_space(rune(text[start])) {
        start += 1
    }
    for end > start && strings.is_space(rune(text[end - 1])) {
        end -= 1
    }
    if start >= end {
        return
    }
    if n := len(res.ranges); n > 0 && res.ranges[n - 1].start == start && res.ranges[n - 1].end == end {
        return
    }
    if _, err := append(&res.ranges, lang.Text_Range{start = start, end = end}); err != nil {
        return
    }
}

@(private = "file")
is_word_byte :: proc(b: u8) -> bool {
    return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b >= 0x80
}
