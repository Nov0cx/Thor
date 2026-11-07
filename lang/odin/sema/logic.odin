// Statements that cannot do what they say (`logic/self-assign`, `logic/identical-branches`,
// `logic/const-condition`).
package odinsema

import "core:strings"

import odinsyntax "../syntax"

// True when the assignment `stmt` is `place = place` with a place that has no side effect.
self_assign :: proc(stmt: odinsyntax.Syntax_Node) -> bool {
    as := odinsyntax.as_assign_stmt(stmt) or_return
    op := odinsyntax.assign_stmt_op(&as) or_return
    if op.green.kind != .Eq {
        return false
    }
    lhs := odinsyntax.assign_stmt_lhs(&as) or_return
    rhs := odinsyntax.assign_stmt_rhs(&as) or_return
    li := odinsyntax.expr_list_items(&lhs)
    ri := odinsyntax.expr_list_items(&rhs)
    a := odinsyntax.child_iter_next(&li) or_return
    b := odinsyntax.child_iter_next(&ri) or_return
    if _, more := odinsyntax.child_iter_next(&li); more {
        return false
    }
    if _, more := odinsyntax.child_iter_next(&ri); more {
        return false
    }
    ta := squeeze(odinsyntax.node_text(a), context.temp_allocator)
    return plain_place(ta) && ta == squeeze(odinsyntax.node_text(b), context.temp_allocator)
}

// The offset of the `else` branch of the `if` statement `stmt` when it has the same text as its
// body, and the offset of the condition when it is the literal `true` or `false`.
if_problems :: proc(stmt: odinsyntax.Syntax_Node) -> (identical: int, constant: int, value: bool) {
    identical, constant = -1, -1
    is_, is_if := odinsyntax.as_if_stmt(stmt)
    if !is_if {
        return
    }
    if cond, ok := odinsyntax.if_stmt_cond(&is_); ok {
        text := strings.trim(odinsyntax.node_text(cond), "() \t\r\n")
        if text == "true" || text == "false" {
            constant, value = int(cond.offset), text == "true"
        }
    }
    body, has_body := odinsyntax.if_stmt_body(&is_)
    other, has_else := odinsyntax.if_stmt_else_branch(&is_)
    if !has_body || !has_else || body.green.kind != .Block || other.green.kind != .Block {
        return
    }
    text := squeeze(odinsyntax.node_text(body), context.temp_allocator)
    if len(text) > 2 && text == squeeze(odinsyntax.node_text(other), context.temp_allocator) {
        identical = int(other.offset)
    }
    return
}

// `s` without its white space.
@(private = "file")
squeeze :: proc(s: string, allocator := context.allocator) -> string {
    b := strings.builder_make(0, len(s), allocator)
    for r in s {
        switch r {
        case ' ', '\t', '\r', '\n':
        case:
            strings.write_rune(&b, r)
        }
    }
    return strings.to_string(b)
}

// True when `s` is a name, a selector chain or a dereference of one: reading it has no effect.
@(private = "file")
plain_place :: proc(s: string) -> bool {
    if s == "" || s == "_" {
        return false
    }
    for r in s {
        switch r {
        case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '.', '^':
        case:
            return false
        }
    }
    return true
}
