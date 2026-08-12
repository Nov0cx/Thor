// Format Document, Format Selection and format-on-type: dispatch a Format /
// Format_Range / Format_On_Type request and apply its edits through the same
// all-or-nothing path a rename goes through, so each lands as one undo entry.
// format_on_save (setting.odin, files.odin) reuses the Format dispatch/apply
// pair for the explicit-save hook.
package thor

import "core:fmt"
import "core:strings"

import "../lang"
import "../setting"
import "../textedit"

// The open buffer for `path`, or nil when the file is not open — a private
// duplicate of lang_host.odin's own (file-scoped there, so unreachable here).
// Package-private (not file-scoped): files.odin's orphan-save flush needs it too.
@(private)
thor_format_open_file_at :: proc(thor: ^Thor, path: string) -> ^Open_File {
    for file in thor.open_files {
        if !file.closed && thor_same_path(file.path, path) {
            return file
        }
    }
    return nil
}

// Runs whatever save format_on_save left pending for the just-finished
// format (files.odin sets format_save_pending before dispatching), then, for
// a Save All in progress, pops and dispatches the next queued file — one at
// a time, since .Format has a single consumer slot like every other kind.
@(private = "file")
thor_finish_pending_format_save :: proc(thor: ^Thor) {
    if thor.format_save_pending {
        thor.format_save_pending = false
        if file := thor_format_open_file_at(thor, thor.format_path); file != nil {
            thor_save_file(thor, file)
        }
    }
    for len(thor.format_save_queue) > 0 {
        path := thor.format_save_queue[0]
        ordered_remove(&thor.format_save_queue, 0)
        file := thor_format_open_file_at(thor, path)
        delete(path)
        if file == nil {
            continue
        }
        thor_save_explicit(thor, file)
        return
    }
}

// Dispatches a format request for `file`. Returns whether it dispatched —
// false means the backend declined (non-Odin file, feature off, no active
// buffer), which the caller treats as "nothing to wait for".
thor_format_file :: proc(thor: ^Thor, file: ^Open_File) -> bool {
    if file == nil || !file.loaded {
        return false
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, .Format) {
        return false
    }
    source := textedit.text(&file.state)
    id := lang.manager_request_latest(
        &thor.lang_manager,
        .Format,
        file.path,
        ext,
        source,
        0,
        file.state.revision,
        thor.workspace_dir,
        tab_size = textedit.tab_width(&file.state),
    )
    if id == 0 {
        return false
    }
    thor.format_request_id = id
    delete(thor.format_path)
    thor.format_path = strings.clone(file.path)
    return true
}

// Format Selection: dispatches a Format_Range request over the caret's
// selection, aligned to whole lines — a half-line range makes most servers
// produce nonsense. With no selection this falls through to thor_format_file,
// so the keybind is never a dead key.
thor_format_selection :: proc(thor: ^Thor, file: ^Open_File) -> bool {
    if file == nil || !file.loaded {
        return false
    }
    cursor := textedit.primary_cursor(&file.state)
    if !textedit.has_selection(cursor) {
        return thor_format_file(thor, file)
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_allows(&thor.lang_manager, ext, .Format_Range) {
        return false
    }
    source := textedit.text(&file.state)
    lo, hi := textedit.selection_range(cursor)
    lo = textedit.line_start(source, lo)
    hi = textedit.line_end(source, hi)
    id := lang.manager_request_latest(
        &thor.lang_manager,
        .Format_Range,
        file.path,
        ext,
        source,
        lo,
        file.state.revision,
        thor.workspace_dir,
        end = hi,
        tab_size = textedit.tab_width(&file.state),
    )
    if id == 0 {
        return false
    }
    thor.format_range_request_id = id
    delete(thor.format_range_path)
    thor.format_range_path = strings.clone(file.path)
    return true
}

// Fired by the editor after a character lands, when the buffer's backend asked
// for it as an on-type trigger (widgets.editor_set_on_type_enabled,
// lang.manager_on_type_trigger). Debounced like completion, so a fast typist's
// burst of trigger characters costs one round trip. Silent throughout —
// thor_apply_on_type_format never flashes the statusline, since an edit
// landing mid-typing is not something the user asked to see a status for.
thor_format_on_type :: proc(thor: ^Thor, file: ^Open_File, offset: int, char: string) {
    if file == nil || !file.loaded || !setting.format_on_type(&thor.config) {
        return
    }
    ext := thor_file_extension(file.name)
    if !lang.manager_on_type_trigger(&thor.lang_manager, ext, char) {
        return
    }
    source := textedit.text(&file.state)
    id := lang.manager_request_debounced(
        &thor.lang_manager,
        .Format_On_Type,
        file.path,
        ext,
        source,
        offset,
        file.state.revision,
        thor.workspace_dir,
        tab_size = textedit.tab_width(&file.state),
        trigger = char,
    )
    if id == 0 {
        return
    }
    thor.on_type_request_id = id
    delete(thor.on_type_path)
    thor.on_type_path = strings.clone(file.path)
}

// The three explicit-save entry points (Ctrl+S, the palette, Save All) funnel
// through here instead of thor_save_file directly: with format_on_save on, a
// dirty Odin buffer formats first and saves once the result lands
// (thor_apply_format runs the save on every terminal outcome, so this never
// blocks a save forever). Autosave must never call this — it goes straight to
// thor_save_file — since formatting on every quiet-typing pause would fight
// the user's own cursor.
thor_save_explicit :: proc(thor: ^Thor, file: ^Open_File) {
    if file == nil || !file.loaded || file.closed {
        return
    }
    if file.state.revision == file.saved_revision || !setting.format_on_save(&thor.config) {
        thor_save_file(thor, file)
        return
    }
    if thor_format_file(thor, file) {
        thor.format_save_pending = true
        return
    }
    thor_save_file(thor, file)
}

// Ctrl+alt+l / "Edit: Format Document": formats the active buffer.
thor_format_document :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil {
        return
    }
    if !thor_format_file(thor, file) {
        thor_flash_status(thor, "Formatting is not available for this file", is_error = true)
    }
}

