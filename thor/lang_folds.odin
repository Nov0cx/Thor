// Folding ranges from the language backend, used ahead of the grammar's.
package thor

import "core:slice"
import "core:strings"

import "../editview"
import "../lang"
import "../textedit"

// Asks the backend for the folds of `file` at its revision. True while the backend owns them: a
// request is in flight or it answered. False lets the grammar fold this revision.
@(private = "package")
thor_lang_folds :: proc(thor: ^Thor, file: ^Open_File) -> bool {
    ext := thor_lang_key(thor, file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, .Folding_Range) {
        return false
    }
    if file.lang_folds_asked_valid && file.lang_folds_asked == file.state.revision {
        return !file.lang_folds_declined
    }
    nav := &thor.nav
    if nav.fold_request_id != 0 {
        return true
    }
    source := textedit.text(&file.state)
    id     := lang.manager_request(&thor.lang_manager, .Folding_Range, file.path, ext, source, 0, file.state.revision, thor.workspace_dir)
    if id == 0 {
        return false
    }
    file.lang_folds_asked = file.state.revision
    file.lang_folds_asked_valid = true
    file.lang_folds_declined = false
    nav.fold_request_id = id
    nav.fold_revision = file.state.revision
    delete(nav.fold_path)
    nav.fold_path = strings.clone(file.path)
    delete(nav.fold_source)
    nav.fold_source = strings.clone(source)
    return true
}

// Stores the folds of a landed Folding_Range request. No folds hand the revision to the grammar.
thor_on_lang_folds :: proc(thor: ^Thor, res: ^lang.Result) {
    nav := &thor.nav
    if res.id != nav.fold_request_id {
        return
    }
    nav.fold_request_id = 0
    source := nav.fold_source
    nav.fold_source = ""
    defer delete(source)
    file := thor_open_file_at(thor, nav.fold_path)
    delete(nav.fold_path)
    nav.fold_path = ""
    if file == nil || !file.lang_folds_asked_valid || file.lang_folds_asked != nav.fold_revision {
        return
    }
    if !res.ok || res.undispatched {
        file.lang_folds_declined = true
        return
    }
    starts := thor_fold_line_starts(source)
    clear(&file.folds)
    for r in res.ranges {
        append(&file.folds, editview.Fold_Range{thor_fold_line(starts, r.start), thor_fold_line(starts, r.end)})
    }
    file.folds_revision = nav.fold_revision
    file.folds_ready = true
    thor_apply_file_highlights(thor, file)
}

// Drops the slot of a fold request that will never land; its file folds by grammar.
thor_recover_fold_slot :: proc(thor: ^Thor) {
    nav := &thor.nav
    if nav.fold_request_id == 0 || lang.manager_has_request(&thor.lang_manager, nav.fold_request_id) {
        return
    }
    nav.fold_request_id = 0
    if file := thor_open_file_at(thor, nav.fold_path); file != nil && file.lang_folds_asked == nav.fold_revision {
        file.lang_folds_declined = true
    }
    delete(nav.fold_path)
    nav.fold_path = ""
    delete(nav.fold_source)
    nav.fold_source = ""
}

// The byte offset each line of `text` starts at, on the temp allocator.
@(private = "file")
thor_fold_line_starts :: proc(text: string) -> []int {
    starts := make([dynamic]int, 0, len(text) / 32 + 1, context.temp_allocator)
    append(&starts, 0)
    for i in 0 ..< len(text) {
        if text[i] == '\n' {
            append(&starts, i + 1)
        }
    }
    return starts[:]
}

@(private = "file")
thor_fold_line :: proc(starts: []int, offset: int) -> int {
    index, found := slice.binary_search(starts, offset)
    return found ? index : max(index - 1, 0)
}
