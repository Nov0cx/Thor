// Small shared helpers used by both the statement and expression visitors:
// comma-separated lists, attributes, and the brace_style/convert_do rules
// that decide how a block attaches to the construct in front of it.
package odinfmt

import "core:odin/ast"

@(private)
print_expr_list :: proc(pr: ^Printer, out: ^[dynamic]Doc, exprs: []^ast.Expr) {
	for e, i in exprs {
		if i > 0 {
			append(out, text(", "))
		}
		print_expr(pr, out, e)
	}
}

@(private)
print_attribute :: proc(pr: ^Printer, out: ^[dynamic]Doc, a: ^ast.Attribute) {
	append(out, text("@"))
	if a.tok == .Ident && len(a.elems) == 1 {
		print_expr(pr, out, a.elems[0])
		return
	}
	append(out, text("("))
	print_expr_list(pr, out, a.elems)
	append(out, text(")"))
}

@(private)
print_attributes :: proc(pr: ^Printer, out: ^[dynamic]Doc, attrs: [dynamic]^ast.Attribute) {
	for a in attrs {
		print_attribute(pr, out, a)
		append(out, hard_line(0))
	}
}

// Whether a block's opening brace sits on its own line: Allman always does,
// K&R only for a procedure body, _1TBS/Stroustrup never.
@(private)
brace_own_line :: proc(pr: ^Printer, is_proc_body: bool) -> bool {
	switch pr.opts.brace_style {
	case ._1TBS, .Stroustrup:
		return false
	case .Allman:
		return true
	case .K_And_R:
		return is_proc_body
	}
	return false
}

// Whether `else` starts a new line after the closing brace (Allman and
// Stroustrup) or continues it (`} else {`, _1TBS and K&R).
@(private)
else_own_line :: proc(pr: ^Printer) -> bool {
	return pr.opts.brace_style == .Allman || pr.opts.brace_style == .Stroustrup
}

@(private)
colon_sep :: proc(pr: ^Printer) -> string {
	if pr.opts.spaces_around_colons {
		return " : "
	}
	return ": "
}

// colon_sep, split into the part that belongs inside an alignment cell and the
// part that follows the pad; in_cell + after_cell is colon_sep(pr) always. With
// spaces_around_colons the pad sits before the " : ", so colons and types both
// line up; without it the pad sits after the ":", since a space before a colon
// is what that option is off to avoid.
@(private)
colon_split :: proc(pr: ^Printer) -> (in_cell, after_cell: string) {
	if pr.opts.spaces_around_colons {
		return "", " : "
	}
	return ":", " "
}
