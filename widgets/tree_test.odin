package widgets

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import rl "vendor:raylib"

import "../ui"

// A unique path under the OS temp directory, with native separators. TEMP is
// Windows only; POSIX names it TMPDIR and leaves it unset on the CI runners.
@(private = "file")
tree_test_temp_path :: proc(name: string) -> string {
    base := os.get_env("TEMP", context.temp_allocator)
    when ODIN_OS != .Windows {
        if base == "" {
            base = os.get_env("TMPDIR", context.temp_allocator)
        }
        if base == "" {
            base = "/tmp"
        }
    }
    base = strings.trim_right(base, "/\\")
    joined, _ := filepath.join({base, fmt.tprintf("%s_%d", name, time.now()._nsec)}, context.temp_allocator)
    return joined
}

// A tree over a throwaway directory holding a.txt, b.txt, c.txt and sub/, laid
// out so row N sits at y = N * row_height. The caller destroys both.
@(private = "file")
tree_test_fixture :: proc(t: ^testing.T) -> (tree: ^Tree, root: string) {
    root = tree_test_temp_path("thor_tree_test")
    if err := os.make_directory(root); err != nil {
        testing.fail_now(t, fmt.tprintf("could not create temp dir %q: %v", root, err))
    }
    sub, _ := filepath.join({root, "sub"}, context.temp_allocator)
    _ = os.make_directory(sub)
    for name in ([]string {"a.txt", "b.txt", "c.txt"}) {
        path, _ := filepath.join({root, name}, context.temp_allocator)
        _ = os.write_entire_file(path, transmute([]byte) string("x"))
    }

    tree = tree_create("tree", root)
    tree_layout(&tree.widget, rl.Rectangle {x = 0, y = 0, width = 200, height = 400})
    return
}

@(private = "file")
tree_test_cleanup :: proc(tree: ^Tree, root: string) {
    tree_destroy(&tree.widget)
    _ = os.remove_all(root)
}

// Visible rows in draw order. tree_visible_rows is file-private, so this walks
// the same expanded-children path the widget does.
@(private = "file")
tree_test_rows :: proc(node: ^Tree_Node, rows: ^[dynamic]^Tree_Node) {
    for child in node.children {
        append(rows, child)
        if child.is_dir && child.expanded {
            tree_test_rows(child, rows)
        }
    }
}

@(private = "file")
tree_test_visible :: proc(tree: ^Tree) -> [dynamic]^Tree_Node {
    rows := make([dynamic]^Tree_Node, context.temp_allocator)
    tree_test_rows(tree.root, &rows)
    return rows
}

// Row centre for the Nth visible row, so a synthetic click lands on it.
@(private = "file")
tree_test_row_pos :: proc(tree: ^Tree, index: int) -> rl.Vector2 {
    return rl.Vector2 {10, tree.bounds.y + (cast(f32) index + 0.5) * tree.row_height - tree.scroll_y}
}

@(private = "file")
tree_test_click :: proc(tree: ^Tree, index: int, ctrl, shift: bool) {
    position := tree_test_row_pos(tree, index)
    down := ui.Event {
        kind = .Mouse_Down,
        mouse_position = position,
        mouse_button = .LEFT,
        ctrl = ctrl,
        shift = shift,
    }
    tree_handle_event(&tree.widget, nil, &down)
    up := ui.Event {
        kind = .Mouse_Up,
        mouse_position = position,
        mouse_button = .LEFT,
        ctrl = ctrl,
        shift = shift,
    }
    tree_handle_event(&tree.widget, nil, &up)
}

