// Statement (and declaration — Value_Decl/Import_Decl/etc. are Stmt-derived)
// printing, plus the shared brace-delimited-list machinery blocks, switches
// and struct/enum/union bodies all build on.
package odinfmt

import "core:odin/ast"
import "core:slice"
import "core:strings"

@(private)
Item_Printer :: #type proc(pr: ^Printer, out: ^[dynamic]Doc, item: ^ast.Stmt)

// Prints "{ ...items... }", one item per line via `printer`, preserving
// blank-line gaps and interleaved comments; `extra_indent` adds one more
// indent level around each item (indent_cases, for switch case bodies).
@(private)
print_brace_body :: proc(
	pr: ^Printer,
	out: ^[dynamic]Doc,
	open, close: ast.Node,
	stmts: []^ast.Stmt,
	printer: Item_Printer,
	extra_indent: bool,
) {
	assign_decl_align_ids(pr, stmts)
	append(out, text("{"))
	body: [dynamic]Doc
	prev_line := open.pos.line
	has_prev := true
	for stmt in stmts {
		if stmt == nil {
			continue
		}
		separator(pr, &body, prev_line, has_prev, stmt_start_line(stmt), true)
		item: [dynamic]Doc
		printer(pr, &item, stmt)
		if extra_indent {
			append(&body, indent(item[:]))
		} else {
			for d in item {
				append(&body, d)
			}
		}
		prev_line = stmt.end.line
		has_prev = true
	}
	flush_before(pr, &body, prev_line, has_prev, close.pos.line, true)
	if len(body) == 0 {
		append(out, text("}"))
		return
	}
	append(out, indent(body[:]))
	append(out, hard_line(0))
	append(out, text("}"))
}

@(private)
print_stmt_item :: proc(pr: ^Printer, out: ^[dynamic]Doc, item: ^ast.Stmt) {
	print_stmt(pr, out, item)
}

@(private)
print_block :: proc(pr: ^Printer, out: ^[dynamic]Doc, block: ^ast.Block_Stmt, is_proc_body: bool) {
	if brace_own_line(pr, is_proc_body) {
		append(out, hard_line(0))
	} else {
		append(out, text(" "))
	}
	if print_one_line_block(pr, out, block) {
		return
	}
	open := ast.Node{pos = block.open, end = block.open}
	close := ast.Node{pos = block.close, end = block.close}
	print_brace_body(pr, out, open, close, block.stmts, print_stmt_item, false)
}

// `{ stmt }` for a block the source already wrote on one line, under
// space_single_line_blocks. Decided from the source alone, never from a width
// measurement, so a second format sees the same one-line source and makes the
// same choice. The option never collapses a block the source spread over lines
// — it only declines to expand one.
@(private)
print_one_line_block :: proc(pr: ^Printer, out: ^[dynamic]Doc, block: ^ast.Block_Stmt) -> bool {
	if !pr.opts.space_single_line_blocks || block.open.line != block.close.line {
		return false
	}
	only: ^ast.Stmt
	for stmt in block.stmts {
		if stmt == nil {
			continue
		}
		if only != nil {
			return false
		}
		only = stmt
	}
	if only == nil {
		return false
	}
	// A comment inside would need a separator, and a separator emits a line.
	for cg in pr.comments[pr.comment_idx:] {
		if cg.pos.line > block.close.line {
			break
		}
		if cg.pos.line >= block.open.line {
			return false
		}
	}

	item: [dynamic]Doc
	print_stmt(pr, &item, only)
	if _, flat := measure_flat_children(item[:], &pr.opts); !flat {
		return false
	}
	append(out, text("{ "))
	append(out, ..item[:])
	append(out, text(" }"))
	return true
}

