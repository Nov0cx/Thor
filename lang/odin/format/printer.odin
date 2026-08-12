// The formatter's entry point: parse with the compiler's own front end
// (core:odin/parser), refuse on any syntax error so a broken file is never
// mangled, then print a Doc from the AST and render it.
package odinfmt

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"

// format parses `source` (Odin source, LF-only — the lang seam's contract)
// and returns its canonical layout under `opts`. ok is false when the source
// has a syntax error; out is then empty and must not be used.
format :: proc(source: string, opts: Options, allocator := context.allocator) -> (out: string, ok: bool) {
	file: ast.File
	file.src = source
	file.fullpath = "<format>"

	p := parser.default_parser({.Optional_Semicolons})
	p.err = silent_handler
	p.warn = silent_handler

	if !parser.parse_file(&p, &file) {
		return "", false
	}
	if file.syntax_error_count > 0 {
		return "", false
	}

	pr: Printer
	pr.opts = opts
	pr.src = source
	pr.comments = file.comments[:]

	doc := print_file(&pr, &file)
	rendered := render(doc, &pr.opts, allocator)
	return rendered, true
}

@(private)
silent_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
}
