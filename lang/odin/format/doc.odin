// A Wadler-style pretty-printing document: build once from the AST, then
// render with a width-aware fits check. A Group renders flat (spaces, no
// newlines) when it fits the remaining width, else broken (its Lines become
// newlines); nested groups measure and decide independently, so a call that
// fits still hugs one line inside an outer struct literal that had to break.
//
// A group's fits check measures the group alone, never the text that follows
// it on the same line, so `foo(a, b) or_return` keeps the call flat even when
// the tail crosses character_width. A full check needs a rest-of-document work
// list; this one only ever under-breaks, and never emits wrong code.
package odinfmt

import "core:strings"
import "core:unicode/utf8"

Doc :: ^Doc_Node

Doc_Node :: struct {
	variant: Doc_Variant,
}

Doc_Variant :: union {
	Doc_Text,
	Doc_Line,
	Doc_Hard_Line,
	Doc_Group,
	Doc_Indent,
	Doc_Align,
	Doc_Concat,
	Doc_If_Break,
	Doc_Break_Parent,
}

// Verbatim text with no embedded newline.
Doc_Text :: struct {
	text: string,
}

Line_Kind :: enum {
	Space, // flat: " "     broken: newline + indent
	Soft,  // flat: ""      broken: newline + indent
}

Doc_Line :: struct {
	kind: Line_Kind,
}

// Always a newline, in flat mode too — used for statement/decl separators,
// where "flat" never applies. blanks is how many *extra* blank lines precede
// it (already clamped to newline_limit by the caller).
Doc_Hard_Line :: struct {
	blanks: int,
}

// Rendered flat when its flat width fits in the remaining line, else broken.
// Any Hard_Line below it forces it broken, nested groups included — measure_flat
// recurses into a child group, so a forced break propagates to every ancestor.
Doc_Group :: struct {
	children: []Doc,
}

Doc_Indent :: struct {
	children: []Doc,
}

// One cell of an alignment run: all Doc_Align nodes sharing `id` are padded
// (in a pre-render measurement pass) to the widest cell's flat width.
//
// Two rules the emitter must keep. Every cell sharing an id must start at the
// same column, since the pad is relative to where the cell started. And a cell
// must never sit in a group that can render flat: measure_flat reports a cell's
// unpadded width, so such a group under-measures itself.
Doc_Align :: struct {
	id:       int,
	children: []Doc,
}

Doc_Concat :: struct {
	children: []Doc,
}

// `flat` inside a flat group, `broken` inside a broken one — the trailing comma
// Odin's convention wants on a wrapped list and must not have on a hugged one.
Doc_If_Break :: struct {
	flat:   []Doc,
	broken: []Doc,
}

// No output, but every enclosing group breaks. Emitted next to a `//` comment,
// whose flat rendering would swallow the rest of the line.
Doc_Break_Parent :: struct {}

@(private)
doc_alloc :: proc(v: Doc_Variant, allocator := context.allocator) -> Doc {
	d := new(Doc_Node, allocator)
	d.variant = v
	return d
}

text :: proc(s: string, allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_Text{text = s}, allocator)
}

line :: proc(allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_Line{kind = .Space}, allocator)
}

soft_line :: proc(allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_Line{kind = .Soft}, allocator)
}

hard_line :: proc(blanks := 0, allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_Hard_Line{blanks = blanks}, allocator)
}

group :: proc(children: []Doc, allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_Group{children = children}, allocator)
}

indent :: proc(children: []Doc, allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_Indent{children = children}, allocator)
}

align :: proc(id: int, children: []Doc, allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_Align{id = id, children = children}, allocator)
}

concat :: proc(children: []Doc, allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_Concat{children = children}, allocator)
}

if_break :: proc(flat, broken: []Doc, allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_If_Break{flat = flat, broken = broken}, allocator)
}

break_parent :: proc(allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_Break_Parent{}, allocator)
}

// concat of everything currently in `parts`, so callers can build with a
// [dynamic]Doc and hand it off in one call.
concat_dynamic :: proc(parts: [dynamic]Doc, allocator := context.allocator) -> Doc {
	return doc_alloc(Doc_Concat{children = parts[:]}, allocator)
}

@(private)
rune_width :: proc(s: string) -> int {
	return utf8.rune_count_in_string(s)
}

// Flat width of `d` in columns, or ok=false when `d` contains a Hard_Line
// (and so can never render on one line). Nested groups are measured as if
// flat — the same simplification the renderer relies on: a group's own fits
// check happens when the renderer actually reaches it.
@(private)
measure_flat :: proc(d: Doc, opts: ^Options) -> (width: int, ok: bool) {
	if d == nil {
		return 0, true
	}
	switch v in d.variant {
	case Doc_Text:
		return rune_width(v.text), true
	case Doc_Line:
		return (1 if v.kind == .Space else 0), true
	case Doc_Hard_Line:
		return 0, false
	case Doc_Group:
		return measure_flat_children(v.children, opts)
	case Doc_Indent:
		return measure_flat_children(v.children, opts)
	case Doc_Align:
		return measure_flat_children(v.children, opts)
	case Doc_Concat:
		return measure_flat_children(v.children, opts)
	case Doc_If_Break:
		return measure_flat_children(v.flat, opts)
	case Doc_Break_Parent:
		return 0, false
	}
	return 0, true
}

