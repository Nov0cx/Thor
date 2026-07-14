package thor

import "core:strings"
import "core:unicode/utf8"

import "../setting"
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

// Widget for a pane index (0 = primary, 1 = split).
@(private = "file")
thor_pane_editor :: proc(thor: ^Thor, pane: int) -> ^widgets.Editor {
    return pane == 0 ? thor.editor : thor.editor2
}

// Mirrors the focused pane's file into the active_file signal, the value the
// tabbar, status bar and file commands read.
thor_sync_active_signal :: proc(thor: ^Thor) {
    ui.signal_set(&thor.active_file, thor.pane_file[thor.active_pane])
}

// Opens `index` in the focused pane. A still-loading file leaves the pane empty
// (state nil); thor_process_io re-binds it once the load lands.
thor_set_active_file :: proc(thor: ^Thor, index: int) {
    // Remember the file we are leaving so ctrl+e can flip back. Only a switch to
    // a different file updates it; a same-index refresh must not clobber it.
    previous := thor_active_open_file(thor)
    thor.pane_file[thor.active_pane] = index
    thor_sync_active_signal(thor)

    file := thor_active_open_file(thor)
    if previous != nil && previous != file {
        thor.last_active_file = previous
    }
    thor_bind_pane(thor, thor.active_pane)
}

// Points one pane's editor at whatever file its index names (or empties it).
thor_bind_pane :: proc(thor: ^Thor, pane: int) {
    index := thor.pane_file[pane]
    file: ^Open_File
    if index >= 0 && index < len(thor.open_files) {
        file = thor.open_files[index]
    }
    thor_bind_editor(thor, thor_pane_editor(thor, pane), file)
}

// Binds a single editor widget to a file's buffer, or shows a placeholder while
// there is nothing loaded to draw.
thor_bind_editor :: proc(thor: ^Thor, editor: ^widgets.Editor, file: ^Open_File) {
    if file == nil || file.load_failed || !file.loaded {
        editor.placeholder = "No file open"
        if file != nil {
            switch {
            case file.load_failed: editor.placeholder = "Could not open file"
            case file.is_image:    editor.placeholder = "Image"
            case:                  editor.placeholder = "Loading..."
            }
        }
        widgets.editor_set_state(editor, nil)
        return
    }
    widgets.editor_set_comment_prefix(editor, setting.comment_prefix(&thor.config, file.name))
    widgets.editor_set_state(editor, &file.state)
    widgets.editor_set_highlights(editor, file.highlights[:])
}

// Re-binds any pane currently showing `file` (used after its load completes).
thor_rebind_file_panes :: proc(thor: ^Thor, file: ^Open_File) {
    for index, pane in thor.pane_file {
        if index >= 0 && index < len(thor.open_files) && thor.open_files[index] == file {
            thor_bind_pane(thor, pane)
        }
    }
}

// Pushes `file`'s fresh highlight spans to every pane showing it.
thor_apply_file_highlights :: proc(thor: ^Thor, file: ^Open_File) {
    for index, pane in thor.pane_file {
        if index >= 0 && index < len(thor.open_files) && thor.open_files[index] == file {
            widgets.editor_set_highlights(thor_pane_editor(thor, pane), file.highlights[:])
        }
    }
}

// Swaps the editor panes out for the image view when the active file is an
// image, and back again otherwise. Called every frame so it tracks tab switches,
// splits and closes without each having to poke it.
thor_update_editor_view :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    show_image := file != nil && file.is_image && file.texture_loaded

    thor.image_view.visible = show_image
    thor.editor_split_row.visible = !show_image

    if show_image {
        widgets.image_view_set_texture(thor.image_view, file.texture, file.name)
    } else {
        widgets.image_view_set_texture(thor.image_view, {}, "")
    }
}

// Follows keyboard focus: whichever editor pane holds focus becomes the active
// pane, so the tabbar and status bar track it. Called once per frame.
thor_sync_active_pane :: proc(thor: ^Thor) {
    pane := thor.active_pane
    if !thor.split_visible {
        pane = 0
    } else if thor.ui_context.focused == &thor.editor.widget {
        pane = 0
    } else if thor.ui_context.focused == &thor.editor2.widget {
        pane = 1
    }
    if pane != thor.active_pane {
        thor.active_pane = pane
        thor_sync_active_signal(thor)
    }
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
    info.indent_width = textedit.tab_width()
    info.indent_spaces = true
    info.zoom = int(thor.editor.font_size) * 100 / max(setting.font_size(&thor.config), 1)
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
    case ".cpp", ".cc", ".cxx", ".c++", ".hpp", ".hh", ".hxx", ".h++", ".ipp": return "C++"
    case ".rs": return "Rust"
    case ".go": return "Go"
    case ".jai": return "Jai"
    case ".py": return "Python"
    case ".js", ".jsx", ".mjs", ".cjs": return "JavaScript"
    case ".lua": return "Lua"
    case ".ts", ".mts", ".cts": return "TypeScript"
    case ".tsx": return "TSX"
    case ".zig": return "Zig"
    case ".md": return "Markdown"
    case ".json": return "JSON"
    case ".toml": return "TOML"
    case ".yml", ".yaml": return "YAML"
    case ".xml": return "XML"
    case ".html": return "HTML"
    case ".css": return "CSS"
    case ".glsl", ".vert", ".frag": return "GLSL"
    case ".bat", ".cmd": return "Batch"
    case ".sh", ".bash", ".zsh", ".ksh", ".bashrc", ".zshrc": return "Shell"
    case ".txt": return "Plain Text"
    }
    return "Plain Text"
}

thor_tab_count :: proc(data: rawptr) -> int {
    thor := cast(^Thor) data
    return len(thor.open_files)
}

thor_tab_info :: proc(data: rawptr, index: int) -> widgets.Tab_Info {
    thor := cast(^Thor) data
    file := thor.open_files[index]
    return widgets.Tab_Info {
        name = len(file.tab_label) > 0 ? file.tab_label : file.name,
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
