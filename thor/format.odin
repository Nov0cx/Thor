// Format Document: dispatches a .Format request for the active buffer and
// applies its edits through the same all-or-nothing path a rename goes
// through, so it lands as one undo entry. format_on_save (setting.odin,
// files.odin) reuses the same dispatch/apply pair for the explicit-save hook.
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
    )
    if id == 0 {
        return false
    }
    thor.format_request_id = id
    delete(thor.format_path)
    thor.format_path = strings.clone(file.path)
    return true
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

// Applies a .Format result, then — on every terminal outcome, not only
// success — runs whatever save format_on_save left pending: a save must
// never wait forever on a format that turned out to be a no-op or a refusal.
thor_apply_format :: proc(thor: ^Thor, res: ^lang.Result) {
    if res.id != thor.format_request_id {
        return
    }
    thor.format_request_id = 0

    if !res.ok {
        thor_flash_status(thor, "Cannot format: fix syntax errors first", is_error = true)
        thor_finish_pending_format_save(thor)
        return
    }
    if len(res.edits) == 0 {
        thor_flash_status(thor, "Already formatted")
        thor_finish_pending_format_save(thor)
        return
    }

    applied, _, ok, reason := thor_apply_edits(thor, res.edits[:], thor.format_path, res.revision)
    if !ok {
        thor_flash_status(thor, fmt.tprintf("Cannot format: %s", reason), is_error = true)
        thor_finish_pending_format_save(thor)
        return
    }

    if file := thor_format_open_file_at(thor, thor.format_path); file != nil {
        switch res.newline {
        case .LF:
            thor_set_line_ending(thor, file, .LF)
        case .CRLF:
            thor_set_line_ending(thor, file, .CRLF)
        case .Unspecified:
        }
    }
    thor_flash_status(thor, fmt.tprintf("Formatted: %d change%s", applied, applied == 1 ? "" : "s"))
    thor_finish_pending_format_save(thor)
}
