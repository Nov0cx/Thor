package widgets

import "core:os"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

import "../ui"

Tree_Open_Proc :: #type proc(data: rawptr, path: string)

// Git working-tree status for a path, resolved by the owner (Tree_Status_Proc).
// Directories report an aggregate (Modified / Conflict) when they contain
// changes so the folder name can be tinted too.
Git_Status :: enum u8 {
    None,
    Modified,
    Added,
    Untracked,
    Deleted,
    Renamed,
    Conflict,
}

Tree_Status_Proc :: #type proc(data: rawptr, path: string, is_dir: bool) -> Git_Status

Tree_Node :: struct {
    name:     string, // owned
    path:     string, // owned, full path
    is_dir:   bool,
    expanded: bool,
    loaded:   bool, // directory contents read from disk
    children: [dynamic]^Tree_Node,
}

// Directory tree fed lazily from the filesystem; expanding a folder reads it
// on first open. Rows are drawn directly (no child widgets), so open/close
// costs nothing in the widget tree.
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
    // Right-click opens a context menu supplied by the owner.
    on_context_menu:  Context_Menu_Proc,
    context_menu_data: rawptr,
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
    tree.min_size = rl.Vector2 {0, 120}

    tree.root = new(Tree_Node)
    tree.root.name = strings.clone(root_path)
    tree.root.path = strings.clone(root_path)
    tree.root.is_dir = true
    tree.root.expanded = true
    tree_load_children(tree.root)

    return tree
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

// Enables git status highlighting: `status_proc` maps a path to its status.
tree_set_git :: proc(tree: ^Tree, status_proc: Tree_Status_Proc, data: rawptr) {
    tree.status_proc = status_proc
    tree.status_data = data
}

tree_set_git_colors :: proc(tree: ^Tree, modified, added, deleted, conflict: rl.Color) {
    tree.git_modified_color = modified
    tree.git_added_color = added
    tree.git_deleted_color = deleted
    tree.git_conflict_color = conflict
}

@(private = "file")
tree_status_color :: proc(tree: ^Tree, status: Git_Status) -> rl.Color {
    switch status {
    case .None:                return tree.text_color
    case .Modified, .Renamed:  return tree.git_modified_color
    case .Added, .Untracked:   return tree.git_added_color
    case .Deleted:             return tree.git_deleted_color
    case .Conflict:            return tree.git_conflict_color
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
            ui.draw_icon(tree_file_icon(node.name), cast(i32) x, icon_y, tree.icon_size, tree.chevron_color)
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
}

// Language files get their devicon glyph (the "devicon-" names live in the
// devicons set of the icon manifest); everything else falls back to the
// generic tabler file icons.
@(private = "file")
tree_file_icon :: proc(name: string) -> string {
    switch name {
    case "Dockerfile":
        return "devicon-docker-plain"
    case "CMakeLists.txt":
        return "devicon-cmake-plain"
    }

    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return "file"
    }

    switch name[dot:] {
    case ".c", ".h":
        return "devicon-c-plain"
    case ".cpp", ".hpp", ".cc", ".hh", ".cxx":
        return "devicon-cplusplus-plain"
    case ".rs":
        return "devicon-rust-plain"
    case ".go":
        return "devicon-go-plain"
    case ".py", ".pyw":
        return "devicon-python-plain"
    case ".js", ".mjs", ".cjs":
        return "devicon-javascript-plain"
    case ".ts":
        return "devicon-typescript-plain"
    case ".jsx", ".tsx":
        return "devicon-react-original"
    case ".zig":
        return "devicon-zig-plain"
    case ".glsl", ".vert", ".frag":
        return "devicon-opengl-plain"
    case ".md":
        return "devicon-markdown-original"
    case ".json":
        return "devicon-json-plain"
    case ".yml", ".yaml":
        return "devicon-yaml-plain"
    case ".xml":
        return "devicon-xml-plain"
    case ".html", ".htm":
        return "devicon-html5-plain"
    case ".css":
        return "devicon-css3-plain"
    case ".scss", ".sass":
        return "devicon-sass-original"
    case ".lua":
        return "devicon-lua-plain"
    case ".java":
        return "devicon-java-plain"
    case ".kt", ".kts":
        return "devicon-kotlin-plain"
    case ".cs":
        return "devicon-csharp-plain"
    case ".fs":
        return "devicon-fsharp-plain"
    case ".swift":
        return "devicon-swift-plain"
    case ".rb":
        return "devicon-ruby-plain"
    case ".php":
        return "devicon-php-plain"
    case ".hs":
        return "devicon-haskell-plain"
    case ".ex", ".exs":
        return "devicon-elixir-plain"
    case ".jl":
        return "devicon-julia-plain"
    case ".pl", ".pm":
        return "devicon-perl-plain"
    case ".dart":
        return "devicon-dart-plain"
    case ".scala":
        return "devicon-scala-plain"
    case ".clj", ".cljs":
        return "devicon-clojure-plain"
    case ".erl":
        return "devicon-erlang-plain"
    case ".ml", ".mli":
        return "devicon-ocaml-plain"
    case ".nim":
        return "devicon-nim-plain"
    case ".sh", ".bash", ".zsh":
        return "devicon-bash-plain"
    case ".ps1", ".psm1":
        return "devicon-powershell-plain"
    case ".vim":
        return "devicon-vim-plain"
    case ".tex", ".bib":
        return "devicon-latex-plain"
    case ".cmake":
        return "devicon-cmake-plain"
    case ".vue":
        return "devicon-vuejs-plain"
    case ".svelte":
        return "devicon-svelte-plain"
    case ".graphql", ".gql":
        return "devicon-graphql-plain"
    case ".gitignore", ".gitattributes", ".gitmodules":
        return "devicon-git-plain"
    case ".odin":
        return "odin"
    case ".asm", ".s", ".sql", ".bat":
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
    free(tree)
}
