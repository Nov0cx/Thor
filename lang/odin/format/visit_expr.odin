// Expression printing: literals, operators and the Expr-derived type syntax
// (proc/struct/union/enum/pointer/array/... — Odin folds type expressions
// into Any_Expr, so this file covers both).
package odinfmt

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

print_expr :: proc(pr: ^Printer, out: ^[dynamic]Doc, expr: ^ast.Expr) {
    if expr == nil || pr.too_deep {
        return
    }
    pr.depth += 1
    defer pr.depth -= 1
    if pr.depth > MAX_DEPTH {
        pr.too_deep = true
        return
    }
    print_state_flags(out, expr.state_flags)
    switch e in expr.derived_expr {
    case ^ast.Bad_Expr:
    // Unreachable: format() refuses any source with a parse error.

    case ^ast.Ident:
        append(out, text(e.name))

    case ^ast.Implicit:
        append(out, text(e.tok.text))

    case ^ast.Undef:
        append(out, text(tokenizer.to_string(e.tok)))

    case ^ast.Basic_Lit:
        append(out, text(e.tok.text))

    case ^ast.Basic_Directive:
        append(out, text("#"))
        append(out, text(e.name))

    case ^ast.Ellipsis:
        append(out, text(tokenizer.to_string(e.tok)))
        if e.expr != nil {
            print_expr(pr, out, e.expr)
        }

    case ^ast.Proc_Lit:
        print_proc_lit(pr, out, e)

    case ^ast.Comp_Lit:
        if e.tag != nil {
            print_expr(pr, out, e.tag)
            append(out, text(" "))
        }
        if e.type != nil {
            print_expr(pr, out, e.type)
        }
        print_comp_lit_body(pr, out, e)

    case ^ast.Tag_Expr:
        append(out, text("#"))
        append(out, text(e.name))
        append(out, text(" "))
        print_expr(pr, out, e.expr)

    case ^ast.Unary_Expr:
        append(out, text(e.op.text))
        if e.expr != nil {
            // `--`, `++` and `&&` are one token each.
            if inner, ok := e.expr.derived_expr.(^ast.Unary_Expr); ok && inner.op.kind == e.op.kind {
                #partial switch e.op.kind {
                case .Sub, .Add, .And:
                    append(out, text(" "))
                }
            }
            print_expr(pr, out, e.expr)
        }

    case ^ast.Binary_Expr:
        if !comment_before(pr, e.right.pos.offset) {
            print_binary_chain(pr, out, e)
            return
        }
        print_expr(pr, out, e.left)
        append(out, text(" "))
        append(out, text(e.op.text))
        print_binary_comments(pr, out, e)

    case ^ast.Paren_Expr:
        append(out, text("("))
        print_expr(pr, out, e.expr)
        append(out, text(")"))

    case ^ast.Selector_Expr:
        print_expr(pr, out, e.expr)
        append(out, text(e.op.text))
        print_expr(pr, out, e.field)

    case ^ast.Implicit_Selector_Expr:
        append(out, text("."))
        print_expr(pr, out, e.field)

    case ^ast.Selector_Call_Expr:
        print_expr(pr, out, e.call)

    case ^ast.Index_Expr:
        print_expr(pr, out, e.expr)
        append(out, text("["))
        print_expr(pr, out, e.index)
        append(out, text("]"))

    case ^ast.Deref_Expr:
        print_expr(pr, out, e.expr)
        append(out, text(e.op.text))

    case ^ast.Slice_Expr:
        print_expr(pr, out, e.expr)
        append(out, text("["))
        if e.low != nil {
            print_expr(pr, out, e.low)
        }
        append(out, text(e.interval.text))
        if e.high != nil {
            print_expr(pr, out, e.high)
        }
        append(out, text("]"))

    case ^ast.Matrix_Index_Expr:
        print_expr(pr, out, e.expr)
        append(out, text("["))
        print_expr(pr, out, e.row_index)
        append(out, text(", "))
        print_expr(pr, out, e.column_index)
        append(out, text("]"))

    case ^ast.Call_Expr:
        print_call_expr(pr, out, e)

    case ^ast.Field_Value:
        if cell := align_cell(pr, rawptr(expr)); cell.head != 0 {
            field_doc: [dynamic]Doc
            print_expr(pr, &field_doc, e.field)
            append(out, align(cell.head, field_doc[:]))
        } else {
            print_expr(pr, out, e.field)
        }
        append(out, text(" = "))
        print_expr(pr, out, e.value)

    case ^ast.Ternary_If_Expr:
        // Two distinct surface forms share this node: `cond ? x : y` puts the
        // condition first (op1.kind == .Question); `x if cond else y` puts the
        // true branch first. The field roles swap between them — .x/.cond are
        // not interchangeable with "first operand"/"second operand" here.
        if e.op1.kind == .Question {
            print_expr(pr, out, e.cond)
            append(out, text(" "))
            append(out, text(e.op1.text))
            append(out, text(" "))
            print_expr(pr, out, e.x)
            append(out, text(" "))
            append(out, text(e.op2.text))
            append(out, text(" "))
            print_expr(pr, out, e.y)
        } else {
            print_expr(pr, out, e.x)
            append(out, text(" "))
            append(out, text(e.op1.text))
            append(out, text(" "))
            print_expr(pr, out, e.cond)
            append(out, text(" "))
            append(out, text(e.op2.text))
            append(out, text(" "))
            print_expr(pr, out, e.y)
        }

    case ^ast.Ternary_When_Expr:
        print_expr(pr, out, e.x)
        append(out, text(" "))
        append(out, text(e.op1.text))
        append(out, text(" "))
        print_expr(pr, out, e.cond)
        append(out, text(" "))
        append(out, text(e.op2.text))
        append(out, text(" "))
        print_expr(pr, out, e.y)

    case ^ast.Or_Else_Expr:
        print_expr(pr, out, e.x)
        append(out, text(" "))
        append(out, text(e.token.text))
        append(out, text(" "))
        print_expr(pr, out, e.y)

    case ^ast.Or_Return_Expr:
        print_expr(pr, out, e.expr)
        append(out, text(" "))
        append(out, text(e.token.text))

    case ^ast.Or_Branch_Expr:
        print_expr(pr, out, e.expr)
        append(out, text(" "))
        append(out, text(e.token.text))
        if e.label != nil {
            append(out, text(" "))
            print_expr(pr, out, e.label)
        }

    case ^ast.Type_Assertion:
        print_expr(pr, out, e.expr)
        append(out, text("."))
        if is_maybe_assertion(e) {
            append(out, text("?"))
        } else if e.type != nil {
            append(out, text("("))
            print_expr(pr, out, e.type)
            append(out, text(")"))
        }

    case ^ast.Type_Cast:
        append(out, text(e.tok.text))
        append(out, text("("))
        print_expr(pr, out, e.type)
        append(out, text(")"))
        print_expr(pr, out, e.expr)

    case ^ast.Auto_Cast:
        append(out, text(e.op.text))
        append(out, text(" "))
        print_expr(pr, out, e.expr)

    case ^ast.Asm_Template:
        print_asm_template(pr, out, e)

    case ^ast.Asm_Register:
        print_asm_register(pr, out, e)

    case ^ast.Asm_Label:
        print_asm_label(pr, out, e)

    case ^ast.Asm_Memory_Operand:
        print_asm_memory_operand(pr, out, e)

    case ^ast.Asm_Register_Group:
        print_asm_register_group(pr, out, e)

    case ^ast.Proc_Group:
        append(out, text("proc"))
        append(out, text("{"))
        print_expr_list(pr, out, e.args)
        append(out, text("}"))

    case ^ast.Typeid_Type:
        append(out, text("typeid"))
        if e.specialization != nil {
            append(out, text("/"))
            print_expr(pr, out, e.specialization)
        }

    case ^ast.Helper_Type:
        append(out, text("#type "))
        print_expr(pr, out, e.type)

    case ^ast.Distinct_Type:
        append(out, text("distinct "))
        print_expr(pr, out, e.type)

    case ^ast.Poly_Type:
        append(out, text("$"))
        print_expr(pr, out, e.type)
        if e.specialization != nil {
            append(out, text("/"))
            print_expr(pr, out, e.specialization)
        }

    case ^ast.Proc_Type:
        print_proc_type_head(pr, out, e)
        print_proc_tags(pr, out, e.tags)

    case ^ast.Pointer_Type:
        if e.tag != nil {
            print_expr(pr, out, e.tag)
            append(out, text(" "))
        }
        append(out, text("^"))
        print_expr(pr, out, e.elem)

    case ^ast.Multi_Pointer_Type:
        append(out, text("[^]"))
        print_expr(pr, out, e.elem)

    case ^ast.Array_Type:
        if e.tag != nil {
            print_expr(pr, out, e.tag)
            append(out, text(" "))
        }
        append(out, text("["))
        if e.len != nil {
            print_expr(pr, out, e.len)
        }
        append(out, text("]"))
        print_expr(pr, out, e.elem)

    case ^ast.Dynamic_Array_Type:
        if e.tag != nil {
            print_expr(pr, out, e.tag)
            append(out, text(" "))
        }
        append(out, text("[dynamic]"))
        print_expr(pr, out, e.elem)

    case ^ast.Fixed_Capacity_Dynamic_Array_Type:
        if e.tag != nil {
            print_expr(pr, out, e.tag)
            append(out, text(" "))
        }
        append(out, text("[dynamic; "))
        print_expr(pr, out, e.capacity)
        append(out, text("]"))
        print_expr(pr, out, e.elem)

    case ^ast.Struct_Type:
        print_struct_type(pr, out, e)

    case ^ast.Union_Type:
        print_union_type(pr, out, e)

    case ^ast.Enum_Type:
        print_enum_type(pr, out, e)

    case ^ast.Bit_Set_Type:
        append(out, text("bit_set["))
        print_expr(pr, out, e.elem)
        if e.underlying != nil {
            append(out, text("; "))
            print_expr(pr, out, e.underlying)
        }
        append(out, text("]"))

    case ^ast.Map_Type:
        append(out, text("map["))
        print_expr(pr, out, e.key)
        append(out, text("]"))
        print_expr(pr, out, e.value)

    case ^ast.Relative_Type:
        append(out, text("#relative("))
        print_expr(pr, out, e.tag)
        append(out, text(") "))
        print_expr(pr, out, e.type)

    case ^ast.Matrix_Type:
        append(out, text("matrix["))
        print_expr(pr, out, e.row_count)
        append(out, text(", "))
        print_expr(pr, out, e.column_count)
        append(out, text("]"))
        print_expr(pr, out, e.elem)

    case ^ast.Bit_Field_Type:
        print_bit_field_type(pr, out, e)
    }
}

