// Printing for the `asm` template and the operand, instruction and
// specification nodes only it contains.
package odinfmt

@(private)
print_asm_template :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: Node) {
    ks := kids(e)
    append(out, text("asm"))
    specs, has_specs := find_kind(ks, .Asm_Spec_List)
    params, _ := find_kind(ks, .Param_List)
    print_param_list(pr, out, params)
    results, _ := find_kind(ks, .Result_List)
    print_signature_results(pr, out, results, has_specs && len(node_kids(kids(specs))) > 0)
    if has_specs {
        print_asm_spec_list(pr, out, specs)
    }
    append(out, text(" "))
    body, ok := find_kind(ks, .Asm_Body)
    if !ok {
        append(out, text("{}"))
        return
    }
    bks := kids(body)
    open_line, close_line := brace_lines(pr, bks, body)
    print_brace_body(pr, out, open_line, close_line, node_kids(bks), print_stmt_item, false)
}

// `[spec, spec, #volatile, #clobber %rcx]`.
@(private)
print_asm_spec_list :: proc(pr: ^Printer, out: ^[dynamic]Doc, specs: Node) {
    entries := node_kids(kids(specs))
    if len(entries) == 0 {
        return
    }
    items := make([dynamic]List_Item, 0, len(entries))
    for entry in entries {
        item: [dynamic]Doc
        if entry.kind == .Asm_Spec {
            print_asm_spec(pr, &item, entry)
        } else {
            print_asm_clobber(pr, &item, entry)
        }
        append(&items, List_Item{doc = concat(item[:])})
    }
    append(out, text(" "))
    append_list_group(pr, out, "[", "]", items[:])
}

// `name -> tied: type = value #directive`.
@(private)
print_asm_spec :: proc(pr: ^Printer, out: ^[dynamic]Doc, s: Node) {
    first := true
    after: enum {
        None,
        Arrow,
        Colon,
        Eq,
    }
    for k in kids(s) {
        if !is_node(k) {
            #partial switch k.tok {
            case .Arrow_Right:
                after = .Arrow
            case .Colon:
                after = .Colon
            case .Eq:
                after = .Eq
            }
            continue
        }
        switch {
        case first:
            print_expr(pr, out, k)
        case k.kind == .Directive:
            append(out, text(" "))
            print_expr(pr, out, k)
        case after == .Arrow:
            append(out, text(" -> "))
            print_expr(pr, out, k)
        case after == .Colon:
            append(out, text(colon_sep(pr)))
            print_expr(pr, out, k)
        case after == .Eq:
            append(out, text(" = "))
            print_expr(pr, out, k)
        }
        first = false
        after = .None
    }
}

// `#name` or `#clobber %reg`.
@(private)
print_asm_clobber :: proc(pr: ^Printer, out: ^[dynamic]Doc, c: Node) {
    for n, i in node_kids(kids(c)) {
        if i > 0 {
            append(out, text(" "))
        }
        print_expr(pr, out, n)
    }
}

// The operands after the head node of an instruction or a directive.
@(private)
print_asm_operands :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    nodes := node_kids(ks)
    if len(nodes) == 0 {
        return
    }
    print_expr(pr, out, nodes[0])
    if len(nodes) > 1 {
        append(out, text(" "))
        print_expr_list(pr, out, nodes[1:])
    }
}

@(private)
print_asm_instruction :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    print_asm_operands(pr, out, ks)
}

@(private)
print_asm_label_decl :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    if label, ok := first_node(ks); ok {
        print_expr(pr, out, label)
    }
    append(out, text(":"))
}

@(private)
print_asm_directive :: proc(pr: ^Printer, out: ^[dynamic]Doc, ks: []Node) {
    print_asm_operands(pr, out, ks)
}

// `[%rsp + 0x8]`, `[%gs:0x10]`, `[%r11]:u8`, `[%rax + %rcx*8 - 0x10]`.
// The scale hugs its index, as the operand form itself is written.
@(private)
print_asm_memory_operand :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: Node) {
    for k in kids(e) {
        if is_node(k) {
            print_expr(pr, out, k)
            continue
        }
        #partial switch k.tok {
        case .Add, .Sub:
            append(out, text(" "))
            append(out, text(node_text(pr, k)))
            append(out, text(" "))
        case:
            append(out, text(node_text(pr, k)))
        }
    }
}

// `{%r0, %r1}`, or `{%r0..%r7}` for the two-register range form.
@(private)
print_asm_register_group :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: Node) {
    ks := kids(e)
    close := tok_index(ks, .Close_Brace)
    if close < 0 {
        close = len(ks)
    }
    regs := node_kids(ks[:close])
    append(out, text("{"))
    range_at := -1
    for k, i in ks[:close] {
        if is_tok(k, .Range_Half) || is_tok(k, .Range_Full) {
            range_at = i
        }
    }
    if range_at >= 0 && len(regs) == 2 {
        print_expr(pr, out, regs[0])
        append(out, text(node_text(pr, ks[range_at])))
        print_expr(pr, out, regs[1])
    } else {
        print_expr_list(pr, out, regs)
    }
    append(out, text("}"))
    if colon := tok_index(ks, .Colon, close); colon >= 0 {
        if t, ok := first_node(ks[colon + 1:]); ok {
            append(out, text(":"))
            print_expr(pr, out, t)
        }
    }
}
