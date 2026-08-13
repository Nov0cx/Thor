// The build program for Thor.
//
// Run it from the root of the repository:
//
//    odin run build.odin -file                   # build the editor, debug
//    odin run build.odin -file -- run            # build and start it
//    odin run build.odin -file -- run -release   # build and start an optimized one
//    odin run build.odin -file -- check          # type-check, no binary
//    odin run build.odin -file -- test           # run the package tests
//    odin run build.odin -file -- deps           # get and build HarfBuzz and tree-sitter
//    odin run build.odin -file -- -h             # list the flags
//
// The Odin compiler reads the arguments before `--`, this program the rest.
package build

import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "msvc"

EXE_EXT :: ".exe" when ODIN_OS == .Windows else ""
LIB_EXT :: ".lib" when ODIN_OS == .Windows else ".a"
EXE :: "thor" + EXE_EXT

HARFBUZZ_VERSION :: "12.1.0"

// Lowercase: core:flags matches an argument against the member name, so these
// are the names the user types.
Command :: enum {
    all, // the default command
    check,
    test,
    run,
    deps,
    clean,
}

Options :: struct {
    command: Command `args:"pos=0" usage:"The command to run (default: all)."`,
    release: bool `usage:"Build optimized, into bin/release."`,
    vet:     bool `usage:"Add -vet."`,
    verbose: bool `usage:"Print each command before it runs."`,
}

opt: Options
out_dir: string

main :: proc() {
    flags.parse_or_exit(&opt, os.args, .Odin)

    out_dir = opt.release ? "bin/release" : "bin/debug"

    ok: bool
    switch opt.command {
    case .all:   ok = build_thor()
    case .check: ok = check_all()
    case .test:  ok = run_tests()
    case .run:   ok = build_thor() && launch()
    case .deps:  ok = build_deps()
    case .clean: ok = clean()
    }

    if !ok {
        fmt.eprintfln("[build] the command %v failed", opt.command)
        os.exit(1)
    }
    fmt.printfln("[build] the command %v is complete", opt.command)
}

// Builds the editor into out_dir. The main package reaches every other one.
build_thor :: proc() -> bool {
    if !mkdir(out_dir) {
        return false
    }

    args := make([dynamic]string, context.temp_allocator)
    append(&args, "odin", "build", "main")
    append(&args, fmt.tprintf("-out:%s", join(out_dir, EXE)))
    append_common_flags(&args)
    append_codegen_flags(&args)
    append_link_flags(&args)
    if !exec_msvc(args[:]) {
        return false
    }
    return copy_lua_dll() && stage_resources()
}

// Copies the runtime resources beside the binary. Thor moves its working
// directory to the executable at startup (thor/thor.odin), so these paths are
// exe-relative; a fresh copy each build carries over an edited plugin or theme.
stage_resources :: proc() -> bool {
    for dir in ([]string{"assets", "plugins", "settings", "docs"}) {
        dst := join(out_dir, dir)
        if err := os.remove_all(dst); err != nil {
            fmt.eprintfln("[build] a delete of %s failed: %v", dst, err)
            return false
        }
        if err := os.copy_directory_all(dst, dir); err != nil {
            fmt.eprintfln("[build] a copy of %s failed: %v", dir, err)
            return false
        }
    }
    return true
}

// Examines the types of every package and makes no binary. Each package is
// reachable from main, so one check covers them all. Test files are not part of
// a check; the test command covers those.
check_all :: proc() -> bool {
    args := make([dynamic]string, context.temp_allocator)
    append(&args, "odin", "check", "main")
    append_common_flags(&args)
    return exec(args[:])
}

// Runs the tests of each package that has a _test.odin file. Add a package here
// when it gets its first test file. The working directory stays the root of the
// repository, so a test finds assets/, plugins/ and settings/.
run_tests :: proc() -> bool {
    if !mkdir("bin/test") {
        return false
    }
    // The plugin tests start a Lua state, and Windows looks for lua54.dll beside
    // the test binary, not the working directory.
    if !copy_lua_dll("bin/test") {
        return false
    }

    packages := []string {
        "lang",
        "lang/lsp",
        "lang/odin",
        "lang/odin/format",
        "piecetable",
        "plugin",
        "setting",
        "shell",
        "syntax",
        "textedit",
        "thor",
        "treecache",
        "ui",
        "watch",
        "widgets",
    }
    // Every package runs, so one report names each broken one; a stop at the
    // first would hide the rest from a CI log.
    failed := make([dynamic]string, context.temp_allocator)
    for pkg in packages {
        args := make([dynamic]string, context.temp_allocator)
        append(&args, "odin", "test", pkg)
        // A subpackage's path would name a bin/test subdirectory that does not
        // exist, so the binary is named after the flattened path.
        out, _ := strings.replace_all(pkg, "/", "_", context.temp_allocator)
        append(&args, fmt.tprintf("-out:bin/test/%s%s", out, EXE_EXT))
        append_common_flags(&args)
        append_codegen_flags(&args)
        append_link_flags(&args)
        if !exec_msvc(args[:]) {
            append(&failed, pkg)
        }
    }
    if len(failed) > 0 {
        list := strings.join(failed[:], ", ", context.temp_allocator)
        fmt.eprintfln("[build] these test packages failed: %s", list)
        return false
    }
    return true
}

