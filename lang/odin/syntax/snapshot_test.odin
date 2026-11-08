package odinsyntax

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Rewrites the expected dumps from the parser's output: -define:SYNTAX_BLESS=true.
@(private = "file")
BLESS :: #config(SYNTAX_BLESS, false)

@(private = "file")
TESTDATA :: "lang/odin/syntax/testdata"

// The text of a file with CRLF collapsed to LF; "" and false when it cannot be read.
@(private = "file")
read_lf :: proc(path: string) -> (string, bool) {
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        return "", false
    }
    out, _ := strings.replace_all(string(data), "\r\n", "\n", context.temp_allocator)
    return out, true
}

// The tree without trivia, then one `error@start..end message` line per syntax error.
@(private = "file")
snapshot :: proc(src: string) -> (string, bool) {
    result, err := parse(src)
    if err != nil {
        return "", false
    }
    defer parse_destroy(&result)
    sb := strings.builder_make(context.temp_allocator)
    strings.write_string(&sb, debug_dump(result.tree, context.temp_allocator, trivia = false))
    for e in result.errors {
        fmt.sbprintf(&sb, "error@%d..%d %s\n", e.offset, e.end, error_message(e, context.temp_allocator))
    }
    return strings.to_string(sb), true
}

// Each testdata/<name>.odin.txt parses to the tree in testdata/<name>.dump.
@(test)
test_snapshots :: proc(t: ^testing.T) {
    handle, oerr := os.open(TESTDATA)
    if !testing.expectf(t, oerr == nil, "cannot open %s: %v", TESTDATA, oerr) {
        return
    }
    defer os.close(handle)
    infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
    if !testing.expectf(t, rerr == nil, "cannot list %s: %v", TESTDATA, rerr) {
        return
    }
    count := 0
    for info in infos {
        if !strings.has_suffix(info.name, ".odin.txt") {
            continue
        }
        count += 1
        name := strings.trim_suffix(info.name, ".odin.txt")
        src, ok := read_lf(info.fullpath)
        if !testing.expectf(t, ok, "cannot read %s", info.fullpath) {
            continue
        }
        got, parsed := snapshot(src)
        if !testing.expectf(t, parsed, "%s: parse failed", name) {
            continue
        }
        dump_path, jerr := filepath.join({TESTDATA, strings.concatenate({name, ".dump"}, context.temp_allocator)}, context.temp_allocator)
        if !testing.expect_value(t, jerr, nil) {
            continue
        }
        when BLESS {
            werr := os.write_entire_file(dump_path, transmute([]byte)got)
            testing.expectf(t, werr == nil, "cannot write %s: %v", dump_path, werr)
        } else {
            want, found := read_lf(dump_path)
            if !testing.expectf(t, found, "%s missing; run with -define:SYNTAX_BLESS=true", dump_path) {
                continue
            }
            testing.expectf(t, got == want, "%s: tree differs from %s; run with -define:SYNTAX_BLESS=true and review the diff", name, dump_path)
        }
    }
    testing.expectf(t, count >= 8, "only %d snapshot inputs in %s", count, TESTDATA)
}
