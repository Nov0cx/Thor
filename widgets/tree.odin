package widgets

import "core:os"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

import "../ui"

Tree_Open_Proc :: #type proc(data: rawptr, path: string)
// Fired when Delete is pressed on a selected file; the owner confirms and
// performs the removal (see thor_tree_delete).
Tree_Delete_Proc :: #type proc(data: rawptr, path: string)
// Fired when a row is dropped onto a folder (or the workspace root); the
// owner renames the file on disk into dst_dir (see thor_tree_move).
Tree_Move_Proc :: #type proc(data: rawptr, src_path: string, dst_dir: string)

// Pixel drift from the press position before a held row counts as a drag
// rather than a click.
@(private = "file")
TREE_DRAG_THRESHOLD :: 4

// Git working-tree status for a path, resolved by the owner. Directories report
// an aggregate (Modified / Conflict) so the folder name can be tinted too.
Git_Status :: enum u8 {
    None,
    Modified,
    Added,
    Untracked,
    Deleted,
    Renamed,
    Conflict,
    Submodule,
}

Tree_Status_Proc :: #type proc(data: rawptr, path: string, is_dir: bool) -> Git_Status

Tree_Node :: struct {
    name:     string, // owned
    path:     string, // owned, full path
    is_dir:   bool,
    expanded: bool,
    loaded:   bool, // directory contents read from disk
    parent:   ^Tree_Node, // nil for the root; used for keyboard navigation
    children: [dynamic]^Tree_Node,
}

// Directory tree fed lazily from the filesystem; a folder reads on first open.
// Rows are drawn directly (no child widgets), so expanding costs nothing.
Tree :: struct {
    using widget: ui.Widget,
    root:             ^Tree_Node,
    scroll_y:         f32,
    font_size:        i32,
    icon_size:        i32,
    row_height:       f32,
    indent:           f32,
    selected_path:    string, // owned clone
    on_open:          Tree_Open_Proc,
    open_data:        rawptr,
    on_delete:        Tree_Delete_Proc,
    delete_data:      rawptr,
    // Right-click opens a context menu supplied by the owner.
    on_context_menu:  Context_Menu_Proc,
    context_menu_data: rawptr,
    // Left-button drag-to-move state. drag_source_path is set on Mouse_Down and
    // cleared on Mouse_Up; `dragging` only flips true once the press crosses
    // TREE_DRAG_THRESHOLD, so an ordinary click still expands/opens the row.
    drag_source_path: string, // owned; "" when no row is pressed
    drag_press_pos:   rl.Vector2,
    dragging:         bool,
    drag_target_path: string, // owned; "" when the current hover isn't a valid drop
    on_move:          Tree_Move_Proc,
    move_data:        rawptr,
    drop_target_color: rl.Color,
    // Owner hook mapping a path to its git status (nil = no git highlighting).
    status_proc:      Tree_Status_Proc,
    status_data:      rawptr,
    text_color:       rl.Color,
    dir_color:        rl.Color,
    icon_color:       rl.Color,
    chevron_color:    rl.Color,
    hover_color:      rl.Color,
    selected_color:   rl.Color,
    background_color: rl.Color,
    git_modified_color: rl.Color,
    git_added_color:    rl.Color,
    git_deleted_color:  rl.Color,
    git_conflict_color: rl.Color,
    git_submodule_color: rl.Color,
}

@(private = "file")
Tree_Row :: struct {
    node:  ^Tree_Node,
    depth: i32,
}

tree_vtable := ui.Widget_VTable {
    layout = tree_layout,
    handle_event = tree_handle_event,
    draw = tree_draw,
    destroy = tree_destroy,
}

