package watch

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Builds a finished snapshot from literal entries. `end` is filled in by the
// snapshot itself, so only the other fields carry.
@(private = "file")
scan_of :: proc(entries: []Scan_Entry) -> Scan {
    s: Scan
    s.paths = strings.builder_make()
    s.entries = make([dynamic]Scan_Entry)
    for entry in entries {
        scan_add(&s, entry.path, entry.modified, entry.size, entry.is_dir)
    }
    scan_finish(&s)
    return s
}

@(private = "file")
change_of :: proc(changes: []Change, path: string) -> (Change, bool) {
    for change in changes {
        if change.path == path {
            return change, true
        }
    }
    return {}, false
}

// The per-event filter the recursive Windows watcher applies. A skipped
// directory still reports itself; only what is inside it is noise.
@(test)
test_scan_skip_rel_covers_contents_only :: proc(t: ^testing.T) {
    cases := []struct{rel: string, skip: bool} {
        {"src\\main.odin", false},
        {"node_modules", false},
        {"node_modules\\pkg\\dist\\a.js", true},
        {"node_modules/pkg/dist/a.js", true},
        {"web\\node_modules\\pkg\\a.js", true},
        {"node_modules_helper.odin", false},
        {"src\\node_modules_helper.odin", false},
        {".git\\index", false},
        {".git\\objects", false},
        {".git\\objects\\ab\\cdef", true},
        {".git\\lfs\\objects\\a", true},
        {".git\\refs\\heads\\master", false},
        {"objects\\ab\\cdef", false}, // only git's own object store is noise
        {"", false},
    }
    for c in cases {
        testing.expectf(
            t,
            scan_skip_rel("D:\\work\\repo", c.rel) == c.skip,
            "scan_skip_rel(%q) should be %v",
            c.rel,
            c.skip,
        )
    }
}

@(test)
test_scan_finish_sorts_and_keeps_paths :: proc(t: ^testing.T) {
    s := scan_of({{path = "b/x"}, {path = "a"}, {path = "a/z"}})
    defer scan_destroy(&s)

    testing.expect_value(t, len(s.entries), 3)
    testing.expect_value(t, s.entries[0].path, "a")
    testing.expect_value(t, s.entries[1].path, "a/z")
    testing.expect_value(t, s.entries[2].path, "b/x")
}

@(test)
test_scan_diff_reports_every_kind :: proc(t: ^testing.T) {
    old_scan := scan_of(
        {
            {path = "keep", modified = 1, size = 10},
            {path = "grow", modified = 1, size = 10},
            {path = "touch", modified = 1, size = 10},
            {path = "gone", modified = 1, size = 10},
        },
    )
    defer scan_destroy(&old_scan)
    new_scan := scan_of(
        {
            {path = "keep", modified = 1, size = 10},
            {path = "grow", modified = 1, size = 20},
            {path = "touch", modified = 2, size = 10},
            {path = "fresh", modified = 2, size = 5},
        },
    )
    defer scan_destroy(&new_scan)

    changes := scan_diff(old_scan, new_scan, context.allocator)
    defer delete(changes)

    testing.expect_value(t, len(changes), 4)
    if change, ok := change_of(changes, "grow"); testing.expect(t, ok) {
        testing.expect_value(t, change.kind, Change_Kind.Modified)
    }
    if change, ok := change_of(changes, "touch"); testing.expect(t, ok) {
        testing.expect_value(t, change.kind, Change_Kind.Modified)
    }
    if change, ok := change_of(changes, "gone"); testing.expect(t, ok) {
        testing.expect_value(t, change.kind, Change_Kind.Deleted)
    }
    if change, ok := change_of(changes, "fresh"); testing.expect(t, ok) {
        testing.expect_value(t, change.kind, Change_Kind.Created)
    }
    _, unchanged := change_of(changes, "keep")
    testing.expect(t, !unchanged, "an untouched file must not report a change")
}