// A statement/proc body: a `do stmt` shorthand (kept unless convert_do),
// a real block, or — defensively — some other stmt kind.
@(private)
print_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, body: ^ast.Stmt, is_proc_body: bool) {
	if body == nil {
		return
	}
	if block, ok := body.derived_stmt.(^ast.Block_Stmt); ok {
		if block.uses_do && !pr.opts.convert_do {
			append(out, text(" do "))
			if len(block.stmts) > 0 {
				print_stmt(pr, out, block.stmts[0])
			}
			return
		}
		print_block(pr, out, block, is_proc_body)
		return
	}
	append(out, text(" "))
	print_stmt(pr, out, body)
}

@(private)
print_else :: proc(pr: ^Printer, out: ^[dynamic]Doc, else_stmt: ^ast.Stmt) {
	if else_stmt == nil {
		return
	}
	if else_own_line(pr) {
		append(out, hard_line(0))
	} else {
		append(out, text(" "))
	}
	append(out, text("else"))
	if _, ok := else_stmt.derived_stmt.(^ast.If_Stmt); ok {
		append(out, text(" "))
		print_stmt(pr, out, else_stmt)
		return
	}
	if _, ok := else_stmt.derived_stmt.(^ast.When_Stmt); ok {
		append(out, text(" "))
		print_stmt(pr, out, else_stmt)
		return
	}
	print_body(pr, out, else_stmt, false)
}

// The end of the maximal run of import declarations starting at `i` that is
// safe to reorder: consecutive plain ^ast.Import_Decls, one per line with no
// blank line between them, and no comment on any line the run covers. A comment
// inside pins every member — flush_trailing attaches a trailing comment by
// line, so moving the import it belongs to would re-attach it to a different
// one. Returns `i` when nothing at `i` is sortable.
//
// That restriction is also what keeps the comment cursor happy: every separator
// inside such a run is exactly hard_line(0), so the run prints its own newlines
// and never advances pr.comment_idx out of source order.
@(private)
import_run_end :: proc(pr: ^Printer, stmts: []^ast.Stmt, i: int) -> int {
	end := i
	for end < len(stmts) {
		if stmts[end] == nil || !plain_import(stmts[end]) {
			break
		}
		if end > i && !same_align_run(pr, stmts[end - 1].end.line, stmts[end].pos.line) {
			break
		}
		end += 1
	}
	if end - i < 2 {
		return i
	}
	// A trailing comment sits on the run's own last line, which same_align_run
	// deliberately allows — here it must not, so check the whole span.
	for cg in pr.comments[pr.comment_idx:] {
		if cg.pos.line < stmts[i].pos.line {
			continue
		}
		if cg.pos.line > stmts[end - 1].end.line {
			break
		}
		return i
	}
	return end
}

@(private)
plain_import :: proc(stmt: ^ast.Stmt) -> bool {
	d, ok := stmt.derived_stmt.(^ast.Import_Decl)
	return ok && !d.is_using && len(d.attributes) == 0
}

// The relpath token text without its quotes.
@(private)
import_path :: proc(d: ^ast.Import_Decl) -> string {
	return strings.trim(d.relpath.text, `"`)
}

// Collection-qualified paths (base:, core:, vendor:) sort before local ones, so
// the conventional block shape survives a sort of a run that mixes them — a
// plain lexical sort would pull "../x" to the front.
@(private)
import_rank :: proc(path: string) -> int {
	if strings.contains(path, ":") {
		return 0
	}
	return 1
}

@(private)
import_less :: proc(a, b: ^ast.Stmt) -> bool {
	da, aok := a.derived_stmt.(^ast.Import_Decl)
	db, bok := b.derived_stmt.(^ast.Import_Decl)
	if !aok || !bok {
		return false
	}
	pa, pb := import_path(da), import_path(db)
	if ra, rb := import_rank(pa), import_rank(pb); ra != rb {
		return ra < rb
	}
	if pa != pb {
		return pa < pb
	}
	return da.name.text < db.name.text
}