// A run of one operator (`a && b && c`) as a group: on one line when it fits
// character_width, else broken after each operator with the operands one indent
// in. A newline after an operator ends no statement in Odin.
@(private)
print_binary_chain :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Binary_Expr) {
    first := e.left
    rights := make([dynamic]^ast.Expr, context.temp_allocator)
    append(&rights, e.right)
    for {
        inner, ok := first.derived_expr.(^ast.Binary_Expr)
        if !ok || inner.op.kind != e.op.kind {
            break
        }
        append(&rights, inner.right)
        first = inner.left
    }
    head: [dynamic]Doc
    print_expr(pr, &head, first)
    body: [dynamic]Doc
    #reverse for right in rights {
        append(&body, text(" "))
        append(&body, text(e.op.text))
        append(&body, line())
        print_expr(pr, &body, right)
    }
    append(&head, indent(body[:]))
    append(out, group(head[:]))
}

// The right operand of `e` after the comments written before it. A block
// comment on the operand's line stays inline; any other comment ends the line
// after the operator, and the operand goes on the next line, one indent in.
@(private)
print_binary_comments :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Binary_Expr) {
    inline := true
    for i := pr.comment_idx; i < len(pr.comments) && pr.comments[i].pos.offset < e.right.pos.offset; i += 1 {
        cg := pr.comments[i]
        for tok in cg.list {
            if !strings.has_prefix(tok.text, "/*") || comment_end_line(tok) != e.right.pos.line || tok.pos.line != e.right.pos.line {
                inline = false
            }
        }
    }
    comments := take_comments_before(pr, e.right.pos.offset)
    if inline {
        for c in comments {
            append(out, text(" "))
            append(out, c)
        }
        append(out, text(" "))
        print_expr(pr, out, e.right)
        return
    }
    body: [dynamic]Doc
    for c, i in comments {
        append(&body, i == 0 ? text("  ") : hard_line(0))
        append(&body, c)
    }
    append(&body, hard_line(0))
    print_expr(pr, &body, e.right)
    append(out, indent(body[:]))
}