@(test)
test_scan_diff_ignores_a_directory_write_time :: proc(t: ^testing.T) {
    old_scan := scan_of({{path = "src", modified = 1, is_dir = true}})
    defer scan_destroy(&old_scan)
    new_scan := scan_of(
        {{path = "src", modified = 2, is_dir = true}, {path = "src/new.odin", modified = 2, size = 4}},
    )
    defer scan_destroy(&new_scan)

    changes := scan_diff(old_scan, new_scan, context.allocator)
    defer delete(changes)

    testing.expect_value(t, len(changes), 1)
    testing.expect_value(t, changes[0].kind, Change_Kind.Created)
    testing.expect_value(t, changes[0].path, "src/new.odin")
}

@(test)
test_scan_tree_walks_a_real_directory :: proc(t: ^testing.T) {
    s: Scan
    scan_tree(&s, "watch", context.allocator)
    defer scan_destroy(&s)

    found := false
    for entry in s.entries {
        if strings.has_suffix(entry.path, "scan.odin") {
            found = true
            testing.expect(t, !entry.is_dir, "a source file must not read as a directory")
            testing.expect(t, entry.size > 0, "a source file must have a size")
        }
    }
    testing.expect(t, found, "the walk must find watch/scan.odin")
}

// node_modules and .git/objects (and .git/lfs) are noise a poll never needs
// to walk into. The directories themselves still show up as entries; only
// their contents are skipped.
@(test)
test_scan_tree_skips_git_objects :: proc(t: ^testing.T) {
    root :: "bin/test/scan_skip_test"
    os.remove_all(root)
    defer os.remove_all(root)

    testing.expect(t, os.make_directory_all(root) == nil)
    objects, _ := filepath.join({root, ".git", "objects", "ab"}, context.temp_allocator)
    testing.expect(t, os.make_directory_all(objects) == nil)
    modules, _ := filepath.join({root, "node_modules", "pkg"}, context.temp_allocator)
    testing.expect(t, os.make_directory_all(modules) == nil)

    hidden, _ := filepath.join({objects, "deadbeef"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(hidden, "") == nil)
    module_file, _ := filepath.join({modules, "index.js"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(module_file, "") == nil)
    visible, _ := filepath.join({root, "main.odin"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(visible, "") == nil)

    s: Scan
    scan_tree(&s, root, context.allocator)
    defer scan_destroy(&s)

    has_suffix :: proc(s: Scan, suffix: string) -> bool {
        for entry in s.entries {
            if strings.has_suffix(entry.path, suffix) {
                return true
            }
        }
        return false
    }

    git_objects, _ := filepath.join({".git", "objects"}, context.temp_allocator)
    testing.expect(t, has_suffix(s, "main.odin"), "an ordinary file must still be walked")
    testing.expect(t, has_suffix(s, git_objects), "the skipped directory itself must still be recorded")
    testing.expect(t, has_suffix(s, "node_modules"), "the skipped directory itself must still be recorded")
    testing.expect(t, !has_suffix(s, "deadbeef"), "the contents of .git/objects must not be walked")
    testing.expect(t, !has_suffix(s, "index.js"), "the contents of node_modules must not be walked")
}

// scan_reset must reuse s.entries/s.paths across two walks, not leave stale
// data or dangling path slices behind: two walks of the same tree agree and
// diff to nothing. `before` is built with scan_of, an independent buffer, so
// resetting `s` for the second walk cannot invalidate what it holds.
@(test)
test_scan_tree_reuses_its_buffers :: proc(t: ^testing.T) {
    s: Scan
    scan_tree(&s, "watch", context.allocator)
    defer scan_destroy(&s)
    first_count := len(s.entries)

    before := scan_of(s.entries[:])
    defer scan_destroy(&before)

    scan_tree(&s, "watch", context.allocator)
    testing.expect_value(t, len(s.entries), first_count)

    changes := scan_diff(before, s, context.allocator)
    defer delete(changes)
    testing.expect_value(t, len(changes), 0)
}