// Prints every element of `stmts` in source order, as top-level-flat siblings
// (each preceded by the comment/blank-line separator, no braces of its own —
// the caller supplies those). Returns the line/has-prev state to continue
// from, so a caller can flush trailing comments afterward.
@(private)
print_stmt_list :: proc(
	pr: ^Printer,
	out: ^[dynamic]Doc,
	stmts: []^ast.Stmt,
	prev_line: int,
	has_prev: bool,
) -> (
	last_line: int,
	had_prev: bool,
) {
	assign_decl_align_ids(pr, stmts)
	last_line = prev_line
	had_prev = has_prev
	for i := 0; i < len(stmts); {
		stmt := stmts[i]
		if stmt == nil {
			i += 1
			continue
		}
		if pr.opts.sort_imports {
			if end := import_run_end(pr, stmts, i); end > i {
				run := slice.clone(stmts[i:end])
				slice.sort_by(run, import_less)
				separator(pr, out, last_line, had_prev, stmt.pos.line, true)
				for member, n in run {
					if n > 0 {
						append(out, hard_line(0))
					}
					print_stmt(pr, out, member)
				}
				// The run's last *source* line, not the last printed one, so
				// the next declaration's blank-line gap measures exactly as it
				// would have unsorted.
				last_line = stmts[end - 1].end.line
				had_prev = true
				i = end
				continue
			}
		}
		separator(pr, out, last_line, had_prev, stmt_start_line(stmt), true)
		print_stmt(pr, out, stmt)
		last_line = stmt.end.line
		had_prev = true
		i += 1
	}
	return
}

// Which alignment run a `Name :: value` declaration may join. A type
// declaration and a plain constant are different shapes and never share one, so
// `Foo :: struct {` next to `MAX :: 64` aligns neither against the other.
@(private)
Const_Run_Kind :: enum {
	None,
	Type_Decl, // align_struct_declarations
	Constant,  // align_constant_definitions
}

// An attributed or `using` declaration is left out: it emits its attributes and
// a hard line before the name, so its cell would not start at the run's column.
@(private)
const_run_kind :: proc(stmt: ^ast.Stmt) -> Const_Run_Kind {
	d, ok := stmt.derived_stmt.(^ast.Value_Decl)
	if !ok || d.is_mutable || d.is_using || d.type != nil {
		return .None
	}
	if len(d.values) != 1 || len(d.attributes) > 0 || len(d.names) == 0 {
		return .None
	}
	#partial switch _ in d.values[0].derived_expr {
	case ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Bit_Field_Type:
		return .Type_Decl
	}
	return .Constant
}

// One head id per maximal run of two or more same-kind declarations on adjacent
// lines, so their `::` line up. Called by both sibling walkers, so a run inside
// a block aligns exactly like one at file scope.
@(private)
assign_decl_align_ids :: proc(pr: ^Printer, stmts: []^ast.Stmt) {
	if !pr.opts.align_constant_definitions && !pr.opts.align_struct_declarations {
		return
	}
	for i := 0; i < len(stmts); {
		if stmts[i] == nil {
			i += 1
			continue
		}
		kind := const_run_kind(stmts[i])
		wanted := kind == .Type_Decl ? pr.opts.align_struct_declarations : pr.opts.align_constant_definitions
		if kind == .None || !wanted {
			i += 1
			continue
		}
		end := i + 1
		for end < len(stmts) &&
		    stmts[end] != nil &&
		    const_run_kind(stmts[end]) == kind &&
		    same_align_run(pr, stmts[end - 1].end.line, stmt_start_line(stmts[end])) {
			end += 1
		}
		if end - i >= 2 {
			id := next_align(pr)
			for stmt in stmts[i:end] {
				d := stmt.derived_stmt.(^ast.Value_Decl)
				pr.align_ids[rawptr(d)] = Align_Cell{head = id}
			}
		}
		i = end
	}
}

