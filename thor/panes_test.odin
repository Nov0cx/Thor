package thor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../editview"
import "../setting"
import ui "../vendor/loom/loom"

// A Thor with `n` open files that never load, enough for the pane logic.
@(private = "file")
pane_test_thor :: proc(n: int) -> ^Thor {
    thor := new(Thor)
    thor.active_file = make_signal(-1)
    thor.open_files = make([dynamic]^Open_File)
    thor.pane_file = -1
    thor.last_multi_layout = .Columns2
    thor_pane_reset_weights(thor)
    for i in 0 ..< n {
        file := new(Open_File)
        file.name = fmt.aprintf("f%d.txt", i)
        append(&thor.open_files, file)
    }
    if n > 0 {
        thor.pane_file[0] = 0
    }
    return thor
}

@(private = "file")
pane_test_destroy :: proc(thor: ^Thor) {
    for file in thor.open_files {
        delete(file.name)
        free(file)
    }
    delete(thor.open_files)
    delete(thor.status_message)
    thor_pane_pick_cancel(thor)
    for &editor in thor.editors {
        editview.editor_destroy(&editor)
    }
    free(thor)
}

@(test)
test_layout_table :: proc(t: ^testing.T) {
    testing.expect_value(t, layout_pane_count(.Single), 1)
    testing.expect_value(t, layout_pane_count(.Rows2), 2)
    testing.expect_value(t, layout_pane_count(.Main_Stack), 3)
    testing.expect_value(t, layout_pane_count(.Grid4), 4)
    testing.expect_value(t, layout_pane_count(.Grid6), MAX_PANES)
    testing.expect_value(t, layout_columns(.Rows2), 1)
    testing.expect_value(t, layout_columns(.Grid6), 3)
    // Panes number down each column, then across.
    testing.expect_value(t, layout_first_pane(.Main_Stack, 1), 1)
    testing.expect_value(t, layout_first_pane(.Grid6, 2), 4)
    for layout in Pane_Layout {
        testing.expect(t, layout_pane_count(layout) <= MAX_PANES)
        back, ok := layout_from_name(LAYOUT_NAMES[layout])
        testing.expect(t, ok)
        testing.expect_value(t, back, layout)
        testing.expect(t, layout_pane_count(layout_for_count(layout_pane_count(layout))) >= layout_pane_count(layout))
    }
    _, ok := layout_from_name("columns9")
    testing.expect(t, !ok)
    testing.expect_value(t, thor_pane_of_key("pane5"), 5)
    testing.expect_value(t, thor_pane_of_key("explorer"), -1)
}

// New panes open on files no pane shows; cut panes let go of theirs and take
// the focus with them.
@(test)
test_set_layout_grows_and_shrinks :: proc(t: ^testing.T) {
    thor := pane_test_thor(3)
    defer pane_test_destroy(thor)

    testing.expect(t, thor_set_layout(thor, .Grid4))
    testing.expect_value(t, thor_pane_count(thor), 4)
    testing.expect_value(t, thor.pane_file[1], 1)
    testing.expect_value(t, thor.pane_file[2], 2)
    // Every file is shown, so the last pane mirrors pane 1.
    testing.expect_value(t, thor.pane_file[3], 0)
    testing.expect_value(t, thor.last_multi_layout, Pane_Layout.Grid4)

    thor_focus_pane(thor, 3)
    testing.expect_value(t, thor.active_pane, 3)
    testing.expect(t, thor_set_layout(thor, .Columns2))
    testing.expect_value(t, thor.active_pane, 1)
    testing.expect_value(t, thor.focus_request, "pane1")
    testing.expect_value(t, thor.pane_file[2], -1)
    testing.expect_value(t, thor.pane_file[3], -1)
    testing.expect_value(t, thor.editors[2].state, nil)
}

// A file sent past the last pane grows the layout to hold it.
@(test)
test_file_to_pane_grows_layout :: proc(t: ^testing.T) {
    thor := pane_test_thor(2)
    defer pane_test_destroy(thor)

    thor_file_to_pane(thor, 2)
    testing.expect_value(t, thor.layout, Pane_Layout.Columns3)
    testing.expect_value(t, thor.active_pane, 2)
    testing.expect_value(t, thor.pane_file[2], 0)

    thor_file_to_pane(thor, 4)
    testing.expect_value(t, thor.layout, Pane_Layout.Grid6)
    testing.expect_value(t, thor.pane_file[4], 0)
}

// The side pane is the next one, and from a single pane the remembered layout.
@(test)
test_side_pane :: proc(t: ^testing.T) {
    thor := pane_test_thor(2)
    defer pane_test_destroy(thor)

    thor.last_multi_layout = .Rows2
    testing.expect_value(t, thor_side_pane(thor), 1)
    testing.expect_value(t, thor.layout, Pane_Layout.Rows2)
    thor_focus_pane(thor, 1)
    testing.expect_value(t, thor_side_pane(thor), 0)

    thor_toggle_split(thor)
    testing.expect_value(t, thor.layout, Pane_Layout.Single)
    thor_toggle_split(thor)
    testing.expect_value(t, thor.layout, Pane_Layout.Rows2)
    testing.expect_value(t, thor.active_pane, 1)
}