// Starts the editor with the root of the repository as the working directory;
// the asset, plugin and settings paths are relative to it.
launch :: proc() -> bool {
    return exec({join(out_dir, EXE)})
}

clean :: proc() -> bool {
    if !os.exists("bin") {
        return true
    }
    if err := os.remove_all("bin"); err != nil {
        fmt.eprintfln("[build] a delete of the bin directory failed: %v", err)
        return false
    }
    return true
}

// @Note: -strict-style wants tabs. This repository indents with spaces, so the
// vet flag stays alone.
append_common_flags :: proc(args: ^[dynamic]string) {
    if opt.vet {
        append(args, "-vet")
    }
}

// The command `odin check` refuses the flags -o and -debug. Thus only the
// commands that make a binary add these flags.
append_codegen_flags :: proc(args: ^[dynamic]string) {
    if opt.release {
        append(args, "-o:speed", "-no-bounds-check", "-disable-assert")
    } else {
        append(args, "-debug", "-o:none")
    }
}

// Homebrew keeps libharfbuzz and liblua5.4 out of the default search path of the
// linker. HOMEBREW_PREFIX is set by brew and by the macOS runners of CI.
append_link_flags :: proc(args: ^[dynamic]string) {
    when ODIN_OS == .Darwin {
        prefix := os.get_env("HOMEBREW_PREFIX", context.temp_allocator)
        if prefix == "" {
            prefix = "/opt/homebrew"
        }
        append(args, fmt.tprintf("-extra-linker-flags:-L%s/lib", prefix))
    }
}

// vendor:lua links against lua54.dll on Windows, and the loader looks for it
// beside the executable. On Linux that package links Lua statically.
copy_lua_dll :: proc(dir := "") -> bool {
    when ODIN_OS != .Windows {
        return true
    } else {
        target := dir == "" ? out_dir : dir
        dst := join(target, "lua54.dll")
        if os.exists(dst) {
            return true
        }
        src := join(ODIN_ROOT, "vendor", "lua", "5.4", "windows", "lua54.dll")
        if err := os.copy_file(dst, src); err != nil {
            fmt.eprintfln("[build] a copy of %s failed: %v", src, err)
            return false
        }
        return true
    }
}

// A tree-sitter grammar that syntax/syntax.odin imports.
Grammar :: struct {
    name: string, // the parser directory and the generated package name
    url:  string,
    path: string, // the subdirectory that holds grammar.js, when not the root
}

// The list mirrors the imports of syntax/syntax.odin and the CI workflows. A
// missing parser breaks the build of the whole program, so keep the three in
// step. Formats without a grammar use a Lua lexer in plugins/<id>/plugin.lua.
GRAMMARS := []Grammar {
    {"odin",       "https://github.com/tree-sitter-grammars/tree-sitter-odin", ""},
    {"lua",        "https://github.com/tree-sitter-grammars/tree-sitter-lua",  ""},
    {"c",          "https://github.com/tree-sitter/tree-sitter-c",             ""},
    {"cpp",        "https://github.com/tree-sitter/tree-sitter-cpp",           ""},
    {"go",         "https://github.com/tree-sitter/tree-sitter-go",            ""},
    {"javascript", "https://github.com/tree-sitter/tree-sitter-javascript",    ""},
    // typescript and tsx are two grammars in one repository.
    {"typescript", "https://github.com/tree-sitter/tree-sitter-typescript",    "typescript"},
    {"tsx",        "https://github.com/tree-sitter/tree-sitter-typescript",    "tsx"},
    {"jai",        "https://github.com/constantitus/tree-sitter-jai",          ""},
    {"rust",       "https://github.com/tree-sitter/tree-sitter-rust",          ""},
    {"python",     "https://github.com/tree-sitter/tree-sitter-python",        ""},
    {"ruby",       "https://github.com/tree-sitter/tree-sitter-ruby",          ""},
    {"java",       "https://github.com/tree-sitter/tree-sitter-java",          ""},
    {"kotlin",     "https://github.com/fwcd/tree-sitter-kotlin",               ""},
    {"zig",        "https://github.com/tree-sitter-grammars/tree-sitter-zig",  ""},
    // The repository name c-sharp is not an Odin identifier.
    {"c_sharp",    "https://github.com/tree-sitter/tree-sitter-c-sharp",       ""},
    {"php",        "https://github.com/tree-sitter/tree-sitter-php",           "php"},
    {"haskell",    "https://github.com/tree-sitter/tree-sitter-haskell",       ""},
    {"ocaml",      "https://github.com/tree-sitter/tree-sitter-ocaml",         "grammars/ocaml"},
    {"starlark",   "https://github.com/tree-sitter-grammars/tree-sitter-starlark",   ""},
    {"hcl",        "https://github.com/tree-sitter-grammars/tree-sitter-hcl",        ""},
    {"nix",        "https://github.com/nix-community/tree-sitter-nix",                ""},
    {"pascal",     "https://github.com/Isopod/tree-sitter-pascal",                    ""},
    {"nim",        "https://github.com/alaviss/tree-sitter-nim",                      ""},
    {"commonlisp", "https://github.com/tree-sitter-grammars/tree-sitter-commonlisp",  ""},
}

