// Expression printing: literals, operators and the type syntax
// (proc/struct/union/enum/pointer/array/... — Odin folds type expressions
// into expressions, so this file covers both).
package odinfmt

import "core:strings"

import syn "../syntax"

print_expr :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    if !is_node(expr) || pr.too_deep {
        return
    }
    pr.depth += 1
    defer pr.depth -= 1
    if pr.depth > MAX_DEPTH {
        pr.too_deep = true
        return
    }
    #partial switch expr.kind {
    case .Ident, .Literal, .Context_Expr, .Undef_Expr:
        append(out, text(leaf_text(pr, expr)))

    case .Directive:
        print_directive_node(pr, out, expr)

    case .Proc_Lit:
        print_proc_lit(pr, out, expr)

    case .Comp_Lit:
        print_comp_lit_node(pr, out, expr)

    case .Tag_Expr, .Helper_Type:
        print_tag_expr_node(pr, out, expr)

    case .Unary_Expr:
        print_unary_expr_node(pr, out, expr)

    case .Binary_Expr:
        print_binary_expr_node(pr, out, expr)

    case .Ternary_Expr, .Ternary_If_Expr, .Ternary_When_Expr, .Or_Else_Expr, .Or_Return_Expr, .Or_Branch_Expr:
        print_spaced_node(pr, out, expr)

    case .Paren_Expr:
        print_paren_expr_node(pr, out, expr)

    case .Selector_Expr, .Implicit_Selector:
        // Operand, `.` or `->`, and the field, with nothing between.
        print_tight(pr, out, kids(expr))

    case .Selector_Call_Expr:
        print_selector_call_expr_node(pr, out, expr)

    case .Index_Expr, .Matrix_Index_Expr, .Slice_Expr:
        print_index_node(pr, out, expr)

    case .Deref_Expr:
        print_deref_expr_node(pr, out, expr)

    case .Call_Expr:
        print_call_expr_node(pr, out, expr)

    case .Spread_Expr:
        print_spread_expr_node(pr, out, expr)

    case .Field_Value:
        print_field_value_node(pr, out, expr)

    case .Type_Assertion:
        print_type_assertion_node(pr, out, expr)

    case .Cast_Expr:
        print_cast_expr_node(pr, out, expr)

    case .Auto_Cast_Expr:
        print_auto_cast_expr_node(pr, out, expr)

    case .Proc_Group:
        print_proc_group_node(pr, out, expr)

    case .Typeid_Type, .Poly_Type:
        // `typeid/T`, `$T/U`.
        print_tight(pr, out, kids(expr))

    case .Distinct_Type:
        print_distinct_type_node(pr, out, expr)

    case .Ellipsis_Type:
        print_ellipsis_type_node(pr, out, expr)

    case .Proc_Type:
        print_proc_type_head(pr, out, expr)
        print_proc_tags(pr, out, kids(expr))

    case .Pointer_Type:
        print_pointer_type_node(pr, out, expr)

    case .Multi_Pointer_Type:
        print_multi_pointer_type_node(pr, out, expr)

    case .Array_Type:
        print_array_type_node(pr, out, expr)

    case .Dynamic_Array_Type:
        print_dynamic_array_type_node(pr, out, expr)

    case .Struct_Type:
        print_struct_type(pr, out, expr)

    case .Union_Type:
        print_union_type(pr, out, expr)

    case .Enum_Type:
        print_enum_type(pr, out, expr)

    case .Bit_Set_Type:
        print_bit_set_type_node(pr, out, expr)

    case .Map_Type:
        print_map_type_node(pr, out, expr)

    case .Matrix_Type:
        print_matrix_type_node(pr, out, expr)

    case .Bit_Field_Type:
        print_bit_field_type(pr, out, expr)

    case .Asm_Template:
        print_asm_template(pr, out, expr)

    case .Asm_Register, .Asm_Label:
        print_tight(pr, out, kids(expr))

    case .Asm_Memory_Operand:
        print_asm_memory_operand(pr, out, expr)

    case .Asm_Register_Group:
        print_asm_register_group(pr, out, expr)

    case:
        append(out, text(strings.trim_space(node_text(pr, expr))))
    }
}

