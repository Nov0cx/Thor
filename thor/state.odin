package thor

import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

import "../lang"
import "../plugin"
import "../setting"
import "../textedit"
import ui "../vendor/loom/loom"
import "../editview"
// Keeps the two dock sizes usable. The panels themselves are declared from the
// visibility signals each frame, so there is nothing else to push here.
thor_apply_layout_state :: proc(thor: ^Thor) {
    thor.explorer_width = clamp(thor.explorer_width, EXPLORER_MIN_W, EXPLORER_MAX_W)
    thor.console_height = clamp(thor.console_height, CONSOLE_MIN_H, CONSOLE_MAX_H)
}

EXPLORER_MIN_W :: f32(160)
EXPLORER_MAX_W :: f32(640)
CONSOLE_MIN_H :: f32(110)
CONSOLE_MAX_H :: f32(720)

thor_on_visibility_changed :: proc(data: rawptr, value: bool) {
    thor_apply_layout_state(cast(^Thor) data)
}

// Widget for a pane index (0 = primary, 1 = split).
@(private)
thor_pane_editor :: proc(thor: ^Thor, pane: int) -> ^editview.Editor {
    return pane == 0 ? &thor.editor : &thor.editor2
}

// Widget of the pane the user is in, the target of every command that acts on
// one pane only.
@(private)
thor_active_editor :: proc(thor: ^Thor) -> ^editview.Editor {
    return thor_pane_editor(thor, thor.active_pane)
}

// Mirrors the focused pane's file into the active_file signal, the value the
// tabbar, status bar and file commands read.
thor_sync_active_signal :: proc(thor: ^Thor) {
    signal_set(&thor.active_file, thor.pane_file[thor.active_pane])
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
    // The rebind dropped the previous buffer's borrowed spans; push this file's
    // now, so the gutter is right for the rest of the frame.
    thor_sync_pane_diagnostics(thor, pane)
    thor_sync_pane_diff(thor, pane)
}

// Binds a single editor widget to a file's buffer, or shows a placeholder while
// there is nothing loaded to draw.
thor_bind_editor :: proc(thor: ^Thor, editor: ^editview.Editor, file: ^Open_File, keep_view := false) {
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
        editview.editor_set_state(editor, nil)
        return
    }
    editview.editor_set_comment_prefix(editor, setting.comment_prefix(&thor.config, file.name))
    ext := thor_lang_key(thor, file.name)
    editview.editor_set_completion_semantic(editor, lang.manager_allows(&thor.lang_manager, ext, .Completion))
    editview.editor_set_on_type_enabled(editor, lang.manager_allows(&thor.lang_manager, ext, .Format_On_Type))
    // What a snippet's $TM_FILENAME and $TM_DIRECTORY resolve to.
    dir := filepath.dir(file.path) // a slice of file.path, no allocation
    editview.editor_set_snippet_vars(editor, file.path, dir)
    if keep_view {
        editview.editor_reload_state(editor, &file.state)
    } else {
        editview.editor_set_state(editor, &file.state)
    }
    editview.editor_set_highlights(editor, file.highlights[:])
    editview.editor_set_folds(editor, file.folds[:])
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
            editview.editor_set_highlights(editor, file.highlights[:])
            editview.editor_set_folds(editor, file.folds[:])
        }
    }
}

// Pushes a pane's diagnostics to its editor, or clears them when the buffer has
// moved past the revision they were checked at (so squiggles never sit at stale
// offsets). Called every frame — pushing a borrowed slice is just a pointer set.
thor_sync_pane_diagnostics :: proc(thor: ^Thor, pane: int) {
    index := thor.pane_file[pane]
    editor := thor_pane_editor(thor, pane)
    if index < 0 || index >= len(thor.open_files) {
        // An empty pane must drop what it holds: the slice belongs to a
        // file that can be freed.
        editview.editor_set_diagnostics(editor, nil)
        return
    }
    file := thor.open_files[index]
    if file.loaded && file.diagnostics_revision == file.state.revision && len(file.diagnostics) > 0 {
        editview.editor_set_diagnostics(editor, file.diagnostics[:])
    } else {
        editview.editor_set_diagnostics(editor, nil)
    }
}