tree_create :: proc(id, root_path: string) -> ^Tree {
    tree := new(Tree)
    ui.widget_init(&tree.widget, id, tree_vtable)
    tree.font_size = 17
    tree.icon_size = 16
    tree.row_height = 26
    tree.indent = 16
    tree.text_color = rl.Color {200, 205, 215, 255}
    tree.dir_color = rl.Color {225, 228, 232, 255}
    tree.icon_color = rl.Color {130, 170, 255, 255}
    tree.chevron_color = rl.Color {120, 128, 160, 255}
    tree.hover_color = rl.Color {255, 255, 255, 14}
    tree.selected_color = rl.Color {255, 255, 255, 26}
    tree.background_color = rl.Color {0, 0, 0, 0}
    tree.git_modified_color = rl.Color {229, 192, 123, 255} // amber
    tree.git_added_color = rl.Color {152, 195, 121, 255}    // green
    tree.git_deleted_color = rl.Color {224, 108, 117, 255}  // red
    tree.git_conflict_color = rl.Color {224, 108, 117, 255} // red
    tree.git_submodule_color = rl.Color {199, 146, 234, 255} // purple
    tree.drop_target_color = rl.Color {130, 170, 255, 255}
    tree.min_size = rl.Vector2 {0, 120}

    tree.root = new(Tree_Node)
    tree.root.name = strings.clone(root_path)
    tree.root.path = strings.clone(root_path)
    tree.root.is_dir = true
    tree.root.expanded = true
    tree_load_children(tree.root)

    return tree
}

// Repoints the tree at another directory: the old nodes, selection and scroll
// position go with the folder they belonged to.
tree_set_root :: proc(tree: ^Tree, root_path: string) {
    tree_node_destroy(tree.root)
    tree.root = new(Tree_Node)
    tree.root.name = strings.clone(root_path)
    tree.root.path = strings.clone(root_path)
    tree.root.is_dir = true
    tree.root.expanded = true
    tree_load_children(tree.root)

    delete(tree.selected_path)
    tree.selected_path = ""
    tree.scroll_y = 0

    delete(tree.drag_source_path)
    tree.drag_source_path = ""
    delete(tree.drag_target_path)
    tree.drag_target_path = ""
    tree.dragging = false
}

tree_set_colors :: proc(tree: ^Tree, text, dir, icon, chevron, hover, selected, background: rl.Color) -> ^Tree {
    tree.text_color = text
    tree.dir_color = dir
    tree.icon_color = icon
    tree.chevron_color = chevron
    tree.hover_color = hover
    tree.selected_color = selected
    tree.background_color = background
    return tree
}

tree_set_on_open :: proc(tree: ^Tree, on_open: Tree_Open_Proc, data: rawptr) -> ^Tree {
    tree.on_open = on_open
    tree.open_data = data
    return tree
}

tree_set_on_context_menu :: proc(tree: ^Tree, on_context_menu: Context_Menu_Proc, data: rawptr) {
    tree.on_context_menu = on_context_menu
    tree.context_menu_data = data
}

tree_set_on_delete :: proc(tree: ^Tree, on_delete: Tree_Delete_Proc, data: rawptr) {
    tree.on_delete = on_delete
    tree.delete_data = data
}

tree_set_on_move :: proc(tree: ^Tree, on_move: Tree_Move_Proc, data: rawptr) {
    tree.on_move = on_move
    tree.move_data = data
}

// Enables git status highlighting: `status_proc` maps a path to its status.
tree_set_git :: proc(tree: ^Tree, status_proc: Tree_Status_Proc, data: rawptr) {
    tree.status_proc = status_proc
    tree.status_data = data
}

tree_set_git_colors :: proc(tree: ^Tree, modified, added, deleted, conflict, submodule: rl.Color) {
    tree.git_modified_color = modified
    tree.git_added_color = added
    tree.git_deleted_color = deleted
    tree.git_conflict_color = conflict
    tree.git_submodule_color = submodule
}

@(private = "file")
tree_status_color :: proc(tree: ^Tree, status: Git_Status) -> rl.Color {
    switch status {
    case .None:                return tree.text_color
    case .Modified, .Renamed:  return tree.git_modified_color
    case .Added, .Untracked:   return tree.git_added_color
    case .Deleted:             return tree.git_deleted_color
    case .Conflict:            return tree.git_conflict_color
    case .Submodule:           return tree.git_submodule_color
    }
    return tree.text_color
}

