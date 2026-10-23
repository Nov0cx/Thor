// Positioned access to the lossless tree: the significant children of a node,
// the line of an offset, and the comments of the file in source order.
package odinfmt

import "core:slice"
import "core:strings"

import syn "../syntax"

// A node or a significant token of the tree, with its byte range.
Node :: struct {
    green: ^syn.Green_Node, // nil for a token
    kind:  syn.Syntax_Kind, // .None for a token
    tok:   syn.Token_Kind,
    start: int,
    end:   int,
}

// One comment token.
Comment :: struct {
    text:  string,
    start: int,
    line:  int,
}

// Comments the way core:odin/parser groups them: a run on the line of the code
// before it, or a run on adjacent lines.
Comment_Group :: struct {
    list:  []Comment,
    start: int,
    line:  int,
}

@(private)
node_from_root :: proc(tree: ^syn.Green_Tree) -> Node {
    return Node{green = tree.root, kind = tree.root.kind, start = 0, end = int(tree.root.text_len)}
}

// The nodes and significant tokens directly under `n`, in source order.
@(private)
kids :: proc(n: Node) -> []Node {
    if n.green == nil {
        return nil
    }
    children := syn.green_children(n.green)
    out := make([dynamic]Node, 0, len(children))
    offset := n.start
    for child in children {
        length := int(syn.element_len(child))
        if g, is_node := syn.element_node(child); is_node {
            append(&out, Node{green = g, kind = g.kind, start = offset, end = offset + length})
        } else if tok, _ := syn.element_token(child); !syn.token_is_trivia(tok.kind) && tok.kind != .EOF {
            append(&out, Node{tok = tok.kind, start = offset, end = offset + length})
        }
        offset += length
    }
    return out[:]
}

@(private)
is_node :: #force_inline proc(n: Node) -> bool {
    return n.green != nil
}

@(private)
is_expr :: #force_inline proc(n: Node) -> bool {
    return n.green != nil && syn.kind_is_expr(n.kind)
}

@(private)
is_tok :: #force_inline proc(n: Node, tok: syn.Token_Kind) -> bool {
    return n.green == nil && n.tok == tok
}

// The first node of `kind` in `ks`.
@(private)
find_kind :: proc(ks: []Node, kind: syn.Syntax_Kind) -> (Node, bool) {
    for k in ks {
        if k.green != nil && k.kind == kind {
            return k, true
        }
    }
    return {}, false
}

// The index of the first token of `tok` in `ks` at or after `from`, or -1.
@(private)
tok_index :: proc(ks: []Node, tok: syn.Token_Kind, from := 0) -> int {
    for i in from ..< len(ks) {
        if is_tok(ks[i], tok) {
            return i
        }
    }
    return -1
}

@(private)
has_tok :: proc(ks: []Node, tok: syn.Token_Kind) -> bool {
    return tok_index(ks, tok) >= 0
}

// The expression nodes in `ks`.
@(private)
expr_kids :: proc(ks: []Node) -> []Node {
    out := make([dynamic]Node, 0, len(ks))
    for k in ks {
        if is_expr(k) || k.kind == .Field_Value || k.kind == .Spread_Expr {
            append(&out, k)
        }
    }
    return out[:]
}

// The first expression node of `ks` in [from, to).
@(private)
expr_in :: proc(ks: []Node, from, to: int) -> (Node, bool) {
    for i in max(from, 0) ..< min(to, len(ks)) {
        if is_expr(ks[i]) {
            return ks[i], true
        }
    }
    return {}, false
}

@(private)
node_text :: #force_inline proc(pr: ^Printer, n: Node) -> string {
    return pr.src[n.start:n.end]
}

// The 1-based line of byte `offset`.
@(private)
line_of :: proc(pr: ^Printer, offset: int) -> int {
    i, found := slice.binary_search(pr.line_starts, offset)
    if found {
        return i + 1
    }
    return i
}

@(private)
start_line :: #force_inline proc(pr: ^Printer, n: Node) -> int {
    return line_of(pr, n.start)
}

// The line of the last byte of `n`.
@(private)
end_line :: #force_inline proc(pr: ^Printer, n: Node) -> int {
    return line_of(pr, max(n.start, n.end - 1))
}

// Fills the line index and the comment groups of `pr` from one walk of the tree.
@(private)
index_source :: proc(pr: ^Printer, tree: ^syn.Green_Tree) {
    starts := make([dynamic]int, 0, 1 + strings.count(pr.src, "\n"))
    append(&starts, 0)
    for i in 0 ..< len(pr.src) {
        if pr.src[i] == '\n' {
            append(&starts, i + 1)
        }
    }
    pr.line_starts = starts[:]

    w: Comment_Walk
    w.pr = pr
    if tree.root != nil {
        walk_comments(&w, tree.root, 0)
    }
    close_comment_group(&w)
    pr.comments = w.groups[:]
}

@(private)
Comment_Walk :: struct {
    pr:        ^Printer,
    groups:    [dynamic]Comment_Group,
    current:   [dynamic]Comment,
    prev_line: int, // start line of the last significant token
    in_run:    bool, // no significant token since the last comment
    end_line:  int,  // end line of the last comment of the open group
    same_line: bool, // the open group started on the line of the code before it
}

@(private)
walk_comments :: proc(w: ^Comment_Walk, g: ^syn.Green_Node, offset: int) {
    pos := offset
    for child in syn.green_children(g) {
        length := int(syn.element_len(child))
        if n, is_node := syn.element_node(child); is_node {
            walk_comments(w, n, pos)
        } else if tok, _ := syn.element_token(child); tok.kind == .Line_Comment || tok.kind == .Block_Comment {
            add_comment(w, Comment{text = w.pr.src[pos:][:length], start = pos, line = line_of(w.pr, pos)})
        } else if !syn.token_is_trivia(tok.kind) && tok.kind != .EOF {
            close_comment_group(w)
            w.in_run = false
            w.prev_line = line_of(w.pr, pos)
        }
        pos += length
    }
}

@(private)
add_comment :: proc(w: ^Comment_Walk, c: Comment) {
    if w.in_run && len(w.current) > 0 {
        limit := w.end_line + (w.same_line ? 0 : 1)
        if c.line > limit {
            close_comment_group(w)
        }
    }
    if len(w.current) == 0 {
        w.same_line = !w.in_run && c.line == w.prev_line
    }
    append(&w.current, c)
    w.end_line = comment_end_line(c)
    w.in_run = true
}

@(private)
close_comment_group :: proc(w: ^Comment_Walk) {
    if len(w.current) == 0 {
        return
    }
    list := slice.clone(w.current[:])
    append(&w.groups, Comment_Group{list = list, start = list[0].start, line = list[0].line})
    clear(&w.current)
}

@(private)
is_stmt :: #force_inline proc(n: Node) -> bool {
    return n.green != nil && syn.kind_is_stmt(n.kind)
}