// A declaration's own .pos starts at its name, not its attributes — the
// parser appends `@(...)` attributes to an already-built Value_Decl (etc.)
// node without pulling .pos back to cover them (parse_attribute in
// core:odin/parser). Comment/blank-line separators must use the true leading
// line — the earliest attribute, if any — or a comment right above an
// attributed decl gains a spurious blank line before it.
@(private)
stmt_start_line :: proc(stmt: ^ast.Stmt) -> int {
	attrs: [dynamic]^ast.Attribute
	#partial switch s in stmt.derived_stmt {
	case ^ast.Value_Decl:
		attrs = s.attributes
	case ^ast.Import_Decl:
		attrs = s.attributes
	case ^ast.Foreign_Block_Decl:
		attrs = s.attributes
	case ^ast.Foreign_Import_Decl:
		attrs = s.attributes
	}
	line := stmt.pos.line
	for a in attrs {
		if a.pos.line < line {
			line = a.pos.line
		}
	}
	return line
}

@(private)
print_case_item :: proc(pr: ^Printer, out: ^[dynamic]Doc, item: ^ast.Stmt) {
	print_case_clause(pr, out, item.derived_stmt.(^ast.Case_Clause))
}

@(private)
print_case_clause :: proc(pr: ^Printer, out: ^[dynamic]Doc, cc: ^ast.Case_Clause) {
	append(out, text("case"))
	if len(cc.list) > 0 {
		append(out, text(" "))
		print_expr_list(pr, out, cc.list)
	}
	append(out, text(":"))
	if len(cc.body) == 0 {
		return
	}
	if pr.opts.inline_single_stmt_case && len(cc.body) == 1 && cc.body[0] != nil {
		if _, ok := cc.body[0].derived_stmt.(^ast.Block_Stmt); !ok {
			append(out, text(" "))
			print_stmt(pr, out, cc.body[0])
			return
		}
	}
	body: [dynamic]Doc
	// No flush here: the enclosing print_brace_body bounds any trailing
	// comment against the next case (or the switch's close) on its own next
	// separator call — flushing here would consume comments belonging to it.
	print_stmt_list(pr, &body, cc.body, cc.case_pos.line, true)
	append(out, indent(body[:]))
}

@(private)
print_switch_body :: proc(pr: ^Printer, out: ^[dynamic]Doc, body: ^ast.Stmt) {
	block, ok := body.derived_stmt.(^ast.Block_Stmt)
	append(out, text(" "))
	if !ok {
		append(out, text("{}"))
		return
	}
	open := ast.Node{pos = block.open, end = block.open}
	close := ast.Node{pos = block.close, end = block.close}
	print_brace_body(pr, out, open, close, block.stmts, print_case_item, pr.opts.indent_cases)
}

