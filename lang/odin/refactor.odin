// Refactorings at the caret that need no input: inline a variable, an `if` chain to a `switch` and back.
package odin

import "core:strings"

import lang ".."
import odinsema "sema"
import odinsyntax "syntax"

@(private = "file")
ALL_NODES :: ~odinsyntax.Kind_Set{}

// Appends the refactorings that apply at the caret.
@(private)
refactor_actions :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, caret: Caret, res: ^lang.Result) {
    tok, ok := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(caret.offset), context.temp_allocator)
    if !ok {
        return
    }
    inline_variable(rc, m, caret, res)
    for n := tok.parent; n != nil; n = n.parent {
        if n.green.kind == .Proc_Lit {
            break
        }
        if n.green.kind == .If_Stmt {
            head := n
            for head.parent != nil && head.parent.green.kind == .If_Stmt {
                head = head.parent
            }
            if_to_switch(rc, head^, res)
            break
        }
        if n.green.kind == .Switch_Stmt {
            switch_to_if(rc, n^, res)
            break
        }
    }
}

@(private = "file")
same_node :: proc(a, b: odinsyntax.Syntax_Node) -> bool {
    return a.green == b.green && a.offset == b.offset
}

@(private = "file")
node_at :: proc(rc: ^Request_Context, offset: int) -> (^odinsyntax.Syntax_Node, bool) {
    tok, ok := odinsyntax.node_token_at(odinsyntax.node_root(rc.parsed.tree), u32(offset), context.temp_allocator)
    if !ok || tok.parent == nil {
        return nil, false
    }
    return tok.parent, true
}

// True when `n` or a node under it is of a kind in `kinds`.
@(private = "file")
holds_kind :: proc(n: odinsyntax.Syntax_Node, kinds: odinsyntax.Kind_Set) -> bool {
    if n.green.kind in kinds {
        return true
    }
    n := n
    it := odinsyntax.child_iter(&n, {kinds = ALL_NODES})
    for c in odinsyntax.child_iter_next(&it) {
        if holds_kind(c, kinds) {
            return true
        }
    }
    return false
}

// True when `n` holds a `break` with no label that leaves `n`, or a `fallthrough`.
@(private = "file")
breaks_out :: proc(n: odinsyntax.Syntax_Node, in_loop := false) -> bool {
    n := n
    #partial switch n.green.kind {
    case .Branch_Stmt:
        b := odinsyntax.Branch_Stmt(n)
        kw, _ := odinsyntax.branch_stmt_keyword(&b)
        _, labelled := odinsyntax.branch_stmt_label(&b)
        if kw.green.kind == .Fallthrough {
            return true
        }
        return kw.green.kind == .Break && !labelled && !in_loop
    case .Proc_Lit:
        return false
    }
    inner := in_loop || n.green.kind in odinsyntax.Kind_Set{.For_Stmt, .Range_Stmt, .Switch_Stmt, .Type_Switch_Stmt}
    it := odinsyntax.child_iter(&n, {kinds = ALL_NODES})
    for c in odinsyntax.child_iter_next(&it) {
        if breaks_out(c, inner) {
            return true
        }
    }
    return false
}

// `text` with the indent its lines share replaced by `indent`; blank lines stay empty.
@(private)
reindent :: proc(text, indent: string) -> string {
    lines := strings.split_lines(text, context.temp_allocator)
    common := -1
    for l in lines {
        if strings.trim_space(l) == "" {
            continue
        }
        n := len(l) - len(strings.trim_left(l, " \t"))
        if common < 0 || n < common {
            common = n
        }
    }
    if common < 0 {
        return ""
    }
    sb := strings.builder_make(context.temp_allocator)
    for l, i in lines {
        if i > 0 {
            strings.write_byte(&sb, '\n')
        }
        if strings.trim_space(l) == "" {
            continue
        }
        strings.write_string(&sb, indent)
        strings.write_string(&sb, l[common:])
    }
    return strings.to_string(sb)
}

