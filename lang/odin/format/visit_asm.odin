// Printing for the `asm` template and the operand, instruction and
// specification nodes only it contains. The template's Proc_Type carries an
// "inlineasm" calling convention the `asm` keyword already implies, so the
// signature is printed here instead of through print_proc_type_head.
package odinfmt

import "core:odin/ast"
import "core:odin/tokenizer"

@(private)
print_asm_template :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Asm_Template) {
    append(out, text("asm"))
    has_specs := len(e.specs) > 0 || len(e.clobbers) > 0
    if e.type == nil {
        append(out, text("()"))
    } else {
        append_field_list_group(pr, out, "(", ")", e.type.params)
        print_signature_results(pr, out, e.type, has_specs)
    }
    print_asm_spec_list(pr, out, e)
    append(out, text(" "))
    open_pos := asm_body_open(e)
    open := ast.Node{pos = open_pos, end = open_pos}
    close := ast.Node{pos = e.end, end = e.end}
    print_brace_body(pr, out, open, close, e.instructions, print_stmt_item, false)
}

// The line of the body's opening brace. Asm_Template records no brace position,
// so the end of the signature (or of the last specification) stands in for it —
// the same line whenever the brace hugs them, which is all a blank-line gap
// before the first instruction is measured against.
@(private)
asm_body_open :: proc(e: ^ast.Asm_Template) -> tokenizer.Pos {
    pos := e.pos
    if e.type != nil {
        pos = e.type.end
    }
    for s in e.specs {
        if s.end.offset > pos.offset {
            pos = s.end
        }
    }
    for c in e.clobbers {
        if c.end.offset > pos.offset {
            pos = c.end
        }
    }
    return pos
}

// `[spec, spec, #volatile, #clobber %rcx]`. The two slices come from one
// bracketed list and each is in source order, so a merge on position restores
// the order they were written in.
@(private)
print_asm_spec_list :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Asm_Template) {
    if len(e.specs) == 0 && len(e.clobbers) == 0 {
        return
    }
    items := make([dynamic]Doc, 0, len(e.specs) + len(e.clobbers))
    si, ci := 0, 0
    for si < len(e.specs) || ci < len(e.clobbers) {
        take_spec := ci >= len(e.clobbers)
        if !take_spec && si < len(e.specs) {
            take_spec = e.specs[si].pos.offset < e.clobbers[ci].pos.offset
        }
        item: [dynamic]Doc
        if take_spec {
            print_asm_spec(pr, &item, e.specs[si])
            si += 1
        } else {
            print_asm_clobber(pr, &item, e.clobbers[ci])
            ci += 1
        }
        append(&items, concat(item[:]))
    }
    append(out, text(" "))
    append_list_group(pr, out, "[", "]", items[:])
}

@(private)
print_asm_spec :: proc(pr: ^Printer, out: ^[dynamic]Doc, s: ^ast.Asm_Spec) {
    if s.name != nil {
        append(out, text(s.name.name))
    }
    if s.tied_name != nil {
        append(out, text(" -> "))
        append(out, text(s.tied_name.name))
    }
    if s.type != nil {
        append(out, text(colon_sep(pr)))
        print_expr(pr, out, s.type)
    }
    if s.value != nil {
        append(out, text(" = "))
        print_expr(pr, out, s.value)
    }
    for d in s.directives {
        append(out, text(" "))
        print_expr(pr, out, d)
    }
}

@(private)
print_asm_clobber :: proc(pr: ^Printer, out: ^[dynamic]Doc, c: ^ast.Asm_Clobber) {
    append(out, text("#"))
    append(out, text(c.name))
    if c.value != nil {
        append(out, text(" "))
        print_expr(pr, out, c.value)
    }
}

@(private)
print_asm_instruction :: proc(pr: ^Printer, out: ^[dynamic]Doc, s: ^ast.Asm_Instruction) {
    if s.name != nil {
        append(out, text(s.name.name))
    }
    if len(s.operands) > 0 {
        append(out, text(" "))
        print_expr_list(pr, out, s.operands)
    }
}

@(private)
print_asm_label_decl :: proc(pr: ^Printer, out: ^[dynamic]Doc, s: ^ast.Asm_Label_Decl) {
    append(out, text("."))
    if s.label != nil {
        append(out, text(s.label.name))
    }
    append(out, text(":"))
}

@(private)
print_asm_directive :: proc(pr: ^Printer, out: ^[dynamic]Doc, s: ^ast.Asm_Directive) {
    append(out, text("#"))
    append(out, text(s.name))
    if len(s.operands) > 0 {
        append(out, text(" "))
        print_expr_list(pr, out, s.operands)
    }
}

@(private)
print_asm_register :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Asm_Register) {
    append(out, text("%"))
    append(out, text(e.name))
    if e.flag != "" {
        append(out, text("."))
        append(out, text(e.flag))
    }
}

@(private)
print_asm_label :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Asm_Label) {
    append(out, text("."))
    append(out, text(e.name))
}

// `[%rsp + 0x8]`, `[%gs:0x10]`, `[%r11]:u8`, `#post [%rax + %rcx*8 - 0x10]`.
// The scale hugs its index, as the operand form itself is written.
@(private)
print_asm_memory_operand :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Asm_Memory_Operand) {
    switch e.kind {
    case .Default:
    case .Pre:
        append(out, text("#pre "))
    case .Post:
        append(out, text("#post "))
    }
    append(out, text("["))
    if e.segment_override != nil {
        print_expr(pr, out, e.segment_override)
        append(out, text(":"))
    }
    print_expr(pr, out, e.base)
    if e.index != nil {
        append(out, text(" "))
        append(out, text(e.index_op.text))
        append(out, text(" "))
        print_expr(pr, out, e.index)
        if e.scale != nil {
            append(out, text(e.scale_op.text))
            print_expr(pr, out, e.scale)
        }
    }
    if e.disp != nil {
        append(out, text(" "))
        append(out, text(e.disp_op.text))
        append(out, text(" "))
        print_expr(pr, out, e.disp)
    }
    append(out, text("]"))
    if e.type != nil {
        append(out, text(":"))
        print_expr(pr, out, e.type)
    }
}

// `{%r0, %r1}`, or `{%r0..%r7}` for the two-register range form.
@(private)
print_asm_register_group :: proc(pr: ^Printer, out: ^[dynamic]Doc, e: ^ast.Asm_Register_Group) {
    append(out, text("{"))
    is_range := e.range_token.kind == .Range_Half || e.range_token.kind == .Range_Full
    if is_range && len(e.registers) == 2 {
        print_expr(pr, out, e.registers[0])
        append(out, text(e.range_token.text))
        print_expr(pr, out, e.registers[1])
    } else {
        print_expr_list(pr, out, e.registers)
    }
    append(out, text("}"))
    if e.type != nil {
        append(out, text(":"))
        print_expr(pr, out, e.type)
    }
}