// Single-letter badge drawn at the right of a file row (VS Code-style).
@(private = "file")
tree_status_letter :: proc(status: Git_Status) -> string {
    switch status {
    case .None:      return ""
    case .Modified:  return "M"
    case .Added:     return "A"
    case .Untracked: return "U"
    case .Deleted:   return "D"
    case .Renamed:   return "R"
    case .Conflict:  return "!"
    case .Submodule: return "S"
    }
    return ""
}

// Full path of the node under `position`, or "" when the click is below the
// last row. The returned string is borrowed from the node (owned by the tree).
tree_path_at :: proc(tree: ^Tree, position: rl.Vector2) -> string {
    index := cast(int) ((position.y - tree.bounds.y + tree.scroll_y) / tree.row_height)
    rows := tree_visible_rows(tree)
    if index < 0 || index >= len(rows) {
        return ""
    }
    return rows[index].node.path
}

// True when `path` is `ancestor` itself or lives somewhere inside it.
// Case-insensitive and treats '/' and '\\' as equivalent since tree paths come
// straight from os.read_dir's fullpath without being canonicalized.
@(private = "file")
tree_path_equal_or_within :: proc(path, ancestor: string) -> bool {
    if len(path) < len(ancestor) {
        return false
    }
    for i in 0 ..< len(ancestor) {
        pb := path[i]
        ab := ancestor[i]
        if pb == '/' {
            pb = '\\'
        }
        if ab == '/' {
            ab = '\\'
        }
        if pb >= 'A' && pb <= 'Z' {
            pb += 32
        }
        if ab >= 'A' && ab <= 'Z' {
            ab += 32
        }
        if pb != ab {
            return false
        }
    }
    if len(path) == len(ancestor) {
        return true
    }
    next := path[len(ancestor)]
    return next == '/' || next == '\\'
}

// Folder a drop at `position` would land in: the hovered folder, the hovered
// file's parent, or the workspace root when the cursor is over empty space.
@(private = "file")
tree_drop_target_at :: proc(tree: ^Tree, position: rl.Vector2) -> string {
    index := cast(int) ((position.y - tree.bounds.y + tree.scroll_y) / tree.row_height)
    rows := tree_visible_rows(tree)
    if index < 0 || index >= len(rows) {
        return tree.root.path
    }
    node := rows[index].node
    if node.is_dir {
        return node.path
    }
    if node.parent != nil {
        return node.parent.path
    }
    return tree.root.path
}

@(private = "file")
tree_node_less :: proc(a, b: ^Tree_Node) -> bool {
    if a.is_dir != b.is_dir {
        return a.is_dir
    }

    a_name := a.name
    b_name := b.name
    for len(a_name) > 0 && len(b_name) > 0 {
        a_byte := a_name[0]
        b_byte := b_name[0]
        if a_byte >= 'A' && a_byte <= 'Z' {
            a_byte += 32
        }
        if b_byte >= 'A' && b_byte <= 'Z' {
            b_byte += 32
        }
        if a_byte != b_byte {
            return a_byte < b_byte
        }
        a_name = a_name[1:]
        b_name = b_name[1:]
    }
    return len(a_name) < len(b_name)
}

@(private = "file")
tree_load_children :: proc(node: ^Tree_Node) {
    node.loaded = true

    handle, open_err := os.open(node.path)
    if open_err != nil {
        return
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        return
    }

    for info in infos {
        if info.name == ".git" {
            continue
        }
        child := new(Tree_Node)
        child.name = strings.clone(info.name)
        child.path = strings.clone(info.fullpath)
        child.is_dir = info.type == .Directory
        child.parent = node
        append(&node.children, child)
    }

    slice.sort_by(node.children[:], tree_node_less)
}

@(private = "file")
tree_node_destroy :: proc(node: ^Tree_Node) {
    for child in node.children {
        tree_node_destroy(child)
    }
    delete(node.children)
    delete(node.name)
    delete(node.path)
    free(node)
}

// Re-reads a directory level from disk, keeping expansion state of
// subdirectories that still exist.
tree_refresh :: proc(tree: ^Tree) {
    expanded := make(map[string]bool, context.temp_allocator)
    tree_collect_expanded(tree.root, &expanded)

    for child in tree.root.children {
        tree_node_destroy(child)
    }
    clear(&tree.root.children)
    tree_load_children(tree.root)
    tree_apply_expanded(tree.root, &expanded)
}