// The text of a node that holds one token.
@(private)
leaf_text :: proc(pr: ^Printer, n: Node) -> string {
    for k in kids(n) {
        if !is_node(k) {
            return node_text(pr, k)
        }
    }
    return strings.trim_space(node_text(pr, n))
}

// The first node in `ks`.
@(private)
first_node :: proc(ks: []Node) -> (Node, bool) {
    for k in ks {
        if is_node(k) {
            return k, true
        }
    }
    return {}, false
}

// The nodes in `ks`.
@(private)
node_kids :: proc(ks: []Node) -> []Node {
    out := make([dynamic]Node, 0, len(ks))
    for k in ks {
        if is_node(k) {
            append(&out, k)
        }
    }
    return out[:]
}

// The children of `ks` with nothing between them.
@(private)
print_tight :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    for k in ks {
        if is_node(k) {
            print_expr(pr, out, k)
        } else {
            append(out, text(node_text(pr, k)))
        }
    }
}

// The operands and the operator of a binary expression.
@(private)
binary_parts :: proc(pr: ^Printer, n: Node) -> (lhs, rhs: Node, op: syn.Token_Kind, op_text: string) {
    ks := kids(n)
    at := -1
    for k, i in ks {
        if !is_node(k) {
            at = i
            break
        }
    }
    if at < 0 {
        lhs, _ = first_node(ks)
        return
    }
    op = ks[at].tok
    op_text = node_text(pr, ks[at])
    lhs, _ = first_node(ks[:at])
    rhs, _ = first_node(ks[at + 1:])
    return
}

// A run of one operator (`a && b && c`) as a group: on one line when it fits
// character_width, else broken after each operator with the operands one indent
// in. A newline after an operator ends no statement in Odin.
@(private)
print_binary_chain :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: Node) {
    first, right, op, op_text := binary_parts(pr, e)
    rights := make([dynamic]Node, context.temp_allocator)
    append(&rights, right)
    for first.kind == .Binary_Expr {
        inner_left, inner_right, inner_op, _ := binary_parts(pr, first)
        if inner_op != op {
            break
        }
        append(&rights, inner_right)
        first = inner_left
    }
    head: [dynamic]Doc
    print_expr(pr, &head, first)
    body: [dynamic]Doc
    #reverse for r in rights {
        append(&body, text(" "))
        append(&body, text(op_text))
        append(&body, line())
        print_expr(pr, &body, r)
    }
    append(&head, indent(body[:]))
    append(out, group(head[:]))
}

// The right operand after the comments written before it. A block comment on
// the operand's line stays inline; any other comment ends the line after the
// operator, and the operand goes on the next line, one indent in.
@(private)
print_binary_comments :: proc(pr: ^Printer, out: ^[dynamic]Doc, right: Node) {
    inline := true
    right_line := start_line(pr, right)
    for i := pr.comment_idx; i < len(pr.comments) && pr.comments[i].start < right.start; i += 1 {
        cg := pr.comments[i]
        for tok in cg.list {
            if !strings.has_prefix(tok.text, "/*") || comment_end_line(tok) != right_line || tok.line != right_line {
                inline = false
            }
        }
    }
    comments := take_comments_before(pr, right.start)
    if inline {
        for c in comments {
            append(out, text(" "))
            append(out, c)
        }
        append(out, text(" "))
        print_expr(pr, out, right)
        return
    }
    body: [dynamic]Doc
    for c, i in comments {
        append(&body, i == 0 ? text("  ") : hard_line(0))
        append(&body, c)
    }
    append(&body, hard_line(0))
    print_expr(pr, &body, right)
    append(out, indent(body[:]))
}

