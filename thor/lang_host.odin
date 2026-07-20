package thor

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

import "../lang"
import "../textedit"
import "../widgets"

// How long a transient statusline notice stays up.
STATUS_MESSAGE_SECS :: 3.0

// Go-to-definition and (later) hover wiring between the editor and the language
// intelligence manager. Requests are dispatched from the caret (Alt+Enter) or a
// Ctrl+Click; results arrive asynchronously and are applied in thor_on_lang_result.

// Alt+Enter: resolve the symbol under the caret in the active file.
thor_goto_definition :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    thor_dispatch_goto(thor, file, textedit.primary_cursor(&file.state).caret)
}

// Ctrl+Click: the editor hands back the buffer it was clicked in and the byte
// offset under the cursor. Match the buffer to its open file and dispatch.
thor_editor_goto_definition :: proc(data: rawptr, state: ^textedit.State, offset: int) {
    thor := cast(^Thor) data
    for file in thor.open_files {
        if &file.state == state {
            thor_dispatch_goto(thor, file, offset)
            return
        }
    }
}

// Sends a Definition request for `file` at `offset`. A snapshot of the buffer
// goes with it, so the worker never races later edits; the manager clones the
// strings, so the temp source is fine to hand over.
@(private = "file")
thor_dispatch_goto :: proc(thor: ^Thor, file: ^Open_File, offset: int) {
    if !file.loaded {
        return
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    source := textedit.text(&file.state)
    lang.manager_request(
        &thor.lang_manager,
        .Definition,
        file.path,
        ext,
        source,
        offset,
        file.state.revision,
        thor.workspace_dir,
    )
}

// A row's jump target in the Go to Symbol picker: the file and byte offset to
// jump to when the row is chosen. Kept in the same order as the picker items, so
// the pick callback maps the chosen index straight to it.
Doc_Symbol :: struct {
    path:   string, // owned
    offset: int,
}

// Ctrl+Shift+O: list the active file's top-level symbols in a fuzzy picker. The
// request is async; thor_on_lang_result opens the picker when it lands.
thor_goto_symbol :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    source := textedit.text(&file.state)
    lang.manager_request(
        &thor.lang_manager,
        .Document_Symbols,
        file.path,
        ext,
        source,
        0,
        file.state.revision,
        thor.workspace_dir,
    )
}

// Ctrl+T: list every top-level symbol across the workspace in a fuzzy picker.
// The active buffer (if it's an Odin file) seeds the request with its unsaved
// source and path; otherwise the scan runs over the workspace's .odin files with
// a bare ".odin" extension so it works even with no Odin file focused.
thor_goto_workspace_symbol :: proc(thor: ^Thor) {
    ext := ".odin"
    path := ""
    source := ""
    revision: u64 = 0
    if file := thor_active_open_file(thor); file != nil && file.loaded {
        if e := thor_file_extension(file.name); lang.manager_supports(&thor.lang_manager, e) {
            ext = e
            path = file.path
            source = textedit.text(&file.state)
            revision = file.state.revision
        }
    }
    if !lang.manager_supports(&thor.lang_manager, ext) {
        return
    }
    id := lang.manager_request(
        &thor.lang_manager,
        .Workspace_Symbols,
        path,
        ext,
        source,
        0,
        revision,
        thor.workspace_dir,
    )
    if id == 0 {
        return
    }
    // The scan reads and parses every .odin file off-thread, which takes a beat
    // on a big workspace. Open the picker now (empty, "Loading…") so the chord is
    // instant; thor_update_workspace_symbols fills it when the result lands.
    thor.workspace_symbols_request_id = id
    widgets.command_palette_pick_rich_loading(
        thor.command_palette,
        &thor.ui_context,
        "Go to symbol...",
        thor_pick_symbol,
        thor,
    )
}

// Frees the jump targets kept from the last symbol picker.
thor_clear_doc_symbols :: proc(thor: ^Thor) {
    for sym in thor.doc_symbols {
        delete(sym.path)
    }
    clear(&thor.doc_symbols)
}