@(private = "file")
tree_collect_expanded :: proc(node: ^Tree_Node, expanded: ^map[string]bool) {
    for child in node.children {
        if child.is_dir && child.expanded {
            expanded[strings.clone(child.path, context.temp_allocator)] = true
            tree_collect_expanded(child, expanded)
        }
    }
}

@(private = "file")
tree_apply_expanded :: proc(node: ^Tree_Node, expanded: ^map[string]bool) {
    for child in node.children {
        if child.is_dir && child.path in expanded {
            child.expanded = true
            if !child.loaded {
                tree_load_children(child)
            }
            tree_apply_expanded(child, expanded)
        }
    }
}

@(private = "file")
tree_visible_rows :: proc(tree: ^Tree, allocator := context.temp_allocator) -> [dynamic]Tree_Row {
    rows := make([dynamic]Tree_Row, allocator)
    tree_collect_rows(tree.root, 0, &rows)
    return rows
}

@(private = "file")
tree_collect_rows :: proc(node: ^Tree_Node, depth: i32, rows: ^[dynamic]Tree_Row) {
    for child in node.children {
        append(rows, Tree_Row {node = child, depth = depth})
        if child.is_dir && child.expanded {
            tree_collect_rows(child, depth + 1, rows)
        }
    }
}

tree_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    tree := cast(^Tree) widget
    tree.bounds = bounds
    tree_clamp_scroll(tree)
}

@(private = "file")
tree_clamp_scroll :: proc(tree: ^Tree) {
    rows := tree_visible_rows(tree)
    content_height := cast(f32) len(rows) * tree.row_height
    max_scroll := content_height - tree.bounds.height
    if max_scroll < 0 {
        max_scroll = 0
    }
    tree.scroll_y = clamp(tree.scroll_y, 0, max_scroll)
}

tree_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    tree := cast(^Tree) widget

    #partial switch event.kind {
    case .Key_Press:
        return tree_handle_key(tree, event)
    case .Scroll:
        tree.scroll_y -= event.wheel_delta * tree.row_height * 2
        tree_clamp_scroll(tree)
        return true
    case .Mouse_Down:
        index := cast(int) ((event.mouse_position.y - tree.bounds.y + tree.scroll_y) / tree.row_height)
        rows := tree_visible_rows(tree)
        if index < 0 || index >= len(rows) {
            // Right-click on empty space still opens the menu (workspace root).
            if event.mouse_button == .RIGHT && tree.on_context_menu != nil {
                tree.on_context_menu(tree.context_menu_data, event.mouse_position)
            }
            return true
        }

        node := rows[index].node
        delete(tree.selected_path)
        tree.selected_path = strings.clone(node.path)

        // Right-click selects the row but opens the menu instead of toggling.
        if event.mouse_button == .RIGHT {
            if tree.on_context_menu != nil {
                tree.on_context_menu(tree.context_menu_data, event.mouse_position)
            }
            return true
        }

        // Left button: arm a potential drag on this row instead of acting
        // immediately. Mouse_Up runs the expand/open/move behavior once it's
        // clear whether the press turned into a drag.
        delete(tree.drag_source_path)
        tree.drag_source_path = strings.clone(node.path)
        tree.drag_press_pos = event.mouse_position
        tree.dragging = false
        delete(tree.drag_target_path)
        tree.drag_target_path = ""
        return true

    case .Mouse_Move:
        if tree.drag_source_path == "" {
            return false
        }

        dx := event.mouse_position.x - tree.drag_press_pos.x
        dy := event.mouse_position.y - tree.drag_press_pos.y
        if !tree.dragging {
            if dx * dx + dy * dy < TREE_DRAG_THRESHOLD * TREE_DRAG_THRESHOLD {
                return true
            }
            tree.dragging = true
        }

        target := tree_drop_target_at(tree, event.mouse_position)
        if tree_path_equal_or_within(target, tree.drag_source_path) {
            target = ""
        }
        delete(tree.drag_target_path)
        tree.drag_target_path = target == "" ? "" : strings.clone(target)
        return true

    case .Mouse_Up:
        if event.mouse_button != .LEFT || tree.drag_source_path == "" {
            return false
        }

        was_dragging := tree.dragging
        source_path := tree.drag_source_path
        target_path := tree.drag_target_path

        if was_dragging {
            if target_path != "" && tree.on_move != nil {
                tree.on_move(tree.move_data, source_path, target_path)
            }
        } else {
            // No drag occurred: treat as an ordinary click on the pressed row.
            for row in tree_visible_rows(tree) {
                if row.node.path != source_path {
                    continue
                }
                node := row.node
                if node.is_dir {
                    node.expanded = !node.expanded
                    if node.expanded && !node.loaded {
                        tree_load_children(node)
                    }
                    tree_clamp_scroll(tree)
                } else if tree.on_open != nil {
                    tree.on_open(tree.open_data, node.path)
                }
                break
            }
        }

        delete(tree.drag_source_path)
        tree.drag_source_path = ""
        delete(tree.drag_target_path)
        tree.drag_target_path = ""
        tree.dragging = false
        return true
    }

    return false
}