// A layout whose panes would fall under the minimum size is refused.
@(test)
test_layout_needs_room :: proc(t: ^testing.T) {
    thor := pane_test_thor(1)
    defer pane_test_destroy(thor)

    thor.panes_area = ui.Rect{0, 0, 600, 800}
    testing.expect(t, thor_layout_fits(thor, .Columns2))
    testing.expect(t, !thor_layout_fits(thor, .Columns3))
    testing.expect(t, !thor_set_layout(thor, .Grid6))
    testing.expect_value(t, thor.layout, Pane_Layout.Single)
    // Cycling skips what does not fit.
    thor_cycle_layout(thor, 1)
    testing.expect_value(t, thor.layout, Pane_Layout.Columns2)
    thor_cycle_layout(thor, 1)
    testing.expect_value(t, thor.layout, Pane_Layout.Rows2)
}

@(test)
test_pane_weights :: proc(t: ^testing.T) {
    weights := [3]f32{1, 1, 1}
    thor_pane_drag_weights(weights[:], 0, {1, 1}, 150, 900)
    testing.expect_value(t, weights[0], f32(1.5))
    testing.expect_value(t, weights[1], f32(0.5))
    testing.expect_value(t, weights[2], f32(1))
    // A drag past the neighbour stops at its minimum share.
    thor_pane_drag_weights(weights[:], 0, {1.5, 0.5}, 9000, 900)
    testing.expect(t, abs(weights[1] - PANE_MIN_WEIGHT * 3) < 1e-4)

    sizes := thor_pane_sizes(weights[:], 3, 1000)
    testing.expect_value(t, sizes[0] + sizes[1] + sizes[2], f32(1000))
}

@(test)
test_digit_bind_matches_keypad :: proc(t: ^testing.T) {
    bind := setting.Keybind{key = .Num_3, mods = {.Ctrl}}
    testing.expect(t, thor_digit_bind_matches(bind, {key = .Pad_3, mods = {.Ctrl}}))
    testing.expect(t, thor_digit_bind_matches(bind, {key = .Num_3, mods = {.Ctrl}}))
    testing.expect(t, !thor_digit_bind_matches(bind, {key = .Pad_3, mods = {.Ctrl, .Shift}}))
    testing.expect(t, !thor_digit_bind_matches(bind, {key = .Num_4, mods = {.Ctrl}}))
}

// A session written before layouts restores its split as two columns.
@(test)
test_restore_old_split_session :: proc(t: ^testing.T) {
    thor := restore_pane_session(t, "thor_panes_old_test", `"split_visible":true,"split_ratio":0.3,"active_pane":1`)
    if thor == nil {
        return
    }
    defer pane_test_destroy(thor)
    testing.expect_value(t, thor.layout, Pane_Layout.Columns2)
    testing.expect_value(t, thor.col_weight[0], f32(0.3))
    testing.expect_value(t, thor.active_pane, 1)
}

@(test)
test_restore_layout_session :: proc(t: ^testing.T) {
    thor := restore_pane_session(
        t,
        "thor_panes_new_test",
        `"layout":"grid6","pane_files":[],"col_weight":[2,1,1],"row_weight":[[1,1],[1,3],[1,1]],"active_pane":4`,
    )
    if thor == nil {
        return
    }
    defer pane_test_destroy(thor)
    testing.expect_value(t, thor.layout, Pane_Layout.Grid6)
    testing.expect_value(t, thor.col_weight[0], f32(2))
    testing.expect_value(t, thor.row_weight[1][1], f32(3))
    testing.expect_value(t, thor.active_pane, 4)
    testing.expect_value(t, thor.focus_request, "pane4")
}

// Restores a session with no files and the given extra fields.
@(private = "file")
restore_pane_session :: proc(t: ^testing.T, workspace, fields: string) -> ^Thor {
    if !os.is_dir(workspace) && os.make_directory(workspace) != nil {
        testing.fail_now(t, "could not create test workspace")
    }
    defer os.remove(workspace)
    if !os.is_dir("sessions") && os.make_directory("sessions") != nil {
        testing.fail_now(t, "could not create sessions dir")
    }
    data := fmt.tprintf(`{{"workspace":%q,"open_files":[],"active_file":-1,%s}}`, workspace, fields)
    path := strings.concatenate({"sessions/", thor_path_key(workspace), ".json"}, context.temp_allocator)
    if os.write_entire_file(path, transmute([]u8)data) != nil {
        testing.fail_now(t, "could not write the test session")
    }
    defer os.remove(path)

    thor := pane_test_thor(0)
    thor.zombie_files = make([dynamic]^Open_File)
    defer delete(thor.zombie_files)
    thor.workspace_dir = workspace
    thor_restore_session(thor)
    delete(thor.dock_layout)
    thor.dock_layout = ""
    return thor
}
