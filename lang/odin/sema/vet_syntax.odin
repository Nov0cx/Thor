package odinsema

import "core:mem"
import "core:slice"

import odinsyntax "../syntax"

// The offsets of the semicolons `-vet-semicolon` reports: one that ends its line or its block, and
// one that starts a line.
vet_semicolons :: proc(parsed: odinsyntax.Parse, allocator := context.allocator) -> (out: [dynamic]int, err: mem.Allocator_Error) {
    out = make([dynamic]int, allocator) or_return
    if parsed.tree == nil {
        return
    }
    toks := odinsyntax.lex_all(parsed.tree.text, context.temp_allocator)
    headers := make(map[int]struct{}, 16, context.temp_allocator) or_return
    if parsed.tree.root != nil {
        header_semicolons(odinsyntax.node_root(parsed.tree), &headers) or_return
    }
    for tok, i in toks {
        if tok.kind != .Semicolon || int(tok.offset) in headers {
            continue
        }
        prev := i - 1
        for prev >= 0 && toks[prev].kind == .Whitespace {
            prev -= 1
        }
        next := i + 1
        for next < len(toks) && (toks[next].kind == .Whitespace || toks[next].kind == .Line_Comment || toks[next].kind == .Block_Comment) {
            next += 1
        }
        starts_line := prev < 0 || toks[prev].kind == .Newline
        ends := next >= len(toks) || toks[next].kind == .Newline || toks[next].kind == .EOF || toks[next].kind == .Close_Brace
        if starts_line || ends {
            append(&out, int(tok.offset)) or_return
        }
    }
    return
}

// Adds the offsets of the semicolons that separate the parts of an `if`, `for`, `switch` or `when` header.
@(private = "file")
header_semicolons :: proc(n: odinsyntax.Syntax_Node, out: ^map[int]struct{}) -> mem.Allocator_Error {
    n := n
    #partial switch n.green.kind {
    case .If_Stmt, .For_Stmt, .Range_Stmt, .Switch_Stmt, .Type_Switch_Stmt, .When_Stmt:
        if first, ok := odinsyntax.find_child_token(&n, {tokens = {.Semicolon}}); ok {
            out[int(first.offset)] = {}
        }
        if last, ok := odinsyntax.find_child_token(&n, {tokens = {.Semicolon}, last = true}); ok {
            out[int(last.offset)] = {}
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        header_semicolons(child, out) or_return
    }
    return nil
}

// The offsets of the first token of each statement and field whose line is indented with a space,
// as `-vet-tabs` reports them.
vet_tabs :: proc(parsed: odinsyntax.Parse, allocator := context.allocator) -> (out: [dynamic]int, err: mem.Allocator_Error) {
    out = make([dynamic]int, allocator) or_return
    if parsed.tree == nil || parsed.tree.root == nil {
        return
    }
    tabs_walk(parsed.tree.text, odinsyntax.node_root(parsed.tree), &out) or_return
    slice.sort(out[:])
    return
}

@(private = "file")
tabs_walk :: proc(text: string, n: odinsyntax.Syntax_Node, out: ^[dynamic]int) -> mem.Allocator_Error {
    n := n
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        in_foreign := n.parent != nil && n.parent.green.kind == .Foreign_Block
        if !in_foreign && tabs_subject(n.green.kind, child.green.kind) && spaced_indent(text, int(child.offset)) {
            append(out, int(child.offset)) or_return
        }
        tabs_walk(text, child, out) or_return
    }
    return nil
}

// True when a `child` of a `parent` is a statement, a field or a member that `-vet-tabs` checks.
@(private = "file")
tabs_subject :: proc(parent, child: odinsyntax.Syntax_Kind) -> bool {
    #partial switch parent {
    case .Block, .Case_Clause:
        return odinsyntax.kind_is_stmt(child)
    case .Field_List, .Struct_Type, .Result_List:
        return child == .Field
    case .Enum_Type, .Union_Type:
        return true
    case .Bit_Field_Type:
        return child == .Bit_Field_Field
    }
    return false
}

// True when the first token at `offset` starts its line and a space is among the indentation.
@(private = "file")
spaced_indent :: proc(text: string, offset: int) -> bool {
    spaced := false
    for i := offset - 1; i >= 0; i -= 1 {
        switch text[i] {
        case '\n':
            return spaced
        case ' ':
            spaced = true
        case '\t', '\r':
        case:
            return false
        }
    }
    return spaced
}

// The offsets just after the last element of each comma list that ends on a closing bracket of its own
// line with no trailing comma, as `-vet-style` reports them.
vet_style :: proc(parsed: odinsyntax.Parse, allocator := context.allocator) -> (out: [dynamic]int, err: mem.Allocator_Error) {
    out = make([dynamic]int, allocator) or_return
    if parsed.tree == nil || parsed.tree.root == nil {
        return
    }
    toks := odinsyntax.lex_all(parsed.tree.text, context.temp_allocator)
    style_walk(toks, odinsyntax.node_root(parsed.tree), &out) or_return
    slice.sort(out[:])
    return
}

@(private = "file")
style_walk :: proc(toks: []odinsyntax.Token, n: odinsyntax.Syntax_Node, out: ^[dynamic]int) -> mem.Allocator_Error {
    n := n
    #partial switch n.green.kind {
    case .Enum_Type, .Union_Type, .Field_List, .Param_List, .Result_List, .Arg_List, .Comp_Lit, .Proc_Group, .Bit_Field_Type:
        if closer, ok := odinsyntax.find_child_token(&n, {tokens = {.Close_Brace, .Close_Paren}, last = true}); ok {
            if at, missing := missing_comma(toks, int(closer.offset)); missing {
                append(out, at) or_return
            }
        }
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        style_walk(toks, child, out) or_return
    }
    return nil
}

// The end of the element before the closer at `closer`, when a newline lies between them and the
// element has no comma after it.
@(private = "file")
missing_comma :: proc(toks: []odinsyntax.Token, closer: int) -> (at: int, missing: bool) {
    i, found := slice.binary_search_by(toks, closer, proc(t: odinsyntax.Token, offset: int) -> slice.Ordering {return slice.cmp(int(t.offset), offset)})
    if !found {
        return
    }
    newline := false
    for j := i - 1; j >= 0; j -= 1 {
        #partial switch toks[j].kind {
        case .Whitespace, .Line_Comment, .Block_Comment, .Line_Continuation:
        case .Newline:
            newline = true
        case .Comma, .Open_Brace, .Open_Paren, .Semicolon:
            return
        case:
            return int(toks[j].offset + toks[j].len), newline
        }
    }
    return
}
