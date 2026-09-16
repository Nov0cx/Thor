// The file explorer: a lazily loaded directory tree with multi-selection,
// drag-to-move and git status tinting. State lives on `Thor`; `thor_explorer_view`
// declares the visible rows from it each frame.
package thor

import "core:os"
import "core:slice"
import "core:strings"

import ui "../vendor/loom/loom"

EXPLORER_ROW_H :: f32(26)
EXPLORER_INDENT :: f32(16)
// Width of the fold-chevron column, held open on every row.
EXPLORER_CHEVRON_W :: f32(16)
EXPLORER_ICON :: f32(16)

Explorer_Node :: struct {
    name:        string, // owned
    path:        string, // owned, full path
    is_dir:      bool,
    expanded:    bool,
    loaded:      bool, // directory contents read from disk
    load_failed: bool, // the last read of this directory failed
    parent:      ^Explorer_Node, // nil for the root; used for keyboard navigation
    children:    [dynamic]^Explorer_Node,
}

@(private = "file")
Explorer_Row :: struct {
    node:  ^Explorer_Node,
    depth: int,
}

Explorer :: struct {
    root:           ^Explorer_Node, // owned
    // Visible rows in draw order, kept between frames. Every change to the node
    // tree or its expanded set must set rows_dirty.
    rows:           [dynamic]Explorer_Row, // owned
    rows_dirty:     bool,
    selected_path:  string, // owned; the row the caret sits on
    // Full selection, always holding selected_path. Ctrl-click toggles a row in
    // or out, shift-click takes the range from select_anchor. Keys are owned.
    multi_selected: map[string]bool,
    select_anchor:  string, // owned; row a shift-click ranges from
    // Left-button drag-to-move. `sources` is filled on press and cleared on
    // release; `dragging` only flips once the press leaves the row it started on.
    drag_sources:   [dynamic]string, // owned
    dragging:       bool,
    drag_target:    string, // owned; "" when the hover is not a valid drop
    // Pressing inside a multi-selection keeps it whole so the group can be
    // dragged; a release without a drag collapses it to the pressed row.
    pending_collapse: string, // owned
    // Last frame's panel rect and the folder the hovered row drops into. A drop
    // from the shell lands after the frame that saw the cursor, so the answer is
    // read from here rather than hit-tested again.
    panel_rect:     ui.Rect,
    hover_dir:      string, // borrowed from a live node, "" when nothing is hovered
}

thor_explorer_init :: proc(thor: ^Thor, root_path: string) {
    e := &thor.explorer
    e.rows = make([dynamic]Explorer_Row)
    e.multi_selected = make(map[string]bool)
    e.drag_sources = make([dynamic]string)
    explorer_make_root(e, root_path)
}

thor_explorer_destroy :: proc(thor: ^Thor) {
    e := &thor.explorer
    if e.root != nil {
        explorer_node_destroy(e.root)
        e.root = nil
    }
    delete(e.rows)
    explorer_clear_selection(e)
    delete(e.multi_selected)
    explorer_clear_drag_sources(e)
    delete(e.drag_sources)
    delete(e.selected_path)
    delete(e.select_anchor)
    delete(e.drag_target)
    delete(e.pending_collapse)
}

// Repoints the tree at another directory: the old nodes, selection and scroll
// position go with the folder they belonged to.
thor_explorer_set_root :: proc(thor: ^Thor, root_path: string) {
    e := &thor.explorer
    if e.root != nil {
        explorer_node_destroy(e.root)
    }
    explorer_make_root(e, root_path)

    explorer_clear_selection(e)
    delete(e.selected_path)
    e.selected_path = ""
    delete(e.select_anchor)
    e.select_anchor = ""

    explorer_clear_drag_sources(e)
    delete(e.drag_target)
    e.drag_target = ""
    delete(e.pending_collapse)
    e.pending_collapse = ""
    e.dragging = false
}

// Re-reads the root level from disk, keeping the expansion state of
// subdirectories that still exist.
thor_explorer_refresh :: proc(thor: ^Thor) {
    e := &thor.explorer
    if e.root == nil {
        return
    }
    expanded := make(map[string]bool, context.temp_allocator)
    explorer_collect_expanded(e.root, &expanded)

    for child in e.root.children {
        explorer_node_destroy(child)
    }
    clear(&e.root.children)
    explorer_load_children(e.root)
    explorer_apply_expanded(e.root, &expanded)
    e.rows_dirty = true
}

