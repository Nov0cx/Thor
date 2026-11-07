package odin

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

import lang ".."
import "../../shell"
import odinsema "sema"
import odinsyntax "syntax"

@(private = "file")
Vet_Mark :: struct {
    file: string,
    line: int,
    col:  int,
}

@(private = "file")
Syntax_Vet :: struct {
    flag:    string,
    message: string, // the prefix of the compiler's message
}

// The directory name and the file name of `path`, which tell apart two files of one name.
@(private = "file")
mark_file :: proc(path: string) -> string {
    clean, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
    dir, name := filepath.split(clean)
    return strings.concatenate({filepath.base(strings.trim_right(dir, "/")), "/", name}, context.temp_allocator)
}

// The 1-based line and column of `offset` in `src`.
@(private = "file")
line_col_of :: proc(src: string, offset: int) -> (line, col: int) {
    line = 1 + strings.count(src[:offset], "\n")
    start := strings.last_index_byte(src[:offset], '\n') + 1
    return line, offset - start + 1
}

// Appends every directory under `dir` that holds an `.odin` file.
@(private = "file")
oracle_dirs :: proc(dir: string, out: ^[dynamic]string, keep: mem.Allocator) {
    handle, err := os.open(dir)
    if err != nil {
        return
    }
    defer os.close(handle)
    infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
    if rerr != nil {
        return
    }
    has_odin := false
    for info in infos {
        if info.type == .Directory {
            if info.name != "testdata" && !strings.has_prefix(info.name, ".") {
                oracle_dirs(strings.clone(info.fullpath, context.temp_allocator), out, keep)
            }
        } else if strings.has_suffix(info.name, ".odin") {
            has_odin = true
        }
    }
    if has_odin {
        append(out, strings.clone(dir, keep))
    }
}

// Logs the first few differences of each kind with the source line.
@(private = "file")
sample :: proc(shown: ^map[string]int, what, flag, dir: string, m: Vet_Mark) {
    key := strings.concatenate({what, flag}, context.temp_allocator)
    if shown[key] >= 8 {
        return
    }
    shown[strings.clone(key)] += 1
    path := strings.concatenate({dir, "/", filepath.base(m.file)}, context.temp_allocator)
    src, ok := lang.source_read(path, context.temp_allocator)
    text := ""
    if ok {
        rest := src
        n := 1
        for l in strings.split_lines_iterator(&rest) {
            if n == m.line {
                text = l
                break
            }
            n += 1
        }
    }
    log.infof("%s %s %s:%d:%d `%s`", what, flag, path, m.line, m.col, text)
}

// The marks of `-vet-semicolon`, `-vet-tabs` and `-vet-style` over the packages of the repository and
// the Odin root match the compiler's, line and column.
@(test)
test_vet_syntax_oracle :: proc(t: ^testing.T) {
    when !LIVE_ORACLE {
        log.info("skipped: needs -define:LIVE_ORACLE=true")
        return
    }
    arena: virtual.Arena
    if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) {
        return
    }
    defer virtual.arena_destroy(&arena)
    keep := virtual.arena_allocator(&arena)
    dirs := make([dynamic]string, keep)
    for top in ([]string{"atomicfile", "editview", "lang", "main", "plugin", "shell", "thor", "vt", "watch"}) {
        oracle_dirs(top, &dirs, keep)
    }
    root := strings.clone(ODIN_ROOT, keep)
    for top in ([]string{"base", "core", "vendor"}) {
        joined, _ := filepath.join({root, top}, context.temp_allocator)
        oracle_dirs(joined, &dirs, keep)
    }
    free_all(context.temp_allocator)
    slice.sort(dirs[:])
    kinds := [?]Syntax_Vet{{"-vet-semicolon", "Found unneeded semicolon"}, {"-vet-tabs", "With '-vet-tabs'"}, {"-vet-style", "Expected a comma, got a newline"}}
    target := odinsema.target_host()
    target.tests = true
    extra, missed, packages, marks := 0, 0, 0, 0
    shown := make(map[string]int, context.allocator)
    defer delete(shown)
    for dir in dirs {
        if LIVE_ORACLE_ONLY != "" && !strings.contains(dir, LIVE_ORACLE_ONLY) {
            continue
        }
        files, ferr := odinsema.package_dir_files(dir, context.temp_allocator)
        if ferr != nil {
            continue
        }
        for kind, k in kinds {
            want := make(map[Vet_Mark]bool, context.temp_allocator)
            own := make(map[string]bool, context.temp_allocator)
            for path in files {
                own[mark_file(path)] = true
            }
            args := []string{"check", dir, "-no-entry-point", "-max-error-count:100000", "-terse-errors", kind.flag}
            output, _, ran := shell.exec_status("odin", args, ".", ORACLE_TIMEOUT)
            if !ran {
                continue
            }
            it := output
            for line in strings.split_lines_iterator(&it) {
                p, ok := parse_diagnostic_line(line)
                if ok && strings.has_prefix(p.message, kind.message) && mark_file(p.path) in own {
                    want[Vet_Mark{mark_file(p.path), p.line, p.col}] = true
                }
            }
            delete(output)
            have := make(map[Vet_Mark]bool, context.temp_allocator)
            for path in files {
                src, ok := lang.source_read(path, context.temp_allocator)
                if !ok {
                    continue
                }
                parsed, perr := odinsyntax.parse(src, context.temp_allocator)
                if perr != nil {
                    continue
                }
                items, ierr := odinsema.item_tree(parsed, context.temp_allocator)
                if ierr != nil || !odinsema.file_in_build(path, items.tags, target) {
                    continue
                }
                offsets: [dynamic]int
                switch k {
                case 0: offsets, _ = odinsema.vet_semicolons(parsed, context.temp_allocator)
                case 1: offsets, _ = odinsema.vet_tabs(parsed, context.temp_allocator)
                case 2: offsets, _ = odinsema.vet_style(parsed, context.temp_allocator)
                }
                for offset in offsets {
                    line, col := line_col_of(src, offset)
                    have[Vet_Mark{mark_file(path), line, col}] = true
                }
            }
            packages += 1
            for m in have {
                marks += 1
                if m not_in want {
                    extra += 1
                    sample(&shown, "EXTRA", kind.flag, dir, m)
                }
            }
            for m in want {
                if m not_in have {
                    missed += 1
                    sample(&shown, "MISSED", kind.flag, dir, m)
                }
            }
        }
        free_all(context.temp_allocator)
    }
    log.infof("vet syntax: %d package runs, %d marks, %d extra, %d missed", packages, marks, extra, missed)
    testing.expect_value(t, extra, 0)
    testing.expect_value(t, missed, 0)
}