// The statements of a block as lines indented by `indent`, each line ended by a newline.
@(private = "file")
block_lines :: proc(src: string, block: odinsyntax.Syntax_Node, indent: string) -> (string, bool) {
    b := block
    open, has_open := odinsyntax.find_child_token(&b, {tokens = {.Open_Brace}})
    close, has_close := odinsyntax.find_child_token(&b, {tokens = {.Close_Brace}, last = true})
    if !has_open || !has_close {
        return "", false
    }
    return body_lines(src, int(open.offset) + 1, int(close.offset), indent), true
}

// The text of [lo, hi) as whole lines indented by `indent`, each line ended by a newline.
@(private = "file")
body_lines :: proc(src: string, lo, hi: int, indent: string) -> string {
    text := strings.trim_space(src[lo:hi])
    if text == "" {
        return ""
    }
    first := lo + strings.index(src[lo:hi], text)
    prefix := src[line_start(src, first):first]
    if strings.trim_space(prefix) != "" {
        prefix = line_indent(src, first)
    }
    return strings.concatenate({reindent(strings.concatenate({prefix, text}, context.temp_allocator), indent), "\n"}, context.temp_allocator)
}

// Inlines the local at the caret into each of its uses and removes its declaration.
@(private = "file")
inline_variable :: proc(rc: ^Request_Context, m: ^odinsema.Scope_Map, caret: Caret, res: ^lang.Result) {
    src := rc.req.source
    ref, ok := odinsema.ref_at(m, caret.offset)
    if !ok || ref.kind != .Local {
        return
    }
    decl := ref.start if ref.is_decl else ref.decl
    local: odinsema.Local
    found := false
    for l in m.locals {
        if l.name_offset == decl {
            local, found = l, true
            break
        }
    }
    if !found || (local.kind != .Var && local.kind != .Const) || local.is_using || local.value_offset < 0 || local.value_index >= 0 || local.source != .Value {
        return
    }
    name_node, has_name := node_at(rc, decl)
    if !has_name || name_node.parent == nil || name_node.parent.green.kind != .Name_List || name_node.parent.parent == nil {
        return
    }
    decl_node := name_node.parent.parent^
    vd, is_decl := odinsyntax.as_value_decl(decl_node)
    if !is_decl {
        return
    }
    if _, has_attrs := odinsyntax.find_child_node(&decl_node, {kinds = {.Attribute}}); has_attrs {
        return
    }
    names, _ := odinsyntax.value_decl_names(&vd)
    values, has_values := odinsyntax.value_decl_values(&vd)
    if !has_values || count_children(odinsyntax.Syntax_Node(names)) != 1 || count_children(odinsyntax.Syntax_Node(values)) != 1 {
        return
    }
    vit := odinsyntax.expr_list_items(&values)
    value, _ := odinsyntax.child_iter_next(&vit)
    vs, ve := odinsyntax.node_range(value)
    uses := make([dynamic]odinsema.Name_Ref, context.temp_allocator)
    for r in m.refs {
        if r.kind != .Local || r.decl != decl || r.is_decl {
            continue
        }
        if r.is_store || !plain_read(rc, r.start) {
            return
        }
        append(&uses, r)
    }
    if len(uses) == 0 || (len(uses) > 1 && holds_kind(value, {.Call_Expr, .Selector_Call_Expr})) {
        return
    }
    last := uses[len(uses) - 1].end
    // Every name of the value names the same thing at each use, and no local it reads changes.
    for r in m.refs {
        if r.start < int(vs) || r.end > int(ve) {
            continue
        }
        if r.kind != .Local && r.kind != .Free {
            continue
        }
        for u in uses {
            l, visible := odinsema.visible_local(m, r.name, u.start)
            if r.kind == .Local && (!visible || l.name_offset != r.decl) {
                return
            }
            if r.kind == .Free && visible {
                return
            }
        }
        if r.kind == .Local && stored_between(m, r.decl, int(ve), last) {
            return
        }
    }
    text := src[vs:ve]
    compound := value.green.kind in odinsyntax.Kind_Set{.Binary_Expr, .Ternary_Expr, .Ternary_If_Expr, .Ternary_When_Expr, .Or_Else_Expr, .Or_Return_Expr, .Or_Branch_Expr}
    specs := make([dynamic]Edit_Spec, context.temp_allocator)
    ds, de := odinsyntax.node_range(decl_node)
    append(&specs, line_deletion(src, int(ds), int(de)))
    for u in uses {
        t := text
        if compound && needs_parens(rc, u.start) {
            t = strings.concatenate({"(", text, ")"}, context.temp_allocator)
        }
        append(&specs, Edit_Spec{u.start, u.end, t})
    }
    what := "constant" if local.kind == .Const else "variable"
    push_kind_action(res, rc.req, "refactor", strings.concatenate({"Inline ", what, " '", local.name, "'"}, context.temp_allocator), ..specs[:])
}