// Index of the selected row among the visible rows, or -1 when the selection is
// unset or currently collapsed out of view.
@(private = "file")
tree_selected_index :: proc(tree: ^Tree, rows: []Tree_Row) -> int {
    for row, index in rows {
        if row.node.path == tree.selected_path {
            return index
        }
    }
    return -1
}

@(private = "file")
tree_select_node :: proc(tree: ^Tree, node: ^Tree_Node) {
    delete(tree.selected_path)
    tree.selected_path = strings.clone(node.path)
}

// Scrolls so the selected row is fully inside the viewport.
@(private = "file")
tree_scroll_to_selection :: proc(tree: ^Tree) {
    rows := tree_visible_rows(tree)
    index := tree_selected_index(tree, rows[:])
    if index < 0 {
        return
    }
    row_top := cast(f32) index * tree.row_height
    row_bottom := row_top + tree.row_height
    if row_top < tree.scroll_y {
        tree.scroll_y = row_top
    } else if row_bottom > tree.scroll_y + tree.bounds.height {
        tree.scroll_y = row_bottom - tree.bounds.height
    }
    tree_clamp_scroll(tree)
}

// Gives the tree a starting selection (the first row) when it gains focus with
// nothing selected, so arrow-key navigation has an anchor and a visible cursor.
tree_focus :: proc(tree: ^Tree) {
    rows := tree_visible_rows(tree)
    if len(rows) == 0 {
        return
    }
    if tree_selected_index(tree, rows[:]) < 0 {
        tree_select_node(tree, rows[0].node)
    }
}

// Keyboard navigation while the tree holds focus: up/down move the selection,
// left/right collapse/expand or step to parent/child, enter opens or toggles,
// delete asks the owner to remove the file.
@(private = "file")
tree_handle_key :: proc(tree: ^Tree, event: ^ui.Event) -> bool {
    rows := tree_visible_rows(tree)
    if len(rows) == 0 {
        return false
    }
    index := tree_selected_index(tree, rows[:])

    #partial switch event.key {
    case .UP:
        index = index < 0 ? 0 : max(index - 1, 0)
        tree_select_node(tree, rows[index].node)
        tree_scroll_to_selection(tree)
        return true
    case .DOWN:
        index = index < 0 ? 0 : min(index + 1, len(rows) - 1)
        tree_select_node(tree, rows[index].node)
        tree_scroll_to_selection(tree)
        return true
    case .LEFT:
        if index < 0 {
            return true
        }
        node := rows[index].node
        if node.is_dir && node.expanded {
            node.expanded = false
            tree_clamp_scroll(tree)
        } else if node.parent != nil && node.parent != tree.root {
            tree_select_node(tree, node.parent)
            tree_scroll_to_selection(tree)
        }
        return true
    case .RIGHT:
        if index < 0 {
            return true
        }
        node := rows[index].node
        if !node.is_dir {
            return true
        }
        if !node.expanded {
            node.expanded = true
            if !node.loaded {
                tree_load_children(node)
            }
            tree_clamp_scroll(tree)
        } else if len(node.children) > 0 {
            tree_select_node(tree, node.children[0])
            tree_scroll_to_selection(tree)
        }
        return true
    case .ENTER, .KP_ENTER:
        if index < 0 {
            return true
        }
        node := rows[index].node
        if node.is_dir {
            node.expanded = !node.expanded
            if node.expanded && !node.loaded {
                tree_load_children(node)
            }
            tree_clamp_scroll(tree)
        } else if tree.on_open != nil {
            tree.on_open(tree.open_data, node.path)
        }
        return true
    case .DELETE:
        if index < 0 {
            return true
        }
        node := rows[index].node
        // Only files are deletable via the keyboard (matches the requirement of
        // "delete a file"); folders are left to the context menu.
        if !node.is_dir && tree.on_delete != nil {
            tree.on_delete(tree.delete_data, node.path)
        }
        return true
    }

    return false
}

