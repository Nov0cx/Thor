// Code navigation over the language seam: call and type hierarchies, implementations, expand and
// shrink selection, and the reference counts above declarations.
package thor

import "core:fmt"
import "core:strings"

import "../editview"
import "../lang"
import "../textedit"

// The state of the navigation commands of Thor.
Nav_State :: struct {
    list_request_id:  u64,                      // the symbol-list picker's request
    list_empty:       string,                   // static; what to flash when the list is empty
    // Expand and shrink selection. `chain` was computed over `chain_path` at `chain_revision` for a
    // selection of `origin`; `expanded` is the range the last expand selected.
    chain:            [dynamic]lang.Text_Range, // owned
    chain_path:       string,                   // owned
    chain_revision:   u64,
    chain_valid:      bool,
    origin:           lang.Text_Range,
    expanded:         lang.Text_Range,
    history:          [dynamic]lang.Text_Range, // owned; the selections an expand left
    chain_request_id: u64,
    // Reference counts above declarations.
    lens_on:          bool,
    lens_request_id:  u64,
    lens_path:        string, // owned; the file of the request
    lens_source:      string, // owned; the text it was computed over
}

// The reference counts of one file, as lens rows above the declaration lines.
File_Lens :: struct {
    items:         [dynamic]editview.Inlay, // owned labels
    source:        string,                  // owned; the text `items` were computed over
    ready:         bool,
    asked:         u64, // the revision last requested
    asked_valid:   bool,
    view:          [dynamic]editview.Inlay, // `items` rebased onto the live text; labels borrowed
    view_revision: u64,
    view_valid:    bool,
}

thor_cmd_incoming_calls :: proc(data: rawptr) {
    thor_show_symbol_list(cast(^Thor)data, .Call_Hierarchy, "up", "Incoming Calls...", "No incoming calls")
}

thor_cmd_outgoing_calls :: proc(data: rawptr) {
    thor_show_symbol_list(cast(^Thor)data, .Call_Hierarchy, "down", "Outgoing Calls...", "No outgoing calls")
}

thor_cmd_supertypes :: proc(data: rawptr) {
    thor_show_symbol_list(cast(^Thor)data, .Type_Hierarchy, "up", "Supertypes...", "No supertypes")
}

thor_cmd_subtypes :: proc(data: rawptr) {
    thor_show_symbol_list(cast(^Thor)data, .Type_Hierarchy, "down", "Subtypes...", "No subtypes")
}

thor_cmd_implementations :: proc(data: rawptr) {
    thor_show_symbol_list(cast(^Thor)data, .Implementations, "", "Implementations...", "No implementations found")
}

thor_cmd_expand_selection :: proc(data: rawptr) {
    thor_expand_selection(cast(^Thor)data)
}

thor_cmd_shrink_selection :: proc(data: rawptr) {
    thor_shrink_selection(cast(^Thor)data)
}

thor_cmd_toggle_code_lens :: proc(data: rawptr) {
    thor := cast(^Thor)data
    thor.nav.lens_on = !thor.nav.lens_on
    if !thor.nav.lens_on {
        for file in thor.open_files {
            thor_clear_file_lens(file)
        }
    }
    thor_flash_status(thor, thor.nav.lens_on ? "Reference counts on" : "Reference counts off")
}

// Opens a picker for the symbols a hierarchy or implementations request names at the caret. The
// rows arrive in thor_on_symbol_list.
@(private = "file")
thor_show_symbol_list :: proc(thor: ^Thor, kind: lang.Request_Kind, query, title, empty: string) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    ext := thor_lang_key(thor, file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, kind) {
        thor_flash_status(thor, "Not available for this language", is_error = true)
        return
    }
    id := lang.manager_request_latest(
        &thor.lang_manager,
        kind,
        file.path,
        ext,
        textedit.text(&file.state),
        textedit.primary_cursor(&file.state).caret,
        file.state.revision,
        thor.workspace_dir,
        query = query,
    )
    if id == 0 {
        return
    }
    thor.nav.list_request_id = id
    thor.nav.list_empty = empty
    thor_palette_pick_rich_loading(thor, title, thor_pick_symbol, thor)
}

