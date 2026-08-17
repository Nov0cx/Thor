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

// With core.quotePath on, git wraps a non-ASCII path in quotes and prints its
// bytes as octal escapes. Left encoded, the key matches no row and the file
// carries no tint.
@(test)
test_git_status_unquotes_a_c_quoted_path :: proc(t: ^testing.T) {
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
    // "\303\274" is the UTF-8 for "ü"; the rename keeps the new path only.
    git_parse_status(thor, " M \"src/\\303\\274ber.odin\"\nR  \"a.odin\" -> \"b\\tc.odin\"\n", &status)

    expect_git_status(t, status, native("repo", "src", "über.odin"), .Modified)
    expect_git_status(t, status, native("repo", "b\tc.odin"), .Renamed)
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

// Git answers with the spelling its index recorded, which on Windows is not
// always the one the filesystem gives the tree. The key folds case there, so the
// row still colors; on POSIX the two spellings are two files.
@(test)
test_git_status_lookup_folds_case_on_windows :: proc(t: ^testing.T) {
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
    git_parse_status(thor, " M Src/README.MD\n", &status)

    // What the explorer hands the lookup: the filesystem's own spelling.
    tree_path := native("repo", "Src", "README.MD")
    when ODIN_OS == .Windows {
        tree_path = native("repo", "src", "readme.md")
    }
    expect_git_status(t, status, tree_path, .Modified)
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
    lines, ok := diff[git_map_key(key)]
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

// The path the tree and the open files would carry, built independently of the
// spelling git.odin makes.
@(private = "file")
native :: proc(parts: ..string) -> string {
    joined, _ := filepath.join(parts, context.temp_allocator)
    return joined
}

// The diff is scoped to the open files, since git_apply_diff throws away every
// hunk outside them. The fallbacks matter more than the fast path: a pathspec
// that cannot be built must leave a whole-repo diff, never a broken command.
@(test)
test_git_diff_command_scopes_to_open_files :: proc(t: ^testing.T) {
    whole := git_diff_command(nil)
    testing.expect(t, !strings.contains(whole, " -- "), "nothing open should diff the whole repo")

    scoped := git_diff_command({"src/a b.odin", "src/c.odin"})
    testing.expect(t, strings.has_prefix(scoped, whole), "the scoped diff keeps the base command")
    testing.expectf(t, strings.contains(scoped, `"src/a b.odin"`), "a path with a space is unquoted: %s", scoped)
    testing.expectf(t, strings.contains(scoped, `"src/c.odin"`), "the second path is missing: %s", scoped)

    // Forty characters per path, so the budget is passed well before the end.
    long := strings.repeat("p", 40, context.temp_allocator)
    many := make([dynamic]string, context.temp_allocator)
    for _ in 0 ..< GIT_DIFF_CMD_MAX / 20 {
        append(&many, long)
    }
    testing.expect_value(t, git_diff_command(many[:]), whole)

    when ODIN_OS == .Windows {
        // git_quote_path has no safe escape for an embedded quote there.
        testing.expect_value(t, git_diff_command({`src\a"b.odin`}), whole)
    }
}

@(private = "file")
expect_git_status :: proc(
    t: ^testing.T,
    status: map[string]widgets.Git_Status,
    key: string,
    want: widgets.Git_Status,
    loc := #caller_location,
) {
    // `key` is the path the tree carries; the lookup folds it exactly as
    // thor_tree_git_status does.
    got, ok := status[git_map_key(key)]
    testing.expectf(t, ok, "no status for %q", key, loc = loc)
    if ok {
        testing.expect_value(t, got, want, loc = loc)
    }
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