tree_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    tree := cast(^Tree) widget

    if tree.background_color.a > 0 {
        rl.DrawRectangleRec(tree.bounds, tree.background_color)
    }

    rows := tree_visible_rows(tree)
    ui.begin_clip(tree.bounds)
    defer ui.end_clip()

    mouse_inside := ctx.hot == widget

    for row, index in rows {
        row_y := tree.bounds.y + cast(f32) index * tree.row_height - tree.scroll_y
        if row_y + tree.row_height < tree.bounds.y || row_y > tree.bounds.y + tree.bounds.height {
            continue
        }

        row_rect := rl.Rectangle {
            x = tree.bounds.x,
            y = row_y,
            width = tree.bounds.width,
            height = tree.row_height,
        }

        node := row.node
        if node.path == tree.selected_path {
            rl.DrawRectangleRec(row_rect, tree.selected_color)
        } else if mouse_inside && rl.CheckCollisionPointRec(ctx.mouse_pos, row_rect) {
            rl.DrawRectangleRec(row_rect, tree.hover_color)
        }
        if tree.dragging && tree.drag_target_path != "" && node.path == tree.drag_target_path {
            rl.DrawRectangleLinesEx(row_rect, 2, tree.drop_target_color)
        }

        x := tree.bounds.x + 8 + cast(f32) row.depth * tree.indent
        icon_y := cast(i32) (row_y + (tree.row_height - cast(f32) tree.icon_size) * 0.5)

        if node.is_dir {
            chevron := node.expanded ? "chevron-down" : "chevron-right"
            ui.draw_icon(chevron, cast(i32) x, icon_y, tree.icon_size, tree.chevron_color)
            x += cast(f32) tree.icon_size + 4
            folder := node.expanded ? "folder-open" : "folder"
            ui.draw_icon(folder, cast(i32) x, icon_y, tree.icon_size, tree.icon_color)
        } else {
            x += cast(f32) tree.icon_size + 4
            // Tint the file icon with its language's vendor colour; unknown types
            // keep the neutral chevron colour.
            icon_color := tree.chevron_color
            if vendor, ok := tree_vendor_color(node.name); ok {
                icon_color = vendor
            }
            ui.draw_icon(tree_file_icon(node.name), cast(i32) x, icon_y, tree.icon_size, icon_color)
        }
        x += cast(f32) tree.icon_size + 6

        text_y := cast(i32) (row_y + (tree.row_height - cast(f32) tree.font_size) * 0.5)
        status := tree.status_proc != nil ? tree.status_proc(tree.status_data, node.path, node.is_dir) : Git_Status.None
        color := node.is_dir ? tree.dir_color : tree.text_color
        if status != .None {
            color = tree_status_color(tree, status)
        }
        ui.draw_text(node.name, cast(i32) x, text_y, tree.font_size, color)

        // Right-aligned status letter for files (folders only get the tint).
        if status != .None && !node.is_dir {
            letter := tree_status_letter(status)
            badge_x := tree.bounds.x + tree.bounds.width - cast(f32) ui.measure_text(letter, tree.font_size) - 10
            ui.draw_text(letter, cast(i32) badge_x, text_y, tree.font_size, color)
        }
    }

    // The workspace root has no row of its own; show the drop as a border
    // around the whole tree instead of a row highlight.
    if tree.dragging && tree.drag_target_path == tree.root.path {
        rl.DrawRectangleLinesEx(tree.bounds, 2, tree.drop_target_color)
    }
}