// Mouse dwell: the editor asks the owner to resolve a hover at `offset`. The
// pane is remembered so the async result routes back to it. A snapshot of the
// buffer goes with the request, so the worker never races later edits.
thor_editor_hover :: proc(data: rawptr, editor: ^widgets.Editor, state: ^textedit.State, offset: int) {
    thor := cast(^Thor) data
    for file in thor.open_files {
        if &file.state != state {
            continue
        }
        if !file.loaded {
            return
        }
        ext := thor_file_extension(file.name)
        if !lang.manager_supports(&thor.lang_manager, ext) {
            return
        }
        source := textedit.text(&file.state)
        id := lang.manager_request(
            &thor.lang_manager,
            .Hover,
            file.path,
            ext,
            source,
            offset,
            file.state.revision,
            thor.workspace_dir,
        )
        thor.hover_editor = editor
        thor.hover_request_id = id
        return
    }
}

// Reaped on the main thread once per frame (see the run loop). Applies whatever
// the backend resolved; a failed go-to-definition flashes the statusline.
thor_on_lang_result :: proc(user: rawptr, res: ^lang.Result) {
    thor := cast(^Thor) user
    #partial switch res.kind {
    case .Definition:
        if res.ok {
            thor_goto_location(thor, res.location.path, res.location.start)
        } else {
            thor_flash_status(thor, "No definition found", is_error = true)
        }
    case .Hover:
        // Drop superseded results; only the latest request's answer may show,
        // and only while its buffer snapshot is still current.
        if res.id != thor.hover_request_id || thor.hover_editor == nil {
            return
        }
        editor := thor.hover_editor
        if res.ok && editor.state != nil && editor.state.revision == res.revision {
            widgets.editor_show_hover(editor, res.hover.text, res.hover.start, res.hover.end)
        }
    case .Document_Symbols:
        thor_show_symbols(thor, res, "No symbols in file")
    case .Workspace_Symbols:
        thor_update_workspace_symbols(thor, res)
    }
}

// Fills the already-open (loading) workspace-symbol picker once its scan lands.
// Drops the result if it's superseded by a newer Ctrl+T or the picker has since
// been closed or replaced (command_palette_pick_rich_set is a no-op then). An
// empty scan closes the loading picker and flashes instead of leaving it hanging.
@(private = "file")
thor_update_workspace_symbols :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.workspace_symbols_request_id {
        return
    }
    thor.workspace_symbols_request_id = 0
    if !widgets.command_palette_pick_loading(thor.command_palette) {
        return // picker closed or replaced by another pick; drop the result
    }
    if !res.ok || len(res.symbols) == 0 {
        widgets.command_palette_close(thor.command_palette, &thor.ui_context)
        thor_flash_status(thor, "No symbols in workspace")
        return
    }
    items := thor_build_symbol_items(thor, res)
    widgets.command_palette_pick_rich_set(thor.command_palette, items)
}

// Builds the rich symbol picker from a symbol result and opens it. Each row is
// the real Odin declaration ("add :: proc(...) -> int"), its name tinted by kind
// and a "path:line" preview under the selected row. The result's memory is freed
// right after this returns (see manager_dispatch), so each row's jump target is
// cloned into Thor-owned storage the pick callback reads on a later frame; the
// palette deep-copies the display strings itself.
@(private = "file")
thor_show_symbols :: proc(thor: ^Thor, res: ^lang.Result, empty_message: string) {
    if !res.ok || len(res.symbols) == 0 {
        thor_flash_status(thor, empty_message)
        return
    }
    items := thor_build_symbol_items(thor, res)
    widgets.command_palette_pick_rich(
        thor.command_palette,
        &thor.ui_context,
        "Go to symbol...",
        items,
        thor_pick_symbol,
        thor,
    )
}

// Rebuilds the picker's jump targets (doc_symbols) from a symbol result and
// returns the matching rich rows in the same order, temp-allocated (the palette
// deep-copies them). Shared by the document-symbol and workspace-symbol pickers.
@(private = "file")
thor_build_symbol_items :: proc(thor: ^Thor, res: ^lang.Result) -> []widgets.Pick_Item {
    thor_clear_doc_symbols(thor)
    items := make([dynamic]widgets.Pick_Item, context.temp_allocator)
    for sym in res.symbols {
        append(&thor.doc_symbols, Doc_Symbol {path = strings.clone(sym.path), offset = sym.offset})
        append(&items, widgets.Pick_Item {
            text     = sym.signature,
            name_len = min(len(sym.name), len(sym.signature)),
            color    = thor_symbol_color(thor, sym.kind),
            detail   = thor_symbol_detail(thor, sym),
        })
    }
    return items[:]
}