// Gets the submodules and builds their native libraries. These are gitignored
// inside the submodules, so each machine builds them once.
build_deps :: proc() -> bool {
    if !exec({"git", "submodule", "update", "--init", "--recursive"}) {
        return false
    }
    when ODIN_OS == .Windows {
        if !build_harfbuzz() {
            return false
        }
    }
    return build_tree_sitter()
}

// Builds harfbuzz.lib, which the bindings expect at odin-harfbuzz/libs. Only
// Windows needs it; elsewhere the bindings do `foreign import "system:harfbuzz"`.
//
// -Db_vscrt=mt and -Db_ndebug=true are load-bearing: Odin links the static CRT,
// and a /MD build of HarfBuzz leaves __imp__wassert unresolved.
build_harfbuzz :: proc() -> bool {
    lib := "vendor/odin-harfbuzz/libs/harfbuzz.lib"
    if os.exists(lib) {
        return true
    }

    work := "bin/deps"
    src := join(work, fmt.tprintf("harfbuzz-%s", HARFBUZZ_VERSION))
    if !mkdir(work) || !mkdir(filepath.dir(lib)) {
        return false
    }

    if !os.exists(src) {
        archive := fmt.tprintf("harfbuzz-%s.tar.xz", HARFBUZZ_VERSION)
        url := fmt.tprintf(
            "https://github.com/harfbuzz/harfbuzz/releases/download/%s/%s",
            HARFBUZZ_VERSION, archive,
        )
        if !exec({"curl", "-L", "-o", archive, url}, work) {
            return false
        }
        // The tar of Windows cannot read .xz.
        script := fmt.tprintf("import tarfile; tarfile.open('%s').extractall(filter='data')", archive)
        if !exec({"python", "-c", script}, work) {
            return false
        }
    }

    if !os.exists(join(src, "build")) {
        if !exec_msvc({
            "meson", "setup", "build", "--buildtype=release",
            "-Db_vscrt=mt", "-Db_ndebug=true", "-Ddefault_library=static",
            "-Dtests=disabled", "-Ddocs=disabled", "-Dbenchmark=disabled",
            "-Dglib=disabled", "-Dgobject=disabled", "-Dcairo=disabled",
            "-Dicu=disabled", "-Dfreetype=disabled", "-Dchafa=disabled",
            "-Dutilities=disabled",
        }, src) {
            fmt.eprintln("[build] meson and ninja come from `python -m pip install --user meson ninja`; the Scripts directory must be on PATH")
            return false
        }
    }
    if !exec_msvc({"meson", "compile", "-C", "build"}, src) {
        return false
    }

    // meson writes a plain COFF archive; the .lib name is what the binding's
    // foreign import asks for.
    if err := os.copy_file(lib, join(src, "build", "src", "libharfbuzz.a")); err != nil {
        fmt.eprintfln("[build] a copy of libharfbuzz.a failed: %v", err)
        return false
    }
    return true
}

