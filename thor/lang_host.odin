package thor

import "core:path/filepath"
import "core:strings"

import "../lang"
import "../textedit"
import "../widgets"

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

// Reaped on the main thread once per frame (see the run loop). Applies whatever
// the backend resolved.
thor_on_lang_result :: proc(user: rawptr, res: ^lang.Result) {
    thor := cast(^Thor) user
    if !res.ok {
        return
    }
    #partial switch res.kind {
    case .Definition:
        thor_goto_location(thor, res.location.path, res.location.start)
    }
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
