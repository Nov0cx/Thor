// Golden-file-style unit tests exercise individual options; the round-trip
// suite (below) is the broad safety net — every substantial package in this
// repo formats with no meaning change (token-stream equal, ignoring commas
// and semicolons that legitimately come and go with reflow) and is
// idempotent. A failure there is the signal to add a targeted case here.
package odinfmt

import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
test_refuses_syntax_error :: proc(t: ^testing.T) {
	_, ok := format("package p\nfoo :: proc( {\n", default_options())
	testing.expect(t, !ok, "a syntax error must refuse, never guess")
}

@(test)
test_idempotent_default :: proc(t: ^testing.T) {
	src := "package p\nFoo::struct{x:int,y:int}\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	out2, ok2 := format(out, default_options())
	defer delete(out2)
	testing.expect(t, ok2)
	testing.expect_value(t, out2, out)
}

@(test)
test_brace_style_allman :: proc(t: ^testing.T) {
	opts := default_options()
	opts.brace_style = .Allman
	src := "package p\nf :: proc() {\n\treturn\n}\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "proc()\n{"), out)
}

@(test)
test_tabs_false_uses_spaces :: proc(t: ^testing.T) {
	opts := default_options()
	opts.tabs = false
	opts.spaces = 2
	src := "package p\nFoo :: struct {\n\tx: int,\n}\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\n  x: int,"), out)
}

@(test)
test_spaces_around_colons :: proc(t: ^testing.T) {
	opts := default_options()
	opts.spaces_around_colons = true
	src := "package p\nx: int = 1\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "x : int = 1"), out)
}

@(test)
test_align_struct_fields :: proc(t: ^testing.T) {
	src := "package p\nFoo :: struct {\n\tx: int,\n\tlonger: string,\n}\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\tx:      int,"), out)
	testing.expect(t, strings.contains(out, "\tlonger: string,"), out)
}

@(test)
test_align_struct_fields_off :: proc(t: ^testing.T) {
	opts := default_options()
	opts.align_struct_fields = false
	src := "package p\nFoo :: struct {\n\tx: int,\n\tlonger: string,\n}\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\tx: int,"), out)
}

@(test)
test_align_run_breaks_on_blank_line :: proc(t: ^testing.T) {
	src := "package p\nFoo :: struct {\n\tx: int,\n\tlonger: string,\n\n\ta: int,\n\tbb: string,\n}\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\tx:      int,"), out)
	testing.expect(t, strings.contains(out, "\ta:  int,"), out)
}

@(test)
test_align_run_breaks_on_own_line_comment :: proc(t: ^testing.T) {
	src := "package p\nFoo :: struct {\n\tx: int,\n\tlonger: string,\n\t// note\n\ta: int,\n\tbb: string,\n}\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\tx:      int,"), out)
	testing.expect(t, strings.contains(out, "\ta:  int,"), out)
}

@(test)
test_align_run_keeps_trailing_comment :: proc(t: ^testing.T) {
	src := "package p\nFoo :: struct {\n\tx: int, // why\n\tlonger: string,\n}\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\tx:      int,  // why"), out)
	testing.expect(t, strings.contains(out, "\tlonger: string,"), out)
}

@(test)
test_align_fields_spaces_around_colons :: proc(t: ^testing.T) {
	opts := default_options()
	opts.spaces_around_colons = true
	src := "package p\nFoo :: struct {\n\tx: int,\n\tlonger: string,\n}\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\tx      : int,"), out)
	testing.expect(t, strings.contains(out, "\tlonger : string,"), out)
}

@(test)
test_align_fields_using_prefix_in_cell :: proc(t: ^testing.T) {
	src := "package p\nFoo :: struct {\n\tusing base: Bar,\n\tx: int,\n}\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\tusing base: Bar,"), out)
	testing.expect(t, strings.contains(out, "\tx:          int,"), out)
}

@(test)
test_align_fields_multiline_type_not_padded :: proc(t: ^testing.T) {
	src := "package p\nFoo :: struct {\n\tx: int,\n\tinner: struct {\n\t\ta: int,\n\t\tbb: int,\n\t},\n}\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, assert_no_trailing_whitespace(t, "<inline>", out), out)
}

@(test)
test_align_struct_values_comp_lit :: proc(t: ^testing.T) {
	opts := default_options()
	opts.exp_multiline_composite_literals = true
	src := "package p\nv := Foo{\n\ta = 1,\n\tlonger = 2,\n}\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\ta      = 1,"), out)
	testing.expect(t, strings.contains(out, "\tlonger = 2,"), out)
}

