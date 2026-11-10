package thor

import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "../editview"
import "../textedit"

// Bytes of op text a history row shows.
UNDO_HISTORY_SNIPPET :: 48

// Opens the Undo History picker over the focused buffer's undo tree. A pick moves the buffer to that state.
thor_cmd_undo_history :: proc(data: rawptr) {
    thor := cast(^Thor) data
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    state := &file.state
    root := textedit.history_root(state)
    if root == textedit.NO_NODE {
        thor_flash_status(thor, "No undo history")
        return
    }
    thor_clear_undo_history(thor)
    thor.undo_history_path = strings.clone(file.path)
    thor.undo_history_revision = state.revision

    items := make([dynamic]Pick_Item, context.temp_allocator)
    current := textedit.history_current(state)
    current_row := undo_history_rows(thor, state, &items, root, current, time.now())
    thor_palette_pick_rich(thor, "Undo history...", items[:], thor_pick_undo_history, thor)
    thor_palette_select_item(thor, current_row)
}

// Frees what the last Undo History picker kept.
thor_clear_undo_history :: proc(thor: ^Thor) {
    delete(thor.undo_history_path)
    thor.undo_history_path = ""
    clear(&thor.undo_history_nodes)
}

@(private = "file")
thor_pick_undo_history :: proc(data: rawptr, index: int) {
    thor := cast(^Thor) data
    if index < 0 || index >= len(thor.undo_history_nodes) {
        return
    }
    file := thor_open_file_at(thor, thor.undo_history_path)
    if file == nil || !file.loaded {
        thor_flash_status(thor, "The file of that undo history is closed", is_error = true)
        return
    }
    if file.state.revision != thor.undo_history_revision {
        thor_flash_status(thor, "The buffer changed; open Undo History again", is_error = true)
        return
    }
    if !textedit.undo_goto(&file.state, thor.undo_history_nodes[index]) {
        return
    }
    if editor := thor_pane_editor(thor, thor.active_pane); editor != nil && editor.state == &file.state {
        editview.editor_scroll_to_caret(editor)
    }
}

// Adds one row per node, depth-first from `root`: older branches indented below
// their parent, the newest child continuing at the same indent. Returns the row of `current`.
@(private = "file")
undo_history_rows :: proc(
    thor: ^Thor,
    state: ^textedit.State,
    items: ^[dynamic]Pick_Item,
    root, current: int,
    now: time.Time,
    indent := 0,
) -> int {
    current_row := -1
    index := root
    for index != textedit.NO_NODE {
        node := textedit.history_node(state, index)
        if node == nil {
            break
        }
        if index == current {
            current_row = len(items)
        }
        append(items, undo_history_item(thor, node, index == current, indent, now))
        append(&thor.undo_history_nodes, index)

        n := len(node.children)
        for k in 0 ..< max(n - 1, 0) {
            row := undo_history_rows(thor, state, items, node.children[k], current, now, indent + 1)
            if row >= 0 {
                current_row = row
            }
        }
        index = n > 0 ? node.children[n - 1] : textedit.NO_NODE
    }
    return current_row
}

@(private = "file")
undo_history_item :: proc(thor: ^Thor, node: ^textedit.Undo_Node, is_current: bool, indent: int, now: time.Time) -> Pick_Item {
    b := strings.builder_make(context.temp_allocator)
    for _ in 0 ..< indent {
        strings.write_string(&b, "  ")
    }
    strings.write_string(&b, is_current ? "● " : "○ ")
    fmt.sbprintf(&b, "#%d", node.seq)
    name_len := strings.builder_len(b)

    detail := ""
    if node.parent == textedit.NO_NODE {
        strings.write_string(&b, "  oldest state")
    } else {
        inserted, deleted := textedit.node_summary(node)
        fmt.sbprintf(&b, "  +%d -%d  %s", inserted, deleted, undo_history_age(time.diff(node.stamp, now)))
        if len(node.ops) > 0 {
            op := node.ops[0]
            sign := op.kind == .Insert ? "+ " : "- "
            snippet := undo_history_snippet(op.text)
            if snippet != "" {
                fmt.sbprintf(&b, "  %s%s", sign, snippet)
                detail = strings.concatenate({sign, snippet}, context.temp_allocator)
            }
        }
    }
    return Pick_Item {
        text     = strings.to_string(b),
        name_len = name_len,
        color    = is_current ? thor.theme.functions_color : thor.theme.primary_text_color,
        detail   = detail,
    }
}

// The first non-blank line of `text`, cut on a rune boundary.
@(private = "file")
undo_history_snippet :: proc(text: string) -> string {
    rest := text
    for line in strings.split_lines_iterator(&rest) {
        trimmed := strings.trim_space(line)
        if trimmed == "" {
            continue
        }
        if len(trimmed) <= UNDO_HISTORY_SNIPPET {
            return trimmed
        }
        cut := UNDO_HISTORY_SNIPPET
        for cut > 0 && !utf8.rune_start(trimmed[cut]) {
            cut -= 1
        }
        return strings.concatenate({trimmed[:cut], "…"}, context.temp_allocator)
    }
    return ""
}

@(private = "file")
undo_history_age :: proc(age: time.Duration) -> string {
    seconds := int(time.duration_seconds(age))
    switch {
    case seconds < 60:
        return fmt.tprintf("%ds ago", max(seconds, 0))
    case seconds < 3600:
        return fmt.tprintf("%dm ago", seconds / 60)
    case seconds < 86400:
        return fmt.tprintf("%dh ago", seconds / 3600)
    }
    return fmt.tprintf("%dd ago", seconds / 86400)
}
