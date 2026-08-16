package thor

import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../lang"
import "../plugin"
import "../setting"
import "../textedit"
import "../ui"
import "../widgets"

thor_apply_layout_state :: proc(thor: ^Thor) {
    has_workspace := thor.workspace_dir != ""
    explorer_visible := has_workspace && ui.signal_get(&thor.explorer_visible)
    console_visible := has_workspace && ui.signal_get(&thor.console_visible)

    thor.explorer_panel.visible = explorer_visible
    thor.explorer_splitter.visible = explorer_visible
    thor.explorer_stub_panel.visible = has_workspace && !explorer_visible

    thor.console_splitter.visible = console_visible
    thor.console_panel.visible = console_visible
    thor.console_stub_panel.visible = has_workspace && !console_visible

    thor.tabbar.visible = has_workspace

    thor.explorer_panel.min_size[0] = thor.explorer_width
    thor.console_panel.min_size[1] = thor.console_height
}

thor_on_visibility_changed :: proc(data: rawptr, value: bool) {
    thor_apply_layout_state(cast(^Thor) data)
}

// Widget for a pane index (0 = primary, 1 = split).
@(private)
thor_pane_editor :: proc(thor: ^Thor, pane: int) -> ^widgets.Editor {
    return pane == 0 ? thor.editor : thor.editor2
}