@(test)
test_align_struct_values_off :: proc(t: ^testing.T) {
	opts := default_options()
	opts.align_struct_values = false
	src := "package p\nE :: enum {\n\tA = 1,\n\tLong = 2,\n}\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\tA = 1,"), out)
}

@(test)
test_align_values_break_on_bare_member :: proc(t: ^testing.T) {
	src := "package p\nE :: enum {\n\tA = 1,\n\tBare,\n\tCcc = 2,\n\tDddd = 3,\n}\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\tA = 1,"), out)
	testing.expect(t, strings.contains(out, "\tCcc  = 2,"), out)
	testing.expect(t, assert_no_trailing_whitespace(t, "<inline>", out), out)
}

@(test)
test_align_enum_values :: proc(t: ^testing.T) {
	src := "package p\nE :: enum {\n\tA = 1,\n\tLong = 2,\n}\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\tA    = 1,"), out)
	testing.expect(t, strings.contains(out, "\tLong = 2,"), out)
}

@(test)
test_align_bit_field :: proc(t: ^testing.T) {
	src := "package p\nB :: bit_field u32 {\n\ta: int | 3,\n\tlonger: uint | 4,\n}\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "\ta:      int  | 3,"), out)
	testing.expect(t, strings.contains(out, "\tlonger: uint | 4,"), out)
}

@(test)
test_align_constant_definitions :: proc(t: ^testing.T) {
	opts := default_options()
	opts.align_constant_definitions = true
	src := "package p\nA :: 1\nLONGER :: 2\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "A      :: 1"), out)
	testing.expect(t, strings.contains(out, "LONGER :: 2"), out)
}

@(test)
test_align_constant_definitions_off :: proc(t: ^testing.T) {
	src := "package p\nA :: 1\nLONGER :: 2\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "A :: 1"), out)
}

@(test)
test_align_struct_declarations :: proc(t: ^testing.T) {
	opts := default_options()
	opts.align_struct_declarations = true
	src := "package p\nA :: struct {}\nLonger :: enum {}\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "A      :: struct {}"), out)
	testing.expect(t, strings.contains(out, "Longer :: enum {}"), out)
}

@(test)
test_align_decl_runs_do_not_mix_kinds :: proc(t: ^testing.T) {
	opts := default_options()
	opts.align_constant_definitions = true
	opts.align_struct_declarations = true
	src := "package p\nMAX :: 64\nFoo :: struct {}\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "MAX :: 64"), out)
	testing.expect(t, strings.contains(out, "Foo :: struct {}"), out)
}

@(test)
test_sort_imports :: proc(t: ^testing.T) {
	src := "package p\n\nimport \"core:strings\"\nimport \"core:fmt\"\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "import \"core:fmt\"\nimport \"core:strings\""), out)
}

@(test)
test_sort_imports_off :: proc(t: ^testing.T) {
	opts := default_options()
	opts.sort_imports = false
	src := "package p\n\nimport \"core:strings\"\nimport \"core:fmt\"\n"
	out, ok := format(src, opts)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "import \"core:strings\"\nimport \"core:fmt\""), out)
}

@(test)
test_sort_imports_ranks_collections_first :: proc(t: ^testing.T) {
	src := "package p\n\nimport \"core:fmt\"\nimport \"../msvc\"\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "import \"core:fmt\"\nimport \"../msvc\""), out)
}

@(test)
test_sort_imports_comment_pins_run :: proc(t: ^testing.T) {
	src := "package p\n\nimport \"core:strings\"\n// keep\nimport \"core:fmt\"\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "import \"core:strings\"\n// keep\nimport \"core:fmt\""), out)
}

@(test)
test_sort_imports_blank_line_splits_runs :: proc(t: ^testing.T) {
	src := "package p\n\nimport \"core:strings\"\nimport \"core:fmt\"\n\nimport \"core:os\"\nimport \"core:mem\"\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "import \"core:fmt\"\nimport \"core:strings\""), out)
	testing.expect(t, strings.contains(out, "import \"core:mem\"\nimport \"core:os\""), out)
}

@(test)
test_sort_imports_keeps_binding_name :: proc(t: ^testing.T) {
	src := "package p\n\nimport \"core:strings\"\nimport rl \"vendor:raylib\"\n"
	out, ok := format(src, default_options())
	defer delete(out)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(out, "import \"core:strings\"\nimport rl \"vendor:raylib\""), out)
}

