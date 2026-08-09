package lsp

import "core:os"
import "core:testing"

// Run from the repository root: odin test lang/lsp

// An absent program is absent, not an error: the server it names simply never
// starts.
@(test)
test_executable_find_missing :: proc(t: ^testing.T) {
    _, empty := executable_find("")
    testing.expect(t, !empty)

    _, nonsense := executable_find("thor-no-such-language-server")
    testing.expect(t, !nonsense)

    _, nonsense_path := executable_find("./thor-no-such-language-server")
    testing.expect(t, !nonsense_path)
}

// A name that holds a separator is a path, tested as written rather than
// searched. Run from the repository root, so build.odin is beside the test.
@(test)
test_executable_find_by_path :: proc(t: ^testing.T) {
    path, ok := executable_find("./build.odin")
    defer delete(path)
    testing.expect(t, ok)
    testing.expect_value(t, path, "./build.odin")
}

// The PATH search, with the suffix a bare name needs on Windows: `cmd` is on
// PATH only as `cmd.exe`, so a search that does not try the suffixes finds
// nothing.
@(test)
test_executable_find_on_path :: proc(t: ^testing.T) {
    when ODIN_OS == .Windows {
        path, ok := executable_find("cmd")
        defer delete(path)
        testing.expect(t, ok)
        testing.expect(t, is_batch(path) == false)
    } else {
        // Not every image puts the same programs on PATH, so this pins the lookup
        // only where the shell itself is where it always is.
        if !os.is_file("/bin/sh") {
            return
        }
        path, ok := executable_find("/bin/sh")
        defer delete(path)
        testing.expect(t, ok)
        testing.expect_value(t, path, "/bin/sh")
    }
}

// What decides that a program needs the command interpreter.
@(test)
test_is_batch :: proc(t: ^testing.T) {
    Case :: struct {
        path: string,
        want: bool,
    }
    cases := []Case {
        {"C:/tools/tsserver.cmd", true},
        {"C:/tools/TSSERVER.BAT", true},
        {"C:/tools/clangd.exe", false},
        {"/usr/bin/clangd", false},
        {"C:/tools/x.cmd.exe", false},
        {"", false},
    }
    for entry in cases {
        testing.expectf(t, is_batch(entry.path) == entry.want, "%q read as %v", entry.path, !entry.want)
    }
}

// A command whose program is not installed resolves to nothing, and an empty
// command names no program at all.
@(test)
test_command_resolve_missing :: proc(t: ^testing.T) {
    _, empty := command_resolve({})
    testing.expect(t, !empty)

    _, absent := command_resolve({"thor-no-such-language-server", "--stdio"})
    testing.expect(t, !absent)
}

// The arguments after the program are kept in order and untouched.
@(test)
test_command_resolve_keeps_arguments :: proc(t: ^testing.T) {
    program := ODIN_OS == .Windows ? "cmd" : "/bin/sh"
    if program == "/bin/sh" && !os.is_file(program) {
        return
    }

    cmd, ok := command_resolve({program, "--stdio", "--log=verbose"})
    defer command_destroy(&cmd)
    testing.expect(t, ok)
    if !ok {
        return
    }
    testing.expect(t, os.is_file(cmd.exe))
    testing.expect_value(t, len(cmd.args), 2)
    testing.expect_value(t, cmd.args[0], "--stdio")
    testing.expect_value(t, cmd.args[1], "--log=verbose")
}
