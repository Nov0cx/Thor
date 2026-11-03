// Document highlight: the uses of the symbol at the caret of the active pane, asked for when the caret stops.
package thor

import "core:strings"

import "../editview"
import "../lang"
import "../textedit"

// Asks for and pushes the uses of the symbol at the caret of the file `pane` shows. Only the active pane shows them.
thor_sync_pane_occurrences :: proc(thor: ^Thor, pane: int) {
    editor := thor_pane_editor(thor, pane)
    index := thor.pane_file[pane]
    if pane != thor.active_pane || index < 0 || index >= len(thor.open_files) {
        editview.editor_set_occurrences(editor, nil)
        return
    }
    file := thor.open_files[index]
    if !file.loaded || editor.state != &file.state {
        editview.editor_set_occurrences(editor, nil)
        return
    }
    shown := thor.occurrence_path == file.path && thor.occurrence_revision == file.state.revision
    if shown && thor_occurrences_cover_cursors(thor.occurrences[:], file.state.cursors[:]) {
        editview.editor_set_occurrences(editor, thor.occurrences[:])
        return
    }
    editview.editor_set_occurrences(editor, nil)
    cursor := textedit.primary_cursor(&file.state)
    if len(file.state.cursors) == 1 && cursor.anchor == cursor.caret {
        thor_request_occurrences(thor, file, cursor.caret)
    }
}

// True when `caret` is inside one of `occurrences` or at one of its ends.
thor_occurrences_cover :: proc(occurrences: []editview.Occurrence, caret: int) -> bool {
    for occ in occurrences {
        if caret >= occ.start && caret <= occ.end {
            return true
        }
    }
    return false
}

// True when each cursor is a caret on a use or a selection of one whole use, as ctrl + d leaves them.
thor_occurrences_cover_cursors :: proc(occurrences: []editview.Occurrence, cursors: []textedit.Cursor) -> bool {
    if len(cursors) == 0 {
        return false
    }
    for cursor in cursors {
        lo, hi := textedit.selection_range(cursor)
        covered := false
        for occ in occurrences {
            if lo == hi ? lo >= occ.start && lo <= occ.end : lo == occ.start && hi == occ.end {
                covered = true
                break
            }
        }
        if !covered {
            return false
        }
    }
    return true
}

// Asks for the uses at `caret` once per caret, revision and file. A newer ask supersedes the older one.
@(private = "file")
thor_request_occurrences :: proc(thor: ^Thor, file: ^Open_File, caret: int) {
    if thor.occurrence_ask_path == file.path && thor.occurrence_ask_revision == file.state.revision && thor.occurrence_ask_caret == caret {
        return
    }
    ext := thor_lang_key(thor, file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, .Document_Highlight) {
        return
    }
    id := lang.manager_request_debounced(
        &thor.lang_manager,
        .Document_Highlight,
        file.path,
        ext,
        textedit.text(&file.state),
        caret,
        file.state.revision,
        thor.workspace_dir,
        delay = lang.DEBOUNCE_HOVER,
    )
    if id == 0 {
        return
    }
    thor.occurrence_request_id = id
    if thor.occurrence_ask_path != file.path {
        delete(thor.occurrence_ask_path)
        thor.occurrence_ask_path = strings.clone(file.path)
    }
    thor.occurrence_ask_revision = file.state.revision
    thor.occurrence_ask_caret = caret
}

// Stores the uses of a landed request. A superseded or undispatched result is dropped.
thor_update_occurrences :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.occurrence_request_id {
        return
    }
    thor.occurrence_request_id = 0
    if res.undispatched {
        return
    }
    clear(&thor.occurrences)
    for h in res.highlights {
        append(&thor.occurrences, editview.Occurrence{start = h.start, end = h.end, write = h.kind == .Write})
    }
    if thor.occurrence_path != thor.occurrence_ask_path {
        delete(thor.occurrence_path)
        thor.occurrence_path = strings.clone(thor.occurrence_ask_path)
    }
    thor.occurrence_revision = res.revision
}

// Drops the slot of a request that will never land: a cancelled result never reaches its handler.
thor_recover_occurrence_slot :: proc(thor: ^Thor) {
    if thor.occurrence_request_id != 0 && !lang.manager_has_request(&thor.lang_manager, thor.occurrence_request_id) {
        thor.occurrence_request_id = 0
        thor.occurrence_ask_caret = -1
    }
}

// Drops the landed uses and the ask, so the next caret stop asks again.
thor_clear_occurrences :: proc(thor: ^Thor) {
    clear(&thor.occurrences)
    delete(thor.occurrence_path)
    thor.occurrence_path = ""
    delete(thor.occurrence_ask_path)
    thor.occurrence_ask_path = ""
    thor.occurrence_ask_caret = -1
    thor.occurrence_revision = 0
    thor.occurrence_request_id = 0
}
