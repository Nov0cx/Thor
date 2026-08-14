package thor

import "core:strings"
import "core:testing"

import "../widgets"

// A file changed in both places lists twice: once staged, once unstaged, each
// with its own side's status letter.
@(test)
test_git_porcelain_z_splits_staged_and_unstaged :: proc(t: ^testing.T) {
    entries := make([dynamic]Git_File_Entry)
    defer git_file_entries_destroy(&entries)
    git_parse_porcelain_z("MM a.txt\x00?? b.txt\x00A  c.txt\x00 D d.txt\x00", &entries)

    testing.expect_value(t, len(entries), 5)
    expect_git_entry(t, entries[0], "a.txt", .Modified, true)
    expect_git_entry(t, entries[1], "a.txt", .Modified, false)
    expect_git_entry(t, entries[2], "b.txt", .Untracked, false)
    expect_git_entry(t, entries[3], "c.txt", .Added, true)
    expect_git_entry(t, entries[4], "d.txt", .Deleted, false)
}

// A rename record carries its origin path as the following NUL field, which
// must be consumed with the record or every later entry misaligns.
@(test)
test_git_porcelain_z_rename_consumes_the_origin_field :: proc(t: ^testing.T) {
    entries := make([dynamic]Git_File_Entry)
    defer git_file_entries_destroy(&entries)
    git_parse_porcelain_z("R  new.txt\x00old.txt\x00A  c.txt\x00", &entries)

    testing.expect_value(t, len(entries), 2)
    expect_git_entry(t, entries[0], "new.txt", .Renamed, true)
    expect_git_entry(t, entries[1], "c.txt", .Added, true)
}

// A conflict is one unstaged entry: both sides need the same resolve, and a
// stage button on it would mislead.
@(test)
test_git_porcelain_z_conflict_is_one_unstaged_entry :: proc(t: ^testing.T) {
    entries := make([dynamic]Git_File_Entry)
    defer git_file_entries_destroy(&entries)
    git_parse_porcelain_z("UU x.txt\x00AA y.txt\x00", &entries)

    testing.expect_value(t, len(entries), 2)
    expect_git_entry(t, entries[0], "x.txt", .Conflict, false)
    expect_git_entry(t, entries[1], "y.txt", .Conflict, false)
}

// -z keeps paths verbatim, so a non-ASCII name arrives unquoted; error text
// and ignored entries produce nothing.
@(test)
test_git_porcelain_z_keeps_non_ascii_and_drops_noise :: proc(t: ^testing.T) {
    entries := make([dynamic]Git_File_Entry)
    defer git_file_entries_destroy(&entries)
    git_parse_porcelain_z("M  ümlaut ñ.txt\x00!! build/out.txt\x00", &entries)
    git_parse_porcelain_z("fatal: not a git repository", &entries)

    testing.expect_value(t, len(entries), 1)
    expect_git_entry(t, entries[0], "ümlaut ñ.txt", .Modified, true)
}

@(test)
test_git_upstream_counts :: proc(t: ^testing.T) {
    ahead, behind, ok := git_parse_upstream_counts("2\t3\n")
    testing.expect(t, ok, "counts did not parse")
    testing.expect_value(t, behind, 2)
    testing.expect_value(t, ahead, 3)

    _, _, bad := git_parse_upstream_counts("fatal: no upstream configured")
    testing.expect(t, !bad, "error text parsed as counts")
}

// The hunk header seeds both counters; each row then carries the 1-based line
// it holds on its side, 0 on the side it has none.
@(test)
test_git_diff_rows_number_both_sides :: proc(t: ^testing.T) {
    rows := make([dynamic]Git_Diff_Row)
    defer git_diff_rows_destroy(&rows)
    diff := "diff --git a/f b/f\nindex 111..222 100644\n--- a/f\n+++ b/f\n@@ -2,2 +2,2 @@ ctx\n line two\n-old three\n+new three\n"
    git_parse_diff_rows(diff, &rows)

    testing.expect_value(t, len(rows), 4)
    testing.expect_value(t, rows[0].kind, Git_Diff_Row_Kind.Hunk)
    expect_diff_row(t, rows[1], .Context, 2, 2, "line two")
    expect_diff_row(t, rows[2], .Removed, 3, 0, "old three")
    expect_diff_row(t, rows[3], .Added, 0, 3, "new three")
}

