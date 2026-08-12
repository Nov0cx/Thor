// The file entry point and the four Stmt-derived declaration kinds that can
// appear at file scope: value (var/const), import, and the two foreign forms.
package odinfmt

import "core:odin/ast"

print_file :: proc(pr: ^Printer, file: ^ast.File) -> Doc {
	out: [dynamic]Doc

	prev_line := 0
	has_prev := false
	for tag, i in file.tags {
		if i > 0 {
			append(&out, hard_line(0))
		}
		append(&out, text(tag.text))
		prev_line = tag.pos.line
		has_prev = true
	}

	if file.pkg_decl != nil {
		if has_prev {
			// A build tag hugs the package clause by convention: exactly one
			// flat newline down to it (and to any comment strictly between),
			// never blank-line-preserved the way ordinary decls are.
			flush_before(pr, &out, prev_line, has_prev, file.pkg_decl.pos.line, true)
			append(&out, hard_line(0))
		} else {
			separator(pr, &out, prev_line, has_prev, file.pkg_decl.pos.line, true)
		}
		append(&out, text("package "))
		append(&out, text(file.pkg_decl.name))
		prev_line = file.pkg_decl.end.line
		has_prev = true
	}

	prev_line, has_prev = print_stmt_list(pr, &out, file.decls[:], prev_line, has_prev)
	flush_remaining(pr, &out, prev_line, has_prev)
	append(&out, hard_line(0)) // exactly one trailing newline

	return concat_dynamic(out)
}

@(private)
value_decl_op :: proc(has_type, is_mutable: bool) -> string {
	switch {
	case !has_type && is_mutable:
		return " := "
	case !has_type && !is_mutable:
		return " :: "
	case has_type && is_mutable:
		return " = "
	case:
		return " : "
	}
}

@(private)
print_value_decl :: proc(pr: ^Printer, out: ^[dynamic]Doc, d: ^ast.Value_Decl) {
	print_attributes(pr, out, d.attributes)
	if d.is_using {
		append(out, text("using "))
	}
	print_expr_list(pr, out, d.names)
	has_type := d.type != nil
	if has_type {
		append(out, text(colon_sep(pr)))
		print_expr(pr, out, d.type)
	}
	if len(d.values) > 0 {
		append(out, text(value_decl_op(has_type, d.is_mutable)))
		print_expr_list(pr, out, d.values)
	} else if !has_type {
		append(out, text(":")) // degenerate but never drop content silently
	}
}

@(private)
print_import_decl :: proc(pr: ^Printer, out: ^[dynamic]Doc, d: ^ast.Import_Decl) {
	print_attributes(pr, out, d.attributes)
	if d.is_using {
		append(out, text("using "))
	}
	append(out, text("import "))
	if d.name.text != "" {
		append(out, text(d.name.text))
		append(out, text(" "))
	}
	append(out, text(d.relpath.text))
}

@(private)
print_foreign_block_decl :: proc(pr: ^Printer, out: ^[dynamic]Doc, d: ^ast.Foreign_Block_Decl) {
	print_attributes(pr, out, d.attributes)
	append(out, text("foreign"))
	if d.foreign_library != nil {
		append(out, text(" "))
		print_expr(pr, out, d.foreign_library)
	}
	if block, ok := d.body.derived_stmt.(^ast.Block_Stmt); ok {
		print_block(pr, out, block, false)
	}
}

@(private)
print_foreign_import_decl :: proc(pr: ^Printer, out: ^[dynamic]Doc, d: ^ast.Foreign_Import_Decl) {
	print_attributes(pr, out, d.attributes)
	append(out, text("foreign import "))
	if d.name != nil {
		print_expr(pr, out, d.name)
		append(out, text(" "))
	}
	if len(d.fullpaths) == 1 {
		print_expr(pr, out, d.fullpaths[0])
		return
	}
	append(out, text("{"))
	print_expr_list(pr, out, d.fullpaths)
	append(out, text("}"))
}