// Widget of the pane the user is in, the target of every command that acts on
// one pane only.
@(private)
thor_active_editor :: proc(thor: ^Thor) -> ^widgets.Editor {
    return thor_pane_editor(thor, thor.active_pane)
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
// keep_view holds the scroll offset, for a re-bind of the buffer already shown.
thor_bind_pane :: proc(thor: ^Thor, pane: int, keep_view := false) {
    index := thor.pane_file[pane]
    file: ^Open_File
    if index >= 0 && index < len(thor.open_files) {
        file = thor.open_files[index]
    }
    thor_bind_editor(thor, thor_pane_editor(thor, pane), file, keep_view)
}

// Binds a single editor widget to a file's buffer, or shows a placeholder while
// there is nothing loaded to draw.
thor_bind_editor :: proc(thor: ^Thor, editor: ^widgets.Editor, file: ^Open_File, keep_view := false) {
    if file == nil || file.load_failed || !file.loaded {
        editor.placeholder = "No file open"
        if file != nil {
            switch {
            case file.load_failed: editor.placeholder = "Could not open file"
            // A model loads synchronously (thor_load_model), so this text is
            // never actually seen mid-load; an image loads on the async
            // worker now (thor_apply_image), so it can be.
            case file.is_image:    editor.placeholder = file.texture_loaded ? "Image" : "Loading image..."
            case file.is_model:    editor.placeholder = "3D Model"
            case:                  editor.placeholder = "Loading..."
            }
        }
        widgets.editor_set_state(editor, nil)
        return
    }
    widgets.editor_set_comment_prefix(editor, setting.comment_prefix(&thor.config, file.name))
    ext := thor_lang_key(thor, file.name)
    widgets.editor_set_completion_semantic(editor, lang.manager_allows(&thor.lang_manager, ext, .Completion))
    widgets.editor_set_on_type_enabled(editor, lang.manager_allows(&thor.lang_manager, ext, .Format_On_Type))
    // What a snippet's $TM_FILENAME and $TM_DIRECTORY resolve to.
    dir := filepath.dir(file.path)
    defer delete(dir)
    widgets.editor_set_snippet_vars(editor, file.path, dir)
    if keep_view {
        widgets.editor_reload_state(editor, &file.state)
    } else {
        widgets.editor_set_state(editor, &file.state)
    }
    widgets.editor_set_highlights(editor, file.highlights[:])
    widgets.editor_set_folds(editor, file.folds[:])
}

// Re-binds any pane currently showing `file` (used after its load completes).
thor_rebind_file_panes :: proc(thor: ^Thor, file: ^Open_File, keep_view := false) {
    for index, pane in thor.pane_file {
        if index >= 0 && index < len(thor.open_files) && thor.open_files[index] == file {
            thor_bind_pane(thor, pane, keep_view)
        }
    }
}

// Pushes `file`'s fresh highlight spans to every pane showing it.
thor_apply_file_highlights :: proc(thor: ^Thor, file: ^Open_File) {
    for index, pane in thor.pane_file {
        if index >= 0 && index < len(thor.open_files) && thor.open_files[index] == file {
            editor := thor_pane_editor(thor, pane)
            widgets.editor_set_highlights(editor, file.highlights[:])
            widgets.editor_set_folds(editor, file.folds[:])
        }
    }
}

// Pushes a pane's diagnostics to its editor, or clears them when the buffer has
// moved past the revision they were checked at (so squiggles never sit at stale
// offsets). Called every frame — pushing a borrowed slice is just a pointer set.
thor_sync_pane_diagnostics :: proc(thor: ^Thor, pane: int) {
    index := thor.pane_file[pane]
    if index < 0 || index >= len(thor.open_files) {
        return
    }
    file := thor.open_files[index]
    editor := thor_pane_editor(thor, pane)
    if file.loaded && file.diagnostics_revision == file.state.revision && len(file.diagnostics) > 0 {
        widgets.editor_set_diagnostics(editor, file.diagnostics[:])
    } else {
        widgets.editor_set_diagnostics(editor, nil)
    }
}

// Pushes a pane's git diff lines to its editor. Called every frame alongside
// thor_sync_pane_diagnostics — pushing a borrowed slice is just a pointer set.
thor_sync_pane_diff :: proc(thor: ^Thor, pane: int) {
    index := thor.pane_file[pane]
    if index < 0 || index >= len(thor.open_files) {
        return
    }
    file := thor.open_files[index]
    editor := thor_pane_editor(thor, pane)
    if file.loaded && len(file.diff_lines) > 0 {
        widgets.editor_set_diff_lines(editor, file.diff_lines[:])
    } else {
        widgets.editor_set_diff_lines(editor, nil)
    }
}

// Swaps the image view in for image files and the model view in for 3D models
// (both whole-panel overlays), and swaps
// the markdown preview in for whichever pane is not currently focused when the
// active file is markdown and preview is on -- the focused pane keeps showing
// the source, like opening the preview "to the side". Called every frame so it
// tracks tab switches, splits, toggles and closes without each having to poke it.
thor_update_editor_view :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    show_image := file != nil && file.is_image && file.texture_loaded
    show_model := file != nil && file.is_model && file.model_loaded
    show_md := !show_image && !show_model && thor.markdown_preview &&
        file != nil && file.loaded && thor_is_markdown(file.name)

    has_workspace := thor.workspace_dir != ""
    thor.image_view.visible = show_image
    thor.model_view.visible = show_model
    thor.editor_split_row.visible = has_workspace && !show_image && !show_model
    thor.welcome_panel.visible = !has_workspace

    if show_image {
        widgets.image_view_set_texture(thor.image_view, file.texture, file.name)
    } else {
        widgets.image_view_set_texture(thor.image_view, {}, "")
    }

    if show_model {
        widgets.model_view_set_model(thor.model_view, file.model, file.model_bounds, file.name)
    } else {
        widgets.model_view_set_model(thor.model_view, {}, {}, "")
    }

    // The preview needs a second pane to sit beside the source; open the split
    // first if it is not already on, without moving focus off the source.
    if show_md && !thor.split_visible {
        thor.split_visible = true
        thor_apply_split(thor)
    }

    preview_pane := show_md ? 1 - thor.active_pane : -1

    thor.editor.visible = preview_pane != 0
    thor.markdown_view.visible = preview_pane == 0
    thor.editor2.visible = thor.split_visible && preview_pane != 1
    thor.markdown_view2.visible = preview_pane == 1

    if preview_pane == 0 {
        thor.markdown_view.grow = thor.editor.grow
        widgets.markdown_view_set_font_size(thor.markdown_view, thor.editor2.font_size)
        widgets.markdown_view_set_source(
            thor.markdown_view,
            textedit.text(&file.state),
            file.state.revision,
            &file.state,
        )
    }
    if preview_pane == 1 {
        thor.markdown_view2.grow = thor.editor2.grow
        widgets.markdown_view_set_font_size(thor.markdown_view2, thor.editor.font_size)
        widgets.markdown_view_set_source(
            thor.markdown_view2,
            textedit.text(&file.state),
            file.state.revision,
            &file.state,
        )
    }
}

