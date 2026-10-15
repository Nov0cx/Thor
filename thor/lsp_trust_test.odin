package thor

import "core:testing"

// A grant names one workspace and one file: another folder, or the same folder
// with a changed file, is not allowed by it.
@(test)
test_lsp_grant_keys_on_workspace_and_digest :: proc(t: ^testing.T) {
    before := thor_lsp_digest(transmute([]byte)string(`{"servers":[{"id":"a","command":["good"]}]}`))
    after := thor_lsp_digest(transmute([]byte)string(`{"servers":[{"id":"a","command":["evil"]}]}`))
    testing.expect(t, before != after, "two files share a digest")
    testing.expect_value(t, len(before), 64)

    rows := make([dynamic]Lsp_Grant, context.temp_allocator)
    testing.expect(t, !thor_lsp_find_grant(rows[:], "work/repo", before), "an empty list allowed a file")

    thor_lsp_set_grant(&rows, "work/repo", before)
    testing.expect(t, thor_lsp_find_grant(rows[:], "work/repo", before), "the grant was not found")
    when ODIN_OS == .Windows {
        testing.expect(t, thor_lsp_find_grant(rows[:], "Work/Repo", before), "the folder match is case-sensitive")
    } else {
        testing.expect(t, !thor_lsp_find_grant(rows[:], "Work/Repo", before), "the folder match ignores case")
    }
    testing.expect(t, !thor_lsp_find_grant(rows[:], "work/other", before), "a grant reached another folder")
    testing.expect(t, !thor_lsp_find_grant(rows[:], "work/repo", after), "a changed file stayed allowed")
    testing.expect(t, !thor_lsp_find_grant(rows[:], "", before), "no workspace was allowed")

    // A new answer replaces the old one for the folder.
    thor_lsp_set_grant(&rows, "work/repo", after)
    testing.expect_value(t, len(rows), 1)
    testing.expect(t, thor_lsp_find_grant(rows[:], "work/repo", after), "the new grant was not found")
    testing.expect(t, !thor_lsp_find_grant(rows[:], "work/repo", before), "the old file stayed allowed")
}