print_stmt :: proc(pr: ^Printer, out: ^[dynamic]Doc, stmt: ^ast.Stmt) {
	if stmt == nil {
		return
	}
	switch s in stmt.derived_stmt {
	case ^ast.Bad_Stmt:
	// Unreachable: format() refuses any source with a parse error.

	case ^ast.Empty_Stmt:
	// A stray ';' carries nothing worth reproducing.

	case ^ast.Expr_Stmt:
		print_expr(pr, out, s.expr)

	case ^ast.Tag_Stmt:
		append(out, text("#"))
		append(out, text(s.name))
		append(out, text(" "))
		print_stmt(pr, out, s.stmt)

	case ^ast.Assign_Stmt:
		print_expr_list(pr, out, s.lhs)
		append(out, text(" "))
		append(out, text(s.op.text))
		append(out, text(" "))
		print_expr_list(pr, out, s.rhs)

	case ^ast.Block_Stmt:
		if s.label != nil {
			print_expr(pr, out, s.label)
			append(out, text(": "))
		}
		print_block(pr, out, s, false)

	case ^ast.If_Stmt:
		if s.label != nil {
			print_expr(pr, out, s.label)
			append(out, text(": "))
		}
		append(out, text("if "))
		if s.init != nil {
			print_stmt(pr, out, s.init)
			append(out, text("; "))
		}
		print_expr(pr, out, s.cond)
		print_body(pr, out, s.body, false)
		print_else(pr, out, s.else_stmt)

	case ^ast.When_Stmt:
		append(out, text("when "))
		print_expr(pr, out, s.cond)
		print_body(pr, out, s.body, false)
		print_else(pr, out, s.else_stmt)

	case ^ast.Return_Stmt:
		append(out, text("return"))
		if len(s.results) > 0 {
			append(out, text(" "))
			print_expr_list(pr, out, s.results)
		}

	case ^ast.Defer_Stmt:
		append(out, text("defer "))
		print_stmt(pr, out, s.stmt)

	case ^ast.For_Stmt:
		if s.label != nil {
			print_expr(pr, out, s.label)
			append(out, text(": "))
		}
		append(out, text("for"))
		switch {
		case s.init == nil && s.cond == nil && s.post == nil:
		case s.init == nil && s.post == nil && s.cond != nil:
			append(out, text(" "))
			print_expr(pr, out, s.cond)
		case:
			append(out, text(" "))
			if s.init != nil {
				print_stmt(pr, out, s.init)
			}
			append(out, text("; "))
			if s.cond != nil {
				print_expr(pr, out, s.cond)
			}
			append(out, text("; "))
			if s.post != nil {
				print_stmt(pr, out, s.post)
			}
		}
		print_body(pr, out, s.body, false)

	case ^ast.Range_Stmt:
		if s.label != nil {
			print_expr(pr, out, s.label)
			append(out, text(": "))
		}
		if s.reverse {
			append(out, text("#reverse "))
		}
		append(out, text("for "))
		print_expr_list(pr, out, s.vals)
		append(out, text(" in "))
		print_expr(pr, out, s.expr)
		print_body(pr, out, s.body, false)

	case ^ast.Inline_Range_Stmt:
		if s.label != nil {
			print_expr(pr, out, s.label)
			append(out, text(": "))
		}
		append(out, text("#unroll"))
		if len(s.args) > 0 {
			append(out, text("("))
			print_expr_list(pr, out, s.args)
			append(out, text(")"))
		}
		append(out, text(" for "))
		if s.val0 != nil {
			print_expr(pr, out, s.val0)
		}
		if s.val1 != nil {
			append(out, text(", "))
			print_expr(pr, out, s.val1)
		}
		append(out, text(" in "))
		print_expr(pr, out, s.expr)
		print_body(pr, out, s.body, false)

	case ^ast.Case_Clause:
		print_case_clause(pr, out, s)

	case ^ast.Switch_Stmt:
		if s.label != nil {
			print_expr(pr, out, s.label)
			append(out, text(": "))
		}
		if s.partial {
			append(out, text("#partial "))
		}
		append(out, text("switch"))
		if s.init != nil || s.cond != nil {
			append(out, text(" "))
			if s.init != nil {
				print_stmt(pr, out, s.init)
				append(out, text("; "))
			}
			if s.cond != nil {
				print_expr(pr, out, s.cond)
			}
		}
		print_switch_body(pr, out, s.body)

	case ^ast.Type_Switch_Stmt:
		if s.label != nil {
			print_expr(pr, out, s.label)
			append(out, text(": "))
		}
		if s.partial {
			append(out, text("#partial "))
		}
		append(out, text("switch "))
		if s.tag != nil {
			print_stmt(pr, out, s.tag)
		}
		print_switch_body(pr, out, s.body)

	case ^ast.Branch_Stmt:
		append(out, text(s.tok.text))
		if s.label != nil {
			append(out, text(" "))
			print_expr(pr, out, s.label)
		}

	case ^ast.Using_Stmt:
		append(out, text("using "))
		print_expr_list(pr, out, s.list)

	case ^ast.Bad_Decl:
	// Unreachable: format() refuses any source with a parse error.

	case ^ast.Value_Decl:
		print_value_decl(pr, out, s)

	case ^ast.Package_Decl:
	// Never appears in file.decls — handled by print_file directly.

	case ^ast.Import_Decl:
		print_import_decl(pr, out, s)

	case ^ast.Foreign_Block_Decl:
		print_foreign_block_decl(pr, out, s)

	case ^ast.Foreign_Import_Decl:
		print_foreign_import_decl(pr, out, s)
	}
}