@(private)
token_stream :: proc(src: string) -> [dynamic]tokenizer.Token {
	t: tokenizer.Tokenizer
	tokenizer.init(&t, src, "<probe>")
	t.flags += {.Insert_Semicolon}
	out: [dynamic]tokenizer.Token
	for {
		tok := tokenizer.scan(&t)
		#partial switch tok.kind {
		case .Comment:
			continue
		case .Semicolon:
			continue // Optional_Semicolons noise, or a real ';' the formatter splits onto its own line — neither is a meaning change
		case .Comma:
			continue // a trailing comma before ) or } comes and goes with line-wrapping (phase 3, not yet implemented) — not a meaning change
		}
		append(&out, tok)
		if tok.kind == .EOF {
			break
		}
	}
	return out
}

// Alignment is whitespace, so the token stream cannot see it at all: a cell
// padded on the wrong line, or a run that pads a member with nothing after it,
// is token-identical and visibly broken. Nothing this printer emits ever
// legitimately ends a line with a space or a tab.
@(private)
assert_no_trailing_whitespace :: proc(t: ^testing.T, path, out: string) -> bool {
	rest := out
	for line_no := 1; ; line_no += 1 {
		line := rest
		if cut := strings.index_byte(rest, '\n'); cut >= 0 {
			line = rest[:cut]
			rest = rest[cut + 1:]
		} else {
			rest = ""
		}
		if len(line) > 0 {
			if last := line[len(line) - 1]; last == ' ' || last == '\t' {
				fmt.println("TRAILING WHITESPACE:", path, "line", line_no, ":", line)
				testing.fail(t)
				return false
			}
		}
		if len(rest) == 0 {
			break
		}
	}
	return true
}

@(private)
assert_round_trip :: proc(t: ^testing.T, path: string) {
	src, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.println("skip (unreadable):", path)
		return
	}
	defer delete(src)
	source := string(src)
	// The token-stream comparison is order-sensitive and sort_imports is
	// exactly a reordering, so meaning is checked with sorting off; the
	// defaults then get the two checks that survive a reorder (below).
	unsorted := default_options()
	unsorted.sort_imports = false
	out, fok := format(source, unsorted)
	defer delete(out)
	_ = os.write_entire_file("bin/test/last_out.odin.txt", transmute([]u8)out)
	if !fok {
		fmt.println("FORMAT FAILED (syntax error):", path)
		testing.fail(t)
		return
	}
	if !assert_no_trailing_whitespace(t, path, out) {
		return
	}

	before := token_stream(source)
	defer delete(before)
	after := token_stream(out)
	defer delete(after)
	if len(before) != len(after) {
		fmt.println("TOKEN COUNT MISMATCH:", path, "before:", len(before), "after:", len(after))
		n := min(len(before), len(after))
		diverged := false
		for i in 0 ..< n {
			if before[i].kind != after[i].kind || before[i].text != after[i].text {
				fmt.println("  first diff at token", i, "before:", before[i], "after:", after[i])
				diverged = true
				break
			}
		}
		if !diverged {
			fmt.println("  all", n, "common tokens matched; extra/missing tail. Last few before shared boundary:")
			lo := max(0, n - 5)
			for i in lo ..< n {
				fmt.println("   before[", i, "]=", before[i])
			}
			fmt.println("  tail of the longer side:")
			if len(before) > len(after) {
				for i in n ..< len(before) {
					fmt.println("   before[", i, "]=", before[i])
				}
			} else {
				for i in n ..< len(after) {
					fmt.println("   after[", i, "]=", after[i])
				}
			}
		}
		testing.fail(t)
		return
	}
	for i in 0 ..< len(before) {
		if before[i].kind != after[i].kind || before[i].text != after[i].text {
			fmt.println("TOKEN MISMATCH:", path, "at", i, "before:", before[i], "after:", after[i])
			testing.fail(t)
			return
		}
	}

	out2, fok2 := format(out, unsorted)
	defer delete(out2)
	if !fok2 {
		fmt.println("NOT IDEMPOTENT (second format failed):", path)
		testing.fail(t)
		return
	}
	if out2 != out {
		fmt.println("NOT IDEMPOTENT:", path)
		_ = os.write_entire_file("bin/test/idem_1.odin.txt", transmute([]u8)out)
		_ = os.write_entire_file("bin/test/idem_2.odin.txt", transmute([]u8)out2)
		testing.fail(t)
		return
	}

	if !assert_sorted_round_trip(t, path, source) {
		return
	}
	fmt.println("OK", path, len(before), "tokens")
}

