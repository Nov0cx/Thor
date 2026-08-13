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

// A field. With a head cell from the pre-pass the name side is padded so the
// types line up; with none the output is the plain form. The `using` and
// `#no_alias` prefixes belong inside the cell: one that starts past the indent
// column is padded relative to the wrong place.
@(private)
print_field :: proc(pr: ^Printer, out: ^[dynamic]Doc, f: ^ast.Field) {
	cell := align_cell(pr, rawptr(f))

	head: [dynamic]Doc
	if .Using in f.flags {
		append(&head, text("using "))
	}
	for flag in FIELD_DIRECTIVE_FLAGS {
		if flag in f.flags {
			append(&head, text(ast.field_flag_strings[flag]))
			append(&head, text(" "))
		}
	}
	has_names := len(f.names) > 0 && !field_name_is_synthetic(f)
	if has_names {
		print_expr_list(pr, &head, f.names)
	}

	in_cell, after_cell := colon_split(pr)
	has_colon := has_names && f.type != nil
	if has_colon {
		append(&head, text(in_cell))
	}

	type_doc: [dynamic]Doc
	if f.type != nil {
		print_expr(pr, &type_doc, f.type)
	}

	if cell.head != 0 {
		append(out, align(cell.head, head[:]))
	} else {
		append(out, ..head[:])
	}
	if has_colon {
		append(out, text(after_cell))
	}
	append(out, ..type_doc[:])

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

// print_field_list as a wrappable group — the parameter-list shape, where a
// signature too long for character_width takes one parameter per line.
@(private)
append_field_list_group :: proc(pr: ^Printer, out: ^[dynamic]Doc, open, close: string, fl: ^ast.Field_List) {
	if fl == nil {
		append(out, text(open))
		append(out, text(close))
		return
	}
	items := make([dynamic]Doc, 0, len(fl.list))
	for f in fl.list {
		field: [dynamic]Doc
		print_field(pr, &field, f)
		append(&items, concat(field[:]))
	}
	append_list_group(pr, out, open, close, items[:])
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
// Whether a field has the `name: type` shape a head cell needs. A bare embedded
// type (`using Foo`), a synthetic `_` name and a missing type all have no colon
// to align to.
@(private)
field_alignable :: proc(f: ^ast.Field) -> bool {
	return f.type != nil && len(f.names) > 0 && !field_name_is_synthetic(f)
}

// One head id per maximal run of two or more alignable fields on adjacent
// lines. Runs are decided here, before a single field is emitted, so a
// separator that later appends a comment cannot change one mid-flight; a lone
// field gets no id, since padding a cell to its own width does nothing.
@(private)
assign_field_align_ids :: proc(pr: ^Printer, fields: []^ast.Field) {
	if !pr.opts.align_struct_fields {
		return
	}
	for i := 0; i < len(fields); {
		if !field_alignable(fields[i]) {
			i += 1
			continue
		}
		end := i + 1
		for end < len(fields) &&
		    field_alignable(fields[end]) &&
		    same_align_run(pr, fields[end - 1].end.line, fields[end].pos.line) {
			end += 1
		}
		if end - i >= 2 {
			id := next_align(pr)
			for f in fields[i:end] {
				cell := pr.align_ids[rawptr(f)]
				cell.head = id
				pr.align_ids[rawptr(f)] = cell
			}
		}
		i = end
	}
}

@(private)
print_field_brace_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, close_line: int, fields: []^ast.Field) {
	assign_field_align_ids(pr, fields)
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

// One head id per maximal run of two or more adjacent `name = value` elements,
// so their `=` line up. Bare enum members and union variants have no field to
// pad and end a run. Shared by enum bodies and multi-line composite literals.
@(private)
assign_field_value_align_ids :: proc(pr: ^Printer, exprs: []^ast.Expr) {
	if !pr.opts.align_struct_values {
		return
	}
	for i := 0; i < len(exprs); {
		if !is_flat_field_value(exprs[i]) {
			i += 1
			continue
		}
		end := i + 1
		for end < len(exprs) &&
		    is_flat_field_value(exprs[end]) &&
		    same_align_run(pr, exprs[end - 1].end.line, exprs[end].pos.line) {
			end += 1
		}
		if end - i >= 2 {
			id := next_align(pr)
			for ex in exprs[i:end] {
				cell := pr.align_ids[rawptr(ex)]
				cell.head = id
				pr.align_ids[rawptr(ex)] = cell
			}
		}
		i = end
	}
}

// A `name = value` element whose name stays on one line, so its cell is
// paddable.
@(private)
is_flat_field_value :: proc(ex: ^ast.Expr) -> bool {
	fv, ok := ex.derived_expr.(^ast.Field_Value)
	if !ok || fv.field == nil {
		return false
	}
	return fv.field.pos.line == fv.field.end.line
}

// One bare expression per line, comma-terminated — union variants and enum
// fields.
@(private)
print_expr_brace_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, close_line: int, exprs: []^ast.Expr) {
	assign_field_value_align_ids(pr, exprs)
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
	cell := align_cell(pr, rawptr(f))
	in_cell, after_cell := colon_split(pr)

	head: [dynamic]Doc
	print_expr(pr, &head, f.name)
	append(&head, text(in_cell))
	if cell.head != 0 {
		append(out, align(cell.head, head[:]))
	} else {
		append(out, ..head[:])
	}
	append(out, text(after_cell))

	type_doc: [dynamic]Doc
	print_expr(pr, &type_doc, f.type)
	if cell.value != 0 {
		append(out, align(cell.value, type_doc[:]))
	} else {
		append(out, ..type_doc[:])
	}

	append(out, text(" | "))
	print_expr(pr, out, f.bit_size)
	if f.tag.text != "" {
		append(out, text(" "))
		append(out, text(f.tag.text))
	}
}

// A bit-field field is always `name: type | bits`, so every member of a run is
// alignable: the head cell lines up the types, the value cell the `|`.
@(private)
assign_bit_field_align_ids :: proc(pr: ^Printer, fields: []^ast.Bit_Field_Field) {
	if !pr.opts.align_struct_fields && !pr.opts.align_struct_values {
		return
	}
	for i := 0; i < len(fields); {
		end := i + 1
		for end < len(fields) &&
		    same_align_run(pr, fields[end - 1].end.line, fields[end].pos.line) {
			end += 1
		}
		if end - i >= 2 {
			head_id := pr.opts.align_struct_fields ? next_align(pr) : 0
			value_id := pr.opts.align_struct_values ? next_align(pr) : 0
			for f in fields[i:end] {
				pr.align_ids[rawptr(f)] = Align_Cell{head = head_id, value = value_id}
			}
		}
		i = end
	}
}

@(private)
print_bit_field_brace_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, close_line: int, fields: []^ast.Bit_Field_Field) {
	assign_bit_field_align_ids(pr, fields)
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