// The rows currently selected, in a temporary slice by default.
thor_explorer_selection :: proc(thor: ^Thor, allocator := context.temp_allocator) -> []string {
    e := &thor.explorer
    paths := make([dynamic]string, 0, len(e.multi_selected), allocator)
    for path in e.multi_selected {
        append(&paths, path)
    }
    return paths[:]
}

// The caret row, or "" when nothing is selected.
thor_explorer_selected :: proc(thor: ^Thor) -> string {
    return thor.explorer.selected_path
}

// ---- the node tree -------------------------------------------------------------

@(private = "file")
explorer_make_root :: proc(e: ^Explorer, root_path: string) {
    e.root = new(Explorer_Node)
    e.root.name = strings.clone(root_path)
    e.root.path = strings.clone(root_path)
    e.root.is_dir = true
    e.root.expanded = true
    explorer_load_children(e.root)
    e.rows_dirty = true
}

@(private = "file")
explorer_node_less :: proc(a, b: ^Explorer_Node) -> bool {
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
explorer_load_children :: proc(node: ^Explorer_Node) {
    node.loaded = true
    node.load_failed = false

    handle, open_err := os.open(node.path)
    if open_err != nil {
        node.load_failed = true
        return
    }
    defer os.close(handle)

    infos, read_err := os.read_dir(handle, -1, context.temp_allocator)
    if read_err != nil {
        node.load_failed = true
        return
    }

    for info in infos {
        if info.name == ".git" {
            continue
        }
        child := new(Explorer_Node)
        child.name = strings.clone(info.name)
        child.path = strings.clone(info.fullpath)
        child.is_dir = info.type == .Directory
        child.parent = node
        append(&node.children, child)
    }

    slice.sort_by(node.children[:], explorer_node_less)
}

@(private = "file")
explorer_node_destroy :: proc(node: ^Explorer_Node) {
    for child in node.children {
        explorer_node_destroy(child)
    }
    delete(node.children)
    delete(node.name)
    delete(node.path)
    free(node)
}

@(private = "file")
explorer_collect_expanded :: proc(node: ^Explorer_Node, expanded: ^map[string]bool) {
    for child in node.children {
        if child.is_dir && child.expanded {
            expanded[strings.clone(child.path, context.temp_allocator)] = true
            explorer_collect_expanded(child, expanded)
        }
    }
}

@(private = "file")
explorer_apply_expanded :: proc(node: ^Explorer_Node, expanded: ^map[string]bool) {
    for child in node.children {
        if child.is_dir && child.path in expanded {
            child.expanded = true
            if !child.loaded {
                explorer_load_children(child)
            }
            explorer_apply_expanded(child, expanded)
        }
    }
}

// The rows in draw order, borrowed and invalidated by the next expand, collapse
// or refresh. Rebuilds only when the row list is stale.
@(private = "file")
explorer_visible_rows :: proc(e: ^Explorer) -> []Explorer_Row {
    if e.root == nil {
        return nil
    }
    if e.rows_dirty {
        clear(&e.rows)
        explorer_collect_rows(e.root, 0, &e.rows)
        e.rows_dirty = false
    }
    return e.rows[:]
}

@(private = "file")
explorer_collect_rows :: proc(node: ^Explorer_Node, depth: int, rows: ^[dynamic]Explorer_Row) {
    for child in node.children {
        append(rows, Explorer_Row{node = child, depth = depth})
        if child.is_dir && child.expanded {
            explorer_collect_rows(child, depth + 1, rows)
        }
    }
}

// Opens or shuts a folder, reading it from disk on first open. The only way
// expansion changes, so the row list cannot go stale unnoticed.
@(private = "file")
explorer_set_expanded :: proc(e: ^Explorer, node: ^Explorer_Node, expanded: bool) {
    if node.expanded == expanded {
        return
    }
    node.expanded = expanded
    // A read that failed is retried on the next open: the folder may have been
    // locked, or gone, only for the moment.
    if expanded && (!node.loaded || node.load_failed) {
        explorer_load_children(node)
    }
    e.rows_dirty = true
}

// ---- selection -------------------------------------------------------------------

@(private = "file")
explorer_clear_selection :: proc(e: ^Explorer) {
    for path in e.multi_selected {
        delete(path)
    }
    clear(&e.multi_selected)
}

@(private = "file")
explorer_add_selected :: proc(e: ^Explorer, path: string) {
    if path in e.multi_selected {
        return
    }
    e.multi_selected[strings.clone(path)] = true
}

@(private = "file")
explorer_remove_selected :: proc(e: ^Explorer, path: string) {
    // delete_key drops the entry but hands back nothing, so the owned key has to
    // be found by content before it can be freed.
    for key in e.multi_selected {
        if key == path {
            delete_key(&e.multi_selected, key)
            delete(key)
            return
        }
    }
}

// Replaces the selection with a single row; plain clicks and keyboard
// navigation both collapse the selection this way.
@(private = "file")
explorer_select_single :: proc(e: ^Explorer, path: string) {
    // Cloned up front: `path` may alias a string the clears below free.
    kept := strings.clone(path, context.temp_allocator)
    explorer_clear_selection(e)
    delete(e.selected_path)
    e.selected_path = strings.clone(kept)
    delete(e.select_anchor)
    e.select_anchor = strings.clone(kept)
    e.multi_selected[strings.clone(kept)] = true
}

// Ctrl-click: adds or removes one row, leaving the rest of the selection alone.
@(private = "file")
explorer_select_toggle :: proc(e: ^Explorer, path: string) {
    if path in e.multi_selected {
        explorer_remove_selected(e, path)
        if e.selected_path == path {
            delete(e.selected_path)
            e.selected_path = ""
            for remaining in e.multi_selected {
                e.selected_path = strings.clone(remaining)
                break
            }
        }
        return
    }
    explorer_add_selected(e, path)
    delete(e.selected_path)
    e.selected_path = strings.clone(path)
    delete(e.select_anchor)
    e.select_anchor = strings.clone(path)
}

// Shift-click: selects every visible row between the anchor and `path`, keeping
// the anchor so a second shift-click re-ranges from the same starting row.
@(private = "file")
explorer_select_range :: proc(e: ^Explorer, path: string) {
    rows := explorer_visible_rows(e)
    anchor_index, target_index := -1, -1
    for row, index in rows {
        if row.node.path == e.select_anchor {
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

    explorer_clear_selection(e)
    for index in lo ..= hi {
        explorer_add_selected(e, rows[index].node.path)
    }
    delete(e.selected_path)
    e.selected_path = strings.clone(path)
    if e.select_anchor == "" {
        e.select_anchor = strings.clone(path)
    }
}

@(private = "file")
explorer_clear_drag_sources :: proc(e: ^Explorer) {
    for path in e.drag_sources {
        delete(path)
    }
    clear(&e.drag_sources)
}

// True when `path` is `ancestor` itself or lives somewhere inside it.
// Case-insensitive, and it treats the two separators as equal since paths come
// straight from os.read_dir without being canonicalized.
explorer_path_within :: proc(path, ancestor: string) -> bool {
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

// Folder a shell drop at `point` lands in, from the row the last frame hovered.
// False when the pointer is not over the panel.
thor_explorer_drop_target_at :: proc(thor: ^Thor, point: ui.Vec2) -> (string, bool) {
    e := &thor.explorer
    if !ui.rect_contains(e.panel_rect, point) {
        return "", false
    }
    if e.hover_dir != "" {
        return e.hover_dir, true
    }
    return e.root != nil ? e.root.path : "", e.root != nil
}

// Folder a drop on `node` would land in: the folder itself, or a file's parent.
@(private = "file")
explorer_drop_dir :: proc(e: ^Explorer, node: ^Explorer_Node) -> string {
    if node == nil {
        return e.root != nil ? e.root.path : ""
    }
    if node.is_dir {
        return node.path
    }
    if node.parent != nil {
        return node.parent.path
    }
    return e.root != nil ? e.root.path : ""
}

// ---- the view ---------------------------------------------------------------------

thor_explorer_view :: proc(thor: ^Thor) {
    e := &thor.explorer
    rows := explorer_visible_rows(e)

    panel := ui.scope(
        {
            key = "explorer",
            flags = {.Clip, .Scroll_Y, .Clickable, .Focusable},
            props = {
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                bg = thor.theme.second_background,
            },
        },
    )
    if panel.focused {
        thor.focus_owner = "explorer"
    }
    if thor.focus_request == "explorer" {
        ui.set_focus(panel.id)
        thor.focus_request = ""
    }

    if len(rows) == 0 {
        ui.label(
            "No files",
            {key = "empty", props = {pad = ui.xy(12, 8), color = thor.theme.disabled}},
        )
        return
    }

    // A drop lands where the pointer is, so the target is recomputed each frame
    // the drag runs and read once on the release.
    hovered: ^Explorer_Node
    released := false

    {
        first, last := ui.virtual(len(rows), EXPLORER_ROW_H)
        defer ui.end_virtual()

        for index in first ..< last {
            row := rows[index]
            ui.push_id_int(i64(index))
            it := explorer_row(thor, row.node, row.depth)
            ui.pop_id()

            if it.hovered {
                hovered = row.node
            }
            if it.pressed {
                explorer_press(thor, row.node, ui.mods())
            }
            if it.dragging {
                e.dragging = true
            }
            if it.released {
                released = true
            }
            if it.right_clicked {
                explorer_right_click(thor, row.node)
            }
            if it.clicked {
                explorer_click(thor, row.node)
            }
        }
    }

    e.panel_rect = panel.rect
    e.hover_dir = hovered != nil ? explorer_drop_dir(e, hovered) : ""

    explorer_drag(thor, panel, hovered, released)
    if ui.focus_within(panel.node) {
        explorer_keys(thor)
    }
}

@(private = "file")
explorer_row :: proc(thor: ^Thor, node: ^Explorer_Node, depth: int) -> ui.Interaction {
    e := &thor.explorer
    on := node.path in e.multi_selected
    drop := e.dragging && e.drag_target == node.path

    it := ui.scope(
        {
            key = "row",
            flags = {.Clickable, .Draggable, .Group},
            props = {
                w = ui.Grow(1),
                h = ui.Px(EXPLORER_ROW_H),
                dir = .Row,
                align = .Center,
                gap = {4, 0},
                pad = {l = 6 + f32(depth) * EXPLORER_INDENT, r = 6},
                bg = on ? thor.theme.selection_background : ui.Color{0, 0, 0, 0},
                border = {
                    width = ui.all(drop ? 1 : 0),
                    color = thor.theme.accent_color,
                },
                cursor = .Pointer,
            },
            hover = {bg = on ? thor.theme.selection_background : thor.theme.buttons},
        },
    )

    // The chevron column is reserved on a file row as well, so a file icon and a
    // folder icon sit at the same indent.
    ui.begin(
        {
            key = "chevron",
            props = {
                w = ui.Px(EXPLORER_CHEVRON_W),
                h = ui.Px(EXPLORER_ROW_H),
                justify = .Center,
                align = .Center,
            },
        },
    )
    if node.is_dir {
        thor_icon_label(thor, node.expanded ? "chevron-down" : "chevron-right", thor.theme.muted_color)
    }
    ui.end()

    if node.is_dir {
        thor_icon_label(thor, node.expanded ? "folder-open" : "folder", thor.theme.accent_color, key = "folder")
    } else {
        // The icon carries the language's vendor colour; unknown types keep the
        // neutral one.
        tint := thor.theme.muted_color
        if vendor, ok := explorer_vendor_color(node.name); ok {
            tint = vendor
        }
        thor_icon_label(thor, explorer_file_icon(node.name), tint)
    }

    status := thor_tree_git_status(thor, node.path, node.is_dir)
    color := node.is_dir ? thor.theme.foreground : thor.theme.primary_text_color
    if node.load_failed {
        color = thor.theme.danger_color
    } else if status != .None {
        color = explorer_status_color(thor, status)
    }

    ui.label(
        node.name,
        {key = "name", props = {w = ui.Grow(1), color = color, text_wrap = .Ellipsis}},
    )

    // The path, since a deep row is indented far enough to hide it, plus the git
    // state the tint alone only hints at.
    detail := node.load_failed ? "Could not be read" : git_status_name(status)
    thor_tip(thor, it.id, node.path, detail)
    return it
}

@(private = "file")
explorer_status_color :: proc(thor: ^Thor, status: Git_Status) -> ui.Color {
    #partial switch status {
    case .Modified, .Renamed:
        return thor.theme.warning_color
    case .Added, .Untracked:
        return thor.theme.success_color
    case .Deleted, .Conflict:
        return thor.theme.danger_color
    case .Submodule:
        return thor.theme.info_color
    }
    return thor.theme.primary_text_color
}

// A press decides the selection. Ctrl and shift only adjust it: the click that
// follows must not expand the folder or open the file, which explorer_click
// sees through `suppress_click`.
@(private = "file")
explorer_press :: proc(thor: ^Thor, node: ^Explorer_Node, mods: ui.Mod_Set) {
    e := &thor.explorer
    if .Ctrl in mods {
        explorer_select_toggle(e, node.path)
        return
    }
    if .Shift in mods {
        explorer_select_range(e, node.path)
        return
    }
    // Pressing inside a multi-selection keeps it whole so the group can be
    // dragged; the release collapses it when no drag happened.
    if node.path in e.multi_selected && len(e.multi_selected) > 1 {
        delete(e.pending_collapse)
        e.pending_collapse = strings.clone(node.path)
    } else {
        explorer_select_single(e, node.path)
    }

    explorer_clear_drag_sources(e)
    for path in e.multi_selected {
        append(&e.drag_sources, strings.clone(path))
    }
}

@(private = "file")
explorer_click :: proc(thor: ^Thor, node: ^Explorer_Node) {
    e := &thor.explorer
    if e.dragging {
        return
    }
    if e.pending_collapse != "" {
        explorer_select_single(e, e.pending_collapse)
        delete(e.pending_collapse)
        e.pending_collapse = ""
    }
    if .Ctrl in ui.mods() || .Shift in ui.mods() {
        return
    }
    if node.is_dir {
        explorer_set_expanded(e, node, !node.expanded)
        return
    }
    thor_tree_open(thor, node.path)
}

@(private = "file")
explorer_right_click :: proc(thor: ^Thor, node: ^Explorer_Node) {
    e := &thor.explorer
    if node.path not_in e.multi_selected {
        explorer_select_single(e, node.path)
    }
    thor_explorer_context_menu(thor, node.path, ui.mouse_pos())
}

// Tracks the live drag: the target folder while the pointer is inside the panel,
// and the move (or drag-out) the release performs.
@(private = "file")
explorer_drag :: proc(
    thor: ^Thor,
    panel: ui.Interaction,
    hovered: ^Explorer_Node,
    released: bool,
) {
    e := &thor.explorer
    inside := ui.rect_contains(panel.rect, ui.mouse_pos())

    if e.dragging {
        target := inside ? explorer_drop_dir(e, hovered) : ""
        if target != e.drag_target {
            delete(e.drag_target)
            e.drag_target = strings.clone(target)
        }
    }

    if !released {
        return
    }
    if e.dragging {
        if e.drag_target != "" {
            for source in e.drag_sources {
                // A folder cannot be moved into itself or its own subtree.
                if explorer_path_within(e.drag_target, source) {
                    continue
                }
                thor_tree_move(thor, source, e.drag_target)
            }
        } else if len(e.drag_sources) > 0 {
            thor_tree_drag_out(thor, e.drag_sources[:], ui.mouse_pos())
        }
    } else if e.pending_collapse != "" {
        explorer_select_single(e, e.pending_collapse)
    }

    e.dragging = false
    delete(e.drag_target)
    e.drag_target = ""
    delete(e.pending_collapse)
    e.pending_collapse = ""
    explorer_clear_drag_sources(e)
}

@(private = "file")
explorer_keys :: proc(thor: ^Thor) {
    e := &thor.explorer
    rows := explorer_visible_rows(e)
    if len(rows) == 0 {
        return
    }
    index := -1
    for row, i in rows {
        if row.node.path == e.selected_path {
            index = i
            break
        }
    }

    if ui.take_key(.Up) {
        next := index < 0 ? 0 : max(index - 1, 0)
        explorer_select_single(e, rows[next].node.path)
    }
    if ui.take_key(.Down) {
        next := index < 0 ? 0 : min(index + 1, len(rows) - 1)
        explorer_select_single(e, rows[next].node.path)
    }
    if ui.take_key(.Left) && index >= 0 {
        node := rows[index].node
        if node.is_dir && node.expanded {
            explorer_set_expanded(e, node, false)
        } else if node.parent != nil && node.parent != e.root {
            explorer_select_single(e, node.parent.path)
        }
    }
    if ui.take_key(.Right) && index >= 0 {
        node := rows[index].node
        if node.is_dir {
            if !node.expanded {
                explorer_set_expanded(e, node, true)
            } else if len(node.children) > 0 {
                explorer_select_single(e, node.children[0].path)
            }
        }
    }
    if (ui.take_key(.Enter) || ui.take_key(.Pad_Enter)) && index >= 0 {
        node := rows[index].node
        if node.is_dir {
            explorer_set_expanded(e, node, !node.expanded)
        } else {
            thor_tree_open(thor, node.path)
        }
    }
    // Folders included: the confirmation sits in front of the removal, and
    // silently ignoring the key reads as a broken Delete.
    if ui.take_key(.Delete) && index >= 0 {
        thor_tree_delete(thor, rows[index].node.path)
    }
}

// ---- file icons -------------------------------------------------------------------

// Vendor (brand) colour for a file's language, GitHub-linguist style, used to
// tint its row icon. `ok` is false for names with no known language, so the
// caller keeps its neutral fallback. Colours are lightened where the true brand
// tone would be too dark to read on a dark background.
@(private = "file")
explorer_vendor_color :: proc(name: string) -> (ui.Color, bool) {
    switch name {
    case "Dockerfile":
        return ui.Color{58, 137, 227, 255}, true
    case "CMakeLists.txt":
        return ui.Color{100, 130, 173, 255}, true
    }

    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return {}, false
    }

    switch name[dot:] {
    case ".c", ".h":                           return ui.Color{90, 150, 214, 255}, true
    case ".cpp", ".hpp", ".cc", ".hh", ".cxx": return ui.Color{243, 75, 125, 255}, true
    case ".rs":                                return ui.Color{222, 165, 132, 255}, true
    case ".go":                                return ui.Color{0, 173, 216, 255}, true
    case ".py", ".pyw":                        return ui.Color{255, 212, 59, 255}, true
    case ".js", ".mjs", ".cjs":                return ui.Color{241, 224, 90, 255}, true
    case ".ts":                                return ui.Color{73, 143, 217, 255}, true
    case ".jsx", ".tsx":                       return ui.Color{97, 218, 251, 255}, true
    case ".zig":                               return ui.Color{236, 145, 92, 255}, true
    case ".glsl", ".vert", ".frag":            return ui.Color{90, 150, 214, 255}, true
    case ".md":                                return ui.Color{117, 143, 255, 255}, true
    case ".json":                              return ui.Color{203, 161, 53, 255}, true
    case ".yml", ".yaml":                      return ui.Color{203, 75, 80, 255}, true
    case ".xml":                               return ui.Color{150, 190, 90, 255}, true
    case ".html", ".htm":                      return ui.Color{227, 100, 60, 255}, true
    case ".css":                               return ui.Color{102, 129, 214, 255}, true
    case ".scss", ".sass":                     return ui.Color{207, 100, 154, 255}, true
    case ".lua":                               return ui.Color{80, 120, 255, 255}, true
    case ".java":                              return ui.Color{214, 143, 61, 255}, true
    case ".kt", ".kts":                        return ui.Color{169, 123, 255, 255}, true
    case ".cs":                                return ui.Color{104, 33, 122, 255}, true
    case ".fs":                                return ui.Color{55, 139, 186, 255}, true
    case ".swift":                             return ui.Color{240, 81, 56, 255}, true
    case ".rb":                                return ui.Color{204, 52, 45, 255}, true
    case ".php":                               return ui.Color{119, 123, 180, 255}, true
    case ".hs":                                return ui.Color{143, 78, 139, 255}, true
    case ".ex", ".exs":                        return ui.Color{150, 120, 180, 255}, true
    case ".jl":                                return ui.Color{150, 90, 165, 255}, true
    case ".pl", ".pm":                         return ui.Color{90, 130, 190, 255}, true
    case ".dart":                              return ui.Color{0, 180, 171, 255}, true
    case ".scala":                             return ui.Color{194, 65, 84, 255}, true
    case ".clj", ".cljs":                      return ui.Color{130, 190, 80, 255}, true
    case ".erl":                               return ui.Color{184, 57, 152, 255}, true
    case ".ml", ".mli":                        return ui.Color{232, 137, 62, 255}, true
    case ".nim":                               return ui.Color{240, 200, 80, 255}, true
    case ".sh", ".bash", ".zsh":               return ui.Color{137, 224, 81, 255}, true
    case ".ps1", ".psm1":                      return ui.Color{90, 145, 216, 255}, true
    case ".vim":                               return ui.Color{90, 175, 90, 255}, true
    case ".tex", ".bib":                       return ui.Color{120, 160, 200, 255}, true
    case ".cmake":                             return ui.Color{100, 130, 173, 255}, true
    case ".vue":                               return ui.Color{65, 184, 131, 255}, true
    case ".svelte":                            return ui.Color{255, 90, 45, 255}, true
    case ".graphql", ".gql":                   return ui.Color{229, 53, 171, 255}, true
    case ".gitignore", ".gitattributes", ".gitmodules":
        return ui.Color{240, 80, 50, 255}, true
    case ".odin":                              return ui.Color{104, 172, 227, 255}, true
    }
    return {}, false
}

// Language files get a `filetype-` glyph from the active file icon pack; `.odin`
// has no glyph in either pack, so it keeps its own family, and everything else
// falls back to the generic file icons of the primary pack.
@(private = "file")
explorer_file_icon :: proc(name: string) -> string {
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
    case ".c", ".h":                           return "filetype-c"
    case ".cpp", ".hpp", ".cc", ".hh", ".cxx": return "filetype-cpp"
    case ".rs":                                return "filetype-rust"
    case ".go":                                return "filetype-go"
    case ".py", ".pyw":                        return "filetype-python"
    case ".js", ".mjs", ".cjs":                return "filetype-javascript"
    case ".ts":                                return "filetype-typescript"
    case ".jsx", ".tsx":                       return "filetype-react"
    case ".zig":                               return "filetype-zig"
    case ".glsl", ".vert", ".frag":            return "filetype-glsl"
    case ".md":                                return "filetype-markdown"
    case ".json":                              return "filetype-json"
    case ".yml", ".yaml":                      return "filetype-yaml"
    case ".xml":                               return "filetype-xml"
    case ".html", ".htm":                      return "filetype-html"
    case ".css":                               return "filetype-css"
    case ".scss", ".sass":                     return "filetype-sass"
    case ".lua":                               return "filetype-lua"
    case ".java":                              return "filetype-java"
    case ".kt", ".kts":                        return "filetype-kotlin"
    case ".cs":                                return "filetype-csharp"
    case ".fs":                                return "filetype-fsharp"
    case ".swift":                             return "filetype-swift"
    case ".rb":                                return "filetype-ruby"
    case ".php":                               return "filetype-php"
    case ".hs":                                return "filetype-haskell"
    case ".ex", ".exs":                        return "filetype-elixir"
    case ".jl":                                return "filetype-julia"
    case ".pl", ".pm":                         return "filetype-perl"
    case ".dart":                              return "filetype-dart"
    case ".scala":                             return "filetype-scala"
    case ".clj", ".cljs":                      return "filetype-clojure"
    case ".erl":                               return "filetype-erlang"
    case ".ml", ".mli":                        return "filetype-ocaml"
    case ".nim":                               return "filetype-nim"
    case ".sh", ".bash", ".zsh":               return "filetype-shell"
    case ".ps1", ".psm1":                      return "filetype-powershell"
    case ".vim":                               return "filetype-vim"
    case ".tex", ".bib":                       return "filetype-latex"
    case ".cmake":                             return "filetype-cmake"
    case ".vue":                               return "filetype-vue"
    case ".svelte":                            return "filetype-svelte"
    case ".graphql", ".gql":                   return "filetype-graphql"
    case ".gitignore", ".gitattributes", ".gitmodules":
        return "filetype-git"
    case ".odin":                              return "odin"
    case ".asm", ".s", ".sql", ".bat", ".slang", ".slangh":
        return "file-code"
    case ".txt", ".toml", ".ini", ".cfg", ".log":
        return "file-text"
    }
    return "file"
}
