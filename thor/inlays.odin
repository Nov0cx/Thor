// Inlay hints: the backend's virtual text, asked for the window a pane shows and rebased onto later text.
package thor

import "core:strings"

import "../editview"
import "../lang"
import "../textedit"

// Asks for, rebases and pushes the inlay hints of the file `pane` shows.
thor_sync_pane_inlays :: proc(thor: ^Thor, pane: int) {
    editor := thor_pane_editor(thor, pane)
    index := thor.pane_file[pane]
    if index < 0 || index >= len(thor.open_files) {
        editview.editor_set_inlays(editor, nil)
        return
    }
    file := thor.open_files[index]
    if !file.loaded {
        editview.editor_set_inlays(editor, nil)
        return
    }
    thor_request_inlays(thor, file, editor)
    thor_rebase_file_inlays(file)
    editview.editor_set_inlays(editor, file.inlay_view[:])
}

// Asks for the hints of the window `editor` shows when the file has none for its text or the
// view left the window they cover. One request at a time, as for semantic tokens.
@(private = "file")
thor_request_inlays :: proc(thor: ^Thor, file: ^Open_File, editor: ^editview.Editor) {
    if thor.inlay_request_id != 0 {
        return
    }
    margin := max(editview.editor_visible_row_count(editor), 1)
    start, end, ok := editview.editor_visible_byte_range(editor, margin)
    if !ok {
        return
    }
    if file.inlay_ready && file.inlay_revision == file.state.revision && start >= file.inlay_start && end <= file.inlay_end {
        return
    }
    ext := thor_lang_key(thor, file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, .Inlay_Hints) {
        return
    }
    source := textedit.text(&file.state)
    id := lang.manager_request_debounced(
        &thor.lang_manager,
        .Inlay_Hints,
        file.path,
        ext,
        source,
        start,
        file.state.revision,
        thor.workspace_dir,
        delay = lang.DEBOUNCE_HOVER,
        end = end,
    )
    if id == 0 {
        return
    }
    thor.inlay_request_id = id
    thor.inlay_start, thor.inlay_end = start, end
    delete(thor.inlay_path)
    thor.inlay_path = strings.clone(file.path)
    delete(thor.inlay_source)
    thor.inlay_source = strings.clone(source)
}

// Stores the hints of a landed request. Looked up by path, since the tab may have closed.
thor_update_inlays :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.inlay_request_id {
        return
    }
    thor.inlay_request_id = 0
    file := thor_open_file_at(thor, thor.inlay_path)
    delete(thor.inlay_path)
    thor.inlay_path = ""
    source := thor.inlay_source
    thor.inlay_source = ""
    if file == nil || res.undispatched {
        delete(source)
        return
    }
    thor_clear_file_inlays(file)
    for hint in res.inlays {
        append(&file.inlays, editview.Inlay {
            offset    = hint.offset,
            label     = strings.clone(hint.label),
            parameter = hint.kind == .Parameter,
            pad_left  = hint.pad_left,
            pad_right = hint.pad_right,
        })
    }
    file.inlay_source = source
    file.inlay_revision = res.revision
    file.inlay_start, file.inlay_end = thor.inlay_start, thor.inlay_end
    file.inlay_ready = true
}

// Drops the slot of a request that will never land: a cancelled result never reaches its handler.
thor_recover_inlay_slot :: proc(thor: ^Thor) {
    if thor.inlay_request_id != 0 && !lang.manager_has_request(&thor.lang_manager, thor.inlay_request_id) {
        thor.inlay_request_id = 0
        delete(thor.inlay_path)
        thor.inlay_path = ""
        delete(thor.inlay_source)
        thor.inlay_source = ""
    }
}

// Moves the hints onto the live text when the buffer changed since they were computed.
@(private = "file")
thor_rebase_file_inlays :: proc(file: ^Open_File) {
    if file.inlay_view_valid && file.inlay_view_revision == file.state.revision {
        return
    }
    clear(&file.inlay_view)
    file.inlay_view_revision = file.state.revision
    file.inlay_view_valid = true
    source := textedit.text(&file.state)
    if file.inlay_source == source {
        append(&file.inlay_view, ..file.inlays[:])
        return
    }
    thor_rebase_inlays(&file.inlay_view, file.inlays[:], file.inlay_source, source)
}

// The hints of `old_text` at their offsets in `new_text`. A hint inside the changed span is dropped.
@(private)
thor_rebase_inlays :: proc(out: ^[dynamic]editview.Inlay, inlays: []editview.Inlay, old_text, new_text: string) {
    prefix, suffix := thor_common_affixes(old_text, new_text)
    tail := len(old_text) - suffix
    delta := len(new_text) - len(old_text)
    for inlay in inlays {
        if inlay.offset <= prefix && inlay.offset < tail {
            append(out, inlay)
        } else if inlay.offset >= tail && inlay.offset > prefix {
            moved := inlay
            moved.offset += delta
            append(out, moved)
        }
    }
}

// Drops a file's hints and the text they were computed over.
thor_clear_file_inlays :: proc(file: ^Open_File) {
    for inlay in file.inlays {
        delete(inlay.label)
    }
    clear(&file.inlays)
    clear(&file.inlay_view)
    delete(file.inlay_source)
    file.inlay_source = ""
    file.inlay_revision = 0
    file.inlay_ready = false
    file.inlay_view_valid = false
}