// Builds the tree-sitter runtime and each parser of GRAMMARS into the submodule.
// A library that is already there stays; delete it to force a rebuild.
build_tree_sitter :: proc() -> bool {
    repo := "vendor/odin-tree-sitter"

    if !os.exists(join(repo, "tree-sitter", "libtree-sitter" + LIB_EXT)) {
        if !exec_msvc({"odin", "run", "build", "--", "install"}, repo) {
            return false
        }
    }

    for g in GRAMMARS {
        if os.exists(join(repo, "parsers", g.name, "parser" + LIB_EXT)) {
            continue
        }
        // The git URL is positional. -name keeps the generated package, the
        // tree_sitter_<id> binding and the parser directory in agreement.
        args := make([dynamic]string, context.temp_allocator)
        append(&args, "odin", "run", "build", "--", "install-parser", g.url)
        append(&args, fmt.tprintf("-name=%s", g.name))
        if g.path != "" {
            append(&args, fmt.tprintf("-path=%s", g.path))
        }
        append(&args, "-yes")
        if !exec_msvc(args[:], repo) {
            return false
        }
    }
    return true
}

// Does a command with cl, link and the MSVC environment on PATH. Thor links
// harfbuzz.lib and libtree-sitter.lib, so its build needs them too. A shell that
// is already a developer shell has VSINSTALLDIR set and needs no wrapper.
//
// The command goes through a generated batch file. VsDevCmd.bat sits under a path
// with spaces, and cmd.exe unescapes a `cmd /c` line differently than the process
// spawner quotes it; a file has no such layer.
exec_msvc :: proc(args: []string, working_dir := "") -> bool {
    when ODIN_OS != .Windows {
        return exec(args, working_dir)
    } else {
        if os.get_env("VSINSTALLDIR", context.temp_allocator) != "" {
            return exec(args, working_dir)
        }
        vsdevcmd, found := msvc.find_vsdevcmd()
        if !found {
            fmt.eprintln("[build] the MSVC tools are absent (install Visual Studio with the C++ workload)")
            return false
        }
        if !mkdir("bin") {
            return false
        }

        script := strings.builder_make(context.temp_allocator)
        fmt.sbprintln(&script, "@echo off")
        if working_dir != "" {
            dir, err := os.get_absolute_path(working_dir, context.temp_allocator)
            if err != nil {
                fmt.eprintfln("[build] the path %s is not resolvable: %v", working_dir, err)
                return false
            }
            fmt.sbprintfln(&script, `cd /d "%s" || exit /b 1`, dir)
        }
        // VsDevCmd.bat prints a spurious "vswhere.exe not found" on stderr, so
        // both streams go to nul; the exit code still reports a real failure, and
        // the batch file stays on disk to run by hand.
        fmt.sbprintfln(&script, `call "%s" -arch=amd64 -host_arch=amd64 >nul 2>&1 || exit /b 1`, vsdevcmd)
        fmt.sbprintln(&script, command_line(args))

        // Backslashes: cmd.exe reads a leading forward slash as a switch.
        bat := join("bin", "msvc.bat")
        if err := os.write_entire_file(bat, strings.to_string(script)); err != nil {
            fmt.eprintfln("[build] a write of %s failed: %v", bat, err)
            return false
        }

        if opt.verbose {
            fmt.printfln("  $ %s  [msvc]", command_line(args))
        }
        return exec({"cmd", "/c", bat}, quiet = true)
    }
}

// Joins the arguments into one command line, quoting each one that has a space.
command_line :: proc(args: []string) -> string {
    parts := make([dynamic]string, 0, len(args), context.temp_allocator)
    for arg in args {
        if strings.contains(arg, " ") {
            append(&parts, fmt.tprintf(`"%s"`, arg))
        } else {
            append(&parts, arg)
        }
    }
    return strings.join(parts[:], " ", context.temp_allocator)
}

// filepath.join also returns an allocator error. The temporary allocator makes
// that error very unusual, so this hides it.
join :: proc(parts: ..string) -> string {
    joined, _ := filepath.join(parts, context.temp_allocator)
    return joined
}

mkdir :: proc(path: string) -> bool {
    if err := os.mkdir_all(path); err != nil && err != .Exist {
        fmt.eprintfln("[build] the directory %s is not possible: %v", path, err)
        return false
    }
    return true
}

// Does a command and waits for its end. The child writes to the console of this
// program.
exec :: proc(args: []string, working_dir := "", quiet := false) -> bool {
    if opt.verbose && !quiet {
        fmt.printfln("  $ %s", strings.join(args, " ", context.temp_allocator))
    }

    desc := os.Process_Desc {
        command     = args,
        working_dir = working_dir,
        stdout      = os.stdout,
        stderr      = os.stderr,
        stdin       = os.stdin,
    }

    process, start_err := os.process_start(desc)
    if start_err != nil {
        fmt.eprintfln("[build] a start of %q failed: %v", args[0], start_err)
        return false
    }

    state, wait_err := os.process_wait(process)
    if wait_err != nil {
        fmt.eprintfln("[build] a wait for %q failed: %v", args[0], wait_err)
        return false
    }
    return state.exit_code == 0
}
