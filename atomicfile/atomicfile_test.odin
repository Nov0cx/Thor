package atomicfile

// Run from the repository root: odin test atomicfile

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// A relative directory of its own for one test.
@(private = "file")
scratch :: proc(t: ^testing.T, name: string) -> (dir: string, ok: bool) {
    dir = fmt.tprintf("atomicfile_%s_%d", name, time.now()._nsec)
    if err := os.make_directory_all(dir); err != nil {
        testing.expectf(t, false, "could not make %q: %v", dir, err)
        return "", false
    }
    return dir, true
}

@(private = "file")
at :: proc(dir, name: string) -> string {
    joined, _ := os.join_path({dir, name}, context.temp_allocator)
    return joined
}

@(private = "file")
holds :: proc(path, want: string) -> bool {
    data, err := os.read_entire_file(path, context.temp_allocator)
    return err == nil && string(data) == want
}

// Fails when `dir` holds a temp file.
@(private = "file")
no_temp_left :: proc(t: ^testing.T, dir: string) {
    entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
    testing.expectf(t, err == nil, "could not list %q: %v", dir, err)
    for entry in entries {
        testing.expectf(t, !strings.has_suffix(entry.name, ".tmp"), "a temp file was left: %q", entry.name)
    }
}

@(test)
test_write_replaces_and_creates :: proc(t: ^testing.T) {
    dir, ok := scratch(t, "replace")
    if !ok {
        return
    }
    defer os.remove_all(dir)

    path := at(dir, "file.txt")
    testing.expect_value(t, write(path, transmute([]byte) string("first")), nil)
    testing.expect(t, holds(path, "first"), "a missing file must be created")
    testing.expect_value(t, write(path, transmute([]byte) string("second\x00tail")), nil)
    testing.expect(t, holds(path, "second\x00tail"), "the file must hold the new data")
    testing.expect_value(t, write(path, nil), nil)
    testing.expect(t, holds(path, ""), "an empty write must empty the file")
    no_temp_left(t, dir)
}

@(test)
test_write_follows_a_symlink :: proc(t: ^testing.T) {
    // A symlink needs a privilege Windows may not grant; the warning is expected.
    context.logger = log.nil_logger()
    dir, ok := scratch(t, "symlink")
    if !ok {
        return
    }
    defer os.remove_all(dir)

    real := at(dir, "real.txt")
    link := at(dir, "link.txt")
    testing.expect_value(t, write(real, transmute([]byte) string("old")), nil)
    if err := os.symlink("real.txt", link); err != nil {
        return
    }
    testing.expect_value(t, write(link, transmute([]byte) string("new")), nil)
    testing.expect(t, holds(real, "new"), "the link target must get the data")
    info, err := os.lstat(link, context.temp_allocator)
    testing.expect(t, err == nil && info.type == .Symlink, "the link must stay a link")
}

@(test)
test_write_keeps_the_mode :: proc(t: ^testing.T) {
    when ODIN_OS != .Windows {
        dir, ok := scratch(t, "mode")
        if !ok {
            return
        }
        defer os.remove_all(dir)

        path := at(dir, "run.sh")
        testing.expect_value(t, write(path, transmute([]byte) string("#!/bin/sh\n")), nil)
        mode := os.perm_number(0o751)
        testing.expect_value(t, os.change_mode(path, mode), nil)
        testing.expect_value(t, write(path, transmute([]byte) string("#!/bin/sh\necho\n")), nil)
        info, err := os.stat(path, context.temp_allocator)
        testing.expect_value(t, err, nil)
        testing.expect_value(t, info.mode, mode)
    }
}
