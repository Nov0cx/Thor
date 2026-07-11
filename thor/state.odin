package thor

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import "../textedit"
import "../ui"
import "../widgets"

thor_apply_layout_state :: proc(thor: ^Thor) {
    explorer_visible := ui.signal_get(&thor.explorer_visible)
    console_visible := ui.signal_get(&thor.console_visible)

    thor.explorer_panel.visible = explorer_visible
    thor.explorer_splitter.visible = explorer_visible
    thor.explorer_stub_panel.visible = !explorer_visible

    thor.console_splitter.visible = console_visible
    thor.console_panel.visible = console_visible
    thor.console_stub_panel.visible = !console_visible

    thor.explorer_panel.min_size[0] = thor.explorer_width
    thor.console_panel.min_size[1] = thor.console_height
}

// Points the editor at the buffer of the newly active file. A file that is
// still loading keeps the editor empty (state nil) so nothing can be typed
// into a buffer that set_text is about to replace; thor_process_io re-runs
// this once the load lands.
thor_set_active_file :: proc(thor: ^Thor, index: int) {
    ui.signal_set(&thor.active_file, index)

    file := thor_active_open_file(thor)
    if file == nil {
        thor.editor.placeholder = "No file open"
        widgets.editor_set_state(thor.editor, nil)
        return
    }

    if file.load_failed {
        thor.editor.placeholder = "Could not open file"
        widgets.editor_set_state(thor.editor, nil)
        return
    }
    if !file.loaded {
        thor.editor.placeholder = "Loading..."
        widgets.editor_set_state(thor.editor, nil)
        return
    }

    widgets.editor_set_comment_prefix(thor.editor, thor_comment_prefix(file.name))
    widgets.editor_set_state(thor.editor, &file.state)
}

// Line-comment marker by file extension; empty disables Ctrl+K commenting.
@(private = "file")
thor_comment_prefix :: proc(name: string) -> string {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return ""
    }

    switch name[dot:] {
    case ".odin", ".c", ".h", ".cpp", ".hpp", ".cc", ".rs", ".go", ".js", ".ts", ".zig", ".glsl", ".vert", ".frag":
        return "//"
    case ".py", ".sh", ".toml", ".yml", ".yaml", ".gitignore", ".gitmodules":
        return "#"
    case ".ini", ".cfg":
        return ";"
    }
    return ""
}

thor_console_text :: proc(data: rawptr) -> string {
    thor := cast(^Thor) data

    file := thor_active_open_file(thor)
    active := file != nil ? file.path : "none"
    return fmt.tprintf(
        "> workspace: %s\n> branch: %s\n> open files: %d\n> active: %s",
        thor.workspace_dir,
        thor.git_branch != "" ? thor.git_branch : "no git",
        len(thor.open_files),
        active,
    )
}

thor_status_info :: proc(data: rawptr) -> widgets.Status_Info {
    thor := cast(^Thor) data

    info: widgets.Status_Info
    info.branch = thor.git_branch
    info.line = 1
    info.column = 1

    file := thor_active_open_file(thor)
    if file == nil {
        return info
    }

    info.file_open = true
    info.file_name = file.name
    info.language = thor_language_name(file.name)
    info.indent_width = textedit.TAB_WIDTH
    info.indent_spaces = true
    info.saving = file.saving
    info.modified = file.loaded && file.state.revision != file.saved_revision

    if file.loaded {
        text := textedit.text(&file.state)
        caret := textedit.primary_cursor(&file.state).caret
        line_start := textedit.line_start(text, caret)
        info.line = textedit.line_index(text, caret) + 1
        info.column = utf8.rune_count_in_string(text[line_start:caret]) + 1
    }

    return info
}

@(private = "file")
thor_language_name :: proc(name: string) -> string {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return "Plain Text"
    }

    switch name[dot:] {
    case ".odin": return "Odin"
    case ".c", ".h": return "C"
    case ".cpp", ".hpp", ".cc": return "C++"
    case ".rs": return "Rust"
    case ".go": return "Go"
    case ".py": return "Python"
    case ".js": return "JavaScript"
    case ".ts": return "TypeScript"
    case ".zig": return "Zig"
    case ".md": return "Markdown"
    case ".json": return "JSON"
    case ".toml": return "TOML"
    case ".yml", ".yaml": return "YAML"
    case ".xml": return "XML"
    case ".html": return "HTML"
    case ".css": return "CSS"
    case ".glsl", ".vert", ".frag": return "GLSL"
    case ".txt": return "Plain Text"
    }
    return "Plain Text"
}

// --- Tabbar callbacks -------------------------------------------------------

thor_tab_count :: proc(data: rawptr) -> int {
    thor := cast(^Thor) data
    return len(thor.open_files)
}

thor_tab_info :: proc(data: rawptr, index: int) -> widgets.Tab_Info {
    thor := cast(^Thor) data
    file := thor.open_files[index]
    return widgets.Tab_Info {
        name = file.name,
        modified = file.loaded && file.state.revision != file.saved_revision,
        loading = !file.loaded && !file.load_failed,
    }
}

thor_tab_active :: proc(data: rawptr) -> int {
    thor := cast(^Thor) data
    return ui.signal_get(&thor.active_file)
}

thor_tab_select :: proc(data: rawptr, index: int) {
    thor := cast(^Thor) data
    thor_set_active_file(thor, index)
}

thor_tab_close :: proc(data: rawptr, index: int) {
    thor := cast(^Thor) data
    thor_close_file(thor, index)
}
