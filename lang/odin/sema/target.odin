package odinsema

import "core:strings"

Target_OS :: enum u8 {
    Unknown,
    Windows,
    Darwin,
    Linux,
    FreeBSD,
    OpenBSD,
    NetBSD,
    Haiku,
    WASI,
    JS,
    Orca,
    Freestanding,
}

Target_Arch :: enum u8 {
    Unknown,
    amd64,
    i386,
    arm32,
    arm64,
    wasm32,
    wasm64p32,
    riscv64,
}

// The build configuration that decides which files of a package are compiled.
Target :: struct {
    os:    Target_OS,
    arch:  Target_Arch,
    tests: bool, // `_test.odin` files count, as under `odin test`
}

@(private = "file")
OS_NAMES := [Target_OS]string {
    .Unknown      = "",
    .Windows      = "windows",
    .Darwin       = "darwin",
    .Linux        = "linux",
    .FreeBSD      = "freebsd",
    .OpenBSD      = "openbsd",
    .NetBSD       = "netbsd",
    .Haiku        = "haiku",
    .WASI         = "wasi",
    .JS           = "js",
    .Orca         = "orca",
    .Freestanding = "freestanding",
}

@(private = "file")
ARCH_NAMES := [Target_Arch]string {
    .Unknown   = "",
    .amd64     = "amd64",
    .i386      = "i386",
    .arm32     = "arm32",
    .arm64     = "arm64",
    .wasm32    = "wasm32",
    .wasm64p32 = "wasm64p32",
    .riscv64   = "riscv64",
}

// The target this program runs on. Test files count.
target_host :: proc() -> Target {
    t := Target{tests = true}
    #partial switch ODIN_OS {
    case .Windows:      t.os = .Windows
    case .Darwin:       t.os = .Darwin
    case .Linux:        t.os = .Linux
    case .FreeBSD:      t.os = .FreeBSD
    case .OpenBSD:      t.os = .OpenBSD
    case .NetBSD:       t.os = .NetBSD
    case .WASI:         t.os = .WASI
    case .JS:           t.os = .JS
    case .Orca:         t.os = .Orca
    case .Freestanding: t.os = .Freestanding
    }
    #partial switch ODIN_ARCH {
    case .amd64:     t.arch = .amd64
    case .i386:      t.arch = .i386
    case .arm32:     t.arch = .arm32
    case .arm64:     t.arch = .arm64
    case .wasm32:    t.arch = .wasm32
    case .wasm64p32: t.arch = .wasm64p32
    case .riscv64:   t.arch = .riscv64
    }
    return t
}

// The OS a build tag or file name suffix names, case-insensitive; .Unknown when none.
target_os_from_string :: proc(s: string) -> Target_OS {
    for name, os in OS_NAMES {
        if name != "" && strings.equal_fold(s, name) {
            return os
        }
    }
    return .Unknown
}

// The architecture a build tag or file name suffix names, case-insensitive; .Unknown when none.
target_arch_from_string :: proc(s: string) -> Target_Arch {
    for name, arch in ARCH_NAMES {
        if name != "" && strings.equal_fold(s, name) {
            return arch
        }
    }
    return .Unknown
}

// True when the file at `path` with file tags `tags` is compiled for `target`, as the compiler decides it:
// the file name (a leading `.`, `_test`, OS and arch suffixes) and every `#+build` tag.
file_in_build :: proc(path: string, tags: []string, target: Target) -> bool {
    if !file_name_in_build(path, target) {
        return false
    }
    for tag in tags {
        name, rest := tag_split(tag)
        if name == "build" && !build_tag_holds(rest, target) {
            return false
        }
    }
    return true
}

// The file name rules of the compiler: `name_os`, `name_arch`, `name_os_arch` and `name_arch_os`.
file_name_in_build :: proc(path: string, target: Target) -> bool {
    name := path
    if i := strings.last_index_any(name, "/\\"); i >= 0 {
        name = name[i + 1:]
    }
    if i := strings.last_index_byte(name, '.'); i > 0 {
        name = name[:i]
    } else if i == 0 {
        return false
    }
    if strings.has_prefix(name, ".") {
        return false
    }
    if !target.tests && name != "_test" && strings.has_suffix(name, "_test") {
        return false
    }
    under := strings.last_index_byte(name, '_')
    if under < 0 {
        return true
    }
    last := name[under + 1:]
    before := ""
    if under > 0 {
        head := name[:under]
        before = head[strings.last_index_byte(head, '_') + 1:]
    }
    os1, arch1 := target_os_from_string(last), target_arch_from_string(last)
    os2, arch2 := target_os_from_string(before), target_arch_from_string(before)
    switch {
    case os1 != .Unknown && arch2 != .Unknown:
        return os1 == target.os && arch2 == target.arch
    case arch1 != .Unknown && os2 != .Unknown:
        return arch1 == target.arch && os2 == target.os
    case os1 != .Unknown:
        return os1 == target.os
    case arch1 != .Unknown:
        return arch1 == target.arch
    }
    return true
}

// Evaluates the text after `#+build`: a comma separates alternatives, a space joins terms,
// `!` negates one, and `ignore` excludes the file. An unknown term is false.
build_tag_holds :: proc(expr: string, target: Target) -> bool {
    trimmed := strings.trim_space(expr)
    if trimmed == "" {
        return true
    }
    rest := trimmed
    for alternative in strings.split_iterator(&rest, ",") {
        holds := true
        terms := 0
        words := alternative
        for word in strings.fields_iterator(&words) {
            terms += 1
            term := word
            negated := false
            for strings.has_prefix(term, "!") {
                negated = !negated
                term = term[1:]
            }
            if term == "ignore" {
                holds = false
                continue
            }
            match: bool
            if os := target_os_from_string(term); os != .Unknown {
                match = os == target.os
            } else if arch := target_arch_from_string(term); arch != .Unknown {
                match = arch == target.arch
            } else {
                holds = false
                continue
            }
            if negated {
                match = !match
            }
            holds = holds && match
        }
        if terms > 0 && holds {
            return true
        }
    }
    return false
}