@(private = "file")
count_children :: proc(n: odinsyntax.Syntax_Node) -> int {
    n := n
    count := 0
    it := odinsyntax.child_iter(&n, {kinds = ALL_NODES})
    for _ in odinsyntax.child_iter_next(&it) {
        count += 1
    }
    return count
}

// True when the identifier at `offset` is only read: no assignment place, address, slice or `->` operand.
@(private = "file")
plain_read :: proc(rc: ^Request_Context, offset: int) -> bool {
    ident, ok := node_at(rc, offset)
    if !ok {
        return false
    }
    child := ident^
    for p := ident.parent; p != nil; p = p.parent {
        #partial switch p.green.kind {
        case .Unary_Expr:
            u := odinsyntax.Unary_Expr(p^)
            op, _ := odinsyntax.unary_expr_op(&u)
            if op.green.kind == .And {
                return false
            }
            return true
        case .Slice_Expr:
            s := odinsyntax.Slice_Expr(p^)
            operand, has := odinsyntax.slice_expr_operand(&s)
            return !(has && same_node(operand, child))
        case .Selector_Expr:
            s := odinsyntax.Selector_Expr(p^)
            operand, has := odinsyntax.selector_expr_operand(&s)
            if !has || !same_node(operand, child) {
                return true
            }
            if _, arrow := odinsyntax.selector_expr_arrow(&s); arrow {
                return false
            }
        case .Index_Expr:
        case .Expr_List:
            if p.parent != nil && p.parent.green.kind == .Assign_Stmt {
                as := odinsyntax.Assign_Stmt(p.parent^)
                lhs, has := odinsyntax.assign_stmt_lhs(&as)
                return !(has && lhs.offset == p.offset)
            }
            if p.parent != nil && p.parent.green.kind == .Range_Stmt {
                return false
            }
            return true
        case:
            return true
        }
        child = p^
    }
    return true
}

// True when the local declared at `decl` is a place of an assignment in (from, to).
@(private = "file")
stored_between :: proc(m: ^odinsema.Scope_Map, decl, from, to: int) -> bool {
    for r in m.refs {
        if r.kind == .Local && r.decl == decl && r.is_store && r.start > from && r.start < to {
            return true
        }
    }
    return false
}

// True when an expression put at the identifier at `offset` needs parentheses.
@(private = "file")
needs_parens :: proc(rc: ^Request_Context, offset: int) -> bool {
    ident, ok := node_at(rc, offset)
    if !ok || ident.parent == nil {
        return true
    }
    #partial switch ident.parent.green.kind {
    case .Expr_List, .Arg_List, .Paren_Expr, .Field_Value, .Return_Stmt:
        return false
    }
    return true
}

// The subject and the values of an `if` condition `s == a || s == b`. False for any other shape.
@(private = "file")
equality_values :: proc(cond: odinsyntax.Syntax_Node, out: ^[dynamic]string, subject: ^string) -> bool {
    cond := cond
    if cond.green.kind == .Paren_Expr {
        p := odinsyntax.Paren_Expr(cond)
        inner, ok := odinsyntax.paren_expr_expr(&p)
        return ok && equality_values(inner, out, subject)
    }
    b, is_binary := odinsyntax.as_binary_expr(cond)
    if !is_binary {
        return false
    }
    op, _ := odinsyntax.binary_expr_op(&b)
    lhs, has_lhs := odinsyntax.binary_expr_lhs(&b)
    rhs, has_rhs := odinsyntax.binary_expr_rhs(&b)
    if !has_lhs || !has_rhs {
        return false
    }
    #partial switch op.green.kind {
    case .Cmp_Or:
        return equality_values(lhs, out, subject) && equality_values(rhs, out, subject)
    case .Cmp_Eq:
        if !pure_subject(lhs) {
            return false
        }
        text := odinsyntax.node_text(lhs)
        if subject^ == "" {
            subject^ = text
        } else if subject^ != text {
            return false
        }
        append(out, odinsyntax.node_text(rhs))
        return true
    }
    return false
}

