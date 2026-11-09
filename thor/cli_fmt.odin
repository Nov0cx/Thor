package thor

// `thor fmt`: formats Odin files and packages with no window, answered before
// the editor starts. Options come from the nearest `.thor/odin-formatter.lua`.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../atomicfile"
import "../lang/odin"
import "../lang/odin/format"

FMT_CONFIG_DIR :: ".thor"

FMT_EXIT_OK :: 0
FMT_EXIT_DIFF :: 1 // `--check` found a file that needs formatting
FMT_EXIT_ERROR :: 2 // an unreadable or unwritable file, or a syntax error
FMT_EXIT_USAGE :: 64

FMT_USAGE ::
`Usage: thor fmt [option] path...
       thor fmt [option] -

  path             An Odin file, or a folder. A folder takes every .odin file
                   in it and in its subfolders. A trailing /... is accepted.
  -                Read one file from stdin and write the result to stdout.

Options:
  -w, --write      Write the result back to each file.
  --check          Name each file that needs formatting and exit with 1.
  -h, --help       Print this text and exit.

Without -w and --check a single file prints to stdout.
Exit codes: 0 done, 1 --check found a difference, 2 error, 64 usage.`

// The parsed arguments of `thor fmt`.
Fmt_Args :: struct {
    write: bool,
    check: bool,
    stdin: bool,
    help:  bool,
    paths: []string, // slices of the arguments
}

// Whether the arguments name the formatter.
thor_cli_is_fmt :: proc(args: []string) -> bool {
    return len(args) >= 2 && args[1] == "fmt"
}

// Parses the arguments after `fmt`. `problem` is empty when they are usable.
thor_cli_fmt_args :: proc(args: []string, allocator := context.temp_allocator) -> (parsed: Fmt_Args, problem: string) {
    paths := make([dynamic]string, 0, len(args), allocator)
    for arg in args[min(2, len(args)):] {
        switch arg {
        case "-w", "--write":
            parsed.write = true
        case "--check":
            parsed.check = true
        case "-":
            parsed.stdin = true
        case "-h", "--help", "-help":
            parsed.help = true
        case:
            if strings.has_prefix(arg, "-") {
                return {}, fmt.tprintf("unknown option %q", arg)
            }
            append(&paths, arg)
        }
    }
    parsed.paths = paths[:]
    switch {
    case parsed.help:
    case parsed.write && parsed.check:
        problem = "-w and --check cannot be combined"
    case parsed.stdin && (parsed.write || len(paths) > 0):
        problem = "- reads stdin and takes no path and no -w"
    case !parsed.stdin && len(paths) == 0:
        problem = "no path given"
    case !parsed.stdin && !parsed.write && !parsed.check && len(paths) != 1:
        problem = "name one file, or use -w or --check for several"
    }
    return parsed, problem
}

// Runs `thor fmt` when the arguments ask for it. `handled` is false for any
// other command line; otherwise the caller exits with `code`.
cli_fmt :: proc(args: []string) -> (code: int, handled: bool) {
    if !thor_cli_is_fmt(args) {
        return 0, false
    }
    cli_attach_console()
    logger := log.create_console_logger(.Warning)
    defer log.destroy_console_logger(logger)
    context.logger = logger

    parsed, problem := thor_cli_fmt_args(args)
    if parsed.help {
        fmt.println(FMT_USAGE)
        return FMT_EXIT_OK, true
    }
    if problem != "" {
        fmt.eprintfln("thor fmt: %s", problem)
        fmt.eprintln(FMT_USAGE)
        return FMT_EXIT_USAGE, true
    }
    if parsed.stdin {
        return fmt_stdin(parsed), true
    }
    return fmt_paths(parsed), true
}

// Formatter options of one workspace, read once per run.
@(private)
Fmt_Config :: struct {
    opts:            format.Options,
    newline_present: bool,
}

@(private = "file")
fmt_stdin :: proc(parsed: Fmt_Args) -> int {
    data, err := os.read_entire_file(os.stdin, context.allocator)
    if err != nil {
        fmt.eprintfln("thor fmt: cannot read stdin: %v", err)
        return FMT_EXIT_ERROR
    }
    defer delete(data)
    cwd, _ := os.get_working_directory(context.temp_allocator)
    config := fmt_config_for(cwd)
    source := string(data)
    out, ok := fmt_source(source, config)
    if !ok {
        fmt.eprintln("thor fmt: <stdin>: syntax error, left as it is")
        return FMT_EXIT_ERROR
    }
    if parsed.check {
        if out != source {
            fmt.eprintln("<stdin>")
            return FMT_EXIT_DIFF
        }
        return FMT_EXIT_OK
    }
    if _, werr := os.write_string(os.stdout, out); werr != nil {
        fmt.eprintfln("thor fmt: cannot write stdout: %v", werr)
        return FMT_EXIT_ERROR
    }
    return FMT_EXIT_OK
}

