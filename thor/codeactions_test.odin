package thor

import "core:strings"
import "core:testing"

import "../lang"
import "../textedit"

// A Resolve_Action result lands like a rename: its edits are applied to the buffer the
// offer was made against, and a refusal reports the backend's reason.
@(test)
test_resolved_action_applies_edits :: proc(t: ^testing.T) {
    PATH :: "w/app/main.odin"

    thor := new(Thor)
    defer free(thor)
    defer thor_clear_edit_undo(thor)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)
    defer delete(thor.status_message)
    defer delete(thor.resolve_action_title)

    file := new(Open_File)
    file.path = PATH
    file.loaded = true
    textedit.init(&file.state)
    textedit.set_text(&file.state, "x := a + b\n")
    defer {
        textedit.destroy(&file.state)
        free(file)
    }
    append(&thor.open_files, file)
    thor.code_action_path = PATH
    thor.resolve_action_request_id = 7
    thor.resolve_action_title = strings.clone("Extract variable")

    edits := make([dynamic]lang.Text_Edit, context.temp_allocator)
    append(&edits, lang.Text_Edit{path = PATH, start = 5, end = 10, old_text = "a + b", new_text = "sum"})
    res := lang.Result{id = 7, ok = true, revision = file.state.revision, edits = edits}
    thor_apply_resolved_action(thor, &res)
    testing.expect_value(t, textedit.text(&file.state), "x := sum\n")
    testing.expect_value(t, thor.resolve_action_request_id, 0)

    thor.resolve_action_request_id = 8
    failed := lang.Result{id = 8, ok = false, message = {text = "the selection is not an expression"}}
    thor_apply_resolved_action(thor, &failed)
    testing.expect(t, strings.contains(thor.status_message, "the selection is not an expression"), thor.status_message)
    testing.expect_value(t, textedit.text(&file.state), "x := sum\n")
}
