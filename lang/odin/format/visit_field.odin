// Field, Field_List, Attribute and Bit_Field_Field printing, plus the
// brace-delimited-list builders for the three item shapes structs, unions
// (and enums), and bit_fields hand the visitor: fields, bare expressions, and
// bit-field fields respectively. Mirrors print_brace_body in visit_stmt.odin,
// which does the same for statement lists — Odin has no shared "has a
// position" interface across these pointer types, so the three stay separate.
package odinfmt

import "core:odin/ast"

@(private)
FIELD_DIRECTIVE_FLAGS := []ast.Field_Flag{.No_Alias, .C_Vararg, .Const, .Any_Int, .Subtype, .By_Ptr, .No_Broadcast, .No_Capture}

// A param/result written with no name at all (`proc(int, string)`, `-> (T,
// U)`) still gets one synthetic `_` ast.Ident per field — core:odin/parser's
// parse_field_list stamps it at the type's own position rather than leaving
// names empty. A real `_: T` field has its `_` positioned before the type,
// at the identifier's own source location — that's the distinguishing
// signal, since both cases otherwise look identical on the Field struct.
@(private)
field_name_is_synthetic :: proc(f: ^ast.Field) -> bool {
	if len(f.names) != 1 || f.type == nil {
		return false
	}
	ident, ok := f.names[0].derived_expr.(^ast.Ident)
	if !ok || ident.name != "_" {
		return false
	}
	return f.names[0].pos == f.type.pos
}

@(private)
print_field :: proc(pr: ^Printer, out: ^[dynamic]Doc, f: ^ast.Field) {
	if .Using in f.flags {
		append(out, text("using "))
	}
	for flag in FIELD_DIRECTIVE_FLAGS {
		if flag in f.flags {
			append(out, text(ast.field_flag_strings[flag]))
			append(out, text(" "))
		}
	}
	has_names := len(f.names) > 0 && !field_name_is_synthetic(f)
	if has_names {
		print_expr_list(pr, out, f.names)
	}
	if f.type != nil {
		if has_names {
			append(out, text(colon_sep(pr)))
		}
		print_expr(pr, out, f.type)
	}
	if f.default_value != nil {
		if f.type != nil {
			append(out, text(" = "))
		} else {
			append(out, text(" := "))
		}
		print_expr(pr, out, f.default_value)
	}
	if f.tag.text != "" {
		append(out, text(" "))
		append(out, text(f.tag.text))
	}
}

@(private)
print_field_list :: proc(pr: ^Printer, out: ^[dynamic]Doc, fl: ^ast.Field_List) {
	if fl == nil {
		return
	}
	for f, i in fl.list {
		if i > 0 {
			append(out, text(", "))
		}
		print_field(pr, out, f)
	}
}

// One field per line, comma-terminated — the struct/bit_field-poly-params
// body shape. `close_line` is the enclosing type node's own end line (never
// the Field_List's — the parser leaves Field_List.open/close at their zero
// value, so relying on those miscomputes every blank-line gap in the body).
@(private)
print_field_brace_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, close_line: int, fields: []^ast.Field) {
	append(out, text("{"))
	if len(fields) == 0 {
		body: [dynamic]Doc
		flush_before(pr, &body, 0, false, close_line, true)
		append_brace_close(out, body[:])
		return
	}
	body: [dynamic]Doc
	prev_line, has_prev := flush_before(pr, &body, 0, false, fields[0].pos.line, true)
	append(&body, hard_line(0))
	for f, i in fields {
		if i > 0 {
			separator(pr, &body, prev_line, has_prev, f.pos.line, true)
		}
		field_doc: [dynamic]Doc
		print_field(pr, &field_doc, f)
		for d in field_doc {
			append(&body, d)
		}
		append(&body, text(","))
		prev_line = f.end.line
		has_prev = true
	}
	flush_before(pr, &body, prev_line, has_prev, close_line, true)
	append_brace_close(out, body[:])
}

// One bare expression per line, comma-terminated — union variants and enum
// fields.
@(private)
print_expr_brace_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, close_line: int, exprs: []^ast.Expr) {
	append(out, text("{"))
	if len(exprs) == 0 {
		body: [dynamic]Doc
		flush_before(pr, &body, 0, false, close_line, true)
		append_brace_close(out, body[:])
		return
	}
	body: [dynamic]Doc
	prev_line, has_prev := flush_before(pr, &body, 0, false, exprs[0].pos.line, true)
	append(&body, hard_line(0))
	for ex, i in exprs {
		if i > 0 {
			separator(pr, &body, prev_line, has_prev, ex.pos.line, true)
		}
		elem_doc: [dynamic]Doc
		print_expr(pr, &elem_doc, ex)
		for d in elem_doc {
			append(&body, d)
		}
		append(&body, text(","))
		prev_line = ex.end.line
		has_prev = true
	}
	flush_before(pr, &body, prev_line, has_prev, close_line, true)
	append_brace_close(out, body[:])
}

// Common tail of every brace-body builder: an empty body collapses to "}"
// with no indent/newline of its own, otherwise the body sits on its own
// indented lines with the closing brace on a fresh line.
@(private)
append_brace_close :: proc(out: ^[dynamic]Doc, body: []Doc) {
	if len(body) == 0 {
		append(out, text("}"))
		return
	}
	append(out, indent(body))
	append(out, hard_line(0))
	append(out, text("}"))
}

@(private)
print_bit_field_field :: proc(pr: ^Printer, out: ^[dynamic]Doc, f: ^ast.Bit_Field_Field) {
	print_expr(pr, out, f.name)
	append(out, text(colon_sep(pr)))
	print_expr(pr, out, f.type)
	append(out, text(" | "))
	print_expr(pr, out, f.bit_size)
	if f.tag.text != "" {
		append(out, text(" "))
		append(out, text(f.tag.text))
	}
}

@(private)
print_bit_field_brace_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, close_line: int, fields: []^ast.Bit_Field_Field) {
	append(out, text("{"))
	if len(fields) == 0 {
		body: [dynamic]Doc
		flush_before(pr, &body, 0, false, close_line, true)
		append_brace_close(out, body[:])
		return
	}
	body: [dynamic]Doc
	prev_line, has_prev := flush_before(pr, &body, 0, false, fields[0].pos.line, true)
	append(&body, hard_line(0))
	for f, i in fields {
		if i > 0 {
			separator(pr, &body, prev_line, has_prev, f.pos.line, true)
		}
		field_doc: [dynamic]Doc
		print_bit_field_field(pr, &field_doc, f)
		for d in field_doc {
			append(&body, d)
		}
		append(&body, text(","))
		prev_line = f.end.line
		has_prev = true
	}
	flush_before(pr, &body, prev_line, has_prev, close_line, true)
	append_brace_close(out, body[:])
}

@(private)
print_where :: proc(pr: ^Printer, out: ^[dynamic]Doc, clauses: []^ast.Expr) {
	if len(clauses) == 0 {
		return
	}
	append(out, text(" where "))
	print_expr_list(pr, out, clauses)
}
