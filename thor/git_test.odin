package thor

import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../widgets"

// Git prints repo-relative paths with forward slashes, but the explorer tree and
// Open_File.path both carry native separators. A key built with the wrong one
// matches nothing, which is how the whole feature stayed invisible on POSIX.
@(test)
test_git_status_keys_use_the_native_separator :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_prefix = strings.concatenate({"repo", filepath.SEPARATOR_STRING}, context.temp_allocator)

    status := make(map[string]widgets.Git_Status)
    defer {
        for path in status {
            delete(path)
        }
        delete(status)
    }
    git_parse_status(thor, " M src/main.odin\n?? docs/api/new.md\n", &status)

    // Every ancestor is tinted too, so a change deep in the tree shows on the
    // collapsed folder above it.
    expect_git_status(t, status, native("repo", "src", "main.odin"), .Modified)
    expect_git_status(t, status, native("repo", "src"), .Modified)
    expect_git_status(t, status, native("repo", "docs", "api", "new.md"), .Untracked)
    expect_git_status(t, status, native("repo", "docs", "api"), .Modified)
    expect_git_status(t, status, native("repo", "docs"), .Modified)
    testing.expect_value(t, len(status), 5)
}

// A conflict outranks the Modified marker its ancestors would otherwise take.
@(test)
test_git_status_conflict_wins_on_ancestors :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_prefix = strings.concatenate({"repo", filepath.SEPARATOR_STRING}, context.temp_allocator)

    status := make(map[string]widgets.Git_Status)
    defer {
        for path in status {
            delete(path)
        }
        delete(status)
    }
    git_parse_status(thor, " M src/a.odin\nUU src/b.odin\n", &status)

    expect_git_status(t, status, native("repo", "src", "b.odin"), .Conflict)
    expect_git_status(t, status, native("repo", "src"), .Conflict)
}

// The gutter reads the diff map with Open_File.path, so its keys need the same
// native spelling the status keys do.
@(test)
test_git_diff_keys_use_the_native_separator :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_prefix = strings.concatenate({"repo", filepath.SEPARATOR_STRING}, context.temp_allocator)

    diff := make(map[string][dynamic]widgets.Diff_Line_Kind)
    defer {
        for path, lines in diff {
            delete(path)
            delete(lines)
        }
        delete(diff)
    }
    git_parse_diff(thor, "+++ b/src/main.odin\n@@ -1,0 +2,2 @@\n", &diff)

    key := native("repo", "src", "main.odin")
    lines, ok := diff[key]
    testing.expectf(t, ok, "no diff for %q", key)
    if !ok {
        return
    }
    testing.expect_value(t, len(lines), 3)
    testing.expect_value(t, lines[0], widgets.Diff_Line_Kind.None)
    testing.expect_value(t, lines[1], widgets.Diff_Line_Kind.Added)
    testing.expect_value(t, lines[2], widgets.Diff_Line_Kind.Added)
}

// A file header with no hunk under it (a mode-only or a binary change) builds a
// key the map never takes; the parser owns it and must free it itself.
@(test)
test_git_diff_drops_a_key_with_no_hunk :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    thor.workspace_prefix = strings.concatenate({"repo", filepath.SEPARATOR_STRING}, context.temp_allocator)

    diff := make(map[string][dynamic]widgets.Diff_Line_Kind)
    defer {
        for path, lines in diff {
            delete(path)
            delete(lines)
        }
        delete(diff)
    }
    git_parse_diff(thor, "+++ b/mode-only.txt\n+++ b/tail.txt\n", &diff)
    testing.expect_value(t, len(diff), 0)
}

// The path the tree and the open files would carry, built independently of the
// spelling git.odin makes.
@(private = "file")
native :: proc(parts: ..string) -> string {
    joined, _ := filepath.join(parts, context.temp_allocator)
    return joined
}

@(private = "file")
expect_git_status :: proc(
    t: ^testing.T,
    status: map[string]widgets.Git_Status,
    key: string,
    want: widgets.Git_Status,
    loc := #caller_location,
) {
    got, ok := status[key]
    testing.expectf(t, ok, "no status for %q", key, loc = loc)
    if ok {
        testing.expect_value(t, got, want, loc = loc)
    }
}