// The `{...}` of a composite literal; `ks` are the children of the literal.
@(private)
print_comp_lit_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    open := tok_index(ks, .Open_Brace)
    close := tok_index(ks, .Close_Brace)
    if open < 0 || close < 0 {
        append(out, text("{}"))
        return
    }
    elems := expr_kids(ks[open + 1:close])
    if len(elems) == 0 {
        append(out, text("{}"))
        return
    }
    open_line := start_line(pr, ks[open])
    close_line := start_line(pr, ks[close])
    close_offset := ks[close].start
    multiline := pr.opts.exp_multiline_composite_literals && open_line != close_line
    if !multiline {
        // The group is off when exp_multiline_composite_literals is on: it
        // would break a literal the source wrote on one line, and the second
        // format would then read `open.line != close.line` and take the other
        // branch instead — the same input rendering two ways.
        if pr.opts.exp_multiline_composite_literals {
            append(out, text("{"))
            print_expr_list(pr, out, elems)
            append(out, text("}"))
            return
        }
        items := make([dynamic]List_Item, 0, len(elems))
        for el, i in elems {
            item := List_Item {leading = take_comments_before(pr, el.start)}
            elem: [dynamic]Doc
            print_expr(pr, &elem, el)
            item.doc = concat(elem[:])
            next := i + 1 < len(elems) ? elems[i + 1].start : close_offset
            item.trailing = take_trailing(pr, end_line(pr, el), next)
            append(&items, item)
        }
        append_list_group(pr, out, "{", "}", items[:], take_comments_before(pr, close_offset))
        return
    }
    append(out, text("{"))
    assign_field_value_align_ids(pr, elems)
    body: [dynamic]Doc
    prev_line := open_line
    has_prev := true
    for el in elems {
        separator(pr, &body, prev_line, has_prev, start_line(pr, el), true)
        elem_doc: [dynamic]Doc
        print_expr(pr, &elem_doc, el)
        for d in elem_doc {
            append(&body, d)
        }
        append(&body, text(","))
        prev_line = end_line(pr, el)
        has_prev = true
    }
    flush_before(pr, &body, prev_line, has_prev, close_line, true)
    append(out, indent(body[:]))
    append(out, hard_line(0))
    append(out, text("}"))
}

// The `(...)` of a call.
@(private)
print_arg_list :: proc(pr: ^Printer, out: ^[dynamic]Doc, list: Node) {
    ks := kids(list)
    args := expr_kids(ks)
    close_offset := list.end
    if i := tok_index(ks, .Close_Paren); i >= 0 {
        close_offset = ks[i].start
    }
    items := make([dynamic]List_Item, 0, len(args))
    for a, i in args {
        item := List_Item {leading = take_comments_before(pr, a.start)}
        arg: [dynamic]Doc
        print_expr(pr, &arg, a)
        item.doc = concat(arg[:])
        next := i + 1 < len(args) ? args[i + 1].start : close_offset
        item.trailing = take_trailing(pr, end_line(pr, a), next)
        append(&items, item)
    }
    append_list_group(pr, out, "(", ")", items[:], take_comments_before(pr, close_offset))
}

// The directives of a procedure type or literal, each with a space before it.
@(private)
print_proc_tags :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    for k in ks {
        if k.kind == .Directive {
            append(out, text(" "))
            print_expr(pr, out, k)
        }
    }
}

// The signature only — params, results, calling convention — with no tags.
@(private)
print_proc_type_head :: proc(pr: ^Printer, out: ^[dynamic]Doc, pt: Node) {
    ks := kids(pt)
    append(out, text("proc"))
    if i := tok_index(ks, .String); i >= 0 {
        append(out, text(" "))
        append(out, text(node_text(pr, ks[i])))
    }
    params, _ := find_kind(ks, .Param_List)
    print_param_list(pr, out, params)
    results, _ := find_kind(ks, .Result_List)
    print_signature_results(pr, out, results)
}

