// The formatter's entry point: parse with the compiler's own front end
// (core:odin/parser), refuse on any syntax error so a broken file is never
// mangled, then print a Doc from the AST and render it.
package odinfmt

import "base:runtime"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"

// core:odin/tokenizer fills its keyword table on the first tokenizer.init, under a
// double-checked lock that does not re-check: a second thread that arrives while the
// first fills asserts with the table spinlock held, and every later parse then spins
// on it forever. The table is filled here, before any thread runs.
@(init)
warm_keyword_table :: proc "contextless" () {
	context = runtime.default_context()
	t: tokenizer.Tokenizer
	tokenizer.init(&t, "", "<warm>", silent_handler)
}

// format parses `source` (Odin source, LF-only — the lang seam's contract)
// and returns its canonical layout under `opts`. ok is false when the source
// has a syntax error; out is then empty and must not be used.
format :: proc(source: string, opts: Options, allocator := context.allocator) -> (out: string, ok: bool) {
	// The AST and the Doc tree are scratch, and core:odin/ast has no destructor:
	// one arena holds both and drops them together, so only the rendered string
	// reaches the caller.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return "", false
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

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
	pr.align_ids = make(map[rawptr]Align_Cell) // arena-backed, dropped with the AST

	doc := print_file(&pr, &file)
	rendered := render(doc, &pr.opts, allocator)
	return rendered, true
}

@(private)
silent_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
}
