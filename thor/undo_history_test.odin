package thor

import "core:strings"
import "core:testing"

import "../textedit"

@(test)
test_undo_history_lists_branches_and_moves :: proc(t: ^testing.T) {
    thor := new(Thor)
    defer free(thor)
    defer thor_palette_destroy(thor)
    defer delete(thor.status_message)
    thor.open_files = make([dynamic]^Open_File)
    defer delete(thor.open_files)

    file := new(Open_File)
    file.path = strings.clone("w/a.txt")
    file.loaded = true
    textedit.init(&file.state)
    defer {
        textedit.destroy(&file.state)
        delete(file.path)
        free(file)
    }
    append(&thor.open_files, file)
    signal_set(&thor.active_file, 0)
    defer {
        thor_clear_undo_history(thor)
        delete(thor.undo_history_nodes)
    }

    textedit.insert_text(&file.state, "aa")
    textedit.insert_text(&file.state, "bb")
    textedit.undo(&file.state)
    textedit.insert_text(&file.state, "cc")

    thor_cmd_undo_history(thor)
    testing.expect(t, thor.palette_open)
    // The root, "aa", the older branch "bb", then "cc".
    testing.expect_value(t, len(thor.palette.pick_items), 4)
    testing.expect_value(t, thor.palette.selected, 3)
    testing.expect(t, strings.contains(thor.palette.pick_items[2].text, "bb"))
    testing.expect(t, strings.has_prefix(thor.palette.pick_items[2].text, "  "))

    thor.palette.pick_index_run(thor.palette.pick_data, 2)
    testing.expect_value(t, textedit.text(&file.state), "aabb")

    // A stale picker does not move the buffer.
    thor.palette.pick_index_run(thor.palette.pick_data, 0)
    testing.expect_value(t, textedit.text(&file.state), "aabb")
    testing.expect(t, thor.status_message_error)
}
