package thor

// The program arguments. Thor takes any number of paths — the folder to open as
// the workspace and the files to open in tabs — plus the version and help flags,
// both answered before the window opens.

import "core:fmt"

// Release version, year.month.patch. The same value the top CHANGELOG.md
// heading carries.
VERSION :: "2026.08.4"

USAGE ::
`Usage: thor [path...]
       thor [option]

  path             Folder to open as the workspace, or file to open in a tab.
                   Several files open as several tabs, the last one active. The
                   first folder given becomes the workspace and any later one is
                   ignored, since a window holds one workspace. Without a path
                   Thor opens the last workspace, then the directory it was
                   started in.

Options:
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
        case "--version", "-version", "-v", "--help", "-help", "-h", "-?":
            continue
        }
        append(&paths, arg)
    }
    return paths[:]
}

// Answers a version or help flag on stdout. Returns true when the caller must
// exit instead of starting the editor.
//
// The platform files cli_windows.odin and cli_posix.odin supply:
//   cli_attach_console :: proc()
// Windows attaches the parent console, since a release binary links the windows
// subsystem and starts without one. POSIX is a no-op.
cli_handled :: proc(args: []string) -> bool {
    switch thor_cli_action(args) {
    case .Version:
        cli_attach_console()
        fmt.printfln("thor %s", VERSION)
        return true
    case .Help:
        cli_attach_console()
        fmt.printfln("thor %s", VERSION)
        fmt.println(USAGE)
        return true
    case .Open:
        return false
    }
    return false
}
