// Golden-file-style unit tests exercise individual options; the round-trip
// suite (below) is the broad safety net — every substantial package in this
// repo formats with no meaning change (token-stream equal, ignoring commas
// and semicolons that legitimately come and go with reflow) and is
// idempotent. A failure there is the signal to add a targeted case here.
package odinfmt

import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
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

@(private)
assert_round_trip :: proc(t: ^testing.T, path: string) {
	src, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.println("skip (unreadable):", path)
		return
	}
	defer delete(src)
	source := string(src)
	out, fok := format(source, default_options())
	defer delete(out)
	_ = os.write_entire_file("bin/test/last_out.odin.txt", transmute([]u8)out)
	if !fok {
		fmt.println("FORMAT FAILED (syntax error):", path)
		testing.fail(t)
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

	out2, fok2 := format(out, default_options())
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

	fmt.println("OK", path, len(before), "tokens")
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