@(private = "file")
thor_is_markdown :: proc(name: string) -> bool {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return false
    }
    switch strings.to_lower(name[dot:], context.temp_allocator) {
    case ".md", ".markdown", ".mdown", ".mkd":
        return true
    }
    return false
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
    if thor.lsp_progress_message != "" {
        info.busy = true
        info.busy_message = thor.lsp_progress_message
    } else if thor.lang_busy_shown {
        info.busy = true
        info.busy_message = thor_lang_busy_label(thor.lang_busy_kinds)
    }
    if thor.status_message != "" && rl.GetTime() - thor.status_message_time < STATUS_MESSAGE_SECS {
        info.message = thor.status_message
        info.is_error = thor.status_message_error
    }
    // Only the focused editor's jump count is being typed; a count another pane
    // was left holding is not shown.
    if editor := thor_pane_editor(thor, thor.active_pane);
       thor.ui_context.focused == &editor.widget {
        info.jump_count, info.jump_up, info.jump_active = widgets.editor_pending_jump(editor)
    }

    file := thor_active_open_file(thor)
    if file == nil {
        return info
    }

    info.file_open = true
    info.file_name = file.name
    info.file_path = file.path
    info.language = thor_language_name(thor, file.name)
    thor_refresh_indent(file)
    // detect_indent reports no width for tabs, and a width of 0 hides the
    // segment, so a tab-indented file shows the column width one renders as.
    info.indent_spaces = file.indent.style != .Tabs
    info.indent_width = textedit.tab_width(&file.state)
    if file.indent.style == .Spaces && file.indent.width > 0 {
        info.indent_width = file.indent.width
    }
    info.zoom = int(thor.editor.font_size) * 100 / max(setting.font_size(&thor.config), 1)
    info.saving = file.saving
    info.modified = file.loaded && file.state.revision != file.saved_revision
    if file.loaded {
        info.line_ending = thor_line_ending_label(file.line_ending)

        text := textedit.text(&file.state)
        caret := textedit.primary_cursor(&file.state).caret
        caret_line := textedit.state_line_index(&file.state, caret)
        info.line = caret_line + 1
        // Counted from the logical line start, so on a soft-wrapped continuation
        // row this and the caret's pixel column are deliberately different.
        info.column = textedit.column(text, caret, textedit.tab_width(&file.state)) + 1

        // With no transient notice up, show the diagnostic on the caret's line
        // (an error outranks a warning) so its message is readable without a hover.
        if info.message == "" && file.diagnostics_revision == file.state.revision {
            best := -1
            for d, i in file.diagnostics {
                if d.line != caret_line || d.message == "" {
                    continue
                }
                if best < 0 || (d.severity == .Error && file.diagnostics[best].severity != .Error) {
                    best = i
                }
            }
            if best >= 0 {
                info.message = file.diagnostics[best].message
                info.is_error = file.diagnostics[best].severity == .Error
            }
        }
    }

    return info
}

// Seconds between whole-buffer indent scans. The style does not change between
// keystrokes, and a scan per keystroke is a scan per character typed.
@(private = "file")
INDENT_SCAN_INTERVAL :: 1.0