// Rows sort folders first, so the visible order is sub/, a.txt, b.txt, c.txt.
@(test)
test_tree_multi_select :: proc(t: ^testing.T) {
    tree, root := tree_test_fixture(t)
    defer tree_test_cleanup(tree, root)

    rows := tree_test_visible(tree)
    testing.expect_value(t, len(rows), 4)

    // A plain click selects one row and nothing else.
    tree_test_click(tree, 1, ctrl = false, shift = false)
    testing.expect_value(t, len(tree.multi_selected), 1)
    testing.expect_value(t, tree.selected_path, rows[1].path)

    // Ctrl-click adds a second row without disturbing the first.
    tree_test_click(tree, 3, ctrl = true, shift = false)
    testing.expect_value(t, len(tree.multi_selected), 2)
    testing.expect(t, rows[1].path in tree.multi_selected, "the first click stays selected")
    testing.expect(t, rows[3].path in tree.multi_selected, "ctrl-click adds to the selection")

    // Ctrl-clicking a selected row takes it back out.
    tree_test_click(tree, 3, ctrl = true, shift = false)
    testing.expect_value(t, len(tree.multi_selected), 1)
    testing.expect(t, rows[3].path not_in tree.multi_selected, "ctrl-click toggles a row off")

    // Shift-click ranges from the anchor, inclusive at both ends.
    tree_test_click(tree, 1, ctrl = false, shift = false)
    tree_test_click(tree, 3, ctrl = false, shift = true)
    testing.expect_value(t, len(tree.multi_selected), 3)
    for index in 1 ..= 3 {
        testing.expect(t, rows[index].path in tree.multi_selected, "the whole range is selected")
    }

    // A plain click afterwards collapses back to the one row.
    tree_test_click(tree, 0, ctrl = false, shift = false)
    testing.expect_value(t, len(tree.multi_selected), 1)
    testing.expect_value(t, tree.selected_path, rows[0].path)
}

// Ctrl/shift-click only adjusts the selection: the folder must not toggle open.
@(test)
test_tree_modified_click_does_not_expand :: proc(t: ^testing.T) {
    tree, root := tree_test_fixture(t)
    defer tree_test_cleanup(tree, root)

    folder := tree_test_visible(tree)[0]
    testing.expect(t, folder.is_dir, "folders sort ahead of files")

    tree_test_click(tree, 0, ctrl = true, shift = false)
    testing.expect(t, !folder.expanded, "ctrl-click selects without expanding")

    tree_test_click(tree, 0, ctrl = false, shift = false)
    testing.expect(t, folder.expanded, "a plain click still expands")
}

@(private = "file")
Tree_Test_Move :: struct {
    sources: [dynamic]string,
    target:  string,
}

@(private = "file")
tree_test_on_move :: proc(data: rawptr, src_path, dst_dir: string) {
    record := cast(^Tree_Test_Move) data
    append(&record.sources, src_path)
    record.target = dst_dir
}

// Dragging a row that belongs to a multi-selection carries the whole group.
@(test)
test_tree_drag_moves_whole_selection :: proc(t: ^testing.T) {
    tree, root := tree_test_fixture(t)
    defer tree_test_cleanup(tree, root)

    record: Tree_Test_Move
    defer delete(record.sources)
    tree_set_on_move(tree, tree_test_on_move, &record)

    rows := tree_test_visible(tree)
    folder := rows[0]

    // Select a.txt and b.txt, then press on a.txt and drag onto sub/.
    tree_test_click(tree, 1, ctrl = false, shift = false)
    tree_test_click(tree, 2, ctrl = true, shift = false)

    press := tree_test_row_pos(tree, 1)
    down := ui.Event {kind = .Mouse_Down, mouse_position = press, mouse_button = .LEFT}
    tree_handle_event(&tree.widget, nil, &down)

    drop := tree_test_row_pos(tree, 0)
    move := ui.Event {kind = .Mouse_Move, mouse_position = drop}
    tree_handle_event(&tree.widget, nil, &move)
    testing.expect(t, tree.dragging, "moving past the threshold starts a drag")
    testing.expect_value(t, tree.drag_target_path, folder.path)

    up := ui.Event {kind = .Mouse_Up, mouse_position = drop, mouse_button = .LEFT}
    tree_handle_event(&tree.widget, nil, &up)

    testing.expect_value(t, len(record.sources), 2)
    testing.expect_value(t, record.target, folder.path)
    testing.expect(t, !folder.expanded, "a drop is not a click, so the folder stays shut")
}

