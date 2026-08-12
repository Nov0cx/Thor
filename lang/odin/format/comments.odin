// Comment interleaving. The parser appends every comment group it sees —
// free-floating, leading-doc or trailing — to ast.File.comments in source
// order, so a single position cursor over that list plus the ordinary node
// walk is enough: the visitor never reads a node's own .docs/.comment field,
// it just asks the cursor to catch up to the position it is about to print.
package odinfmt

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

Printer :: struct {
	opts:         Options,
	src:          string,
	comments:     []^ast.Comment_Group,
	comment_idx:  int,
	next_align_id: int,
}

@(private)
next_align :: proc(pr: ^Printer) -> int {
	pr.next_align_id += 1
	return pr.next_align_id
}

// blanks between two lines that are `gap` apart (gap = next.line - prev.line),
// clamped by the caller's newline_limit at render time — this just turns a
// line gap into "how many blank lines sit between them", never negative.
@(private)
blanks_between :: proc(prev_line, next_line: int) -> int {
	gap := next_line - prev_line - 1
	if gap < 0 {
		return 0
	}
	return gap
}

@(private)
comment_group_text :: proc(pr: ^Printer, cg: ^ast.Comment_Group, out: ^[dynamic]Doc) {
	for tok, i in cg.list {
		if i > 0 {
			blanks := blanks_between(cg.list[i - 1].pos.line, tok.pos.line)
			append(out, hard_line(blanks))
		}
		append(out, text(strings.trim_right_space(tok.text)))
	}
}

// Appends every pending comment group that starts on `line` (the line the
// just-printed node ended on) as a trailing comment: a couple of spaces then
// the comment text, no line break of its own. Returns the line the printer
// should now treat as "last printed" (the trailing comment's own last line).
@(private)
flush_trailing :: proc(pr: ^Printer, out: ^[dynamic]Doc, line: int) -> int {
	last_line := line
	for pr.comment_idx < len(pr.comments) {
		cg := pr.comments[pr.comment_idx]
		if cg.pos.line != last_line {
			break
		}
		append(out, text("  "))
		comment_group_text(pr, cg, out)
		last_line = cg.list[len(cg.list) - 1].pos.line
		pr.comment_idx += 1
	}
	return last_line
}

// Flushes any trailing comment clinging to prev's last line, then every
// own-line comment that falls before next's line (or, with has_next false,
// every comment left), preserving blank-line gaps throughout. Does not add
// the final gap up to `next` itself — see separator, which adds that on top
// for the common "print next right after" case; a caller that supplies its
// own fixed newline before what comes next (a closing brace) wants this one
// instead, or its own hard_line(0) would double up with the gap this leaves
// behind.
@(private)
flush_before :: proc(pr: ^Printer, out: ^[dynamic]Doc, prev_line: int, has_prev: bool, next_line: int, has_next: bool) -> (last_line: int, had_content: bool) {
	last_line = prev_line
	had_content = has_prev
	if has_prev {
		last_line = flush_trailing(pr, out, prev_line)
	}

	for pr.comment_idx < len(pr.comments) {
		cg := pr.comments[pr.comment_idx]
		if has_next && cg.pos.line >= next_line {
			break
		}
		if had_content || len(out^) > 0 {
			append(out, hard_line(blanks_between(last_line, cg.pos.line)))
		}
		comment_group_text(pr, cg, out)
		last_line = cg.list[len(cg.list) - 1].pos.line
		pr.comment_idx += 1
		last_line = flush_trailing(pr, out, last_line)
		had_content = true
	}
	return
}

// flush_before, plus the gap up to `next` itself. Appends everything to
// `out`; the caller still owns emitting `next`'s own content afterward.
@(private)
separator :: proc(pr: ^Printer, out: ^[dynamic]Doc, prev_line: int, has_prev: bool, next_line: int, has_next: bool) {
	last_line, had_content := flush_before(pr, out, prev_line, has_prev, next_line, has_next)
	if has_next {
		if had_content || len(out^) > 0 {
			append(out, hard_line(blanks_between(last_line, next_line)))
		}
	}
}

// Flushes every comment left in pr.comments (called once, after the last
// top-level declaration) so trailing free-floating comments are never lost.
@(private)
flush_remaining :: proc(pr: ^Printer, out: ^[dynamic]Doc, prev_line: int, has_prev: bool) {
	separator(pr, out, prev_line, has_prev, 0, false)
}

@(private)
pos_line :: proc(pos: tokenizer.Pos) -> int {
	return pos.line
}