// Vendor (brand) colour for a file's language, GitHub-linguist style, used to
// tint its tree icon. `ok` is false for names with no known language, so the
// caller keeps its neutral fallback. Colours are lightened where the true brand
// tone would be too dark to read on the dark tree background.
@(private = "file")
tree_vendor_color :: proc(name: string) -> (rl.Color, bool) {
    switch name {
    case "Dockerfile":     return rl.Color {58, 137, 227, 255}, true
    case "CMakeLists.txt": return rl.Color {100, 130, 173, 255}, true
    }

    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return {}, false
    }

    switch name[dot:] {
    case ".c", ".h":                          return rl.Color {90, 150, 214, 255}, true
    case ".cpp", ".hpp", ".cc", ".hh", ".cxx": return rl.Color {243, 75, 125, 255}, true
    case ".rs":                               return rl.Color {222, 165, 132, 255}, true
    case ".go":                               return rl.Color {0, 173, 216, 255}, true
    case ".py", ".pyw":                       return rl.Color {255, 212, 59, 255}, true
    case ".js", ".mjs", ".cjs":               return rl.Color {241, 224, 90, 255}, true
    case ".ts":                               return rl.Color {73, 143, 217, 255}, true
    case ".jsx", ".tsx":                      return rl.Color {97, 218, 251, 255}, true
    case ".zig":                              return rl.Color {236, 145, 92, 255}, true
    case ".glsl", ".vert", ".frag":           return rl.Color {90, 150, 214, 255}, true
    case ".md":                               return rl.Color {117, 143, 255, 255}, true
    case ".json":                             return rl.Color {203, 161, 53, 255}, true
    case ".yml", ".yaml":                     return rl.Color {203, 75, 80, 255}, true
    case ".xml":                              return rl.Color {150, 190, 90, 255}, true
    case ".html", ".htm":                     return rl.Color {227, 100, 60, 255}, true
    case ".css":                              return rl.Color {102, 129, 214, 255}, true
    case ".scss", ".sass":                    return rl.Color {207, 100, 154, 255}, true
    case ".lua":                              return rl.Color {80, 120, 255, 255}, true
    case ".java":                             return rl.Color {214, 143, 61, 255}, true
    case ".kt", ".kts":                       return rl.Color {169, 123, 255, 255}, true
    case ".cs":                               return rl.Color {104, 33, 122, 255}, true
    case ".fs":                               return rl.Color {55, 139, 186, 255}, true
    case ".swift":                            return rl.Color {240, 81, 56, 255}, true
    case ".rb":                               return rl.Color {204, 52, 45, 255}, true
    case ".php":                              return rl.Color {119, 123, 180, 255}, true
    case ".hs":                               return rl.Color {143, 78, 139, 255}, true
    case ".ex", ".exs":                       return rl.Color {150, 120, 180, 255}, true
    case ".jl":                               return rl.Color {150, 90, 165, 255}, true
    case ".pl", ".pm":                        return rl.Color {90, 130, 190, 255}, true
    case ".dart":                             return rl.Color {0, 180, 171, 255}, true
    case ".scala":                            return rl.Color {194, 65, 84, 255}, true
    case ".clj", ".cljs":                     return rl.Color {130, 190, 80, 255}, true
    case ".erl":                              return rl.Color {184, 57, 152, 255}, true
    case ".ml", ".mli":                       return rl.Color {232, 137, 62, 255}, true
    case ".nim":                              return rl.Color {240, 200, 80, 255}, true
    case ".sh", ".bash", ".zsh":              return rl.Color {137, 224, 81, 255}, true
    case ".ps1", ".psm1":                     return rl.Color {90, 145, 216, 255}, true
    case ".vim":                              return rl.Color {90, 175, 90, 255}, true
    case ".tex", ".bib":                      return rl.Color {120, 160, 200, 255}, true
    case ".cmake":                            return rl.Color {100, 130, 173, 255}, true
    case ".vue":                              return rl.Color {65, 184, 131, 255}, true
    case ".svelte":                           return rl.Color {255, 90, 45, 255}, true
    case ".graphql", ".gql":                  return rl.Color {229, 53, 171, 255}, true
    case ".gitignore", ".gitattributes", ".gitmodules": return rl.Color {240, 80, 50, 255}, true
    case ".odin":                             return rl.Color {104, 172, 227, 255}, true
    }
    return {}, false
}