@(private = "file")
fmt_paths :: proc(parsed: Fmt_Args) -> int {
    files := make([dynamic]string)
    code := FMT_EXIT_OK
    for arg in parsed.paths {
        if !fmt_collect(arg, &files) {
            fmt.eprintfln("thor fmt: %s: no such file or folder", arg)
            code = FMT_EXIT_ERROR
        }
    }
    if !parsed.write && !parsed.check && len(files) != 1 {
        fmt.eprintln("thor fmt: name one file, or use -w or --check for a folder")
        return FMT_EXIT_USAGE
    }

    configs := make(map[string]Fmt_Config)
    for path in files {
        defer free_all(context.temp_allocator)
        data, rerr := os.read_entire_file(path, context.allocator)
        if rerr != nil {
            fmt.eprintfln("thor fmt: %s: cannot read: %v", path, rerr)
            code = FMT_EXIT_ERROR
            continue
        }
        defer delete(data)

        workspace := fmt_workspace(path)
        config, known := configs[workspace]
        if !known {
            config = fmt_config_for(workspace)
            configs[strings.clone(workspace, context.allocator)] = config
        }
        source := string(data)
        out, ok := fmt_source(source, config)
        if !ok {
            fmt.eprintfln("thor fmt: %s: syntax error, left as it is", path)
            code = FMT_EXIT_ERROR
            continue
        }
        changed := out != source
        switch {
        case parsed.check:
            if changed {
                fmt.println(path)
                if code == FMT_EXIT_OK {
                    code = FMT_EXIT_DIFF
                }
            }
        case parsed.write:
            if !changed {
                continue
            }
            if werr := atomicfile.write(path, transmute([]u8)out); werr != nil {
                fmt.eprintfln("thor fmt: %s: cannot write: %v", path, werr)
                code = FMT_EXIT_ERROR
            }
        case:
            if _, werr := os.write_string(os.stdout, out); werr != nil {
                fmt.eprintfln("thor fmt: cannot write stdout: %v", werr)
                code = FMT_EXIT_ERROR
            }
        }
    }
    return code
}

// Adds the .odin files `arg` names: the file itself, or every one under a
// folder. Hidden folders are skipped. False when `arg` does not exist.
@(private = "file")
fmt_collect :: proc(arg: string, files: ^[dynamic]string) -> bool {
    path := arg
    for suffix in ([]string{"/...", "\\..."}) {
        if strings.has_suffix(path, suffix) {
            path = path[:len(path) - len(suffix)]
            if path == "" {
                path = "."
            }
        }
    }
    if !os.exists(path) {
        return false
    }
    if !os.is_dir(path) {
        append(files, strings.clone(path))
        return true
    }
    fmt_collect_dir(path, files, 0)
    return true
}

@(private = "file")
FMT_MAX_DEPTH :: 64

@(private = "file")
fmt_collect_dir :: proc(dir: string, files: ^[dynamic]string, depth: int) {
    if depth >= FMT_MAX_DEPTH {
        return
    }
    infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
    if err != nil {
        fmt.eprintfln("thor fmt: %s: cannot read folder: %v", dir, err)
        return
    }
    for info in infos {
        switch {
        case info.type == .Directory:
            if !strings.has_prefix(info.name, ".") {
                fmt_collect_dir(info.fullpath, files, depth + 1)
            }
        case filepath.ext(info.name) == ".odin":
            append(files, strings.clone(info.fullpath))
        }
    }
}

// The nearest folder at or above `path` that holds a `.thor` folder, else the
// folder of the file itself, which then reads no config and gets the defaults.
@(private = "file")
fmt_workspace :: proc(path: string) -> string {
    absolute, aerr := filepath.abs(path, context.temp_allocator)
    if aerr != nil {
        return ""
    }
    dir := filepath.dir(absolute)
    current := dir
    for {
        if os.is_dir(filepath.join({current, FMT_CONFIG_DIR}, context.temp_allocator) or_else "") {
            return current
        }
        parent := filepath.dir(current)
        if parent == current || parent == "" {
            return ""
        }
        current = parent
    }
}

@(private)
fmt_config_for :: proc(workspace: string) -> Fmt_Config {
    opts, newline_present := odin.load_format_options(workspace)
    return {opts, newline_present}
}

// The source formatted, in the line ending the config names, else the one the
// source uses. False for a syntax error. The result is in the temp allocator.
@(private)
fmt_source :: proc(source: string, config: Fmt_Config) -> (out: string, ok: bool) {
    crlf := strings.contains(source, "\r\n")
    text := source
    if crlf {
        text, _ = strings.replace_all(source, "\r\n", "\n", context.temp_allocator)
    }
    formatted := format.format(text, config.opts, context.temp_allocator) or_return
    want_crlf := crlf
    if config.newline_present {
        want_crlf = config.opts.newline_style == .CRLF
    }
    if want_crlf {
        formatted, _ = strings.replace_all(formatted, "\n", "\r\n", context.temp_allocator)
    }
    return formatted, true
}