// The default options, sorting included: still parses, still converges, and no
// token was dropped or duplicated. A multiset compare is the strongest check
// that survives a reorder, and reordering is the only thing sort_imports does.
@(private)
assert_sorted_round_trip :: proc(t: ^testing.T, path, source: string) -> bool {
	sorted, ok := format(source, default_options())
	defer delete(sorted)
	if !ok {
		fmt.println("FORMAT FAILED (sorted):", path)
		testing.fail(t)
		return false
	}
	if !assert_no_trailing_whitespace(t, path, sorted) {
		return false
	}

	again, ok2 := format(sorted, default_options())
	defer delete(again)
	if !ok2 || again != sorted {
		fmt.println("NOT IDEMPOTENT (sorted):", path)
		_ = os.write_entire_file("bin/test/idem_1.odin.txt", transmute([]u8)sorted)
		_ = os.write_entire_file("bin/test/idem_2.odin.txt", transmute([]u8)again)
		testing.fail(t)
		return false
	}

	before := token_stream(source)
	defer delete(before)
	after := token_stream(sorted)
	defer delete(after)
	if len(before) != len(after) {
		fmt.println("TOKEN COUNT MISMATCH (sorted):", path, len(before), "vs", len(after))
		testing.fail(t)
		return false
	}
	slice.sort_by(before[:], token_less)
	slice.sort_by(after[:], token_less)
	for i in 0 ..< len(before) {
		if before[i].kind != after[i].kind || before[i].text != after[i].text {
			fmt.println("TOKEN MULTISET MISMATCH (sorted):", path, "at", i, before[i], after[i])
			testing.fail(t)
			return false
		}
	}
	return true
}

@(private)
token_less :: proc(a, b: tokenizer.Token) -> bool {
	if a.kind != b.kind {
		return a.kind < b.kind
	}
	return a.text < b.text
}

@(test)
test_round_trip_real_files :: proc(t: ^testing.T) {
	paths := []string{
		"lang/lang.odin",
		"lang/feature.odin",
		"lang/source.odin",
		"lang/odin/config.odin",
		"lang/odin/engine.odin",
		"lang/odin/resolve.odin",
		"lang/odin/actions.odin",
		"lang/odin/completion.odin",
		"lang/odin/container.odin",
		"lang/odin/using.odin",
		"lang/odin/typeref.odin",
		"lang/odin/infer.odin",
		"lang/odin/decl.odin",
		"lang/odin/index.odin",
		"lang/odin/symbols.odin",
		"lang/odin/semantic.odin",
		"lang/odin/check.odin",
		"lang/odin/packagedoc.odin",
		"lang/odin/builtins.odin",
		"lang/odin/path_windows.odin",
		"lang/odin/path_posix.odin",
		"lang/lsp/config.odin",
		"lang/lsp/requests.odin",
		"lang/lsp/decode.odin",
		"lang/lsp/server.odin",
		"lang/lsp/position.odin",
		"lang/lsp/capability.odin",
		"textedit/ops.odin",
		"textedit/textedit.odin",
		"piecetable/piecetable.odin",
		"thor/files.odin",
		"thor/lang_host.odin",
		"thor/thor.odin",
		"thor/commands.odin",
		"thor/actions.odin",
		"thor/build.odin",
		"thor/git.odin",
		"thor/codeactions.odin",
		"thor/windows.odin",
		"thor/settings_ui.odin",
		"thor/terminal.odin",
		"thor/menus.odin",
		"widgets/editor.odin",
		"widgets/console.odin",
		"widgets/command_palette.odin",
		"ui/context.odin",
		"ui/text.odin",
		"ui/shape.odin",
		"watch/poll.odin",
		"watch/scan.odin",
		"watch/watch_windows.odin",
		"watch/watch_posix.odin",
		"shell/shell_windows.odin",
		"shell/shell_posix.odin",
		"shell/session_windows.odin",
		"shell/child_windows.odin",
		"shell/profile_windows.odin",
		"setting/setting.odin",
		"syntax/syntax.odin",
		"treecache/treecache.odin",
		"plugin/plugin.odin",
		"plugin/sandbox.odin",
		"plugin/view.odin",
		"msvc/msvc.odin",
		"build.odin",
	}
	for p in paths {
		assert_round_trip(t, p)
	}
}
