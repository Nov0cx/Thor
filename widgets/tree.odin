package widgets

import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../ui"

Tree_Open_Proc :: #type proc(data: rawptr, path: string)
// Fired when Delete is pressed on a selected file; the owner confirms and
// performs the removal (see thor_tree_delete). `path` is the caret row, which is
// always part of tree_selection, so the owner can widen it to the whole
// selection.
Tree_Delete_Proc :: #type proc(data: rawptr, path: string)
// Fired when a row is dropped onto a folder (or the workspace root); the
// owner renames the file on disk into dst_dir (see thor_tree_move).
Tree_Move_Proc :: #type proc(data: rawptr, src_path: string, dst_dir: string)
// Fired when a drag started in the tree is released outside the panel; the
// owner maps the release point to an action (see thor_tree_drag_out).
Tree_Drag_Out_Proc :: #type proc(data: rawptr, paths: []string, position: rl.Vector2)

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
    // Visible rows in draw order, kept between frames. Every change to the node
    // tree or its expanded set must set rows_dirty.
    rows:             [dynamic]Tree_Row, // owned
    rows_dirty:       bool,
    scroll_y:         f32,
    font_size:        i32,
    icon_size:        i32,
    row_height:       f32,
    indent:           f32,
    selected_path:    string, // owned clone; the row the caret sits on
    // Full selection, always containing selected_path. Ctrl-click toggles a row
    // in or out, shift-click takes the range from select_anchor. Keys are owned.
    multi_selected:   map[string]bool,
    select_anchor:    string, // owned; row a shift-click ranges from
    on_open:          Tree_Open_Proc,
    open_data:        rawptr,
    on_delete:        Tree_Delete_Proc,
    delete_data:      rawptr,
    // Right-click opens a context menu supplied by the owner.
    on_context_menu:  Context_Menu_Proc,
    context_menu_data: rawptr,
    // Left-button drag-to-move state. drag_sources is filled on Mouse_Down and
    // cleared on Mouse_Up; `dragging` only flips true once the press crosses
    // TREE_DRAG_THRESHOLD, so an ordinary click still expands/opens the row.
    drag_source_path: string, // owned; the pressed row, "" when none
    drag_sources:     [dynamic]string, // owned; the whole selection being dragged
    drag_press_pos:   rl.Vector2,
    dragging:         bool,
    drag_target_path: string, // owned; "" when the current hover isn't a valid drop
    // Pressing inside a multi-selection keeps it whole so the group can be
    // dragged; a release without a drag collapses it to the pressed row.
    pending_collapse: bool,
    // Ctrl/shift-click only adjusts the selection: the release must not expand
    // the folder or open the file.
    suppress_click_action: bool,
    // Scrollbar drag: `scrollbar_grab` is where inside the thumb it was taken,
    // so the thumb keeps its grip on the cursor instead of jumping.
    scrollbar_dragging: bool,
    scrollbar_grab:   f32,
    on_move:          Tree_Move_Proc,
    move_data:        rawptr,
    on_drag_out:      Tree_Drag_Out_Proc,
    drag_out_data:    rawptr,
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
    scrollbar_color:  rl.Color,
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
    tree.rows_dirty = true

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
    tree.rows_dirty = true

    tree_clear_multi_select(tree)
    delete(tree.selected_path)
    tree.selected_path = ""
    delete(tree.select_anchor)
    tree.select_anchor = ""
    tree.scroll_y = 0

    tree_clear_drag_sources(tree)
    delete(tree.drag_source_path)
    tree.drag_source_path = ""
    delete(tree.drag_target_path)
    tree.drag_target_path = ""
    tree.dragging = false
    tree.pending_collapse = false
    tree.suppress_click_action = false
}