// Pushes a pane's git diff lines to its editor. Called every frame alongside
// thor_sync_pane_diagnostics — pushing a borrowed slice is just a pointer set.
thor_sync_pane_diff :: proc(thor: ^Thor, pane: int) {
    index := thor.pane_file[pane]
    editor := thor_pane_editor(thor, pane)
    if index < 0 || index >= len(thor.open_files) {
        // An empty pane must drop what it holds: the slice belongs to a
        // file that can be freed.
        editview.editor_set_diff_lines(editor, nil)
        return
    }
    file := thor.open_files[index]
    if file.loaded && len(file.diff_lines) > 0 {
        editview.editor_set_diff_lines(editor, file.diff_lines[:])
    } else {
        editview.editor_set_diff_lines(editor, nil)
    }
}

// What one editor pane shows.
Pane_Content :: enum {
    Editor,
    Markdown,
}

// What the workspace area shows this frame. An image, a model and the welcome
// page each take the whole area; otherwise the two panes show a source or the
// rendered markdown beside it.
Workspace_View :: struct {
    file:     ^Open_File, // borrowed, nil when no file is active
    image:    bool,
    model:    bool,
    welcome:  bool,
    split:    bool,
    pane:     [2]Pane_Content,
}

// Decides what the workspace area shows: the image view for image files, the
// model view for 3D models (both whole-area), and the markdown preview in
// whichever pane is not focused when the active file is markdown and preview is
// on. The focused pane keeps the source, like opening the preview to the side.
// Called once a frame, so it tracks tab switches, splits, toggles and closes
// without each having to poke it.
thor_workspace_view :: proc(thor: ^Thor) -> Workspace_View {
    file := thor_active_open_file(thor)
    out := Workspace_View{file = file}
    out.image = file != nil && file.is_image && file.texture_loaded
    out.model = file != nil && file.is_model && file.model_loaded
    out.welcome = thor.workspace_dir == ""

    show_md := !out.image && !out.model && thor.markdown_preview &&
        file != nil && file.loaded && thor_is_markdown(file.name)

    // The preview needs a second pane to sit beside the source; open the split
    // first if it is not already on, without moving focus off the source.
    if show_md && !thor.split_visible {
        thor.split_visible = true
        thor_apply_split(thor)
    }
    out.split = thor.split_visible

    if show_md {
        out.pane[1 - thor.active_pane] = .Markdown
    }
    return out
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
    // A pending request wins over what the view saw: a right-click focuses the
    // pane and the menu takes the focus straight after, so `focus_owner` would
    // name the menu.
    named := thor.focus_request != "" ? thor.focus_request : thor.focus_owner
    pane := thor.active_pane
    if !thor.split_visible {
        pane = 0
    } else if named == "pane0" {
        pane = 0
    } else if named == "pane1" {
        pane = 1
    }
    if pane != thor.active_pane {
        thor.active_pane = pane
        thor_sync_active_signal(thor)
    }
}

thor_status_info :: proc(data: rawptr) -> Status_Info {
    thor := cast(^Thor) data

    info: Status_Info
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
       editor.focused {
        info.jump_count, info.jump_up, info.jump_active = editview.editor_pending_jump(editor)
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

thor_tab_info :: proc(data: rawptr, index: int) -> Tab_Info {
    thor := cast(^Thor) data
    file := thor.open_files[index]
    return Tab_Info {
        name = len(file.tab_label) > 0 ? file.tab_label : file.name,
        tooltip = file.path,
        modified = file.loaded && file.state.revision != file.saved_revision,
        loading = !thor_file_ready(file) && !file.load_failed,
    }
}

thor_tab_active :: proc(data: rawptr) -> int {
    thor := cast(^Thor) data
    return signal_get(&thor.active_file)
}

thor_tab_select :: proc(data: rawptr, index: int) {
    thor := cast(^Thor) data
    thor_set_active_file(thor, index)
}

thor_tab_close :: proc(data: rawptr, index: int) {
    thor := cast(^Thor) data
    thor_close_file(thor, index)
}