// `x.?`: the parser stores the `?` as an operand-less unary expression.
@(private)
is_maybe_assertion :: proc(e: ^ast.Type_Assertion) -> bool {
    if e.type == nil {
        return false
    }
    u, ok := e.type.derived_expr.(^ast.Unary_Expr)
    return ok && u.op.kind == .Question && u.expr == nil
}

@(private)
print_comp_lit_body ::proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Comp_Lit) {
    if len(e.elems) == 0 {
        append(out, text("{}"))
        return
    }
    multiline := pr.opts.exp_multiline_composite_literals && e.open.line != e.close.line
    if !multiline {
        // The group is off when exp_multiline_composite_literals is on: it
        // would break a literal the source wrote on one line, and the second
        // format would then read `open.line != close.line` and take the other
        // branch instead — the same input rendering two ways.
        if pr.opts.exp_multiline_composite_literals {
            append(out, text("{"))
            print_expr_list(pr, out, e.elems)
            append(out, text("}"))
            return
        }
        items := make([dynamic]List_Item, 0, len(e.elems))
        for el, i in e.elems {
            item := List_Item {leading = take_comments_before(pr, el.pos.offset)}
            elem: [dynamic]Doc
            print_expr(pr, &elem, el)
            item.doc = concat(elem[:])
            next := i + 1 < len(e.elems) ? e.elems[i + 1].pos.offset : e.close.offset
            item.trailing = take_trailing(pr, el.end.line, next)
            append(&items, item)
        }
        append_list_group(pr, out, "{", "}", items[:], take_comments_before(pr, e.close.offset))
        return
    }
    append(out, text("{"))
    assign_field_value_align_ids(pr, e.elems)
    body: [dynamic]Doc
    prev_line := e.open.line
    has_prev := true
    for el in e.elems {
        separator(pr, &body, prev_line, has_prev, el.pos.line, true)
        elem_doc: [dynamic]Doc
        print_expr(pr, &elem_doc, el)
        for d in elem_doc {
            append(&body, d)
        }
        append(&body, text(","))
        prev_line = el.end.line
        has_prev = true
    }
    flush_before(pr, &body, prev_line, has_prev, e.close.line, true)
    append(out, indent(body[:]))
    append(out, hard_line(0))
    append(out, text("}"))
}