@(private = "file")
tree_test_on_delete :: proc(data: rawptr, path: string) {
    record := cast(^string) data
    record^ = path
}

// Delete reports the caret row, and the caret row is always part of the
// selection: that invariant is what lets the owner widen it to the whole group
// (see thor_tree_delete).
@(test)
test_tree_delete_reports_a_selected_row :: proc(t: ^testing.T) {
    tree, root := tree_test_fixture(t)
    defer tree_test_cleanup(tree, root)

    deleted: string
    tree_set_on_delete(tree, tree_test_on_delete, &deleted)

    rows := tree_test_visible(tree)
    tree_test_click(tree, 1, ctrl = false, shift = false)
    tree_test_click(tree, 2, ctrl = true, shift = false)
    testing.expect_value(t, len(tree.multi_selected), 2)

    key := ui.Event {kind = .Key_Press, key = .DELETE}
    tree_handle_event(&tree.widget, nil, &key)

    testing.expect_value(t, deleted, rows[2].path)
    testing.expect(t, deleted in tree.multi_selected, "the reported row is part of the selection")
    testing.expect_value(t, len(tree_selection(tree)), 2)
}

@(private = "file")
Tree_Test_Drag_Out :: struct {
    count:    int,
    position: rl.Vector2,
}

@(private = "file")
tree_test_on_drag_out :: proc(data: rawptr, paths: []string, position: rl.Vector2) {
    record := cast(^Tree_Test_Drag_Out) data
    record.count = len(paths)
    record.position = position
}

// Releasing a drag outside the panel hands the rows to the owner instead of
// moving them, which is how a row reaches the editor.
@(test)
test_tree_drag_out_of_panel :: proc(t: ^testing.T) {
    tree, root := tree_test_fixture(t)
    defer tree_test_cleanup(tree, root)

    moves: Tree_Test_Move
    defer delete(moves.sources)
    tree_set_on_move(tree, tree_test_on_move, &moves)

    record: Tree_Test_Drag_Out
    tree_set_on_drag_out(tree, tree_test_on_drag_out, &record)

    press := tree_test_row_pos(tree, 1)
    down := ui.Event {kind = .Mouse_Down, mouse_position = press, mouse_button = .LEFT}
    tree_handle_event(&tree.widget, nil, &down)

    outside := rl.Vector2 {tree.bounds.x + tree.bounds.width + 120, press.y}
    move := ui.Event {kind = .Mouse_Move, mouse_position = outside}
    tree_handle_event(&tree.widget, nil, &move)
    testing.expect_value(t, tree.drag_target_path, "")

    up := ui.Event {kind = .Mouse_Up, mouse_position = outside, mouse_button = .LEFT}
    tree_handle_event(&tree.widget, nil, &up)

    testing.expect_value(t, record.count, 1)
    testing.expect_value(t, record.position, outside)
    testing.expect_value(t, len(moves.sources), 0)
}

// A folder can never be dropped into itself or into one of its own children.
@(test)
test_tree_drop_target_rejects_self :: proc(t: ^testing.T) {
    tree, root := tree_test_fixture(t)
    defer tree_test_cleanup(tree, root)

    folder := tree_test_visible(tree)[0]
    press := tree_test_row_pos(tree, 0)
    down := ui.Event {kind = .Mouse_Down, mouse_position = press, mouse_button = .LEFT}
    tree_handle_event(&tree.widget, nil, &down)

    // Same row, far enough sideways to count as a drag.
    drift := rl.Vector2 {press.x + 40, press.y}
    move := ui.Event {kind = .Mouse_Move, mouse_position = drift}
    tree_handle_event(&tree.widget, nil, &move)

    testing.expect(t, tree.dragging, "the sideways drift starts a drag")
    testing.expect_value(t, tree.drag_target_path, "")
    testing.expect(t, !folder.expanded, "the drag never expanded the folder")
}