// Fills the loading picker with the rows of a landed hierarchy or implementations request.
thor_on_symbol_list :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.nav.list_request_id {
        return
    }
    thor.nav.list_request_id = 0
    if !thor_palette_pick_loading(thor) {
        return
    }
    if !res.ok || len(res.symbols) == 0 {
        thor_palette_close(thor)
        thor_flash_status(thor, thor.nav.list_empty)
        return
    }
    thor_palette_pick_rich_set(thor, thor_build_symbol_items(thor, res))
}

// Selects the next enclosing syntax range of the selection of the active file.
thor_expand_selection :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    nav     := &thor.nav
    lo, hi  := textedit.selection_range(textedit.primary_cursor(&file.state))
    current := lang.Text_Range{lo, hi}
    if nav.chain_valid && nav.chain_path == file.path && nav.chain_revision == file.state.revision && (current == nav.origin || current == nav.expanded) {
        thor_step_selection(thor, file, current)
        return
    }
    ext := thor_lang_key(thor, file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, .Selection_Range) {
        return
    }
    id := lang.manager_request_latest(
        &thor.lang_manager,
        .Selection_Range,
        file.path,
        ext,
        textedit.text(&file.state),
        lo,
        file.state.revision,
        thor.workspace_dir,
        end = hi,
    )
    if id != 0 {
        nav.chain_request_id = id
    }
}

// Selects the range the last expand left, else nothing.
thor_shrink_selection :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded {
        return
    }
    nav    := &thor.nav
    lo, hi := textedit.selection_range(textedit.primary_cursor(&file.state))
    if !nav.chain_valid ||
        nav.chain_path != file.path ||
        nav.chain_revision != file.state.revision ||
        (lang.Text_Range{lo, hi}) != nav.expanded ||
        len(nav.history) == 0 {
        return
    }
    previous := pop(&nav.history)
    nav.expanded = previous
    textedit.select_range(&file.state, previous.start, previous.end)
    thor_reveal_selection(thor, file)
}

// Stores the chain of a landed Selection_Range request and takes the first step of it.
thor_on_selection_chain :: proc(thor: ^Thor, res: ^lang.Result) {
    nav := &thor.nav
    if res.id != nav.chain_request_id {
        return
    }
    nav.chain_request_id = 0
    file := thor_active_open_file(thor)
    if file == nil || !file.loaded || res.undispatched || !res.ok || file.state.revision != res.revision {
        return
    }
    lo, hi := textedit.selection_range(textedit.primary_cursor(&file.state))
    clear(&nav.chain)
    append(&nav.chain, ..res.ranges[:])
    delete(nav.chain_path)
    nav.chain_path = strings.clone(file.path)
    nav.chain_revision = res.revision
    nav.chain_valid = true
    nav.origin = {lo, hi}
    nav.expanded = {lo, hi}
    clear(&nav.history)
    thor_step_selection(thor, file, {lo, hi})
}

// Selects the first range of the chain that holds `current` and is larger than it.
@(private = "file")
thor_step_selection :: proc(thor: ^Thor, file: ^Open_File, current: lang.Text_Range) {
    nav := &thor.nav
    for r in nav.chain {
        if r.start <= current.start && r.end >= current.end && r != current {
            append(&nav.history, current)
            nav.expanded = r
            textedit.select_range(&file.state, r.start, r.end)
            thor_reveal_selection(thor, file)
            return
        }
    }
}

// Frees the navigation state.
thor_nav_destroy :: proc(thor: ^Thor) {
    nav := &thor.nav
    delete(nav.chain)
    delete(nav.chain_path)
    delete(nav.history)
    delete(nav.lens_path)
    delete(nav.lens_source)
}