// The check directives a statement or an expression carries, each with a
// space after it.
@(private)
print_state_flags :: proc(out: ^[dynamic]Doc, flags: ast.Node_State_Flags) {
    if flags == {} {
        return
    }
    if .Bounds_Check in flags {
        append(out, text("#bounds_check "))
    }
    if .No_Bounds_Check in flags {
        append(out, text("#no_bounds_check "))
    }
    if .Type_Assert in flags {
        append(out, text("#type_assert "))
    }
    if .No_Type_Assert in flags {
        append(out, text("#no_type_assert "))
    }
}

// The inlining directive of a call or a procedure literal.
@(private)
print_inlining :: proc(out: ^[dynamic]Doc, inlining: ast.Proc_Inlining) {
    switch inlining {
    case .None:
    case .Inline:
        append(out, text("#force_inline "))
    case .No_Inline:
        append(out, text("#force_no_inline "))
    }
}

@(private)
print_call_expr ::proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Call_Expr) {
    print_inlining(out, e.inlining)
    if e.tailing == .Must_Tail {
        append(out, text("#must_tail "))
    }
    print_expr(pr, out, e.expr)
    has_ellipsis := e.ellipsis.pos.line != 0
    ellipsis_arg := -1
    if has_ellipsis {
        best := max(int)
        for a, i in e.args {
            if a.pos.offset > e.ellipsis.pos.offset {
                d := a.pos.offset - e.ellipsis.pos.offset
                if d < best {
                    best = d
                    ellipsis_arg = i
                }
            }
        }
    }
    items := make([dynamic]List_Item, 0, len(e.args))
    for a, i in e.args {
        item := List_Item {leading = take_comments_before(pr, a.pos.offset)}
        arg: [dynamic]Doc
        if i == ellipsis_arg {
            append(&arg, text(".."))
        }
        print_expr(pr, &arg, a)
        item.doc = concat(arg[:])
        next := i + 1 < len(e.args) ? e.args[i + 1].pos.offset : e.close.offset
        item.trailing = take_trailing(pr, a.end.line, next)
        append(&items, item)
    }
    append_list_group(pr, out, "(", ")", items[:], take_comments_before(pr, e.close.offset))
}