// `(field, field)` of a parameter list, a group that wraps one per line.
@(private)
print_param_list :: proc(pr: ^Printer, out: ^[dynamic]Doc, params: Node) {
    if !is_node(params) {
        append(out, text("()"))
        return
    }
    ks := kids(params)
    close_offset := params.end
    if i := tok_index(ks, .Close_Paren); i >= 0 {
        close_offset = ks[i].start
    }
    append_field_list_group(pr, out, "(", ")", field_kids(ks), close_offset)
}

// The Field nodes in `ks`.
@(private)
field_kids :: proc(ks: []Node) -> []Node {
    out := make([dynamic]Node, 0, len(ks))
    for k in ks {
        if k.kind == .Field {
            append(&out, k)
        }
    }
    return out[:]
}

// The `-> ...` half of a signature, shared with the `asm` template — a lone
// unnamed result keeps its bare form, every other list is parenthesised.
// parenthesise_single keeps the parentheses of a lone unnamed result for an
// `asm` template that carries a specification list: `-> int [` re-parses as a
// slice of the result type, `-> (int) [` does not.
@(private)
print_signature_results :: proc(pr: ^Printer, out: ^[dynamic]Doc, results: Node, parenthesise_single := false) {
    if !is_node(results) {
        return
    }
    ks := kids(results)
    if has_tok(ks, .Not) {
        append(out, text(" -> !"))
        return
    }
    fields := field_kids(ks)
    if len(fields) == 0 {
        return
    }
    append(out, text(" -> "))
    single_unnamed := len(fields) == 1 && !field_has_names(fields[0])
    if single_unnamed && !parenthesise_single {
        // A block comment between `->` and the type stays there.
        if inline_comments_before(pr, fields[0].start) {
            for c in take_comments_before(pr, fields[0].start) {
                append(out, c)
                append(out, text(" "))
            }
        }
        print_field(pr, out, fields[0])
        return
    }
    close_offset := results.end
    if i := tok_index(ks, .Close_Paren); i >= 0 {
        close_offset = ks[i].start
    }
    append_field_list_group(pr, out, "(", ")", fields, close_offset)
}

@(private)
print_proc_lit :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: Node) {
    ks := kids(e)
    pt, _ := find_kind(ks, .Proc_Type)
    print_proc_type_head(pr, out, pt)
    if wc, ok := find_kind(ks, .Where_Clause); ok {
        print_where(pr, out, wc)
    }
    print_proc_tags(pr, out, kids(pt))
    print_proc_tags(pr, out, ks)
    if has_tok(ks, .Undef) {
        append(out, text(" ---"))
        return
    }
    for k in ks {
        if k.kind == .Block || k.kind == .Do_Body {
            print_body(pr, out, k, true)
            return
        }
    }
}

// The directives of a struct or union, each with its argument: ` #align(16)`.
@(private)
print_type_directives :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    for k, i in ks {
        if k.kind != .Directive {
            continue
        }
        append(out, text(" "))
        print_expr(pr, out, k)
        if i + 1 >= len(ks) {
            continue
        }
        arg := ks[i + 1]
        if !is_expr(arg) || arg.kind == .Directive {
            continue
        }
        append(out, text("("))
        if arg.kind == .Paren_Expr {
            if inner, ok := first_node(kids(arg)); ok {
                print_expr(pr, out, inner)
            }
        } else {
            print_expr(pr, out, arg)
        }
        append(out, text(")"))
    }
}

// The `(...)` parameters of a polymorphic struct or union.
@(private)
print_poly_params :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    params, ok := find_kind(ks, .Param_List)
    if !ok {
        return
    }
    append(out, text("("))
    print_field_list(pr, out, field_kids(kids(params)))
    append(out, text(")"))
}