// The reference counts of the file for its editor's lens rows, at the offsets of the declaration
// names: asks for them when the text moved on. Borrowed; empty when lenses are off.
thor_lens_view :: proc(thor: ^Thor, file: ^Open_File) -> []editview.Inlay {
    if !thor.nav.lens_on {
        return nil
    }
    thor_request_lens(thor, file)
    lens := &file.lens
    if !lens.ready || len(lens.items) == 0 {
        return nil
    }
    if !lens.view_valid || lens.view_revision != file.state.revision {
        clear(&lens.view)
        lens.view_revision = file.state.revision
        lens.view_valid = true
        source := textedit.text(&file.state)
        if lens.source == source {
            append(&lens.view, ..lens.items[:])
        } else {
            thor_rebase_inlays(&lens.view, lens.items[:], lens.source, source)
        }
    }
    return lens.view[:]
}

@(private = "file")
thor_request_lens :: proc(thor: ^Thor, file: ^Open_File) {
    nav  := &thor.nav
    lens := &file.lens
    if nav.lens_request_id != 0 || thor_big_file(file) || (lens.asked_valid && lens.asked == file.state.revision) {
        return
    }
    ext := thor_lang_key(thor, file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, .Code_Lens) {
        return
    }
    source := textedit.text(&file.state)
    id     := lang.manager_request_debounced(
        &thor.lang_manager,
        .Code_Lens,
        file.path,
        ext,
        source,
        0,
        file.state.revision,
        thor.workspace_dir,
        delay = lang.DEBOUNCE_CHECK,
    )
    if id == 0 {
        return
    }
    lens.asked = file.state.revision
    lens.asked_valid = true
    nav.lens_request_id = id
    delete(nav.lens_path)
    nav.lens_path = strings.clone(file.path)
    delete(nav.lens_source)
    nav.lens_source = strings.clone(source)
}

// Stores the counts of a landed Code_Lens request. Looked up by path, since the tab may have closed.
thor_on_lens :: proc(thor: ^Thor, res: ^lang.Result) {
    nav := &thor.nav
    if res.id != nav.lens_request_id {
        return
    }
    nav.lens_request_id = 0
    file := thor_open_file_at(thor, nav.lens_path)
    delete(nav.lens_path)
    nav.lens_path = ""
    source := nav.lens_source
    nav.lens_source = ""
    if file == nil || res.undispatched || !nav.lens_on {
        delete(source)
        return
    }
    thor_clear_file_lens(file)
    for l in res.lenses {
        label := l.count == 1 ? strings.clone("1 reference") : fmt.aprintf("%d references", l.count)
        append(&file.lens.items, editview.Inlay{offset = l.start, label = label, parameter = true})
    }
    file.lens.source = source
    file.lens.ready = true
}

// Drops the counts of a file and the text they were computed over.
thor_clear_file_lens :: proc(file: ^Open_File) {
    lens := &file.lens
    for item in lens.items {
        delete(item.label)
    }
    clear(&lens.items)
    clear(&lens.view)
    delete(lens.source)
    lens.source = ""
    lens.ready = false
    lens.asked_valid = false
    lens.view_valid = false
}

// Frees the counts of a closing file.
thor_destroy_file_lens :: proc(file: ^Open_File) {
    thor_clear_file_lens(file)
    delete(file.lens.items)
    delete(file.lens.view)
}

// Drops the slot of a lens request that will never land.
thor_recover_lens_slot :: proc(thor: ^Thor) {
    nav := &thor.nav
    if nav.lens_request_id != 0 && !lang.manager_has_request(&thor.lang_manager, nav.lens_request_id) {
        nav.lens_request_id = 0
        delete(nav.lens_path)
        nav.lens_path = ""
        delete(nav.lens_source)
        nav.lens_source = ""
    }
}

// Scrolls the active pane to the caret when it shows `file`.
@(private = "file")
thor_reveal_selection :: proc(thor: ^Thor, file: ^Open_File) {
    editor := thor_active_editor(thor)
    if editor.state == &file.state {
        editview.editor_scroll_to_caret(editor)
    }
}