@(private)
print_proc_tags :: proc(pr: ^Printer, out: ^[dynamic]Doc, tags: ast.Proc_Tags) {
    if .Bounds_Check in tags {
        append(out, text(" #bounds_check"))
    }
    if .No_Bounds_Check in tags {
        append(out, text(" #no_bounds_check"))
    }
    if .Optional_Ok in tags {
        append(out, text(" #optional_ok"))
    }
    if .Optional_Allocator_Error in tags {
        append(out, text(" #optional_allocator_error"))
    }
}

// The signature only — params, results, calling convention — with no tags.
// Standalone Proc_Type prints tags itself right after; Proc_Lit prints the
// where-clause and its own tags copy instead (the parser duplicates one
// parsed tag set onto both nodes, so only one side may print it).
@(private)
print_proc_type_head :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Proc_Type) {
    append(out, text("proc"))
    // core:odin/parser's string_to_calling_convention returns the calling
    // convention token's raw text as-is — quotes included — so it prints
    // verbatim; wrapping it in another pair of quotes double-quotes it.
    if cc, ok := e.calling_convention.(string); ok && cc != "" {
        append(out, text(" "))
        append(out, text(cc))
    }
    append_field_list_group(pr, out, "(", ")", e.params, params_end(e))
    print_signature_results(pr, out, e)
}

// The offset the parameter list of `e` ends by. The parser leaves
// Field_List.close unset, so it is the first result, or the end of the type.
@(private)
params_end :: proc(e: ^ast.Proc_Type) -> int {
    if e.results != nil && len(e.results.list) > 0 {
        return e.results.list[0].pos.offset
    }
    return e.end.offset
}

// The `-> ...` half of a signature, shared with the `asm` template — a lone
// unnamed result keeps its bare form, every other list is parenthesised.
// parenthesise_single keeps the parentheses of a lone unnamed result for an
// `asm` template that carries a specification list: `-> int [` re-parses as a
// slice of the result type, `-> (int) [` does not.
@(private)
print_signature_results :: proc(
    pr: ^Printer,
    out: ^[dynamic]Doc,
    e: ^ast.Proc_Type,
    parenthesise_single := false,
) {
    if e.diverging {
        append(out, text(" -> !"))
        return
    }
    if e.results == nil || len(e.results.list) == 0 {
        return
    }
    append(out, text(" -> "))
    single_unnamed := len(e.results.list) == 1 && len(e.results.list[0].names) == 0
    if single_unnamed && !parenthesise_single {
        print_field(pr, out, e.results.list[0])
        return
    }
    append_field_list_group(pr, out, "(", ")", e.results, e.end.offset)
}