// Language files get a `filetype-` glyph from the active file icon pack; `.odin`
// has no glyph in either pack, so it keeps its own family, and everything else
// falls back to the generic file icons of the primary pack.
@(private = "file")
tree_file_icon :: proc(name: string) -> string {
    switch name {
    case "Dockerfile":
        return "filetype-docker"
    case "CMakeLists.txt":
        return "filetype-cmake"
    }

    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return "file"
    }

    switch name[dot:] {
    case ".c", ".h":
        return "filetype-c"
    case ".cpp", ".hpp", ".cc", ".hh", ".cxx":
        return "filetype-cpp"
    case ".rs":
        return "filetype-rust"
    case ".go":
        return "filetype-go"
    case ".py", ".pyw":
        return "filetype-python"
    case ".js", ".mjs", ".cjs":
        return "filetype-javascript"
    case ".ts":
        return "filetype-typescript"
    case ".jsx", ".tsx":
        return "filetype-react"
    case ".zig":
        return "filetype-zig"
    case ".glsl", ".vert", ".frag":
        return "filetype-glsl"
    case ".md":
        return "filetype-markdown"
    case ".json":
        return "filetype-json"
    case ".yml", ".yaml":
        return "filetype-yaml"
    case ".xml":
        return "filetype-xml"
    case ".html", ".htm":
        return "filetype-html"
    case ".css":
        return "filetype-css"
    case ".scss", ".sass":
        return "filetype-sass"
    case ".lua":
        return "filetype-lua"
    case ".java":
        return "filetype-java"
    case ".kt", ".kts":
        return "filetype-kotlin"
    case ".cs":
        return "filetype-csharp"
    case ".fs":
        return "filetype-fsharp"
    case ".swift":
        return "filetype-swift"
    case ".rb":
        return "filetype-ruby"
    case ".php":
        return "filetype-php"
    case ".hs":
        return "filetype-haskell"
    case ".ex", ".exs":
        return "filetype-elixir"
    case ".jl":
        return "filetype-julia"
    case ".pl", ".pm":
        return "filetype-perl"
    case ".dart":
        return "filetype-dart"
    case ".scala":
        return "filetype-scala"
    case ".clj", ".cljs":
        return "filetype-clojure"
    case ".erl":
        return "filetype-erlang"
    case ".ml", ".mli":
        return "filetype-ocaml"
    case ".nim":
        return "filetype-nim"
    case ".sh", ".bash", ".zsh":
        return "filetype-shell"
    case ".ps1", ".psm1":
        return "filetype-powershell"
    case ".vim":
        return "filetype-vim"
    case ".tex", ".bib":
        return "filetype-latex"
    case ".cmake":
        return "filetype-cmake"
    case ".vue":
        return "filetype-vue"
    case ".svelte":
        return "filetype-svelte"
    case ".graphql", ".gql":
        return "filetype-graphql"
    case ".gitignore", ".gitattributes", ".gitmodules":
        return "filetype-git"
    case ".odin":
        return "odin"
    case ".asm", ".s", ".sql", ".bat", ".slang", ".slangh":
        return "file-code"
    case ".txt", ".toml", ".ini", ".cfg", ".log":
        return "file-text"
    }
    return "file"
}

tree_destroy :: proc(widget: ^ui.Widget) {
    tree := cast(^Tree) widget
    tree_node_destroy(tree.root)
    delete(tree.selected_path)
    delete(tree.drag_source_path)
    delete(tree.drag_target_path)
    free(tree)
}