// Re-reads the buffer's indentation when it has moved on and the last scan is
// old enough. detect_indent walks the whole file, and the status bar asks every
// frame.
@(private)
thor_refresh_indent :: proc(file: ^Open_File) {
    if !file.loaded {
        return
    }
    now := rl.GetTime()
    if file.indent_ready &&
       (file.indent_revision == file.state.revision || now - file.indent_time < INDENT_SCAN_INTERVAL) {
        return
    }
    file.indent = textedit.detect_indent(&file.state)
    file.indent_revision = file.state.revision
    file.indent_time = now
    file.indent_ready = true
}

// Language label for the status bar: the registered plugin's own name first, so
// every bundled and workspace language answers for itself and an extensionless
// name (Dockerfile, Makefile) resolves too; then the built-in table for formats
// no plugin claims; then the bare extension.
@(private = "file")
thor_language_name :: proc(thor: ^Thor, name: string) -> string {
    if id := plugin.language_name(&thor.plugins, thor_highlight_key(&thor.plugins, name)); id != "" {
        return id
    }
    if label, ok := thor_builtin_language_name(name); ok {
        return label
    }
    if ext := thor_file_extension(name); len(ext) > 1 {
        return strings.to_upper(ext[1:], context.temp_allocator)
    }
    return "Plain Text"
}

// Names for formats with no language plugin. `ok` is false for a name this does
// not know, which is what separates a miss from a real "Plain Text".
@(private = "file")
thor_builtin_language_name :: proc(name: string) -> (string, bool) {
    // Named after the whole file, so the extension says nothing.
    switch name {
    case "CMakeLists.txt": return "CMake", true
    }

    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return "", false
    }

    switch name[dot:] {
    case ".odin": return "Odin", true
    case ".c", ".h": return "C", true
    case ".cpp", ".cc", ".cxx", ".c++", ".hpp", ".hh", ".hxx", ".h++", ".ipp": return "C++", true
    case ".rs": return "Rust", true
    case ".go": return "Go", true
    case ".jai": return "Jai", true
    case ".py": return "Python", true
    case ".js", ".jsx", ".mjs", ".cjs": return "JavaScript", true
    case ".lua": return "Lua", true
    case ".ts", ".mts", ".cts": return "TypeScript", true
    case ".tsx": return "TSX", true
    case ".zig": return "Zig", true
    case ".md": return "Markdown", true
    case ".json": return "JSON", true
    case ".toml": return "TOML", true
    case ".yml", ".yaml": return "YAML", true
    case ".xml": return "XML", true
    case ".html": return "HTML", true
    case ".css": return "CSS", true
    case ".glsl", ".vert", ".frag": return "GLSL", true
    case ".slang", ".slangh": return "Slang", true
    case ".cmake": return "CMake", true
    case ".bat", ".cmd": return "Batch", true
    case ".sh", ".bash", ".zsh", ".ksh", ".bashrc", ".zshrc": return "Shell", true
    case ".txt": return "Plain Text", true
    }
    return "", false
}

thor_tab_count :: proc(data: rawptr) -> int {
    thor := cast(^Thor) data
    return len(thor.open_files)
}

// Whether a file has something to show: a loaded text buffer, an uploaded
// image texture, or an uploaded model. `loaded` alone is never true for an
// image or a model — they bypass the text pipeline entirely — so a caller
// asking "is there anything to draw yet" must check all three, not `loaded`.
thor_file_ready :: proc(file: ^Open_File) -> bool {
    return file.loaded || file.texture_loaded || file.model_loaded
}

thor_tab_info :: proc(data: rawptr, index: int) -> widgets.Tab_Info {
    thor := cast(^Thor) data
    file := thor.open_files[index]
    return widgets.Tab_Info {
        name = len(file.tab_label) > 0 ? file.tab_label : file.name,
        tooltip = file.path,
        modified = file.loaded && file.state.revision != file.saved_revision,
        loading = !thor_file_ready(file) && !file.load_failed,
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
