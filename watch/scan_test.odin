package watch

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
