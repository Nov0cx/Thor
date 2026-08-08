package thor

// The program arguments. Thor takes one path — the folder or file to open — so
// the only other arguments are the version and help flags, both answered before
// the window opens.

import "core:fmt"

// Release version, year.month.patch. The same value the top CHANGELOG.md
// heading carries.
VERSION :: "2026.08.0"

USAGE ::
`Usage: thor [path]
       thor [option]

  path             Folder to open as the workspace, or file to open in a tab.
                   Without one Thor opens the last workspace, then the directory
                   it was started in.

Options:
  --version, -v    Print the version and exit.
  --help, -h       Print this text and exit.`

// What the arguments ask for. Only the first argument is read, and anything
// that is not a known flag is a path.
Cli_Action :: enum {
    Open,
    Version,
    Help,
}

// Classifies the program arguments (os.args, the executable path included).
thor_cli_action :: proc(args: []string) -> Cli_Action {
    if len(args) < 2 {
        return .Open
    }
    switch args[1] {
    case "--version", "-version", "-v":
        return .Version
    case "--help", "-help", "-h", "-?":
        return .Help
    }
    return .Open
}

// Answers a version or help flag on stdout. Returns true when the caller must
// exit instead of starting the editor.
cli_handled :: proc(args: []string) -> bool {
    switch thor_cli_action(args) {
    case .Version:
        fmt.printfln("thor %s", VERSION)
        return true
    case .Help:
        fmt.printfln("thor %s", VERSION)
        fmt.println(USAGE)
        return true
    case .Open:
        return false
    }
    return false
}