@(private)
print_proc_lit :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Proc_Lit) {
    print_inlining(out, e.inlining)
    print_proc_type_head(pr, out, e.type)
    print_where(pr, out, e.where_clauses)
    print_proc_tags(pr, out, e.tags)
    if e.body == nil {
        append(out, text(" ---"))
        return
    }
    block, ok := e.body.derived_stmt.(^ast.Block_Stmt)
    if !ok {
        return
    }
    if block.uses_do && !pr.opts.convert_do {
        append(out, text(" do "))
        if len(block.stmts) > 0 {
            print_stmt(pr, out, block.stmts[0])
        }
        return
    }
    print_block(pr, out, block, true)
}

@(private)
print_struct_type :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Struct_Type) {
    append(out, text("struct"))
    if e.poly_params != nil {
        append(out, text("("))
        print_field_list(pr, out, e.poly_params)
        append(out, text(")"))
    }
    if e.align != nil {
        append(out, text(" #align("))
        print_expr(pr, out, e.align)
        append(out, text(")"))
    }
    if e.min_field_align != nil {
        append(out, text(" #min_field_align("))
        print_expr(pr, out, e.min_field_align)
        append(out, text(")"))
    }
    if e.max_field_align != nil {
        append(out, text(" #max_field_align("))
        print_expr(pr, out, e.max_field_align)
        append(out, text(")"))
    }
    if e.is_packed {
        append(out, text(" #packed"))
    }
    if e.is_raw_union {
        append(out, text(" #raw_union"))
    }
    if e.is_no_copy {
        append(out, text(" #no_copy"))
    }
    if e.is_all_or_none {
        append(out, text(" #all_or_none"))
    }
    if e.is_simple {
        append(out, text(" #simple"))
    }
    print_where(pr, out, e.where_clauses)
    if e.fields == nil {
        append(out, text(" {}"))
        return
    }
    print_brace_lead(pr, out, false, len(e.fields.list) == 0)
    print_field_brace_body(pr, out, e.end.line, e.fields.list)
}

@(private)
print_union_type :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Union_Type) {
    append(out, text("union"))
    if e.poly_params != nil {
        append(out, text("("))
        print_field_list(pr, out, e.poly_params)
        append(out, text(")"))
    }
    if e.align != nil {
        append(out, text(" #align("))
        print_expr(pr, out, e.align)
        append(out, text(")"))
    }
    switch e.kind {
    case .Normal:
    case .maybe:
        append(out, text(" #maybe"))
    case .no_nil:
        append(out, text(" #no_nil"))
    case .shared_nil:
        append(out, text(" #shared_nil"))
    }
    print_where(pr, out, e.where_clauses)
    print_brace_lead(pr, out, false, len(e.variants) == 0)
    print_expr_brace_body(pr, out, e.end.line, e.variants)
}

@(private)
print_enum_type :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Enum_Type) {
    append(out, text("enum"))
    if e.base_type != nil {
        append(out, text(" "))
        print_expr(pr, out, e.base_type)
    }
    print_brace_lead(pr, out, false, len(e.fields) == 0)
    print_expr_brace_body(pr, out, e.close.line, e.fields)
}

@(private)
print_bit_field_type :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Bit_Field_Type) {
    append(out, text("bit_field "))
    print_expr(pr, out, e.backing_type)
    print_brace_lead(pr, out, false, len(e.fields) == 0)
    print_bit_field_brace_body(pr, out, e.close.line, e.fields)
}
