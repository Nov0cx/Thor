// The build program for Thor.
//
// Run it from the root of the repository:
//
//    odin run build.odin -file                   # build the editor, debug
//    odin run build.odin -file -- run            # build and start it
//    odin run build.odin -file -- run -release   # build and start an optimized one
//    odin run build.odin -file -- check          # type-check, no binary
//    odin run build.odin -file -- test           # run the package tests
//    odin run build.odin -file -- test -release  # run them with the release flags
//    odin run build.odin -file -- deps           # get and build HarfBuzz and tree-sitter
//    odin run build.odin -file -- -h             # list the flags
//
// The Odin compiler reads the arguments before `--`, this program the rest.
package build

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "msvc"

EXE_EXT :: ".exe" when ODIN_OS == .Windows else ""
LIB_EXT :: ".lib" when ODIN_OS == .Windows else ".a"
EXE :: "thor" + EXE_EXT

HARFBUZZ_VERSION :: "12.1.0"
// The SHA-256 of harfbuzz-<version>.tar.xz. Change it together with the version.
HARFBUZZ_SHA256 :: "e5c81b7f6e0b102dfb000cfa424538b8e896ab78a2f4b8a5ec8cae62ab43369e"

// -Db_vscrt=mt and -Db_ndebug=true are load-bearing: Odin links the static CRT,
// and a /MD build of HarfBuzz leaves __imp__wassert unresolved.
HARFBUZZ_FLAGS := []string {
    "--buildtype=release",
    "-Db_vscrt=mt", "-Db_ndebug=true", "-Ddefault_library=static",
    "-Dtests=disabled", "-Ddocs=disabled", "-Dbenchmark=disabled",
    "-Dglib=disabled", "-Dgobject=disabled", "-Dcairo=disabled",
    "-Dicu=disabled", "-Dfreetype=disabled", "-Dchafa=disabled",
    "-Dutilities=disabled",
}

// The file beside a built library that names what it was built from. A library
// with no stamp, or with a different one, is built again.
STAMP :: "thor.stamp"

// The packages -vet examines, by package name. The flag otherwise reaches the
// third-party bindings under vendor/, which this repository cannot correct.
// Add a package here when it is new.
VET_PACKAGES ::
    "main,thor,editview,font,input,lang,lsp,odin,odinfmt,markdown,msvc,piecetable," +
    "plugin,render,search,setting,shell,snippet,syntax,textedit,theme,treecache," +
    "update,vt,watch"

ICON_FILE :: "assets/branding/thor.ico"
VERSION_FILE :: "thor/cli.odin"
PUBLISHER :: "Niklas Leygraf"

TIMESTAMP_URL :: "http://timestamp.digicert.com"

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
    release: bool `usage:"Build optimized, into bin/release. With test: use the release flags."`,
    vet:     bool `usage:"Add -vet for the packages of this repository."`,
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
    // A release binary must not open a console beside the window. Debug keeps
    // the console subsystem for the logger and the tracking-allocator report.
    // A test binary always keeps it, for the report of the test runner.
    when ODIN_OS == .Windows {
        if opt.release {
            append(&args, "-subsystem:windows")
        }
    }
    append_resource_flags(&args)
    if !exec_msvc(args[:]) {
        return false
    }
    return copy_lua_dll() && stage_resources() && sign_binary()
}