// The lines of the `{` and `}` in `ks`.
@(private)
brace_lines :: proc(pr: ^Printer, ks: []Node, fallback: Node) -> (open_line, close_line: int) {
    open_line = start_line(pr, fallback)
    close_line = end_line(pr, fallback)
    if i := tok_index(ks, .Open_Brace); i >= 0 {
        open_line = start_line(pr, ks[i])
    }
    if i := tok_index(ks, .Close_Brace); i >= 0 {
        close_line = start_line(pr, ks[i])
    }
    return
}

@(private)
print_struct_type :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: Node) {
    ks := kids(e)
    append(out, text("struct"))
    print_poly_params(pr, out, ks)
    print_type_directives(pr, out, ks)
    if wc, ok := find_kind(ks, .Where_Clause); ok {
        print_where(pr, out, wc)
    }
    list, ok := find_kind(ks, .Field_List)
    if !ok {
        append(out, text(" {}"))
        return
    }
    lks := kids(list)
    fields := field_kids(lks)
    open_line, close_line := brace_lines(pr, lks, list)
    print_brace_lead(pr, out, false, len(fields) == 0)
    print_field_brace_body(pr, out, open_line, close_line, fields)
}

@(private)
print_union_type :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: Node) {
    ks := kids(e)
    append(out, text("union"))
    print_poly_params(pr, out, ks)
    print_type_directives(pr, out, ks)
    if wc, ok := find_kind(ks, .Where_Clause); ok {
        print_where(pr, out, wc)
    }
    open := tok_index(ks, .Open_Brace)
    variants := expr_kids(ks[open + 1:]) if open >= 0 else []Node{}
    _, close_line := brace_lines(pr, ks, e)
    print_brace_lead(pr, out, false, len(variants) == 0)
    print_expr_brace_body(pr, out, close_line, variants)
}

@(private)
print_enum_type :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: Node) {
    ks := kids(e)
    append(out, text("enum"))
    open := tok_index(ks, .Open_Brace)
    if backing, ok := expr_in(ks, 0, open < 0 ? len(ks) : open); ok {
        append(out, text(" "))
        print_expr(pr, out, backing)
    }
    members := expr_kids(ks[open + 1:]) if open >= 0 else []Node{}
    _, close_line := brace_lines(pr, ks, e)
    print_brace_lead(pr, out, false, len(members) == 0)
    print_expr_brace_body(pr, out, close_line, members)
}

@(private)
print_bit_field_type :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: Node) {
    ks := kids(e)
    append(out, text("bit_field "))
    open := tok_index(ks, .Open_Brace)
    if backing, ok := expr_in(ks, 0, open < 0 ? len(ks) : open); ok {
        print_expr(pr, out, backing)
    }
    fields := make([dynamic]Node, 0, len(ks))
    for k in ks {
        if k.kind == .Bit_Field_Field {
            append(&fields, k)
        }
    }
    _, close_line := brace_lines(pr, ks, e)
    print_brace_lead(pr, out, false, len(fields) == 0)
    print_bit_field_brace_body(pr, out, close_line, fields[:])
}

@(private)
print_directive_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    append(out, text("#"))
    ks := kids(expr)
    if i := tok_index(ks, .Ident); i >= 0 {
        append(out, text(node_text(pr, ks[i])))
    }
}

@(private)
print_comp_lit_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    open := tok_index(ks, .Open_Brace)
    if t, ok := expr_in(ks, 0, open < 0 ? len(ks) : open); ok {
        print_expr(pr, out, t)
    }
    print_comp_lit_body(pr, out, ks)
}

@(private)
print_tag_expr_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    nodes := node_kids(ks)
    for n, i in nodes {
        if i > 0 {
            append(out, text(" "))
        }
        print_expr(pr, out, n)
    }
}

@(private)
print_unary_expr_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    op: Node
    for k in ks {
        if !is_node(k) {
            op = k
            break
        }
    }
    append(out, text(node_text(pr, op)))
    if operand, ok := first_node(ks); ok {
        // `--`, `++` and `&&` are one token each.
        if operand.kind == .Unary_Expr {
            inner_op: Node
            for k in kids(operand) {
                if !is_node(k) {
                    inner_op = k
                    break
                }
            }
            if inner_op.tok == op.tok {
                #partial switch op.tok {
                case .Sub, .Add, .And:
                    append(out, text(" "))
                }
            }
        }
        print_expr(pr, out, operand)
    }
}

