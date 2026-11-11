package thor

import "core:strings"
import "core:testing"

import "../lang/odin/format"

// Every accepted flag spelling, and the arguments that must stay paths.
// Run from the repository root: odin test thor
@(test)
test_cli_action :: proc(t: ^testing.T) {
    testing.expect_value(t, thor_cli_action({"thor"}), Cli_Action.Open)
    testing.expect_value(t, thor_cli_action({}), Cli_Action.Open)

    for arg in ([?]string{"--version", "-version", "-v"}) {
        testing.expect_value(t, thor_cli_action({"thor", arg}), Cli_Action.Version)
    }
    for arg in ([?]string{"--help", "-help", "-h", "-?"}) {
        testing.expect_value(t, thor_cli_action({"thor", arg}), Cli_Action.Help)
    }

    // The workspace argument a shell launch and a new window both pass.
    testing.expect_value(t, thor_cli_action({"thor", "."}), Cli_Action.Open)
    testing.expect_value(t, thor_cli_action({"thor", "D:\\thor"}), Cli_Action.Open)
    testing.expect_value(t, thor_cli_action({"thor", "/home/user/thor"}), Cli_Action.Open)
    testing.expect_value(t, thor_cli_action({"thor", "--versions"}), Cli_Action.Open)

    // Several paths are still an Open, and a flag wins wherever it stands.
    testing.expect_value(t, thor_cli_action({"thor", "a.txt", "b.txt"}), Cli_Action.Open)
    testing.expect_value(t, thor_cli_action({"thor", "a.txt", "--help"}), Cli_Action.Help)
    testing.expect_value(t, thor_cli_action({"thor", "a.txt", "-v"}), Cli_Action.Version)
}

// The paths, in order, with the flags dropped.
@(test)
test_cli_paths :: proc(t: ^testing.T) {
    testing.expect_value(t, len(thor_cli_paths({"thor"})), 0)
    testing.expect_value(t, len(thor_cli_paths({})), 0)

    paths := thor_cli_paths({"thor", "a.txt", "--help", "b.txt"})
    testing.expect_value(t, len(paths), 2)
    testing.expect_value(t, paths[0], "a.txt")
    testing.expect_value(t, paths[1], "b.txt")

    // Not a flag, so still a path -- the same rule thor_cli_action follows.
    kept := thor_cli_paths({"thor", "--versions"})
    testing.expect_value(t, len(kept), 1)
    testing.expect_value(t, kept[0], "--versions")
}

// The version is year.month.patch, the form the changelog headings use.
@(test)
test_version_format :: proc(t: ^testing.T) {
    parts := strings.split(VERSION, ".", context.temp_allocator)
    testing.expect_value(t, len(parts), 3)
    for part in parts {
        testing.expect(t, len(part) > 0, "each version field needs digits")
        for c in part {
            testing.expect(t, c >= '0' && c <= '9', "the version must hold digits only")
        }
    }
}

// `fmt` is a subcommand only as the first argument; the rest are its options.
@(test)
test_cli_fmt_args :: proc(t: ^testing.T) {
    testing.expect(t, thor_cli_is_fmt({"thor", "fmt"}))
    testing.expect(t, !thor_cli_is_fmt({"thor", "a.odin", "fmt"}))
    testing.expect(t, !thor_cli_is_fmt({"thor"}))

    parsed, problem := thor_cli_fmt_args({"thor", "fmt", "-w", "a.odin", "dir"})
    testing.expect_value(t, problem, "")
    testing.expect(t, parsed.write && !parsed.check)
    testing.expect_value(t, len(parsed.paths), 2)

    _, problem = thor_cli_fmt_args({"thor", "fmt", "--check", "dir"})
    testing.expect_value(t, problem, "")
    _, problem = thor_cli_fmt_args({"thor", "fmt", "a.odin"})
    testing.expect_value(t, problem, "")
    parsed, problem = thor_cli_fmt_args({"thor", "fmt", "-"})
    testing.expect(t, problem == "" && parsed.stdin)

    for bad in ([][]string{
        {"thor", "fmt"},
        {"thor", "fmt", "-w", "--check", "a.odin"},
        {"thor", "fmt", "a.odin", "b.odin"},
        {"thor", "fmt", "-", "a.odin"},
        {"thor", "fmt", "--nope", "a.odin"},
    }) {
        _, problem = thor_cli_fmt_args(bad)
        testing.expect(t, problem != "", "a bad command line must be refused")
    }

    parsed, problem = thor_cli_fmt_args({"thor", "fmt", "--help"})
    testing.expect(t, problem == "" && parsed.help)
}

// The formatter keeps the line ending of the source and refuses a syntax error.
@(test)
test_fmt_source :: proc(t: ^testing.T) {
    config  := Fmt_Config{opts = format.default_options()}
    out, ok := fmt_source("package p\r\n\r\nx :: 1\r\n", config)
    testing.expect(t, ok)
    testing.expect(t, strings.contains(out, "\r\n") && !strings.contains(out, "\n\n"), "CRLF must stay CRLF")

    out, ok = fmt_source("package p\n\nx :: 1\n", config)
    testing.expect(t, ok)
    testing.expect(t, !strings.contains(out, "\r"), "LF must stay LF")

    config.newline_present = true
    config.opts.newline_style = .CRLF
    out, ok = fmt_source("package p\n\nx :: 1\n", config)
    testing.expect(t, ok && strings.contains(out, "\r\n"), "a named newline_style wins")

    _, ok = fmt_source("package p\n\nx :: (\n", Fmt_Config{opts = format.default_options()})
    testing.expect(t, !ok, "a syntax error must not format")
}
