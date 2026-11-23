package thor

// The program arguments. Thor takes any number of paths — the folder to open as
// the workspace and the files to open in tabs — plus the version and help flags,
// both answered before the window opens.

import "core:fmt"
import "core:os"

// Release version, year.month.patch. The same value the top CHANGELOG.md
// heading carries.
VERSION :: "2026.11.8"

USAGE :: `Usage: thor [path...]
       thor [option]
       thor fmt [-w|--check] path...   Format Odin files; see thor fmt --help.

  path            Folder to open as the workspace, or file to open in a tab.
                   Several files open as several tabs, the last one active. The
                   first folder given becomes the workspace and any later one is
                   ignored, since a window holds one workspace. Without a path
                   Thor opens the last workspace, or the welcome page.

Options:
  --wait, -w       Block until the tabs of the given files are closed, for use
                   as the editor or merge tool of git. The window opens only
                   these files and keeps no session.
  --version, -v    Print the version and exit.
  --help, -h       Print this text and exit.`

// What the arguments ask for. Anything that is not a known flag is a path.
Cli_Action :: enum {
    Open,
    Version,
    Help,
}

// Classifies the program arguments (os.args, the executable path included). A
// flag wins wherever it stands, so `thor a.txt --help` prints the help instead
// of opening a tab nobody would see.
thor_cli_action :: proc(args: []string) -> Cli_Action {
    if len(args) < 2 {
        return .Open
    }
    for arg in args[1:] {
        switch arg {
        case "--version", "-version", "-v":
            return .Version
        case "--help", "-help", "-h", "-?":
            return .Help
        }
    }
    return .Open
}

// The path arguments in the order given, with the flags dropped. The results
// are slices of `args`, so they live as long as it does.
thor_cli_paths :: proc(args: []string, allocator := context.temp_allocator) -> []string {
    paths := make([dynamic]string, 0, len(args), allocator)
    if len(args) < 2 {
        return paths[:]
    }
    for arg in args[1:] {
        switch arg {
        case "--version", "-version", "-v", "--help", "-help", "-h", "-?", "--wait", "-wait", "-w":
            continue
        }
        append(&paths, arg)
    }
    return paths[:]
}

// True when the arguments ask to block until the given files are closed.
thor_cli_wait :: proc(args: []string) -> bool {
    if len(args) < 2 {
        return false
    }
    for arg in args[1:] {
        switch arg {
        case "--wait", "-wait", "-w":
            return true
        }
    }
    return false
}

// True when one of `paths` is an existing file.
thor_cli_has_file :: proc(paths: []string) -> bool {
    for path in paths {
        if os.is_file(path) {
            return true
        }
    }
    return false
}

// Answers a version or help flag, or a bad --wait, on stdout. `handled` is true
// when the caller must exit with `code` instead of starting the editor.
//
// The platform files cli_windows.odin and cli_posix.odin supply:
//   cli_attach_console :: proc()
// Windows attaches the parent console, since a release binary links the windows
// subsystem and starts without one. POSIX is a no-op.
cli_handled :: proc(args: []string) -> (code: int, handled: bool) {
    switch thor_cli_action(args) {
    case .Version:
        cli_attach_console()
        fmt.printfln("thor %s", VERSION)
        return 0, true
    case .Help:
        cli_attach_console()
        fmt.printfln("thor %s", VERSION)
        fmt.println(USAGE)
        return 0, true
    case .Open:
        if thor_cli_wait(args) && !thor_cli_has_file(thor_cli_paths(args)) {
            cli_attach_console()
            fmt.eprintln("thor: --wait needs a file")
            return 2, true
        }
    }
    return 0, false
}
