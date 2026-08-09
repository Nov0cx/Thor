// Finding a server's program on PATH. `shell.which` searches the directories and
// nothing else, which is all the terminal's shell detectors need — they spell a
// file name in full — so the extension search lives here instead of moving that
// contract.
package lsp

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../shell"

// The suffixes a bare program name may need on Windows, in the order the command
// interpreter tries them. A server installed by npm or cargo is a `.cmd` shim, so
// a search for the name alone finds nothing.
@(private)
WINDOWS_SUFFIXES :: [3]string{".exe", ".cmd", ".bat"}

// A resolved command: the program to start and the arguments to give it.
Command :: struct {
    exe:       string,   // owned
    args:      []string, // owned
    allocator: runtime.Allocator,
}

// Absolute path of the program `name` names, or ok=false when nothing answers to
// it — which is how an uninstalled server stays absent instead of failing at
// every request. A name that holds a path separator is tested as written; a bare
// name is searched on PATH.
executable_find :: proc(name: string, allocator := context.allocator) -> (string, bool) {
    if name == "" {
        return "", false
    }

    if strings.contains(name, "/") || strings.contains(name, "\\") {
        if os.is_file(name) {
            return strings.clone(name, allocator), true
        }
        when ODIN_OS == .Windows {
            for suffix in WINDOWS_SUFFIXES {
                candidate := strings.concatenate({name, suffix}, context.temp_allocator)
                if os.is_file(candidate) {
                    return strings.clone(candidate, allocator), true
                }
            }
        }
        return "", false
    }

    if path, ok := shell.which(name, allocator); ok {
        return path, true
    }
    when ODIN_OS == .Windows {
        for suffix in WINDOWS_SUFFIXES {
            candidate := strings.concatenate({name, suffix}, context.temp_allocator)
            if path, ok := shell.which(candidate, allocator); ok {
                return path, true
            }
        }
    }
    return "", false
}

// The program and arguments that start `command`, with command[0] resolved on
// PATH. A batch file is started through the command interpreter, because
// CreateProcessW cannot execute one. The arguments of a batch server are parsed
// by that interpreter and not by the C runtime, so a '&' or a '|' in a configured
// argument reaches it as an operator.
command_resolve :: proc(command: []string, allocator := context.allocator) -> (Command, bool) {
    if len(command) == 0 {
        return {}, false
    }
    path, found := executable_find(command[0], context.temp_allocator)
    if !found {
        return {}, false
    }

    rest := command[1:]
    when ODIN_OS == .Windows {
        if is_batch(path) {
            // "/c <program> <args>": cmd keeps the quotes around a program whose
            // path holds a space, as long as the command line carries exactly the
            // one quoted pair.
            args := make([]string, len(rest) + 2, allocator)
            args[0] = strings.clone("/c", allocator)
            args[1] = strings.clone(path, allocator)
            for arg, index in rest {
                args[index + 2] = strings.clone(arg, allocator)
            }
            return Command{exe = interpreter(allocator), args = args, allocator = allocator}, true
        }
    }

    args := make([]string, len(rest), allocator)
    for arg, index in rest {
        args[index] = strings.clone(arg, allocator)
    }
    return Command{exe = strings.clone(path, allocator), args = args, allocator = allocator}, true
}

command_destroy :: proc(cmd: ^Command) {
    delete(cmd.exe, cmd.allocator)
    for arg in cmd.args {
        delete(arg, cmd.allocator)
    }
    delete(cmd.args, cmd.allocator)
    cmd^ = {}
}

// True when the resolved program is a batch file. Its extension is what decides,
// exactly as the command interpreter decides it.
@(private)
is_batch :: proc(path: string) -> bool {
    ext := filepath.ext(path)
    return strings.equal_fold(ext, ".cmd") || strings.equal_fold(ext, ".bat")
}

// The command interpreter, from the environment so a machine that keeps it
// somewhere other than System32 still starts it.
@(private)
interpreter :: proc(allocator := context.allocator) -> string {
    if path := os.get_env("COMSPEC", context.temp_allocator); path != "" {
        return strings.clone(path, allocator)
    }
    return strings.clone("cmd.exe", allocator)
}
