package thor

import "core:testing"

import "../editview"
import "../textedit"

@(private = "file")
problems_file :: proc(path, text: string, diags: []editview.Diagnostic) -> ^Open_File {
    file := new(Open_File)
    file.path = path
    file.loaded = true
    textedit.init(&file.state)
    textedit.set_text(&file.state, text)
    for d in diags {
        append(&file.diagnostics, d)
    }
    file.diagnostics_revision = file.state.revision
    return file
}

@(private = "file")
problems_file_destroy :: proc(file: ^Open_File) {
    delete(file.diagnostics)
    delete(file.merged_diagnostics)
    delete(file.syntax_diagnostics)
    textedit.destroy(&file.state)
    free(file)
}

// Groups follow the path, rows follow the line, and files without problems are left out.
@(test)
test_problem_groups_sorted_and_counted :: proc(t: ^testing.T) {
    thor: Thor
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    b := problems_file("pkg/b.odin", "x\ny\n", {
        {start = 2, line = 1, severity = .Warning, message = "late"},
        {start = 0, line = 0, severity = .Error, message = "early", code = "id"},
    })
    defer problems_file_destroy(b)
    a := problems_file("pkg/a.odin", "x\n", {{start = 0, line = 0, severity = .Hint, message = "hint"}})
    defer problems_file_destroy(a)
    clean := problems_file("pkg/c.odin", "x\n", nil)
    defer problems_file_destroy(clean)
    append(&thor.open_files, b, a, clean)

    groups := thor_problem_groups(&thor)
    testing.expect_value(t, len(groups), 2)
    testing.expect_value(t, groups[0].path, "pkg/a.odin")
    testing.expect_value(t, groups[1].path, "pkg/b.odin")
    testing.expect_value(t, groups[1].problems[0].message, "early")
    testing.expect_value(t, groups[1].problems[0].code, "id")
    testing.expect_value(t, groups[1].problems[1].offset, 2)
    testing.expect_value(t, problem_count(groups, .Error), 1)
    testing.expect_value(t, problem_count(groups, .Warning), 1)
    testing.expect_value(t, problem_count(groups, .Hint), 1)
}

@(test)
test_problem_display_path :: proc(t: ^testing.T) {
    thor: Thor
    testing.expect_value(t, problem_display_path(&thor, "ws/a.odin"), "ws/a.odin")
    thor.workspace_prefix = "ws/"
    testing.expect_value(t, problem_display_path(&thor, "ws/src/a.odin"), "src/a.odin")
    testing.expect_value(t, problem_display_path(&thor, "other/a.odin"), "other/a.odin")
}

// The command toggles the panel and hands focus back to where it came from.
@(test)
test_problems_toggle_restores_focus :: proc(t: ^testing.T) {
    thor: Thor
    thor.focus_owner = "pane1"
    thor_cmd_open_problems(&thor)
    testing.expect(t, thor.problems_open)
    testing.expect(t, thor.problems.focus_pending)
    thor_cmd_open_problems(&thor)
    testing.expect(t, !thor.problems_open)
    testing.expect_value(t, thor.focus_request, "pane1")
}