@(private)
measure_flat_children :: proc(children: []Doc, opts: ^Options) -> (width: int, ok: bool) {
	ok = true
	for c in children {
		w, cok := measure_flat(c, opts)
		if !cok {
			return 0, false
		}
		width += w
	}
	return
}

@(private)
Render_Mode :: enum {
	Flat,
	Break,
}

@(private)
Render_State :: struct {
	sb:           strings.Builder,
	opts:         ^Options,
	column:       int,
	level:        int, // indent level, in "tabs" (or opts.spaces-wide steps)
	lines:        int, // newlines written; an align cell that crossed one is never padded
	align_widths: map[int]int,
}

@(private)
indent_width :: proc(rs: ^Render_State) -> int {
	if rs.opts.tabs {
		return rs.level * rs.opts.tabs_width
	}
	return rs.level * rs.opts.spaces
}

@(private)
write_indent :: proc(rs: ^Render_State) {
	if rs.opts.tabs {
		for _ in 0 ..< rs.level {
			strings.write_byte(&rs.sb, '\t')
		}
	} else {
		for _ in 0 ..< rs.level * rs.opts.spaces {
			strings.write_byte(&rs.sb, ' ')
		}
	}
	rs.column = indent_width(rs)
}

@(private)
render_newlines :: proc(rs: ^Render_State, blanks: int) {
	limit := rs.opts.newline_limit
	if limit < 0 {
		limit = 0
	}
	n := blanks
	if n > limit {
		n = limit
	}
	for _ in 0 ..= n {
		strings.write_byte(&rs.sb, '\n')
		rs.lines += 1
	}
	write_indent(rs)
}

@(private)
render_doc :: proc(rs: ^Render_State, d: Doc, mode: Render_Mode) {
	if d == nil {
		return
	}
	switch v in d.variant {
	case Doc_Text:
		strings.write_string(&rs.sb, v.text)
		rs.column += rune_width(v.text)

	case Doc_Line:
		if mode == .Flat {
			if v.kind == .Space {
				strings.write_byte(&rs.sb, ' ')
				rs.column += 1
			}
		} else {
			render_newlines(rs, 0)
		}

	case Doc_Hard_Line:
		render_newlines(rs, v.blanks)

	case Doc_Group:
		// A group inside a flat group inherits flat: the parent already
		// committed to one line, so no descendant may break it.
		child_mode := mode
		if mode == .Break {
			w, fits := measure_flat_children(v.children, rs.opts)
			if fits && (rs.opts.character_width <= 0 || rs.column + w <= rs.opts.character_width) {
				child_mode = .Flat
			} else {
				child_mode = .Break
			}
		}
		for c in v.children {
			render_doc(rs, c, child_mode)
		}

	case Doc_Indent:
		rs.level += 1
		for c in v.children {
			render_doc(rs, c, mode)
		}
		rs.level -= 1

	case Doc_Align:
		// A cell that wrote a newline is left unpadded: rs.column then belongs
		// to the continuation line, and padding it to a width measured from the
		// previous line's start is only trailing whitespace.
		start := rs.column
		at := rs.lines
		for c in v.children {
			render_doc(rs, c, mode)
		}
		if rs.lines != at {
			break
		}
		width := rs.align_widths[v.id]
		for rs.column < start + width {
			strings.write_byte(&rs.sb, ' ')
			rs.column += 1
		}

	case Doc_Concat:
		for c in v.children {
			render_doc(rs, c, mode)
		}

	case Doc_If_Break:
		for c in (mode == .Flat ? v.flat : v.broken) {
			render_doc(rs, c, mode)
		}

	case Doc_Break_Parent:
	// Nothing to write: it only ever changes a group's fits check.
	}
}

// Widest flat width seen for each align id, over the whole document — the
// pre-render measurement pass the renderer's Doc_Align padding relies on.
@(private)
compute_align_widths :: proc(d: Doc, opts: ^Options, widths: ^map[int]int) {
	if d == nil {
		return
	}
	switch v in d.variant {
	case Doc_Text, Doc_Line, Doc_Hard_Line, Doc_Break_Parent:
	case Doc_If_Break:
		for c in v.flat {
			compute_align_widths(c, opts, widths)
		}
		for c in v.broken {
			compute_align_widths(c, opts, widths)
		}
	case Doc_Group:
		for c in v.children {
			compute_align_widths(c, opts, widths)
		}
	case Doc_Indent:
		for c in v.children {
			compute_align_widths(c, opts, widths)
		}
	case Doc_Align:
		// A cell with a hard line in it is never padded, so it must not widen
		// the run either.
		if w, measured := measure_flat_children(v.children, opts); measured {
			if cur, ok := widths[v.id]; !ok || w > cur {
				widths[v.id] = w
			}
		}
		for c in v.children {
			compute_align_widths(c, opts, widths)
		}
	case Doc_Concat:
		for c in v.children {
			compute_align_widths(c, opts, widths)
		}
	}
}

// Renders `d` to a string using `opts`, starting broken at the top level (a
// document's top-level declarations always sit one per line; only inner
// groups make a flat/broken choice).
render :: proc(d: Doc, opts: ^Options, allocator := context.allocator) -> string {
	rs: Render_State
	rs.sb = strings.builder_make(allocator)
	rs.opts = opts
	rs.align_widths = make(map[int]int, context.temp_allocator)
	compute_align_widths(d, opts, &rs.align_widths)
	render_doc(&rs, d, .Break)
	return strings.to_string(rs.sb)
}