// Pick callback: jumps to the chosen row's file and offset. The index is into
// doc_symbols, which the palette kept in the order it was handed the items.
thor_pick_symbol :: proc(data: rawptr, index: int) {
    thor := cast(^Thor) data
    if index < 0 || index >= len(thor.doc_symbols) {
        return
    }
    sym := thor.doc_symbols[index]
    thor_goto_location(thor, sym.path, sym.offset)
}

// The preview line for a symbol row: its file path (workspace-relative, forward
// slashes) and 1-based line. Temp-allocated; the palette copies it.
@(private = "file")
thor_symbol_detail :: proc(thor: ^Thor, sym: lang.Symbol) -> string {
    rel := strings.trim_prefix(sym.path, thor.workspace_dir)
    rel = strings.trim_left(rel, "/\\")
    slash, _ := strings.replace_all(rel, "\\", "/", context.temp_allocator)
    return fmt.tprintf("%s:%d", slash, sym.line)
}

// Tints a symbol name by its kind, reusing the theme's syntax colors so the
// picker reads like code.
@(private = "file")
thor_symbol_color :: proc(thor: ^Thor, kind: string) -> rl.Color {
    switch kind {
    case "function": return thor.theme.functions_color
    case "type":     return thor.theme.keywords_color
    case "enum":     return thor.theme.keywords_color
    case "constant": return thor.theme.numbers_color
    case "var":      return thor.theme.variables_color
    }
    return thor.theme.white_black_color
}

// Posts a transient statusline notice, shown for STATUS_MESSAGE_SECS. Errors
// (is_error) are drawn in the theme's error color, other notices accented.
thor_flash_status :: proc(thor: ^Thor, message: string, is_error := false) {
    delete(thor.status_message)
    thor.status_message = strings.clone(message)
    thor.status_message_time = rl.GetTime()
    thor.status_message_error = is_error
}

// Jumps to `offset` in the file at `path`, opening it if needed. When the target
// is still loading, the jump is deferred to thor_apply_pending_goto.
@(private = "file")
thor_goto_location :: proc(thor: ^Thor, path: string, offset: int) {
    canonical := path
    if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
        canonical = abs
    }

    for file, index in thor.open_files {
        if file.path == canonical {
            thor_set_active_file(thor, index)
            if file.loaded {
                thor_place_caret(thor, file, offset)
            } else {
                thor_set_pending_goto(thor, canonical, offset)
            }
            return
        }
    }

    // Not open: open it, then finish the jump once its buffer lands.
    thor_set_pending_goto(thor, canonical, offset)
    thor_open_file(thor, path)
}

// Applies a deferred jump once its file has loaded. Called each frame from
// thor_update_files, after the I/O reap that may have completed the load.
thor_apply_pending_goto :: proc(thor: ^Thor) {
    if !thor.pending_goto_active {
        return
    }
    for file, index in thor.open_files {
        if file.path != thor.pending_goto_path {
            continue
        }
        if file.load_failed {
            break // give up on this jump
        }
        if !file.loaded {
            return // still loading; retry next frame
        }
        thor_set_active_file(thor, index)
        thor_place_caret(thor, file, thor.pending_goto_offset)
        break
    }
    thor_clear_pending_goto(thor)
}

@(private = "file")
thor_place_caret :: proc(thor: ^Thor, file: ^Open_File, offset: int) {
    textedit.set_single_cursor(&file.state, offset)
    editor := thor.active_pane == 0 ? thor.editor : thor.editor2
    widgets.editor_scroll_to_caret(editor)
}

@(private = "file")
thor_set_pending_goto :: proc(thor: ^Thor, path: string, offset: int) {
    delete(thor.pending_goto_path)
    thor.pending_goto_path = strings.clone(path)
    thor.pending_goto_offset = offset
    thor.pending_goto_active = true
}

@(private = "file")
thor_clear_pending_goto :: proc(thor: ^Thor) {
    delete(thor.pending_goto_path)
    thor.pending_goto_path = ""
    thor.pending_goto_active = false
}

// File extension including the dot (".odin"), or "" when the name has none.
@(private = "file")
thor_file_extension :: proc(name: string) -> string {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return ""
    }
    return name[dot:]
}