@(private)
print_binary_expr_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    lhs, rhs, _, op_text := binary_parts(pr, expr)
    if !comment_before(pr, rhs.start) {
        print_binary_chain(pr, out, expr)
        return
    }
    print_expr(pr, out, lhs)
    append(out, text(" "))
    append(out, text(op_text))
    print_binary_comments(pr, out, rhs)
}

// Operands and keywords, one space between each.
@(private)
print_spaced_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    for k, i in kids(expr) {
        if i > 0 {
            append(out, text(" "))
        }
        if is_node(k) {
            print_expr(pr, out, k)
        } else {
            append(out, text(node_text(pr, k)))
        }
    }
}

@(private)
print_paren_expr_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    append(out, text("("))
    if inner, ok := first_node(kids(expr)); ok {
        print_expr(pr, out, inner)
    }
    append(out, text(")"))
}

@(private)
print_selector_call_expr_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    if call, ok := first_node(kids(expr)); ok {
        print_expr(pr, out, call)
    }
}

// `x[i]`, `m[r, c]`, `s[lo:hi]`.
@(private)
print_index_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    for k in kids(expr) {
        if is_node(k) {
            print_expr(pr, out, k)
        } else if k.tok == .Comma {
            append(out, text(", "))
        } else {
            append(out, text(node_text(pr, k)))
        }
    }
}

@(private)
print_deref_expr_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    if operand, ok := first_node(kids(expr)); ok {
        print_expr(pr, out, operand)
    }
    append(out, text("^"))
}

@(private)
print_call_expr_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    if callee, ok := first_node(ks); ok && callee.kind != .Arg_List {
        print_expr(pr, out, callee)
    }
    if args, ok := find_kind(ks, .Arg_List); ok {
        print_arg_list(pr, out, args)
    }
}

@(private)
print_spread_expr_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    append(out, text(".."))
    if operand, ok := first_node(kids(expr)); ok {
        print_expr(pr, out, operand)
    }
}

@(private)
print_field_value_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    eq := tok_index(ks, .Eq)
    name, _ := expr_in(ks, 0, eq < 0 ? len(ks) : eq)
    if cell := align_cell(pr, expr); cell.head != 0 {
        field_doc: [dynamic]Doc
        print_expr(pr, &field_doc, name)
        append(out, align(cell.head, field_doc[:]))
    } else {
        print_expr(pr, out, name)
    }
    append(out, text(" = "))
    if eq >= 0 {
        if value, ok := expr_in(ks, eq + 1, len(ks)); ok {
            print_expr(pr, out, value)
        }
    }
}

@(private)
print_type_assertion_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    dot := tok_index(ks, .Period)
    if operand, ok := expr_in(ks, 0, dot < 0 ? len(ks) : dot); ok {
        print_expr(pr, out, operand)
    }
    append(out, text("."))
    if has_tok(ks, .Question) {
        append(out, text("?"))
    } else if t, ok := expr_in(ks, dot + 1, len(ks)); ok {
        append(out, text("("))
        print_expr(pr, out, t)
        append(out, text(")"))
    }
}

@(private)
print_cast_expr_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    for k in ks {
        if is_tok(k, .Cast) || is_tok(k, .Transmute) {
            append(out, text(node_text(pr, k)))
        }
    }
    close := tok_index(ks, .Close_Paren)
    append(out, text("("))
    if t, ok := expr_in(ks, 0, close < 0 ? len(ks) : close); ok {
        print_expr(pr, out, t)
    }
    append(out, text(")"))
    if close >= 0 {
        if operand, ok := expr_in(ks, close + 1, len(ks)); ok {
            print_expr(pr, out, operand)
        }
    }
}

