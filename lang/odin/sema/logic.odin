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

// The offset of the `else` branch of the `if` statement `stmt` of `file` when it has the same text
// as its body, and the offset of the condition when condition_value knows it. `c` can be nil.
if_problems :: proc(c: ^Checker, file: File_Id, stmt: odinsyntax.Syntax_Node) -> (identical: int, constant: int, value: bool) {
    identical, constant = -1, -1
    is_, is_if := odinsyntax.as_if_stmt(stmt)
    if !is_if {
        return
    }
    if cond, ok := odinsyntax.if_stmt_cond(&is_); ok {
        if v, known := condition_value(c, file, cond); known {
            constant, value = int(cond.offset), v
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

// The offset of the condition of the `for` statement `stmt` of `file` when it is always false; -1
// when not. `c` can be nil.
for_problem :: proc(c: ^Checker, file: File_Id, stmt: odinsyntax.Syntax_Node) -> int {
    fs, is_for := odinsyntax.as_for_stmt(stmt)
    if !is_for {
        return -1
    }
    cond, has_cond := odinsyntax.for_stmt_cond(&fs)
    if !has_cond {
        return -1
    }
    if v, known := condition_value(c, file, cond); known && !v {
        return int(cond.offset)
    }
    return -1
}

// The value of the condition `cond` of `file` when it is the same on every target. A condition of
// names only is a flag by convention and is left out. With no checker only the literals `true` and
// `false` are known.
condition_value :: proc(c: ^Checker, file: File_Id, cond: odinsyntax.Syntax_Node) -> (value: bool, ok: bool) {
    cond := cond
    for cond.green.kind == .Paren_Expr {
        p, _ := odinsyntax.as_paren_expr(cond)
        cond = odinsyntax.paren_expr_expr(&p) or_return
    }
    text := strings.trim_space(odinsyntax.node_text(cond))
    if text == "true" || text == "false" {
        return text == "true", true
    }
    if c == nil || flag_name(cond) {
        return
    }
    v := const_eval(c, file, cond) or_return
    b := v.(bool) or_return
    if target_dependent(c, file, cond, 0) {
        return
    }
    return b, true
}

// How many named constants target_dependent follows.
@(private = "file")
TARGET_DEPTH :: 8

// The builtins whose value depends on the target.
@(private = "file", rodata)
TARGET_BUILTINS := [?]string{"size_of", "align_of", "offset_of", "type_of", "type_info_of"}

// True when the value of `n` of `file` can change with the target: it reads an `ODIN_*` constant, a
// directive such as `#config` or `#defined`, the size or layout of a type, or a named constant whose
// value does so. A constant that cannot be followed counts as dependent.
@(private = "file")
target_dependent :: proc(c: ^Checker, file: File_Id, n: odinsyntax.Syntax_Node, depth: int) -> bool {
    if depth > TARGET_DEPTH {
        return true
    }
    n := n
    #partial switch n.green.kind {
    case .Directive:
        return true
    case .Ident, .Selector_Expr:
        name := n
        if sel, is_sel := odinsyntax.as_selector_expr(n); is_sel {
            field, has_field := odinsyntax.selector_expr_field(&sel)
            if !has_field {
                return true
            }
            name = odinsyntax.Syntax_Node(field)
        }
        text := odinsyntax.node_text(name)
        if strings.has_prefix(text, "ODIN_") {
            return true
        }
        for b in TARGET_BUILTINS {
            if text == b {
                return true
            }
        }
        op := expr_type(c, file, n)
        if op.mode != .Const || !op.has_symbol {
            return false
        }
        value_file, value, found := const_value_node(c, op.symbol)
        if !found {
            return true
        }
        return target_dependent(c, value_file, value, depth + 1)
    }
    it := odinsyntax.child_iter(&n, {kinds = ~odinsyntax.Kind_Set{}})
    for child in odinsyntax.child_iter_next(&it) {
        if target_dependent(c, file, child, depth) {
            return true
        }
    }
    return false
}

// The value expression of the constant `sym`. An enum member is its own value and gives false.
@(private = "file")
const_value_node :: proc(c: ^Checker, sym: Symbol) -> (file: File_Id, value: odinsyntax.Syntax_Node, ok: bool) {
    name_offset: int
    if sym.item == LOCAL_ITEM {
        name_offset = int(sym.child)
    } else {
        if sym.child >= 0 {
            return
        }
        item := checker_item(c, sym)
        if item == nil {
            return
        }
        name_offset = item.name_offset
    }
    decl: odinsyntax.Syntax_Node
    for n in node_path(c, sym.file, name_offset) {
        if n.green.kind == .Value_Decl {
            decl = n
        }
    }
    v, is_decl := odinsyntax.as_value_decl(decl)
    if !is_decl {
        return
    }
    names := odinsyntax.value_decl_names(&v) or_return
    values := odinsyntax.value_decl_values(&v) or_return
    index := -1
    ni := odinsyntax.name_list_names(&names)
    for i := 0; ; i += 1 {
        name := odinsyntax.child_iter_next(&ni) or_break
        if int(name.offset) == name_offset {
            index = i
            break
        }
    }
    vi := odinsyntax.expr_list_items(&values)
    for i := 0; ; i += 1 {
        expr := odinsyntax.child_iter_next(&vi) or_break
        if i == index {
            return sym.file, expr, true
        }
    }
    return
}

// True when `n` is built only from names and selectors with operators: `DEBUG`, `!DEBUG`,
// `VERSION != NOTICE_VERSION`.
@(private = "file")
flag_name :: proc(n: odinsyntax.Syntax_Node) -> bool {
    n := n
    #partial switch n.green.kind {
    case .Ident, .Selector_Expr, .Implicit_Selector:
        return true
    case .Unary_Expr, .Binary_Expr, .Paren_Expr:
        it := odinsyntax.child_iter(&n, {kinds = odinsyntax.KINDS_EXPR})
        for child in odinsyntax.child_iter_next(&it) {
            if !flag_name(child) {
                return false
            }
        }
        return true
    }
    return false
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