thor_cmd_format_document :: proc(data: rawptr) {
    thor_format_document(cast(^Thor) data)
}

// Ctrl+alt+shift+l / "Edit: Format Selection": formats the selection, or the
// whole document when there is none.
thor_format_selection_command :: proc(thor: ^Thor) {
    file := thor_active_open_file(thor)
    if file == nil {
        return
    }
    if !thor_format_selection(thor, file) {
        thor_flash_status(thor, "Formatting is not available for this file", is_error = true)
    }
}

thor_cmd_format_selection :: proc(data: rawptr) {
    thor_format_selection_command(cast(^Thor) data)
}

// Applies a Format / Format_Range result at `path` through the same
// all-or-nothing edit path a rename goes through. Returns the statusline
// message and whether it is an error, so both Format and Format_Range can
// share one apply body and flash it their own way.
@(private = "file")
thor_format_apply_message :: proc(thor: ^Thor, res: ^lang.Result, path: string) -> (message: string, is_error: bool) {
    if !res.ok {
        return "Cannot format: fix syntax errors first", true
    }
    if len(res.edits) == 0 {
        return "Already formatted", false
    }

    applied, _, ok, reason := thor_apply_edits(thor, res.edits[:], path, res.revision)
    if !ok {
        return fmt.tprintf("Cannot format: %s", reason), true
    }

    if file := thor_format_open_file_at(thor, path); file != nil {
        switch res.newline {
        case .LF:
            thor_set_line_ending(thor, file, .LF)
        case .CRLF:
            thor_set_line_ending(thor, file, .CRLF)
        case .Unspecified:
        }
    }
    return fmt.tprintf("Formatted: %d change%s", applied, applied == 1 ? "" : "s"), false
}

// Applies a .Format result, then — on every terminal outcome, not only
// success — runs whatever save format_on_save left pending: a save must
// never wait forever on a format that turned out to be a no-op or a refusal.
thor_apply_format :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.format_request_id {
        return
    }
    thor.format_request_id = 0
    message, is_error := thor_format_apply_message(thor, res, thor.format_path)
    thor_flash_status(thor, message, is_error = is_error)
    thor_finish_pending_format_save(thor)
}

// Applies a .Format_Range result (Format Selection). No format_on_save
// bookkeeping — only whole-document Format participates in that hook.
thor_apply_format_range :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.format_range_request_id {
        return
    }
    thor.format_range_request_id = 0
    message, is_error := thor_format_apply_message(thor, res, thor.format_range_path)
    thor_flash_status(thor, message, is_error = is_error)
}

// Applies a .Format_On_Type result silently: no statusline flash on any
// outcome. A stale result (the buffer moved past the revision it was computed
// against) is refused by thor_apply_edits' own check, which is the right
// behaviour for a keystroke the user has typed past.
thor_apply_on_type_format :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.on_type_request_id {
        return
    }
    thor.on_type_request_id = 0
    if !res.ok || len(res.edits) == 0 {
        return
    }
    thor_apply_edits(thor, res.edits[:], thor.on_type_path, res.revision)
}