tree_set_colors :: proc(tree: ^Tree, text, dir, icon, chevron, hover, selected, background, scrollbar: rl.Color) -> ^Tree {
    tree.text_color = text
    tree.dir_color = dir
    tree.icon_color = icon
    tree.chevron_color = chevron
    tree.hover_color = hover
    tree.selected_color = selected
    tree.background_color = background
    tree.scrollbar_color = scrollbar
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

tree_set_on_drag_out :: proc(tree: ^Tree, on_drag_out: Tree_Drag_Out_Proc, data: rawptr) {
    tree.on_drag_out = on_drag_out
    tree.drag_out_data = data
}

// The rows currently selected, borrowed from the tree and invalidated by the
// next selection change or refresh.
tree_selection :: proc(tree: ^Tree, allocator := context.temp_allocator) -> []string {
    paths := make([dynamic]string, 0, len(tree.multi_selected), allocator)
    for path in tree.multi_selected {
        append(&paths, path)
    }
    return paths[:]
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

// Ellipsis-truncates name to fit max_width, so a long file name is cut short
// rather than drawn underneath the status badge that follows it.
@(private = "file")
tree_truncate_name :: proc(name: string, max_width: i32, font_size: i32) -> string {
    if max_width <= 0 || ui.measure_text(name, font_size) <= max_width {
        return name
    }
    runes := utf8.string_to_runes(name, context.temp_allocator)
    lo, hi := 0, len(runes)
    for lo < hi {
        mid := (lo + hi + 1) / 2
        candidate := strings.concatenate({string(utf8.runes_to_string(runes[:mid], context.temp_allocator)), "..."}, context.temp_allocator)
        if ui.measure_text(candidate, font_size) <= max_width {
            lo = mid
        } else {
            hi = mid - 1
        }
    }
    if lo == 0 {
        return "..."
    }
    return strings.concatenate({string(utf8.runes_to_string(runes[:lo], context.temp_allocator)), "..."}, context.temp_allocator)
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
// `in_tree` is false when the position is outside the panel, which makes the
// drop somebody else's business.
tree_drop_target_at :: proc(tree: ^Tree, position: rl.Vector2) -> (target: string, in_tree: bool) {
    if !rl.CheckCollisionPointRec(position, tree.bounds) {
        return "", false
    }
    index := cast(int) ((position.y - tree.bounds.y + tree.scroll_y) / tree.row_height)
    rows := tree_visible_rows(tree)
    if index < 0 || index >= len(rows) {
        return tree.root.path, true
    }
    node := rows[index].node
    if node.is_dir {
        return node.path, true
    }
    if node.parent != nil {
        return node.parent.path, true
    }
    return tree.root.path, true
}

@(private = "file")
tree_clear_multi_select :: proc(tree: ^Tree) {
    for path in tree.multi_selected {
        delete(path)
    }
    clear(&tree.multi_selected)
}

@(private = "file")
tree_add_selected :: proc(tree: ^Tree, path: string) {
    if path in tree.multi_selected {
        return
    }
    tree.multi_selected[strings.clone(path)] = true
}

@(private = "file")
tree_remove_selected :: proc(tree: ^Tree, path: string) {
    // delete_key drops the entry but hands back nothing, so the owned key has to
    // be found by content before it can be freed.
    for key in tree.multi_selected {
        if key == path {
            delete_key(&tree.multi_selected, key)
            delete(key)
            return
        }
    }
}

// Replaces the selection with a single row; plain clicks and keyboard
// navigation both collapse the selection this way.
@(private = "file")
tree_set_single_select :: proc(tree: ^Tree, path: string) {
    // Cloned up front: `path` may alias a string the clears below free.
    kept := strings.clone(path, context.temp_allocator)
    tree_clear_multi_select(tree)
    delete(tree.selected_path)
    tree.selected_path = strings.clone(kept)
    delete(tree.select_anchor)
    tree.select_anchor = strings.clone(kept)
    tree.multi_selected[strings.clone(kept)] = true
}

// Ctrl-click: adds or removes one row, leaving the rest of the selection alone.
@(private = "file")
tree_toggle_select :: proc(tree: ^Tree, path: string) {
    if path in tree.multi_selected {
        tree_remove_selected(tree, path)
        if tree.selected_path == path {
            delete(tree.selected_path)
            tree.selected_path = ""
            for remaining in tree.multi_selected {
                tree.selected_path = strings.clone(remaining)
                break
            }
        }
        return
    }
    tree_add_selected(tree, path)
    delete(tree.selected_path)
    tree.selected_path = strings.clone(path)
    delete(tree.select_anchor)
    tree.select_anchor = strings.clone(path)
}

// Shift-click: selects every visible row between the anchor and `path`, keeping
// the anchor so a second shift-click re-ranges from the same starting row.
@(private = "file")
tree_select_range :: proc(tree: ^Tree, path: string) {
    rows := tree_visible_rows(tree)
    anchor_index, target_index := -1, -1
    for row, index in rows {
        if row.node.path == tree.select_anchor {
            anchor_index = index
        }
        if row.node.path == path {
            target_index = index
        }
    }
    if target_index < 0 {
        return
    }
    if anchor_index < 0 {
        anchor_index = target_index
    }
    lo := min(anchor_index, target_index)
    hi := max(anchor_index, target_index)

    tree_clear_multi_select(tree)
    for index in lo ..= hi {
        tree_add_selected(tree, rows[index].node.path)
    }
    delete(tree.selected_path)
    tree.selected_path = strings.clone(path)
    if tree.select_anchor == "" {
        tree.select_anchor = strings.clone(path)
    }
}

@(private = "file")
tree_clear_drag_sources :: proc(tree: ^Tree) {
    for path in tree.drag_sources {
        delete(path)
    }
    clear(&tree.drag_sources)
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
    tree.rows_dirty = true
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

// The rows in draw order, borrowed from the tree and invalidated by the next
// expand, collapse or refresh. Rebuilds only when the row list is stale.
@(private = "file")
tree_visible_rows :: proc(tree: ^Tree) -> []Tree_Row {
    if tree.rows_dirty {
        clear(&tree.rows)
        tree_collect_rows(tree.root, 0, &tree.rows)
        tree.rows_dirty = false
    }
    return tree.rows[:]
}

// Opens or shuts a folder, reading it from disk on first open. The only way
// expansion changes, so the row list cannot go stale unnoticed.
@(private = "file")
tree_set_expanded :: proc(tree: ^Tree, node: ^Tree_Node, expanded: bool) {
    if node.expanded == expanded {
        return
    }
    node.expanded = expanded
    if expanded && !node.loaded {
        tree_load_children(node)
    }
    tree.rows_dirty = true
    tree_clamp_scroll(tree)
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
tree_max_scroll :: proc(tree: ^Tree) -> f32 {
    content_height := cast(f32) len(tree_visible_rows(tree)) * tree.row_height
    return max(content_height - tree.bounds.height, 0)
}

@(private = "file")
tree_clamp_scroll :: proc(tree: ^Tree) {
    tree.scroll_y = clamp(tree.scroll_y, 0, tree_max_scroll(tree))
}

// Track and thumb of the vertical scrollbar, shared by the draw and the
// hit-test so the two cannot drift. `ok` is false when every row fits.
@(private = "file")
tree_scrollbar_rects :: proc(tree: ^Tree) -> (track, thumb: rl.Rectangle, ok: bool) {
    content := cast(f32) len(tree_visible_rows(tree)) * tree.row_height
    return ui.scrollbar_rects(tree.bounds, content, tree.scroll_y, SCROLLBAR_STYLE)
}

// Scrolls so the thumb's top sits `scrollbar_grab` above the cursor.
@(private = "file")
tree_scrollbar_drag_to :: proc(tree: ^Tree, mouse_y: f32) {
    track, thumb, ok := tree_scrollbar_rects(tree)
    if !ok {
        return
    }
    tree.scroll_y = ui.scrollbar_scroll_at(track, thumb, mouse_y, tree.scrollbar_grab, tree_max_scroll(tree))
    tree_clamp_scroll(tree)
}

// Takes hold of the scrollbar when the press lands in its grab strip: on the
// thumb it drags from where it was taken, elsewhere on the track it centers the
// thumb on the click and drags from there.
@(private = "file")
tree_scrollbar_press :: proc(tree: ^Tree, event: ^ui.Event) -> bool {
    if event.mouse_button != .LEFT {
        return false
    }
    track, thumb, ok := tree_scrollbar_rects(tree)
    if !ok || !rl.CheckCollisionPointRec(event.mouse_position, ui.scrollbar_grab_rect(track, SCROLLBAR_GRAB_WIDTH)) {
        return false
    }
    tree.scrollbar_dragging = true
    if event.mouse_position.y >= thumb.y && event.mouse_position.y < thumb.y + thumb.height {
        tree.scrollbar_grab = event.mouse_position.y - thumb.y
    } else {
        tree.scrollbar_grab = thumb.height * 0.5
        tree_scrollbar_drag_to(tree, event.mouse_position.y)
    }
    return true
}

// Vertical scrollbar on the right edge, shown only when the rows overflow the
// panel. No track fill, so a tree that fits costs nothing.
@(private = "file")
tree_draw_scrollbar :: proc(tree: ^Tree) {
    track, thumb, ok := tree_scrollbar_rects(tree)
    if !ok {
        return
    }
    active :=
        tree.scrollbar_dragging ||
        rl.CheckCollisionPointRec(rl.GetMousePosition(), ui.scrollbar_grab_rect(track, SCROLLBAR_GRAB_WIDTH))
    rl.DrawRectangleRec(thumb, active ? tree.text_color : tree.scrollbar_color)
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
        // The scrollbar sits over the rows, so it claims the press first, or a
        // press behind the thumb selects the row underneath it.
        if tree_scrollbar_press(tree, event) {
            return true
        }
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

        // Right-click leaves an existing multi-selection alone so the menu can
        // act on the whole group; otherwise it selects the row it landed on.
        if event.mouse_button == .RIGHT {
            if node.path not_in tree.multi_selected {
                tree_set_single_select(tree, node.path)
            } else {
                delete(tree.selected_path)
                tree.selected_path = strings.clone(node.path)
            }
            if tree.on_context_menu != nil {
                tree.on_context_menu(tree.context_menu_data, event.mouse_position)
            }
            return true
        }

        tree.pending_collapse = false
        tree.suppress_click_action = false
        switch {
        case event.shift:
            tree_select_range(tree, node.path)
            tree.suppress_click_action = true
        case event.ctrl:
            tree_toggle_select(tree, node.path)
            tree.suppress_click_action = true
        case (node.path in tree.multi_selected) && len(tree.multi_selected) > 1:
            delete(tree.selected_path)
            tree.selected_path = strings.clone(node.path)
            tree.pending_collapse = true
        case:
            tree_set_single_select(tree, node.path)
        }

        // Left button: arm a potential drag over the selection instead of
        // acting immediately. Mouse_Up runs the expand/open/move behavior once
        // it's clear whether the press turned into a drag.
        tree_clear_drag_sources(tree)
        if node.path in tree.multi_selected {
            for path in tree.multi_selected {
                append(&tree.drag_sources, strings.clone(path))
            }
        } else {
            append(&tree.drag_sources, strings.clone(node.path))
        }

        delete(tree.drag_source_path)
        tree.drag_source_path = strings.clone(node.path)
        tree.drag_press_pos = event.mouse_position
        tree.dragging = false
        delete(tree.drag_target_path)
        tree.drag_target_path = ""
        return true

    case .Mouse_Move:
        // A thumb press sets no drag sources, so this comes before their guard.
        if tree.scrollbar_dragging {
            tree_scrollbar_drag_to(tree, event.mouse_position.y)
            return true
        }
        if len(tree.drag_sources) == 0 {
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

        target, in_tree := tree_drop_target_at(tree, event.mouse_position)
        if !in_tree {
            target = ""
        }
        // A folder can't be dropped into itself or into one of its own children.
        for source in tree.drag_sources {
            if target != "" && tree_path_equal_or_within(target, source) {
                target = ""
            }
        }
        delete(tree.drag_target_path)
        tree.drag_target_path = target == "" ? "" : strings.clone(target)
        return true

    case .Mouse_Up:
        if tree.scrollbar_dragging {
            tree.scrollbar_dragging = false
            return true
        }
        if event.mouse_button != .LEFT || len(tree.drag_sources) == 0 {
            return false
        }

        was_dragging := tree.dragging
        pressed_path := tree.drag_source_path
        target_path := tree.drag_target_path

        if was_dragging {
            if rl.CheckCollisionPointRec(event.mouse_position, tree.bounds) {
                if target_path != "" && tree.on_move != nil {
                    for source in tree.drag_sources {
                        tree.on_move(tree.move_data, source, target_path)
                    }
                    // The moved rows live under new paths now, so the old
                    // selection no longer points at anything.
                    tree_clear_multi_select(tree)
                    delete(tree.selected_path)
                    tree.selected_path = ""
                    delete(tree.select_anchor)
                    tree.select_anchor = ""
                }
            } else if tree.on_drag_out != nil {
                // Released outside the panel: the owner decides what the drop
                // point means (see thor_tree_drag_out).
                tree.on_drag_out(tree.drag_out_data, tree.drag_sources[:], event.mouse_position)
            }
        } else {
            // No drag occurred: treat as an ordinary click on the pressed row.
            if tree.pending_collapse {
                tree_set_single_select(tree, pressed_path)
            }
            if !tree.suppress_click_action {
                for row in tree_visible_rows(tree) {
                    if row.node.path != pressed_path {
                        continue
                    }
                    node := row.node
                    if node.is_dir {
                        tree_set_expanded(tree, node, !node.expanded)
                    } else if tree.on_open != nil {
                        tree.on_open(tree.open_data, node.path)
                    }
                    break
                }
            }
        }

        tree_clear_drag_sources(tree)
        delete(tree.drag_source_path)
        tree.drag_source_path = ""
        delete(tree.drag_target_path)
        tree.drag_target_path = ""
        tree.dragging = false
        tree.pending_collapse = false
        tree.suppress_click_action = false
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
    tree_set_single_select(tree, node.path)
}

// Scrolls so the selected row is fully inside the viewport.
@(private = "file")
tree_scroll_to_selection :: proc(tree: ^Tree) {
    rows := tree_visible_rows(tree)
    index := tree_selected_index(tree, rows)
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
    if tree_selected_index(tree, rows) < 0 {
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
    index := tree_selected_index(tree, rows)

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
            tree_set_expanded(tree, node, false)
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
            tree_set_expanded(tree, node, true)
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
            tree_set_expanded(tree, node, !node.expanded)
        } else if tree.on_open != nil {
            tree.on_open(tree.open_data, node.path)
        }
        return true
    case .DELETE:
        if index < 0 {
            return true
        }
        node := rows[index].node
        // Folders included: the owner puts a confirmation in front of it, and
        // silently ignoring the key reads as a broken Delete.
        if tree.on_delete != nil {
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
        if node.path in tree.multi_selected {
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

        // The name is truncated to leave room for the status badge, so a long
        // file name never renders underneath it.
        has_badge := status != .None && !node.is_dir
        letter := has_badge ? tree_status_letter(status) : ""
        right_edge := tree.bounds.x + tree.bounds.width - 10
        if has_badge {
            right_edge -= cast(f32) ui.measure_text(letter, tree.font_size) + 6
        }
        name := tree_truncate_name(node.name, cast(i32) (right_edge - x), tree.font_size)
        ui.draw_text(name, cast(i32) x, text_y, tree.font_size, color)

        // Right-aligned status letter for files (folders only get the tint).
        if has_badge {
            badge_x := tree.bounds.x + tree.bounds.width - cast(f32) ui.measure_text(letter, tree.font_size) - 10
            ui.draw_text(letter, cast(i32) badge_x, text_y, tree.font_size, color)
        }
    }

    // The workspace root has no row of its own; show the drop as a border
    // around the whole tree instead of a row highlight.
    if tree.dragging && tree.drag_target_path == tree.root.path {
        rl.DrawRectangleLinesEx(tree.bounds, 2, tree.drop_target_color)
    }

    tree_draw_scrollbar(tree)
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
    delete(tree.rows)
    tree_clear_multi_select(tree)
    delete(tree.multi_selected)
    tree_clear_drag_sources(tree)
    delete(tree.drag_sources)
    delete(tree.selected_path)
    delete(tree.select_anchor)
    delete(tree.drag_source_path)
    delete(tree.drag_target_path)
    free(tree)
}
