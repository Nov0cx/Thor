package thor

import "core:os"
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
    thor.git_prefix = strings.concatenate({"repo", filepath.SEPARATOR_STRING}, context.temp_allocator)

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
    thor.git_prefix = strings.concatenate({"repo", filepath.SEPARATOR_STRING}, context.temp_allocator)

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
    thor.git_prefix = strings.concatenate({"repo", filepath.SEPARATOR_STRING}, context.temp_allocator)

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
    thor.git_prefix = strings.concatenate({"repo", filepath.SEPARATOR_STRING}, context.temp_allocator)

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

// `.git` is a directory in a normal checkout, and a file naming a `gitdir:` in a
// worktree or a submodule. The walk up also answers for a subdirectory opened as
// the workspace, whose git output is still relative to the repo root.
@(test)
test_git_repo_discovery :: proc(t: ^testing.T) {
    ROOT :: "thor_gitrepo.tmp"
    GIT :: ROOT + "/.git"
    DEEP :: ROOT + "/src/deep"
    LINKED :: ROOT + "/linked"
    ABSOLUTE :: ROOT + "/absolute"
    LINKED_GIT :: GIT + "/worktrees/linked"

    os.remove_all(ROOT) // a previous run that died mid-test
    defer os.remove_all(ROOT)

    for dir in ([]string{ROOT, GIT, ROOT + "/src", DEEP, LINKED, ABSOLUTE, GIT + "/worktrees", LINKED_GIT}) {
        testing.expectf(t, os.make_directory(dir) == nil, "could not create %s", dir)
    }
    testing.expect(t, os.write_entire_file(GIT + "/HEAD", transmute([]u8) string("ref: refs/heads/main\n")) == nil, "could not write HEAD")
    testing.expect(t, os.write_entire_file(LINKED_GIT + "/HEAD", transmute([]u8) string("ref: refs/heads/feature\n")) == nil, "could not write worktree HEAD")
    testing.expect(t, os.write_entire_file(LINKED + "/.git", transmute([]u8) string("gitdir: ../.git/worktrees/linked\n")) == nil, "could not write the gitdir pointer")

    absolute_pointer := strings.concatenate({"gitdir: ", thor_abs_path(LINKED_GIT), "\n"}, context.temp_allocator)
    testing.expect(t, os.write_entire_file(ABSOLUTE + "/.git", transmute([]u8) absolute_pointer) == nil, "could not write the absolute gitdir pointer")

    root_abs := strings.clone(thor_abs_path(ROOT), context.temp_allocator)

    // A plain checkout, and the same repo found from a subdirectory of it.
    expect_git_repo(t, ROOT, root_abs, "main")
    expect_git_repo(t, DEEP, root_abs, "main")
    // A worktree: `.git` is a file, and HEAD lives at the path it names.
    expect_git_repo(t, LINKED, strings.clone(thor_abs_path(LINKED), context.temp_allocator), "feature")
    expect_git_repo(t, ABSOLUTE, strings.clone(thor_abs_path(ABSOLUTE), context.temp_allocator), "feature")

    // A detached head shows the short commit hash instead of a branch name.
    testing.expect(t, os.write_entire_file(GIT + "/HEAD", transmute([]u8) string("9f1c2b3a4d5e6f708192a3b4c5d6e7f809a1b2c3\n")) == nil, "could not detach HEAD")
    expect_git_repo(t, ROOT, root_abs, "9f1c2b3a")
}

@(private = "file")
expect_git_repo :: proc(t: ^testing.T, dir, want_root, want_branch: string, loc := #caller_location) {
    root, git_dir, ok := thor_find_git_repo(dir)
    testing.expectf(t, ok, "no repo found for %q", dir, loc = loc)
    if !ok {
        return
    }
    testing.expect_value(t, root, want_root, loc = loc)

    branch := thor_read_git_branch(git_dir)
    defer delete(branch)
    testing.expect_value(t, branch, want_branch, loc = loc)
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