@(private)
print_auto_cast_expr_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    append(out, text("auto_cast "))
    if operand, ok := first_node(kids(expr)); ok {
        print_expr(pr, out, operand)
    }
}

@(private)
print_proc_group_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    append(out, text("proc{"))
    print_expr_list(pr, out, expr_kids(kids(expr)))
    append(out, text("}"))
}

@(private)
print_distinct_type_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    append(out, text("distinct "))
    if t, ok := first_node(kids(expr)); ok {
        print_expr(pr, out, t)
    }
}

@(private)
print_ellipsis_type_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    append(out, text(".."))
    if t, ok := first_node(kids(expr)); ok {
        print_expr(pr, out, t)
    }
}

@(private)
print_pointer_type_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    append(out, text("^"))
    if t, ok := first_node(kids(expr)); ok {
        print_expr(pr, out, t)
    }
}

@(private)
print_multi_pointer_type_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    append(out, text("[^]"))
    if t, ok := first_node(kids(expr)); ok {
        print_expr(pr, out, t)
    }
}

@(private)
print_array_type_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    close := tok_index(ks, .Close_Bracket)
    append(out, text("["))
    if has_tok(ks[:max(close, 0)], .Question) {
        append(out, text("?"))
    } else if n, ok := expr_in(ks, 0, close); ok {
        print_expr(pr, out, n)
    }
    append(out, text("]"))
    if elem, ok := expr_in(ks, close + 1, len(ks)); ok {
        print_expr(pr, out, elem)
    }
}

@(private)
print_dynamic_array_type_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    close := tok_index(ks, .Close_Bracket)
    append(out, text("[dynamic"))
    if capacity, ok := expr_in(ks, 0, close); ok {
        append(out, text("; "))
        print_expr(pr, out, capacity)
    }
    append(out, text("]"))
    if elem, ok := expr_in(ks, close + 1, len(ks)); ok {
        print_expr(pr, out, elem)
    }
}

@(private)
print_bit_set_type_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    semi := tok_index(ks, .Semicolon)
    append(out, text("bit_set["))
    if elem, ok := expr_in(ks, 0, semi < 0 ? len(ks) : semi); ok {
        print_expr(pr, out, elem)
    }
    if semi >= 0 {
        if backing, ok := expr_in(ks, semi + 1, len(ks)); ok {
            append(out, text("; "))
            print_expr(pr, out, backing)
        }
    }
    append(out, text("]"))
}

@(private)
print_map_type_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    close := tok_index(ks, .Close_Bracket)
    append(out, text("map["))
    if key, ok := expr_in(ks, 0, close); ok {
        print_expr(pr, out, key)
    }
    append(out, text("]"))
    if value, ok := expr_in(ks, close + 1, len(ks)); ok {
        print_expr(pr, out, value)
    }
}

@(private)
print_matrix_type_node :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: Node) {
    ks := kids(expr)
    close := tok_index(ks, .Close_Bracket)
    comma := tok_index(ks, .Comma)
    append(out, text("matrix["))
    if rows, ok := expr_in(ks, 0, comma); ok {
        print_expr(pr, out, rows)
    }
    append(out, text(", "))
    if columns, ok := expr_in(ks, comma + 1, close); ok {
        print_expr(pr, out, columns)
    }
    append(out, text("]"))
    if elem, ok := expr_in(ks, close + 1, len(ks)); ok {
        print_expr(pr, out, elem)
    }
}

// Whether the pending comments before `offset` are all one-line block comments.
@(private)
inline_comments_before :: proc(pr: ^Printer, offset: int) -> bool {
    found := false
    for i := pr.comment_idx; i < len(pr.comments) && pr.comments[i].start < offset; i += 1 {
        for c in pr.comments[i].list {
            if !strings.has_prefix(c.text, "/*") || strings.contains(c.text, "\n") {
                return false
            }
            found = true
        }
    }
    return found
}