// Copies the runtime resources beside the binary. Thor moves its working
// directory to the executable at startup (thor/thor.odin), so these paths are
// exe-relative; a fresh copy each build carries over an edited plugin or theme.
stage_resources :: proc() -> bool {
    for dir in ([]string{"assets", "plugins", "settings", "docs"}) {
        dst := join(out_dir, dir)
        // A first build has nothing to delete; POSIX reports that as Not_Exist,
        // Windows as no error.
        if err := os.remove_all(dst); err != nil && err != .Not_Exist {
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
        "editview",
        "font",
        "input",
        "lang",
        "lang/lsp",
        "lang/odin",
        "lang/odin/format",
        "markdown",
        "msvc",
        "piecetable",
        "plugin",
        "render",
        "search",
        "setting",
        "shell",
        "syntax",
        "textedit",
        "theme",
        "thor",
        "treecache",
        "update",
        "vt",
        "watch",
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
        append(args, "-vet", "-vet-packages:" + VET_PACKAGES)
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

// The icon and the file properties the executable carries. Windows only: the
// flag -resource is a Windows flag, and only a command that makes a binary takes
// it — a check of a POSIX target refuses it. A build without the icon file still
// works, it only gets the default icon of the linker.
append_resource_flags :: proc(args: ^[dynamic]string) {
    when ODIN_OS == .Windows {
        if path, ok := write_resource_script(); ok {
            append(args, fmt.tprintf("-resource:%s", path))
        }
    }
}

// Writes the resource script the executable is built with: the Explorer icon and
// the VERSIONINFO block that names the publisher and the version in the file
// properties, in the SmartScreen dialog and in the task manager. It is generated
// because thor/cli.odin holds the one version, and a committed copy of it would
// drift. The bin directory is not under version control, so nothing generated is
// committed; rc.exe puts its compiled .res beside the script.
write_resource_script :: proc() -> (path: string, ok: bool) {
    if !os.exists(ICON_FILE) {
        fmt.eprintfln("[build] %s is absent; the executable gets no icon", ICON_FILE)
        return "", false
    }
    version := read_version() or_return
    fields := version_fields(version) or_return

    icon, abs_err := os.get_absolute_path(ICON_FILE, context.temp_allocator)
    if abs_err != nil {
        fmt.eprintfln("[build] the path %s is not resolvable: %v", ICON_FILE, abs_err)
        return "", false
    }
    // A backslash escapes the character after it inside a resource string, and
    // rc.exe reads a forward slash as a path separator.
    icon, _ = strings.replace_all(icon, "\\", "/", context.temp_allocator)

    script := strings.builder_make(context.temp_allocator)
    // Explorer draws the icon with the lowest ordinal, so this one is 1.
    fmt.sbprintfln(&script, `1 ICON "%s"`, icon)
    fmt.sbprintf(
        &script,
        `
1 VERSIONINFO
FILEVERSION %s
PRODUCTVERSION %s
FILEFLAGSMASK 0x3fL
FILEFLAGS 0x0L
FILEOS 0x40004L
FILETYPE 0x1L
FILESUBTYPE 0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "CompanyName", "%s"
            VALUE "FileDescription", "Thor code editor"
            VALUE "FileVersion", "%s"
            VALUE "InternalName", "thor"
            VALUE "LegalCopyright", "%s, GPL-3.0"
            VALUE "OriginalFilename", "%s"
            VALUE "ProductName", "Thor"
            VALUE "ProductVersion", "%s"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
`,
        fields,
        fields,
        PUBLISHER,
        version,
        PUBLISHER,
        EXE,
        version,
    )

    if !mkdir("bin") {
        return "", false
    }
    path = join("bin", "thor.rc")
    if err := os.write_entire_file(path, strings.to_string(script)); err != nil {
        fmt.eprintfln("[build] a write of %s failed: %v", path, err)
        return "", false
    }
    return path, true
}

// Reads VERSION out of thor/cli.odin. The release workflow reads the same
// constant to gate the tag it is built from, so the resource cannot name a
// version that the editor and the release disagree with.
read_version :: proc() -> (version: string, ok: bool) {
    MARKER :: `VERSION :: "`

    data, err := os.read_entire_file(VERSION_FILE, context.temp_allocator)
    if err != nil {
        fmt.eprintfln("[build] a read of %s failed: %v", VERSION_FILE, err)
        return "", false
    }
    text := string(data)
    start := strings.index(text, MARKER)
    if start < 0 {
        fmt.eprintfln("[build] %s names no VERSION", VERSION_FILE)
        return "", false
    }
    rest := text[start + len(MARKER):]
    end := strings.index(rest, `"`)
    if end < 0 {
        fmt.eprintfln("[build] the VERSION of %s is not terminated", VERSION_FILE)
        return "", false
    }
    return rest[:end], true
}

// The four comma-separated numbers a VERSIONINFO block wants: 2026.08.2 becomes
// 2026,8,2,0. Base ten is explicit because a leading zero is octal to the parser
// and the month field carries one.
version_fields :: proc(version: string) -> (fields: string, ok: bool) {
    numbers: [4]int
    for part, i in strings.split(version, ".", context.temp_allocator) {
        if i >= len(numbers) {
            break
        }
        value, parsed := strconv.parse_int(part, 10)
        if !parsed {
            fmt.eprintfln("[build] the version %q is not a number series", version)
            return "", false
        }
        numbers[i] = value
    }
    return fmt.tprintf("%d,%d,%d,%d", numbers[0], numbers[1], numbers[2], numbers[3]), true
}

// Signs the executable when a certificate is named in the environment, and does
// nothing when none is. Thor ships unsigned, so this stays dormant; it makes a
// signed release a matter of the two variables, not of a change here. signtool
// is on the path of a developer shell, which exec_msvc makes.
sign_binary :: proc() -> bool {
    when ODIN_OS != .Windows {
        return true
    } else {
        certificate := os.get_env("THOR_SIGN_PFX", context.temp_allocator)
        if certificate == "" {
            return true
        }
        args := make([dynamic]string, context.temp_allocator)
        append(&args, "signtool", "sign", "/fd", "SHA256")
        // A timestamp keeps the signature valid past the expiry of the
        // certificate.
        append(&args, "/tr", TIMESTAMP_URL, "/td", "SHA256")
        append(&args, "/f", certificate)
        password := os.get_env("THOR_SIGN_PASS", context.temp_allocator)
        if password != "" {
            append(&args, "/p", password)
        }
        append(&args, join(out_dir, EXE))
        signed := exec_msvc(args[:], secret = password)
        // exec_msvc runs the command from a generated batch file and leaves it
        // on disk, so the password would stay there in plain text. Overwrite it
        // whatever the signing did.
        bat := join("bin", "msvc.bat")
        if os.exists(bat) {
            if err := os.write_entire_file(bat, "@echo off\r\n"); err != nil {
                fmt.eprintfln("[build] a scrub of %s failed: %v", bat, err)
                return false
            }
        }
        return signed
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
    rev:  string, // the commit the parser is built from
    path: string, // the subdirectory that holds grammar.js, when not the root
}

// The list mirrors the imports of syntax/syntax.odin. A missing parser breaks
// the build of the whole program, so keep the two in step. Each grammar is
// pinned: `git ls-remote <url> HEAD` gives the commit to move a row to. Formats
// without a grammar use a Lua lexer in plugins/<id>/plugin.lua.
GRAMMARS := []Grammar {
    {"odin",       "https://github.com/tree-sitter-grammars/tree-sitter-odin",       "d2ca8efb4487e156a60d5bd6db2598b872629403", ""},
    {"lua",        "https://github.com/tree-sitter-grammars/tree-sitter-lua",        "10fe0054734eec83049514ea2e718b2a56acd0c9", ""},
    {"c",          "https://github.com/tree-sitter/tree-sitter-c",                   "b780e47fc780ddc8da13afa35a3f4ed5c157823d", ""},
    {"cpp",        "https://github.com/tree-sitter/tree-sitter-cpp",                 "c009222808634c1014f82438d4883753516a2c24", ""},
    {"go",         "https://github.com/tree-sitter/tree-sitter-go",                  "2346a3ab1bb3857b48b29d779a1ef9799a248cd7", ""},
    {"javascript", "https://github.com/tree-sitter/tree-sitter-javascript",          "58404d8cf191d69f2674a8fd507bd5776f46cb11", ""},
    // typescript and tsx are two grammars in one repository.
    {"typescript", "https://github.com/tree-sitter/tree-sitter-typescript",          "75b3874edb2dc714fb1fd77a32013d0f8699989f", "typescript"},
    {"tsx",        "https://github.com/tree-sitter/tree-sitter-typescript",          "75b3874edb2dc714fb1fd77a32013d0f8699989f", "tsx"},
    {"jai",        "https://github.com/constantitus/tree-sitter-jai",                "96440b0f78a45bed1668d5693f26c0d30b4d1a84", ""},
    {"rust",       "https://github.com/tree-sitter/tree-sitter-rust",                "77a3747266f4d621d0757825e6b11edcbf991ca5", ""},
    {"python",     "https://github.com/tree-sitter/tree-sitter-python",              "26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64", ""},
    {"ruby",       "https://github.com/tree-sitter/tree-sitter-ruby",                "ad907a69da0c8a4f7a943a7fe012712208da6dee", ""},
    {"java",       "https://github.com/tree-sitter/tree-sitter-java",                "e10607b45ff745f5f876bfa3e94fbcc6b44bdc11", ""},
    {"kotlin",     "https://github.com/fwcd/tree-sitter-kotlin",                     "1852ea17b7f60fb3f9d84e0b1555d56b46b39fb1", ""},
    {"zig",        "https://github.com/tree-sitter-grammars/tree-sitter-zig",        "6479aa13f32f701c383083d8b28360ebd682fb7d", ""},
    // The repository name c-sharp is not an Odin identifier.
    {"c_sharp",    "https://github.com/tree-sitter/tree-sitter-c-sharp",             "8c0abe0b84a3681d3e6852ce2e2a1eecb4f731c5", ""},
    {"php",        "https://github.com/tree-sitter/tree-sitter-php",                 "58d5643086ae60e93a3746cca648363ee97c8761", "php"},
    {"haskell",    "https://github.com/tree-sitter/tree-sitter-haskell",             "97288e585b0bd44199720280d067fa35bacd81ff", ""},
    {"ocaml",      "https://github.com/tree-sitter/tree-sitter-ocaml",               "3b2e14e0697d405c9aa0beddfa09b71f45abc504", "grammars/ocaml"},
    {"starlark",   "https://github.com/tree-sitter-grammars/tree-sitter-starlark",   "a453dbf3ba433db0e5ec621a38a7e59d72e4dc69", ""},
    {"hcl",        "https://github.com/tree-sitter-grammars/tree-sitter-hcl",        "64ad62785d442eb4d45df3a1764962dafd5bc98b", ""},
    {"nix",        "https://github.com/nix-community/tree-sitter-nix",               "32c3ce98afdafc2ec9aedf0280a678750f76254c", ""},
    {"pascal",     "https://github.com/Isopod/tree-sitter-pascal",                   "042119eca2e18a60e56317fb06ee3ba5c32cb447", ""},
    {"nim",        "https://github.com/alaviss/tree-sitter-nim",                     "ac72ba30d16edf0be021588a9301ede4accd6cf4", ""},
    {"commonlisp", "https://github.com/tree-sitter-grammars/tree-sitter-commonlisp", "32323509b3d9fe96607d151c2da2c9009eb13a2f", ""},
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
// The stamp is outside the submodule, which ignores only libs/*.lib.
build_harfbuzz :: proc() -> bool {
    lib := "vendor/odin-harfbuzz/libs/harfbuzz.lib"
    stamp := "vendor/harfbuzz.stamp"
    flags := strings.join(HARFBUZZ_FLAGS, " ", context.temp_allocator)
    want := fmt.tprintf("%s %s %s", HARFBUZZ_VERSION, HARFBUZZ_SHA256, flags)
    if os.exists(lib) && stamp_current(stamp, want) {
        return true
    }

    work := "bin/deps"
    archive := fmt.tprintf("harfbuzz-%s.tar.xz", HARFBUZZ_VERSION)
    src := join(work, fmt.tprintf("harfbuzz-%s", HARFBUZZ_VERSION))
    // A source tree of an earlier run can be partial.
    if !mkdir(work) || !mkdir(filepath.dir(lib)) || !remove_tree(src) {
        return false
    }

    if !archive_verified(join(work, archive)) {
        url := fmt.tprintf(
            "https://github.com/harfbuzz/harfbuzz/releases/download/%s/%s",
            HARFBUZZ_VERSION, archive,
        )
        if !exec({"curl", "-fL", "-o", archive, url}, work) {
            return false
        }
        if !archive_verified(join(work, archive)) {
            fmt.eprintfln("[build] %s does not have the SHA-256 %s", archive, HARFBUZZ_SHA256)
            return false
        }
    }
    // The tar of Windows cannot read .xz.
    script := fmt.tprintf("import tarfile; tarfile.open('%s').extractall(filter='data')", archive)
    if !exec({"python", "-c", script}, work) {
        return false
    }

    setup := make([dynamic]string, context.temp_allocator)
    append(&setup, "meson", "setup", "build")
    append(&setup, ..HARFBUZZ_FLAGS)
    if !exec_msvc(setup[:], src) {
        fmt.eprintln("[build] meson and ninja come from `python -m pip install --user meson ninja`; the Scripts directory must be on PATH")
        return false
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
    return stamp_write(stamp, want)
}

// Reports whether the file has the SHA-256 that HARFBUZZ_SHA256 names.
archive_verified :: proc(path: string) -> bool {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        return false
    }
    digest: [sha2.DIGEST_SIZE_256]byte
    ctx: sha2.Context_256
    sha2.init_256(&ctx)
    sha2.update(&ctx, data)
    sha2.final(&ctx, digest[:])
    return string(hex.encode(digest[:], context.temp_allocator)) == HARFBUZZ_SHA256
}

// Builds the tree-sitter runtime and each parser of GRAMMARS into the submodule.
// A library with a current stamp stays.
build_tree_sitter :: proc() -> bool {
    repo := "vendor/odin-tree-sitter"

    // The submodule commit selects the runtime version and writes the bindings,
    // so each stamp names it.
    binding, found := capture({"git", "rev-parse", "HEAD"}, repo)
    if !found {
        return false
    }

    runtime := join(repo, "tree-sitter")
    if !os.exists(join(runtime, "libtree-sitter" + LIB_EXT)) || !stamp_current(join(runtime, STAMP), binding) {
        // Without -clean the tool asks on stdin before it replaces a library.
        if !exec_msvc({"odin", "run", "build", "--", "install", "-clean"}, repo) {
            return false
        }
        if !stamp_write(join(runtime, STAMP), binding) {
            return false
        }
    }

    for g in GRAMMARS {
        dir := join(repo, "parsers", g.name)
        want := fmt.tprintf("%s %s %s %s", g.url, g.rev, g.path, binding)
        if os.exists(join(dir, "parser" + LIB_EXT)) && stamp_current(join(dir, STAMP), want) {
            continue
        }
        mirror, fetched := fetch_grammar(g)
        if !fetched {
            return false
        }
        // The repository is positional. -name keeps the generated package, the
        // tree_sitter_<id> binding and the parser directory in agreement, and
        // -yes replaces a parser that is already there.
        args := make([dynamic]string, context.temp_allocator)
        append(&args, "odin", "run", "build", "--", "install-parser", mirror)
        append(&args, fmt.tprintf("-name=%s", g.name))
        if g.path != "" {
            append(&args, fmt.tprintf("-path=%s", g.path))
        }
        append(&args, "-yes")
        if !exec_msvc(args[:], repo) {
            return false
        }
        if !stamp_write(join(dir, STAMP), want) {
            return false
        }
    }
    return true
}

// Gets the pinned commit of a grammar into a bare repository under bin/deps and
// returns its absolute path. install-parser clones the default branch of the
// repository it is given and takes no revision, so it is given this one, whose
// HEAD is the pinned commit.
fetch_grammar :: proc(g: Grammar) -> (mirror: string, ok: bool) {
    root := join("bin", "deps", "grammars")
    // install-parser appends .git to a name that does not end with it.
    dir := join(root, fmt.tprintf("%s.git", g.name))
    if !mkdir(root) {
        return "", false
    }
    // A write into a new repository fails at random on Windows when a scanner
    // or a file watcher holds the file open, so the fetch gets three tries.
    // unpackLimit keeps the commit as one pack, which is one file to write.
    FETCH_TRIES :: 3
    fetched := false
    for try in 1 ..= FETCH_TRIES {
        if !remove_tree(dir) || !exec({"git", "init", "--quiet", "--bare", dir}) {
            return "", false
        }
        if exec({"git", "-c", "fetch.unpackLimit=1", "fetch", "--quiet", "--depth=1", g.url, g.rev}, dir) {
            fetched = true
            break
        }
        fmt.eprintfln("[build] fetch %d of %d of %s failed", try, FETCH_TRIES, g.url)
    }
    if !fetched {
        fmt.eprintfln("[build] the commit %s of %s is not available", g.rev, g.url)
        return "", false
    }
    if !exec({"git", "update-ref", "--no-deref", "HEAD", "FETCH_HEAD"}, dir) {
        return "", false
    }
    abs, err := os.get_absolute_path(dir, context.temp_allocator)
    if err != nil {
        fmt.eprintfln("[build] the path %s is not resolvable: %v", dir, err)
        return "", false
    }
    return abs, true
}

stamp_current :: proc(path, want: string) -> bool {
    data, err := os.read_entire_file(path, context.temp_allocator)
    return err == nil && string(data) == want
}

stamp_write :: proc(path, want: string) -> bool {
    if err := os.write_entire_file(path, want); err != nil {
        fmt.eprintfln("[build] a write of %s failed: %v", path, err)
        return false
    }
    return true
}

// Deletes a directory tree. A tree that is absent is not an error; POSIX
// reports that as Not_Exist, Windows as no error.
remove_tree :: proc(path: string) -> bool {
    if err := os.remove_all(path); err != nil && err != .Not_Exist {
        fmt.eprintfln("[build] a delete of %s failed: %v", path, err)
        return false
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
exec_msvc :: proc(args: []string, working_dir := "", secret := "") -> bool {
    when ODIN_OS != .Windows {
        return exec(args, working_dir, secret = secret)
    } else {
        if os.get_env("VSINSTALLDIR", context.temp_allocator) != "" {
            return exec(args, working_dir, secret = secret)
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
        // the batch file stays on disk to run by hand. The target is this
        // driver's own architecture, which is the one the editor is built for —
        // an emulated x64 driver builds an x64 editor and must say so.
        target := ODIN_ARCH == .arm64 ? "arm64" : "amd64"
        fmt.sbprintfln(&script, "%s >nul 2>&1 || exit /b 1", msvc.vsdevcmd_call(vsdevcmd, target))
        fmt.sbprintln(&script, command_line(args))

        // Backslashes: cmd.exe reads a leading forward slash as a switch.
        bat := join("bin", "msvc.bat")
        if err := os.write_entire_file(bat, strings.to_string(script)); err != nil {
            fmt.eprintfln("[build] a write of %s failed: %v", bat, err)
            return false
        }

        if opt.verbose {
            fmt.printfln("  $ %s  [msvc]", command_line(args, secret))
        }
        return exec({"cmd", "/c", bat}, quiet = true)
    }
}

// Joins the arguments into one command line, quoting each one that has a space.
// An argument equal to `secret` is masked, for a line that is printed.
command_line :: proc(args: []string, secret := "") -> string {
    parts := make([dynamic]string, 0, len(args), context.temp_allocator)
    for arg in args {
        if secret != "" && arg == secret {
            append(&parts, "***")
        } else if strings.contains(arg, " ") {
            append(&parts, fmt.tprintf(`"%s"`, arg))
        } else {
            append(&parts, arg)
        }
    }
    return strings.join(parts[:], " ", context.temp_allocator)
}

// Joins onto the temp allocator. Only an exhausted allocator can fail here, and
// no part of a build can continue past one.
join :: proc(parts: ..string) -> string {
    joined, err := filepath.join(parts, context.temp_allocator)
    if err != nil {
        fmt.eprintfln("[build] a path join of %v failed: %v", parts, err)
        os.exit(1)
    }
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
// program. -verbose prints the command with the argument `secret` masked.
exec :: proc(args: []string, working_dir := "", quiet := false, secret := "") -> bool {
    if opt.verbose && !quiet {
        fmt.printfln("  $ %s", command_line(args, secret))
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

// Does a command and returns what it wrote to stdout, without the outer spaces.
capture :: proc(args: []string, working_dir := "") -> (out: string, ok: bool) {
    desc := os.Process_Desc {
        command     = args,
        working_dir = working_dir,
    }
    state, stdout, stderr, err := os.process_exec(desc, context.temp_allocator)
    if err != nil {
        fmt.eprintfln("[build] a start of %q failed: %v", args[0], err)
        return "", false
    }
    if state.exit_code != 0 {
        fmt.eprintfln("[build] %s failed: %s", command_line(args), strings.trim_space(string(stderr)))
        return "", false
    }
    return strings.trim_space(string(stdout)), true
}