// Windows git can emit CRLF; the rows must not carry the \r into drawing.
@(test)
test_git_diff_rows_strip_crlf :: proc(t: ^testing.T) {
    rows := make([dynamic]Git_Diff_Row)
    defer git_diff_rows_destroy(&rows)
    git_parse_diff_rows("@@ -1 +1 @@\r\n-a\r\n+b\r\n", &rows)

    testing.expect_value(t, len(rows), 3)
    expect_diff_row(t, rows[1], .Removed, 1, 0, "a")
    expect_diff_row(t, rows[2], .Added, 0, 1, "b")
}

// Binary and missing-newline markers become Meta rows instead of vanishing;
// a second file's headers close the previous hunk.
@(test)
test_git_diff_rows_meta_and_second_file :: proc(t: ^testing.T) {
    rows := make([dynamic]Git_Diff_Row)
    defer git_diff_rows_destroy(&rows)
    diff := "@@ -1 +1 @@\n+x\n\\ No newline at end of file\ndiff --git a/img b/img\nindex 111..222\nBinary files a/img and b/img differ\n"
    git_parse_diff_rows(diff, &rows)

    testing.expect_value(t, len(rows), 4)
    expect_diff_row(t, rows[1], .Added, 0, 1, "x")
    testing.expect_value(t, rows[2].kind, Git_Diff_Row_Kind.Meta)
    testing.expect_value(t, rows[2].text, "No newline at end of file")
    testing.expect_value(t, rows[3].kind, Git_Diff_Row_Kind.Meta)
}

// Past the cap the parser stops with one truncation marker, so a huge diff
// cannot swallow the frame or the heap.
@(test)
test_git_diff_rows_truncate :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    strings.write_string(&b, "@@ -1,0 +1,6000 @@\n")
    for _ in 0 ..< 6000 {
        strings.write_string(&b, "+line\n")
    }

    rows := make([dynamic]Git_Diff_Row)
    defer git_diff_rows_destroy(&rows)
    git_parse_diff_rows(strings.to_string(b), &rows)

    testing.expect_value(t, len(rows), GIT_DIFF_MAX_ROWS + 1)
    last := rows[len(rows) - 1]
    testing.expect_value(t, last.kind, Git_Diff_Row_Kind.Meta)
    testing.expect_value(t, last.text, "diff truncated")
}

@(test)
test_git_quote_path :: proc(t: ^testing.T) {
    quoted, ok := git_quote_path("src/a b.txt")
    testing.expect(t, ok, "plain path refused")
    testing.expect_value(t, quoted, "\"src/a b.txt\"")

    when ODIN_OS == .Windows {
        _, quote_ok := git_quote_path("bad\"name.txt")
        testing.expect(t, !quote_ok, "embedded quote accepted on Windows")
    } else {
        escaped, esc_ok := git_quote_path("pay$day`s \"x\".txt")
        testing.expect(t, esc_ok, "POSIX path refused")
        testing.expect_value(t, escaped, "\"pay\\$day\\`s \\\"x\\\".txt\"")
    }
}

// Branch display: the plain name, a detached marker with the short hash, and
// nothing when HEAD cannot resolve (unborn repo).
@(test)
test_git_snapshot_branch :: proc(t: ^testing.T) {
    named := Git_Op_Job{branch_output = "master\n"}
    testing.expect_value(t, git_snapshot_branch(&named), "master")

    detached := Git_Op_Job{branch_output = "HEAD\n", head_output = "4a26066\n"}
    testing.expect_value(t, git_snapshot_branch(&detached), "detached @ 4a26066")

    unborn := Git_Op_Job{branch_output = "fatal: ambiguous argument 'HEAD'\n", branch_code = 128}
    testing.expect_value(t, git_snapshot_branch(&unborn), "")
}

@(private = "file")
expect_git_entry :: proc(t: ^testing.T, entry: Git_File_Entry, path: string, status: widgets.Git_Status, staged: bool, loc := #caller_location) {
    testing.expect_value(t, entry.path, path, loc = loc)
    testing.expect_value(t, entry.status, status, loc = loc)
    testing.expect_value(t, entry.staged, staged, loc = loc)
}

@(private = "file")
expect_diff_row :: proc(t: ^testing.T, row: Git_Diff_Row, kind: Git_Diff_Row_Kind, old_line, new_line: int, text: string, loc := #caller_location) {
    testing.expect_value(t, row.kind, kind, loc = loc)
    testing.expect_value(t, row.old_line, old_line, loc = loc)
    testing.expect_value(t, row.new_line, new_line, loc = loc)
    testing.expect_value(t, row.text, text, loc = loc)
}