// True for an identifier or a selector chain of identifiers.
@(private = "file")
pure_subject :: proc(n: odinsyntax.Syntax_Node) -> bool {
    n := n
    #partial switch n.green.kind {
    case .Ident:
        return true
    case .Selector_Expr:
        s := odinsyntax.Selector_Expr(n)
        if _, arrow := odinsyntax.selector_expr_arrow(&s); arrow {
            return false
        }
        operand, ok := odinsyntax.selector_expr_operand(&s)
        return ok && pure_subject(operand)
    }
    return false
}

// Turns `if s == a {} else if s == b || s == c {} else {}` into a `switch s`.
@(private = "file")
if_to_switch :: proc(rc: ^Request_Context, head: odinsyntax.Syntax_Node, res: ^lang.Result) {
    src := rc.req.source
    indent := line_indent(src, int(head.offset))
    unit := indent_unit(rc.req)
    subject := ""
    init := ""
    sb := strings.builder_make(context.temp_allocator)
    branches := 0
    node := head
    for {
        s := odinsyntax.If_Stmt(node)
        if _, labelled := odinsyntax.if_stmt_label(&s); labelled {
            return
        }
        if in_init, has_init := odinsyntax.if_stmt_init(&s); has_init {
            if branches > 0 {
                return
            }
            init = odinsyntax.node_text(in_init)
        }
        cond, has_cond := odinsyntax.if_stmt_cond(&s)
        body, has_body := odinsyntax.if_stmt_body(&s)
        if !has_cond || !has_body || body.green.kind != .Block || breaks_out(body) {
            return
        }
        values := make([dynamic]string, context.temp_allocator)
        if !equality_values(cond, &values, &subject) {
            return
        }
        lines, ok := block_lines(src, body, strings.concatenate({indent, unit}, context.temp_allocator))
        if !ok {
            return
        }
        strings.write_string(&sb, indent)
        strings.write_string(&sb, "case ")
        strings.write_string(&sb, strings.join(values[:], ", ", context.temp_allocator))
        strings.write_string(&sb, ":\n")
        strings.write_string(&sb, lines)
        branches += 1
        next, has_else := odinsyntax.if_stmt_else_branch(&s)
        if !has_else {
            break
        }
        if next.green.kind == .If_Stmt {
            node = next
            continue
        }
        if next.green.kind != .Block || breaks_out(next) {
            return
        }
        lines, ok = block_lines(src, next, strings.concatenate({indent, unit}, context.temp_allocator))
        if !ok {
            return
        }
        strings.write_string(&sb, indent)
        strings.write_string(&sb, "case:\n")
        strings.write_string(&sb, lines)
        break
    }
    if branches < 2 {
        return
    }
    head_text := strings.concatenate({"switch ", init, "; " if init != "" else "", subject, " {\n"}, context.temp_allocator)
    text := strings.concatenate({head_text, strings.to_string(sb), indent, "}"}, context.temp_allocator)
    start, end := odinsyntax.node_range(head)
    push_kind_action(res, rc.req, "refactor", "Convert to switch", Edit_Spec{int(start), int(end), text})
}

// Turns a value `switch` into an `if` chain.
@(private = "file")
switch_to_if :: proc(rc: ^Request_Context, sw: odinsyntax.Syntax_Node, res: ^lang.Result) {
    src := rc.req.source
    s := odinsyntax.Switch_Stmt(sw)
    if _, labelled := odinsyntax.switch_stmt_label(&s); labelled {
        return
    }
    subject := ""
    if tag, has_tag := odinsyntax.switch_stmt_tag(&s); has_tag {
        if !pure_subject(tag) {
            return
        }
        subject = odinsyntax.node_text(tag)
    }
    init := ""
    if in_init, has_init := odinsyntax.switch_stmt_init(&s); has_init {
        init = odinsyntax.node_text(in_init)
    }
    body, has_body := odinsyntax.switch_stmt_body(&s)
    if !has_body {
        return
    }
    indent := line_indent(src, int(sw.offset))
    unit := indent_unit(rc.req)
    conds := make([dynamic]string, context.temp_allocator)
    bodies := make([dynamic]string, context.temp_allocator)
    fallback := ""
    has_default := false
    block := odinsyntax.Syntax_Node(body)
    it := odinsyntax.child_iter(&block, {kinds = {.Case_Clause}})
    for clause in odinsyntax.child_iter_next(&it) {
        if breaks_out(clause) {
            return
        }
        clause := clause
        cc := odinsyntax.Case_Clause(clause)
        colon, has_colon := odinsyntax.find_child_token(&clause, {tokens = {.Colon}})
        if !has_colon {
            return
        }
        _, ce := odinsyntax.node_range(clause)
        lines := body_lines(src, int(colon.offset) + 1, int(ce), strings.concatenate({indent, unit}, context.temp_allocator))
        values, has_values := odinsyntax.case_clause_values(&cc)
        if !has_values {
            fallback, has_default = lines, true
            continue
        }
        parts := make([dynamic]string, context.temp_allocator)
        vit := odinsyntax.expr_list_items(&values)
        for v in odinsyntax.child_iter_next(&vit) {
            part, ok := case_condition(subject, v)
            if !ok {
                return
            }
            append(&parts, part)
        }
        if len(parts) > 1 {
            for &p in parts {
                if strings.contains(p, "&&") || (subject == "" && strings.contains(p, " ")) {
                    p = strings.concatenate({"(", p, ")"}, context.temp_allocator)
                }
            }
        }
        append(&conds, strings.join(parts[:], " || ", context.temp_allocator))
        append(&bodies, lines)
    }
    if len(conds) == 0 {
        return
    }
    sb := strings.builder_make(context.temp_allocator)
    for cond, i in conds {
        if i == 0 {
            strings.write_string(&sb, "if ")
            if init != "" {
                strings.write_string(&sb, init)
                strings.write_string(&sb, "; ")
            }
        } else {
            strings.write_string(&sb, " else if ")
        }
        strings.write_string(&sb, cond)
        strings.write_string(&sb, " {\n")
        strings.write_string(&sb, bodies[i])
        strings.write_string(&sb, indent)
        strings.write_byte(&sb, '}')
    }
    if has_default && fallback != "" {
        strings.write_string(&sb, " else {\n")
        strings.write_string(&sb, fallback)
        strings.write_string(&sb, indent)
        strings.write_byte(&sb, '}')
    }
    start, end := odinsyntax.node_range(sw)
    push_kind_action(res, rc.req, "refactor", "Convert to if chain", Edit_Spec{int(start), int(end), strings.to_string(sb)})
}

// The condition one case value stands for: `s == v`, a range test, or the value itself with no subject.
@(private = "file")
case_condition :: proc(subject: string, v: odinsyntax.Syntax_Node) -> (string, bool) {
    if subject == "" {
        return odinsyntax.node_text(v), true
    }
    if b, is_binary := odinsyntax.as_binary_expr(v); is_binary {
        op, _ := odinsyntax.binary_expr_op(&b)
        lo, has_lo := odinsyntax.binary_expr_lhs(&b)
        hi, has_hi := odinsyntax.binary_expr_rhs(&b)
        if op.green.kind == .Range_Half || op.green.kind == .Range_Full || op.green.kind == .Ellipsis {
            if !has_lo || !has_hi {
                return "", false
            }
            cmp := " < " if op.green.kind == .Range_Half else " <= "
            return strings.concatenate({subject, " >= ", odinsyntax.node_text(lo), " && ", subject, cmp, odinsyntax.node_text(hi)}, context.temp_allocator), true
        }
    }
    return strings.concatenate({subject, " == ", odinsyntax.node_text(v)}, context.temp_allocator), true
}
