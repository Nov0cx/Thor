package thor

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import rl "vendor:raylib"

import "../lang"
import "../setting"
import "../textedit"
import "../ui"
import "../widgets"

// Line terminator a file uses on disk. The buffer always holds LF, so a CRLF
// file is collapsed on load and expanded again on save; the editing core and
// every byte offset downstream never see a CR.
Line_Ending :: enum u8 {
    LF,
    CRLF,
}

// One open document. The textedit state lives here, not in the editor widget,
// so undo history and cursors survive tab switches; the editor only borrows it.
Open_File :: struct {
    path:               string, // owned
    name:               string, // slice into path, do not free separately
    // Tab label: base name, plus a trailing directory suffix on collision.
    // Owned; recomputed by thor_update_tab_labels when the open set changes.
    tab_label:          string,
    state:              textedit.State,
    loaded:             bool,
    load_failed:        bool,
    saving:             bool,
    // A disk-change reload is in flight for this file; guards against launching a
    // second one while the first is still reading (the watcher can fire a burst).
    reloading:          bool,
    // The file changed again while that read was in flight. One save fires several
    // watcher events and the first read can land mid-write, so the last event must
    // start another read instead of being dropped.
    reload_pending:     bool,
    // The file changed on disk while this buffer held unsaved edits, and the user
    // has not answered the conflict prompt yet. Blocks further reload attempts, so
    // a burst of watcher events asks once.
    disk_changed:       bool,
    // Tab was closed while a load/save thread still references this record;
    // it is freed on the main thread once pending_jobs drops to zero.
    closed:             bool,
    pending_jobs:       int,
    saved_revision:     u64,
    last_seen_revision: u64,
    // What the next save writes; detected on load. A file Thor creates gets the
    // zero value, LF.
    line_ending:        Line_Ending,
    last_edit:          time.Tick,
    // Syntax highlight spans and the buffer revision they were computed from.
    // The spans cover `highlight_start ..< highlight_end` only — the pane's view
    // plus a margin, not the whole buffer — so a pane that scrolls out of that
    // window re-highlights. Highlighting a large file whole costs seconds.
    highlights:         [dynamic]widgets.Highlight_Span,
    highlight_revision: u64,
    highlighted:        bool,
    highlight_start:    int,
    highlight_end:      int,
    // Foldable line ranges. These follow the buffer, not the view, so they are
    // recomputed on a revision change only — never on a scroll.
    folds:              [dynamic]widgets.Fold_Range,
    folds_revision:     u64,
    folds_ready:        bool,
    // What the analyzer proved each identifier in the buffer to be, layered over
    // the grammar's spans by thor_update_highlights. `semantic_ready` marks a
    // result having landed at all (revision 0 is a real revision), and the
    // overlay is kept across an edit at its now-slightly-stale offsets until the
    // next one lands — dropping it would flash the file back to plain syntax
    // colors on every keystroke.
    semantic:           [dynamic]lang.Semantic_Token,
    semantic_revision:  u64,
    semantic_ready:     bool,
    // Document sync for a backend that mirrors the editor's buffers.
    // `lang_open` marks the mirror as started, `lang_revision` the buffer
    // revision it last received. See thor_lang_notify.
    lang_revision:      u64,
    lang_open:          bool,
    // Compiler diagnostics from the last `odin check` of this file's package,
    // and the buffer revision they were computed against. Shown only while the
    // buffer still matches that revision (an edit clears them until re-checked).
    diagnostics:        [dynamic]widgets.Diagnostic,
    diagnostics_revision: u64,
    // Line-level git diff vs HEAD, refreshed alongside git status. Index i
    // (0-based) holds line i's status; drives the editor's gutter diff bar.
    diff_lines:         [dynamic]widgets.Diff_Line_Kind,
    // Image files bypass the text pipeline: the pixels load into a GPU texture
    // and show in the image view instead of the editor. `loaded` stays false.
    is_image:           bool,
    texture:            rl.Texture2D,
    texture_loaded:     bool,
    // 3D model files take the same bypass as images: the meshes upload to the
    // GPU and show in the model view instead of the editor. `loaded` stays false.
    is_model:           bool,
    model:              rl.Model,
    model_bounds:       rl.BoundingBox,
    model_loaded:       bool,
}

// Loaded via a memory mapping on a worker thread, which copies the view out and
// unmaps at once; the main thread reads the copy into the piece table and frees
// it. A live mapping stops the process that owns the file from truncating it, so
// it must not outlive the read.
Load_Job :: struct {
    owner:   ^Thor,
    file:    ^Open_File,
    path:    string, // borrowed from file; valid while pending_jobs > 0
    worker:  ^thread.Thread,
    // Reload of an already-open buffer after an external disk change, rather than
    // the initial open: the reap diffs the bytes against the buffer.
    reload:  bool,
    // The user already answered the conflict prompt for this file, so the reap
    // replaces the buffer even with unsaved edits in it.
    force:   bool,
    ok:      bool,
    binary:  bool,
    data:    [^]u8,
    size:    int,
    mapping: File_Map, // closed by the worker; closed again on reap is a no-op
    // The worker's copy of the mapped bytes, and the allocator it came from —
    // the worker runs under the default context, not the main thread's.
    buffer:  []u8,
    buffer_allocator: mem.Allocator,
}

Save_Job :: struct {
    owner:    ^Thor,
    file:     ^Open_File,
    path:     string, // borrowed from file; valid while pending_jobs > 0
    text:     string, // owned snapshot, freed on the main thread
    revision: u64,
    worker:   ^thread.Thread,
    ok:       bool,
}

// What a File_Op_Job does with each of its entries.
File_Op_Kind :: enum {
    Delete,
    Copy,
}

// One path a file operation works on, and what came of it.
File_Op_Entry :: struct {
    src:         string, // owned
    dst:         string, // owned, empty for a delete
    err:         os.Error,
    // The delete reported success but the path is still there: Windows only
    // marks a file that still has open handles for deletion.
    left_behind: bool,
}

// Recursive delete and directory copy on a worker thread; both walk whole trees,
// which is too slow for the frame loop. The main thread checks every entry and
// closes the tabs of deleted files before the job starts, so the worker only
// touches the disk.
File_Op_Job :: struct {
    owner:      ^Thor,
    allocator:  mem.Allocator,
    worker:     ^thread.Thread,
    kind:       File_Op_Kind,
    entries:    [dynamic]File_Op_Entry, // owned, with the strings in it
    dest_label: string, // owned, the folder a copy lands in, for the status message
}

// Status bar label for an ending.
thor_line_ending_label :: proc(ending: Line_Ending) -> string {
    return ending == .CRLF ? "CRLF" : "LF"
}

// The ending a file uses, taken from its first terminator: CRLF only when that
// \n follows a \r. A file with no newline at all counts as LF.
thor_detect_line_ending :: proc(content: string) -> Line_Ending {
    for i in 0 ..< len(content) {
        if content[i] == '\n' {
            return i > 0 && content[i - 1] == '\r' ? .CRLF : .LF
        }
    }
    return .LF
}

// Disk bytes as the buffer stores them: every CRLF collapsed to LF, whatever
// the detected ending, so a mixed file leaves no stray CR in the text. Returns
// `content` itself when there is nothing to collapse, so a plain LF file is not
// copied.
thor_to_buffer_text :: proc(content: string, allocator := context.temp_allocator) -> string {
    if !strings.contains(content, "\r\n") {
        return content
    }
    out, _ := strings.replace_all(content, "\r\n", "\n", allocator)
    return out
}

// Buffer text as it goes to disk, expanded back to CRLF when that is the file's
// ending. Always returns an owned string.
thor_to_disk_text :: proc(text: string, ending: Line_Ending, allocator := context.allocator) -> string {
    if ending == .LF {
        return strings.clone(text, allocator)
    }
    // replace_all hands back the input unallocated when the file has no
    // newline at all; that string is temp memory, so clone it instead.
    out, allocated := strings.replace_all(text, "\n", "\r\n", allocator)
    return allocated ? out : strings.clone(text, allocator)
}

@(private = "file")
load_worker :: proc(job: ^Load_Job) {
    defer {
        free_all(context.temp_allocator)
        sync.lock(&job.owner.io_mutex)
        append(&job.owner.finished_loads, job)
        sync.unlock(&job.owner.io_mutex)
    }

    bytes, ok := file_map_open(&job.mapping, job.path)
    if !ok {
        return
    }
    // Copy and unmap here: while the mapping lives, the program that owns the
    // file cannot truncate it, and a save that reloads is exactly when it tries.
    if len(bytes) > 0 {
        err: mem.Allocator_Error
        job.buffer_allocator = context.allocator
        job.buffer, err = make([]u8, len(bytes), job.buffer_allocator)
        if err != nil {
            file_map_close(&job.mapping)
            return
        }
        copy(job.buffer, bytes)
    }
    file_map_close(&job.mapping)
    job.data = raw_data(job.buffer)
    job.size = len(job.buffer)

    // NUL bytes in the head of the file mean it is not text; refuse instead
    // of feeding garbage to the piece table.
    probe := min(job.size, 8000)
    for i in 0 ..< probe {
        if job.data[i] == 0 {
            job.binary = true
            return
        }
    }

    job.ok = true
}

@(private = "file")
save_worker :: proc(job: ^Save_Job) {
    job.ok = os.write_entire_file(job.path, job.text) == nil
    free_all(context.temp_allocator)

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_saves, job)
    sync.unlock(&job.owner.io_mutex)
}

@(private = "file")
file_op_worker :: proc(job: ^File_Op_Job) {
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    for &entry in job.entries {
        switch job.kind {
        case .Delete:
            entry.err = thor_delete_tree(entry.src)
            entry.left_behind = entry.err == nil && os.exists(entry.src)
        case .Copy:
            entry.err = thor_copy_tree(entry.src, entry.dst)
        }
    }

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_file_ops, job)
    sync.unlock(&job.owner.io_mutex)
}

// Starts `entries` on a worker thread and takes ownership of them. `dest_label`
// is the folder a copy lands in, named by the status message on reap.
thor_start_file_op :: proc(thor: ^Thor, kind: File_Op_Kind, entries: [dynamic]File_Op_Entry, dest_label := "") {
    if len(entries) == 0 {
        delete(entries)
        return
    }

    job := new(File_Op_Job)
    job.owner = thor
    job.allocator = context.allocator
    job.kind = kind
    job.entries = entries
    job.dest_label = strings.clone(dest_label)

    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, file_op_worker)
}

// Drains a finished file operation (called from thor_process_io): reports the
// outcome, then refreshes the explorer and git status. A failure outranks the
// count, so a partly failed batch never reads as a clean success.
@(private = "file")
thor_apply_file_op :: proc(thor: ^Thor, job: ^File_Op_Job) {
    thread.join(job.worker)
    thread.destroy(job.worker)

    verb := job.kind == .Delete ? "delete" : "copy"
    done := 0
    failed := ""
    for entry in job.entries {
        name := file_base_name(entry.src)
        switch {
        case entry.err != nil:
            log.warnf("Failed to %s %q: %v", verb, entry.src, entry.err)
            if failed == "" {
                failed = fmt.tprintf("Could not %s %s: %v", verb, name, entry.err)
            }
        case entry.left_behind:
            log.warnf("Delete of %q reported success but the path still exists", entry.src)
            if failed == "" {
                failed = fmt.tprintf("Could not delete %s: still in use", name)
            }
        case:
            done += 1
        }
    }

    switch {
    case failed != "":
        thor_flash_status(thor, failed, is_error = true)
    case job.kind == .Copy:
        noun := done == 1 ? "item" : "items"
        thor_flash_status(
            thor,
            fmt.tprintf("Copied %d %s into %s", done, noun, filepath.base(job.dest_label)),
        )
    case done == 1:
        thor_flash_status(thor, fmt.tprintf("Deleted %s", file_base_name(job.entries[0].src)))
    case:
        thor_flash_status(thor, fmt.tprintf("Deleted %d items", done))
    }

    for entry in job.entries {
        delete(entry.src)
        if entry.dst != "" {
            delete(entry.dst)
        }
    }
    delete(job.entries)
    delete(job.dest_label)
    free(job)
    thor.inflight_jobs -= 1

    widgets.tree_refresh(thor.tree)
    thor_refresh_git_status(thor)
}

@(private = "file")
file_base_name :: proc(path: string) -> string {
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '\\' || path[i] == '/' {
            return path[i + 1:]
        }
    }
    return path
}

// Directory portion of path, without the base name or a trailing separator.
@(private = "file")
file_dir :: proc(path: string) -> string {
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '\\' || path[i] == '/' {
            return path[:i]
        }
    }
    return ""
}

// Tail of dir containing its last `depth` path segments (separators kept as in
// the source). Returns the whole dir when it has fewer than `depth` segments.
@(private = "file")
dir_tail :: proc(dir: string, depth: int) -> string {
    seps := 0
    for i := len(dir) - 1; i >= 0; i -= 1 {
        if dir[i] == '\\' || dir[i] == '/' {
            seps += 1
            if seps == depth {
                return dir[i + 1:]
            }
        }
    }
    return dir
}

@(private = "file")
dir_segment_count :: proc(dir: string) -> int {
    if len(dir) == 0 {
        return 0
    }
    count := 1
    for i in 0 ..< len(dir) {
        if dir[i] == '\\' || dir[i] == '/' {
            count += 1
        }
    }
    return count
}

// Shortest trailing directory that distinguishes `file` from `group`, the open
// files that share its base name. A slice into file.path; the caller copies and
// normalizes.
@(private = "file")
thor_disambiguating_dir :: proc(file: ^Open_File, group: []^Open_File) -> string {
    dir := file_dir(file.path)
    max_depth := max(dir_segment_count(dir), 1)

    // The directories once, not once per depth.
    others := make([dynamic]string, 0, len(group), context.temp_allocator)
    for other in group {
        if other != file {
            append(&others, file_dir(other.path))
        }
    }

    for depth in 1 ..= max_depth {
        tail := dir_tail(dir, depth)
        unique := true
        for other in others {
            if dir_tail(other, depth) == tail {
                unique = false
                break
            }
        }
        if unique {
            return tail
        }
    }
    return dir
}

// Recomputes every open file's tab_label. A unique base name shows alone;
// colliding files get a trailing directory suffix (e.g. "state.odin — thor").
thor_update_tab_labels :: proc(thor: ^Thor) {
    // The files per base name, so a collision is a lookup and the suffix search
    // only compares against the files that can collide.
    groups := make(map[string][dynamic]^Open_File, context.temp_allocator)
    for file in thor.open_files {
        group, seen := groups[file.name]
        if !seen {
            group = make([dynamic]^Open_File, context.temp_allocator)
        }
        append(&group, file)
        groups[file.name] = group
    }

    for file in thor.open_files {
        group := groups[file.name]

        old := file.tab_label
        if len(group) == 1 {
            file.tab_label = strings.clone(file.name)
        } else {
            suffix := thor_disambiguating_dir(file, group[:])
            b := strings.builder_make()
            strings.write_string(&b, file.name)
            if len(suffix) > 0 {
                strings.write_string(&b, " — ") // em dash
                for i in 0 ..< len(suffix) {
                    c := suffix[i]
                    strings.write_byte(&b, c == '\\' ? '/' : c)
                }
            }
            file.tab_label = strings.to_string(b)
        }
        if len(old) > 0 {
            delete(old)
        }
    }
}

thor_active_open_file :: proc(thor: ^Thor) -> ^Open_File {
    index := ui.signal_get(&thor.active_file)
    if index < 0 || index >= len(thor.open_files) {
        return nil
    }
    return thor.open_files[index]
}

thor_open_file :: proc(thor: ^Thor, path: string) {
    // Canonicalize so the same file opened via different path spellings (a
    // relative command path vs. the explorer's) resolves to one tab.
    canonical := path
    if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
        canonical = abs
    }

    for file, index in thor.open_files {
        if thor_same_path(file.path, canonical) {
            thor_set_active_file(thor, index)
            return
        }
    }

    file := new(Open_File)
    file.path = strings.clone(canonical)
    file.name = file_base_name(file.path)
    textedit.init(&file.state)
    append(&thor.open_files, file)

    // Images and models load straight onto the GPU (the GL context is on this
    // thread) and skip the text loader; everything else goes through the async
    // piece-table load.
    if thor_is_image_path(file.name) {
        file.is_image = true
        thor_load_image(file)
    } else if thor_is_model_path(file.name) {
        file.is_model = true
        thor_load_model(file)
    } else {
        file.pending_jobs += 1
        thor.inflight_jobs += 1
        job := new(Load_Job)
        job.owner = thor
        job.file = file
        job.path = file.path
        job.worker = thread.create_and_start_with_poly_data(job, load_worker)
    }

    thor_update_tab_labels(thor)
    thor_set_active_file(thor, len(thor.open_files) - 1)
}

// Reloads an already-open file's buffer from disk after an external change (fed
// by the file watcher). Skips one already being saved or reloaded, one still
// waiting on a conflict answer, images, models, and files that never finished
// their initial load. Goes through the same async mapping path as a fresh load;
// the reap (thor_apply_reload) diffs the bytes against the buffer, so our own
// saves echoing back through the watcher are no-ops. A buffer with unsaved edits
// is never replaced behind the user's back: the reap asks first, unless `force`
// says the user already answered.
thor_reload_file :: proc(thor: ^Thor, file: ^Open_File, force := false) {
    if file.closed || file.is_image || file.is_model || file.load_failed || file.saving {
        return
    }
    if !file.loaded {
        return // initial load still in flight; it will bring the current bytes
    }
    if file.disk_changed && !force {
        return // the conflict prompt for the last change is still unanswered
    }
    if file.reloading {
        file.reload_pending = true // re-issued when the in-flight read lands
        return
    }

    file.reloading = true
    file.pending_jobs += 1
    thor.inflight_jobs += 1
    job := new(Load_Job)
    job.owner = thor
    job.file = file
    job.path = file.path
    job.reload = true
    job.force = force
    job.worker = thread.create_and_start_with_poly_data(job, load_worker)
}

// Applies a reload job's freshly mapped bytes to its open buffer, if they differ
// from what's shown. Leaves the buffer untouched when the file is unreadable or
// the disk already matches; a buffer whose unsaved edits the new bytes would
// overwrite is not replaced but queued for the conflict prompt.
@(private = "file")
thor_apply_reload :: proc(thor: ^Thor, job: ^Load_Job) {
    file := job.file
    if !job.ok {
        // deleted / locked / now binary: keep the current buffer
        log.warnf("Reload of %q read nothing; keeping the buffer", job.path)
        return
    }
    content := job.size > 0 ? string(job.data[:job.size]) : ""
    // Compare the normalized text, or a CRLF file would differ from its own
    // buffer every time and reload on each watcher event.
    ending := thor_detect_line_ending(content)
    buffer_text := thor_to_buffer_text(content)
    // A copy: the cursor remap and the pane rebind below still read it after
    // set_text has replaced the buffer it came from.
    old_text := textedit.text_clone(&file.state, context.temp_allocator)
    if buffer_text == old_text {
        file.line_ending = ending // an external tool may have converted it
        // The edits (or an undo of them) end at exactly what is on disk, so the
        // buffer is not dirty however many revisions it took to get there.
        file.saved_revision = file.state.revision
        return
    }
    // Unsaved edits are never replaced behind the user's back — including edits
    // made while the job was in flight — unless the prompt was already answered.
    if !job.force && file.state.revision != file.saved_revision {
        file.disk_changed = true
        thor_prompt_disk_conflict(thor)
        return
    }

    // Move every cursor with the text it sits on, so a change above a caret does
    // not leave it on another line. Anchors move too, so a selection survives.
    prefix, suffix := thor_common_affixes(old_text, buffer_text)
    cursors := make([dynamic]textedit.Cursor, 0, len(file.state.cursors), context.temp_allocator)
    for cursor in file.state.cursors {
        append(&cursors, textedit.Cursor {
            caret  = thor_remap_offset(old_text, buffer_text, cursor.caret, prefix, suffix),
            anchor = thor_remap_offset(old_text, buffer_text, cursor.anchor, prefix, suffix),
        })
    }

    file.line_ending = ending
    textedit.set_text(&file.state, buffer_text)
    textedit.set_cursors(&file.state, cursors[:])
    file.saved_revision = file.state.revision // set_text zeroed it; stay clean
    file.last_seen_revision = file.state.revision
    file.highlighted = false // re-highlighted by the per-frame pass
    file.folds_ready = false // set_text zeroed the revision folds_revision holds
    thor_clear_file_diagnostics(file)
    file.diagnostics_revision = 0
    // Re-bind here, not in thor_process_io: only this frame still holds the old
    // text the panes need to keep their view on the same lines.
    if !file.closed {
        thor_rebind_reloaded_panes(thor, file, old_text, buffer_text, prefix, suffix)
    }
}

// Asks about the first file whose disk change is waiting on an answer, unless a
// conflict prompt is already open. Enter reloads and discards the buffer's edits,
// a dismissal keeps them; either way the next waiting file is asked about after.
@(private = "file")
thor_prompt_disk_conflict :: proc(thor: ^Thor) {
    if thor.conflict_file != nil {
        return
    }
    for file in thor.open_files {
        if !file.disk_changed || file.closed {
            continue
        }
        thor.conflict_file = file
        delete(thor.conflict_prompt)
        thor.conflict_prompt = strings.concatenate(
            {"\"", file.name, "\" changed on disk. Reload and discard your edits?"},
        )
        widgets.command_palette_confirm(
            thor.command_palette,
            &thor.ui_context,
            thor.conflict_prompt,
            thor_confirm_disk_reload,
            thor,
            thor_dismiss_disk_reload,
        )
        return
    }
}

// Conflict prompt accepted: drop the buffer's edits for what is on disk.
@(private = "file")
thor_confirm_disk_reload :: proc(data: rawptr) {
    thor := cast(^Thor) data
    file := thor.conflict_file
    thor.conflict_file = nil
    if file == nil || file.closed {
        return
    }
    file.disk_changed = false
    thor_reload_file(thor, file, force = true)
    thor_flash_status(thor, "Reloaded from disk")
    thor_prompt_disk_conflict(thor)
}

// Conflict prompt dismissed: the buffer keeps its edits, and the file is only
// asked about again when it changes on disk once more.
@(private = "file")
thor_dismiss_disk_reload :: proc(data: rawptr) {
    thor := cast(^Thor) data
    file := thor.conflict_file
    thor.conflict_file = nil
    if file != nil {
        file.disk_changed = false
    }
    thor_prompt_disk_conflict(thor)
}

// Re-binds every pane showing a just-reloaded file, keeping each view on the
// text it showed: the scroll offset is held and then shifted by the lines the
// top of that view moved. The panes still hold rows over the old text, so this
// must run before the buffer is re-bound.
@(private = "file")
thor_rebind_reloaded_panes :: proc(thor: ^Thor, file: ^Open_File, old_text, new_text: string, prefix, suffix: int) {
    for index, pane in thor.pane_file {
        if index < 0 || index >= len(thor.open_files) || thor.open_files[index] != file {
            continue
        }
        editor := pane == 0 ? thor.editor : thor.editor2
        top := widgets.editor_top_offset(editor)
        moved := thor_remap_offset(old_text, new_text, top, prefix, suffix)
        shift := textedit.line_index(new_text, moved) - textedit.line_index(old_text, top)
        thor_bind_pane(thor, pane, keep_view = true)
        widgets.editor_scroll_lines(editor, shift)
    }
}

// Length of the shared prefix of two texts, and of their shared suffix beyond
// it: what lies between them is the whole change. Both end on a rune boundary,
// so a mapped offset never lands inside a rune.
@(private = "file")
thor_common_affixes :: proc(old_text, new_text: string) -> (prefix, suffix: int) {
    limit := min(len(old_text), len(new_text))
    for prefix < limit && old_text[prefix] == new_text[prefix] {
        prefix += 1
    }
    for prefix > 0 && prefix < len(new_text) && new_text[prefix] & 0xc0 == 0x80 {
        prefix -= 1
    }
    for suffix < limit - prefix && old_text[len(old_text) - 1 - suffix] == new_text[len(new_text) - 1 - suffix] {
        suffix += 1
    }
    for suffix > 0 && new_text[len(new_text) - suffix] & 0xc0 == 0x80 {
        suffix -= 1
    }
    return
}

// Byte offset in `new_text` for one in `old_text`, given their shared affixes:
// an offset before the change keeps it, one after it shifts by the change in
// length, and one inside it lands on the end of the change.
@(private = "file")
thor_remap_offset :: proc(old_text, new_text: string, pos, prefix, suffix: int) -> int {
    if pos <= prefix {
        return pos
    }
    if pos >= len(old_text) - suffix {
        return pos + len(new_text) - len(old_text)
    }
    return min(pos, len(new_text) - suffix)
}

// Recognized raster image extensions, matched case-insensitively on the name.
@(private = "file")
thor_is_image_path :: proc(name: string) -> bool {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return false
    }
    ext := strings.to_lower(name[dot:], context.temp_allocator)
    switch ext {
    case ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".psd", ".hdr", ".qoi":
        return true
    }
    return false
}

// Uploads an image file to a GPU texture on the main thread. On failure the tab
// shows the load-failed placeholder, matching a rejected text file.
@(private = "file")
thor_load_image :: proc(file: ^Open_File) {
    path := strings.clone_to_cstring(file.path, context.temp_allocator)
    texture := rl.LoadTexture(path)
    if texture.id == 0 {
        file.load_failed = true
        log.warnf("Failed to load image %q", file.path)
        return
    }
    // Smooths downscaled images; large photos are almost always shown shrunk.
    rl.SetTextureFilter(texture, .BILINEAR)
    file.texture = texture
    file.texture_loaded = true
}

// Recognized 3D model extensions, matched case-insensitively on the name.
// These are exactly what raylib's LoadModel reads; FBX has no Odin binding, so
// it stays a binary file. A .mtl beside an .obj is still just text.
@(private = "file")
thor_is_model_path :: proc(name: string) -> bool {
    dot := strings.last_index_byte(name, '.')
    if dot < 0 {
        return false
    }
    ext := strings.to_lower(name[dot:], context.temp_allocator)
    switch ext {
    case ".obj", ".gltf", ".glb", ".iqm", ".vox", ".m3d":
        return true
    }
    return false
}

// Uploads a model file to GPU meshes on the main thread. raylib resolves the
// materials and textures relative to the path it is given, so the absolute path
// matters here (Thor's working directory is the executable, not the workspace).
// On failure the tab shows the load-failed placeholder, matching a bad image.
@(private = "file")
thor_load_model :: proc(file: ^Open_File) {
    path := strings.clone_to_cstring(file.path, context.temp_allocator)
    model := rl.LoadModel(path)
    if !rl.IsModelValid(model) {
        rl.UnloadModel(model) // frees the default material LoadModel still made
        file.load_failed = true
        log.warnf("Failed to load model %q", file.path)
        return
    }
    file.model = model
    file.model_bounds = rl.GetModelBoundingBox(model)
    file.model_loaded = true
}

thor_close_file :: proc(thor: ^Thor, index: int) {
    if index < 0 || index >= len(thor.open_files) {
        return
    }
    file := thor.open_files[index]
    if thor.last_active_file == file {
        thor.last_active_file = nil
    }
    if thor.conflict_file == file {
        thor.conflict_file = nil // its prompt outlives the tab; answer nothing
    }
    thor_lang_notify(thor, file, .Closed)
    ordered_remove(&thor.open_files, index)
    thor_update_tab_labels(thor)

    // Fix up both panes for the shift: the closed slot falls back to its
    // neighbour (or none), later slots shift down one.
    for &pane_index in thor.pane_file {
        if pane_index == index {
            pane_index = min(index, len(thor.open_files) - 1)
        } else if pane_index > index {
            pane_index -= 1
        }
    }
    thor_sync_active_signal(thor)
    thor_bind_pane(thor, 0)
    thor_bind_pane(thor, 1)

    if file.pending_jobs > 0 {
        file.closed = true
        append(&thor.zombie_files, file)
    } else {
        thor_free_open_file(file)
    }
}

// `force` writes a buffer that matches its last save; used when the bytes change
// without an edit, as a line-ending switch does.
thor_save_file :: proc(thor: ^Thor, file: ^Open_File, force := false) {
    if !file.loaded || file.saving || file.closed {
        return
    }
    if !force && file.state.revision == file.saved_revision {
        return
    }

    file.saving = true
    file.pending_jobs += 1
    thor.inflight_jobs += 1

    job := new(Save_Job)
    job.owner = thor
    job.file = file
    job.path = file.path
    job.text = thor_to_disk_text(textedit.text(&file.state), file.line_ending)
    job.revision = file.state.revision
    job.worker = thread.create_and_start_with_poly_data(job, save_worker)
}

// Switches what the file writes on disk. A clean buffer is written out at once,
// since converting the file is the whole point of the action; a dirty one keeps
// its pending edits and converts with the next save.
thor_set_line_ending :: proc(thor: ^Thor, file: ^Open_File, ending: Line_Ending) {
    if file == nil || !file.loaded || file.line_ending == ending {
        return
    }
    file.line_ending = ending
    thor_flash_status(thor, fmt.tprintf("Line endings: %s", thor_line_ending_label(ending)))
    if file.state.revision == file.saved_revision {
        thor_save_file(thor, file, force = true)
    }
}

// Status bar click and the palette toggle: flips the active file's ending.
thor_toggle_line_ending :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if file := thor_active_open_file(thor); file != nil {
        thor_set_line_ending(thor, file, file.line_ending == .LF ? .CRLF : .LF)
    }
}

// Ctrl+S from the editor widget: save the active file immediately.
thor_request_save :: proc(data: rawptr) {
    thor := cast(^Thor) data
    if file := thor_active_open_file(thor); file != nil {
        thor_save_file(thor, file)
    }
}

// Called once per frame from the run loop: reaps finished I/O threads and
// kicks off autosaves for buffers that went quiet while dirty.
thor_update_files :: proc(thor: ^Thor) {
    thor_process_io(thor)
    thor_apply_pending_goto(thor)
    thor_update_editor_view(thor)

    autosave_delay := time.Duration(setting.autosave_delay_ms(&thor.config)) * time.Millisecond
    for file in thor.open_files {
        if !file.loaded || file.saving {
            continue
        }
        if file.state.revision != file.last_seen_revision {
            file.last_seen_revision = file.state.revision
            file.last_edit = time.tick_now()
            continue
        }
        if file.state.revision == file.saved_revision {
            continue
        }
        if time.tick_since(file.last_edit) >= autosave_delay {
            thor_save_file(thor, file)
        }
    }

    // Keep each visible pane's buffer highlighted (only the two shown files).
    thor_highlight_pane_file(thor, 0)
    if thor.split_visible && thor.pane_file[1] != thor.pane_file[0] {
        thor_highlight_pane_file(thor, 1)
    }

    // Push (or clear, when the buffer moved past the checked revision) each
    // visible pane's diagnostics.
    thor_sync_pane_diagnostics(thor, 0)
    if thor.split_visible && thor.pane_file[1] != thor.pane_file[0] {
        thor_sync_pane_diagnostics(thor, 1)
    }

    // Push each visible pane's git diff lines for the gutter bar.
    thor_sync_pane_diff(thor, 0)
    if thor.split_visible && thor.pane_file[1] != thor.pane_file[0] {
        thor_sync_pane_diff(thor, 1)
    }
}

// Re-parses the file shown in `pane` if its highlights are missing, stale, or no
// longer cover what the pane displays — the spans span a window around the view,
// so scrolling out of it needs a fresh one just as an edit does.
@(private = "file")
thor_highlight_pane_file :: proc(thor: ^Thor, pane: int) {
    index := thor.pane_file[pane]
    if index < 0 || index >= len(thor.open_files) {
        return
    }
    file := thor.open_files[index]
    if !file.loaded {
        return
    }
    // Folds run on their own cadence: they cover the whole buffer, so they wait
    // for it to go quiet instead of following every keystroke or scroll.
    thor_update_folds(thor, file)
    if !file.highlighted || file.state.revision != file.highlight_revision {
        thor_update_highlights(thor, file)
        return
    }
    editor := thor_pane_editor(thor, pane)
    visible_start, visible_end, ok := widgets.editor_visible_byte_range(editor)
    if ok && (visible_start < file.highlight_start || visible_end > file.highlight_end) {
        thor_update_highlights(thor, file)
    }
}

thor_process_io :: proc(thor: ^Thor) {
    loads := make([dynamic]^Load_Job, context.temp_allocator)
    saves := make([dynamic]^Save_Job, context.temp_allocator)
    git := make([dynamic]^Git_Status_Job, context.temp_allocator)
    ops := make([dynamic]^File_Op_Job, context.temp_allocator)
    shells := make([dynamic]^Shell_Detect_Job, context.temp_allocator)

    sync.lock(&thor.io_mutex)
    for job in thor.finished_loads {
        append(&loads, job)
    }
    for job in thor.finished_saves {
        append(&saves, job)
    }
    for job in thor.finished_git {
        append(&git, job)
    }
    for job in thor.finished_file_ops {
        append(&ops, job)
    }
    for job in thor.finished_shells {
        append(&shells, job)
    }
    clear(&thor.finished_loads)
    clear(&thor.finished_saves)
    clear(&thor.finished_git)
    clear(&thor.finished_file_ops)
    clear(&thor.finished_shells)
    sync.unlock(&thor.io_mutex)

    for job in shells {
        thor_apply_shell_profiles(thor, job)
    }

    thor_process_terminals(thor)

    for job in loads {
        thread.join(job.worker)
        thread.destroy(job.worker)

        file := job.file
        reload := job.reload
        if reload {
            thor_apply_reload(thor, job)
        } else if job.ok {
            content := job.size > 0 ? string(job.data[:job.size]) : ""
            file.line_ending = thor_detect_line_ending(content)
            textedit.set_text(&file.state, thor_to_buffer_text(content))
            file.loaded = true
            file.saved_revision = 0
            file.last_seen_revision = 0
        } else {
            file.load_failed = true
            if job.binary {
                log.warnf("Refusing to open binary file %q", job.path)
            } else {
                log.warnf("Failed to load %q", job.path)
            }
        }

        file_map_close(&job.mapping)
        if job.buffer != nil {
            delete(job.buffer, job.buffer_allocator)
        }
        free(job)

        file.pending_jobs -= 1
        thor.inflight_jobs -= 1
        if reload {
            file.reloading = false
            // The file changed again while this read ran (or it ran mid-write and
            // read a half-written file), so read once more.
            if file.reload_pending {
                file.reload_pending = false
                thor_reload_file(thor, file)
            }
        }

        // A fresh load always re-binds (to show the buffer or the failure
        // placeholder); a reload that replaced the buffer re-bound itself.
        if !file.closed && !reload {
            // The document mirror starts here, not in thor_open_file: before the
            // read lands there is no text to send.
            thor_lang_notify(thor, file, .Opened)
            thor_rebind_file_panes(thor, file)
        }
        thor_reap_file(thor, file)
    }

    for job in saves {
        thread.join(job.worker)
        thread.destroy(job.worker)

        file := job.file
        file.saving = false
        if job.ok {
            if job.revision > file.saved_revision {
                file.saved_revision = job.revision
            }
            // A fresh save queues a re-check of the file's package; a language
            // with no checking backend queues nothing.
            if !file.closed {
                thor_lang_notify(thor, file, .Saved)
                thor_request_diagnostics(thor, file)
            }
        } else {
            log.warnf("Failed to save %q", job.path)
        }

        delete(job.text)
        free(job)

        file.pending_jobs -= 1
        thor.inflight_jobs -= 1
        thor_reap_file(thor, file)
    }

    for job in git {
        thor_apply_git_status(thor, job)
    }

    for job in ops {
        thor_apply_file_op(thor, job)
    }

    // A save may have changed the working tree; refresh the status so the
    // explorer highlighting stays current.
    if len(saves) > 0 {
        thor_refresh_git_status(thor)
    }
}

thor_free_open_file :: proc(file: ^Open_File) {
    if file.texture_loaded {
        rl.UnloadTexture(file.texture)
    }
    if file.model_loaded {
        rl.UnloadModel(file.model)
    }
    textedit.destroy(&file.state)
    delete(file.highlights)
    delete(file.folds)
    delete(file.semantic)
    thor_clear_file_diagnostics(file)
    delete(file.diagnostics)
    delete(file.diff_lines)
    delete(file.tab_label)
    delete(file.path)
    free(file)
}

@(private = "file")
thor_reap_file :: proc(thor: ^Thor, file: ^Open_File) {
    if !file.closed || file.pending_jobs > 0 {
        return
    }
    for zombie, index in thor.zombie_files {
        if zombie == file {
            unordered_remove(&thor.zombie_files, index)
            break
        }
    }
    thor_free_open_file(file)
}

// Blocks until every load/save thread has finished; called from shutdown so
// worker threads never outlive the Thor instance they point into.
thor_drain_io :: proc(thor: ^Thor) {
    for thor.inflight_jobs > 0 {
        thor_process_io(thor)
        if thor.inflight_jobs > 0 {
            time.sleep(time.Millisecond)
        }
        free_all(context.temp_allocator)
    }
}

// Tree widget callback: a file row was clicked in the explorer.
thor_tree_open :: proc(data: rawptr, path: string) {
    thor := cast(^Thor) data
    thor_open_file(thor, path)
}

// True when two paths point at the same file, ignoring separator spelling and
// (Windows) case differences.
thor_same_path :: proc(a, b: string) -> bool {
    aa, bb := a, b
    if abs, err := filepath.abs(a, context.temp_allocator); err == nil {
        aa = abs
    }
    if abs, err := filepath.abs(b, context.temp_allocator); err == nil {
        bb = abs
    }
    return strings.equal_fold(aa, bb)
}

// Tree widget callback / menu entry: Delete was pressed on a row. Deletes the
// whole explorer selection when the row belongs to it, so a multi-select acts as
// one action. Opens a confirmation dialog; thor_confirm_delete does the removal.
thor_tree_delete :: proc(data: rawptr, path: string) {
    thor := cast(^Thor) data
    if path == "" {
        return
    }

    thor_clear_pending_deletes(thor)
    selection := widgets.tree_selection(thor.tree)
    if len(selection) > 1 && slice.contains(selection, path) {
        for selected in selection {
            append(&thor.pending_delete_paths, strings.clone(selected))
        }
    } else {
        append(&thor.pending_delete_paths, strings.clone(path))
    }

    delete(thor.delete_prompt)
    if len(thor.pending_delete_paths) > 1 {
        thor.delete_prompt = fmt.aprintf("Delete %d items?", len(thor.pending_delete_paths))
    } else {
        thor.delete_prompt = strings.concatenate({"Delete \"", file_base_name(path), "\"?"})
    }

    widgets.command_palette_confirm(
        thor.command_palette,
        &thor.ui_context,
        thor.delete_prompt,
        thor_confirm_delete,
        thor,
    )
}

thor_clear_pending_deletes :: proc(thor: ^Thor) {
    for path in thor.pending_delete_paths {
        delete(path)
    }
    clear(&thor.pending_delete_paths)
}

// Confirmation accepted: close any tab for each path and hand the removals to a
// worker. Deleting a folder walks its whole tree, so it never runs on the main
// thread; thor_apply_file_op reports every outcome in the status bar.
thor_confirm_delete :: proc(data: rawptr) {
    thor := cast(^Thor) data
    defer thor_clear_pending_deletes(thor)

    entries: [dynamic]File_Op_Entry
    for path in thor.pending_delete_paths {
        for file, index in thor.open_files {
            if thor_same_path(file.path, path) {
                thor_close_file(thor, index)
                break
            }
        }
        append(&entries, File_Op_Entry{src = strings.clone(path)})
    }
    thor_start_file_op(thor, .Delete, entries)
}

// Tree callback / menu entry: begin renaming `path`. Opens the name prompt
// seeded with the current base name; the rename runs in thor_prompt_rename.
thor_begin_rename :: proc(thor: ^Thor, path: string) {
    if path == "" {
        return
    }
    delete(thor.pending_rename_path)
    thor.pending_rename_path = strings.clone(path)

    widgets.command_palette_prompt(
        thor.command_palette,
        &thor.ui_context,
        "New name",
        thor_prompt_rename,
        thor,
        file_base_name(path),
    )
}

// Name prompt accepted: rename the file/folder on disk within its directory and
// retarget any open tab that pointed at it.
thor_prompt_rename :: proc(data: rawptr, name: string) {
    thor := cast(^Thor) data
    old_path := thor.pending_rename_path
    defer {
        delete(thor.pending_rename_path)
        thor.pending_rename_path = ""
    }

    name := strings.trim_space(name)
    if old_path == "" || name == "" {
        return
    }

    new_path, _ := filepath.join({filepath.dir(old_path), name}, context.temp_allocator)
    if thor_same_path(old_path, new_path) {
        return
    }
    if os.exists(new_path) {
        log.warnf("Cannot rename to %q: already exists", new_path)
        return
    }
    if err := os.rename(old_path, new_path); err != nil {
        log.warnf("Failed to rename %q to %q: %v", old_path, new_path, err)
        return
    }

    // Retarget an open tab for the renamed file so it keeps its buffer and saves
    // to the new location. Folders never match an open file.
    canonical := new_path
    if abs, err := filepath.abs(new_path, context.temp_allocator); err == nil {
        canonical = abs
    }
    for file in thor.open_files {
        if thor_same_path(file.path, old_path) {
            delete(file.path)
            file.path = strings.clone(canonical)
            file.name = file_base_name(file.path)
            break
        }
    }
    thor_update_tab_labels(thor)

    widgets.tree_refresh(thor.tree)
    thor_refresh_git_status(thor)
}

// Tree widget callback: a row was dropped onto dst_dir. Reparents the file or
// folder on disk and retargets any open tab that pointed at it (folders never
// match an open file, matching thor_prompt_rename's rename behavior).
thor_tree_move :: proc(data: rawptr, src_path: string, dst_dir: string) {
    thor := cast(^Thor) data

    new_path, _ := filepath.join({dst_dir, file_base_name(src_path)}, context.temp_allocator)
    if thor_same_path(src_path, new_path) {
        return
    }
    if os.exists(new_path) {
        log.warnf("Cannot move %q to %q: already exists", src_path, new_path)
        thor_flash_status(thor, "Could not move: already exists", is_error = true)
        return
    }
    if err := os.rename(src_path, new_path); err != nil {
        log.warnf("Failed to move %q to %q: %v", src_path, new_path, err)
        thor_flash_status(thor, "Could not move", is_error = true)
        return
    }

    canonical := new_path
    if abs, err := filepath.abs(new_path, context.temp_allocator); err == nil {
        canonical = abs
    }
    for file in thor.open_files {
        if thor_same_path(file.path, src_path) {
            delete(file.path)
            file.path = strings.clone(canonical)
            file.name = file_base_name(file.path)
            break
        }
    }
    thor_update_tab_labels(thor)

    widgets.tree_refresh(thor.tree)
    thor_refresh_git_status(thor)
}

// Tree widget callback: rows were dragged out of the explorer and released at
// `position`. Dropping on the editor column opens the files as tabs; anywhere
// else (title bar, status bar, off-window) the drag is abandoned.
thor_tree_drag_out :: proc(data: rawptr, paths: []string, position: rl.Vector2) {
    thor := cast(^Thor) data
    if thor.editor_column == nil || !rl.CheckCollisionPointRec(position, thor.editor_column.bounds) {
        return
    }
    opened := 0
    for path in paths {
        if os.is_dir(path) {
            continue
        }
        thor_open_file(thor, path)
        opened += 1
    }
    if opened == 0 {
        thor_flash_status(thor, "Only files can be opened in the editor", is_error = true)
    }
}

// Deletes a file, or a directory and everything below it. Written out instead
// of left to os.remove_all because that is SHFileOperationW on Windows, a shell
// call the file-op worker has no COM apartment for.
thor_delete_tree :: proc(path: string) -> os.Error {
    if !os.is_dir(path) {
        return os.remove(path)
    }

    handle, open_err := os.open(path)
    if open_err != nil {
        return open_err
    }
    infos, dir_err := os.read_dir(handle, -1, context.allocator)
    os.close(handle) // an open handle blocks the remove of the directory itself
    if dir_err != nil {
        return dir_err
    }
    defer os.file_info_slice_delete(infos, context.allocator)

    for info in infos {
        if err := thor_delete_tree(info.fullpath); err != nil {
            return err
        }
    }
    return os.remove(path)
}

// Copies a file or a whole directory tree to `dst`. Directories recurse; an
// existing destination is left untouched and reported, so a copy can never
// silently overwrite. Runs on the file-op worker, and frees each directory
// listing on the way out, so peak memory follows the tree depth, not its size.
thor_copy_tree :: proc(src, dst: string) -> os.Error {
    if os.exists(dst) {
        return os.General_Error.Exist
    }
    if !os.is_dir(src) {
        return os.copy_file(dst, src)
    }

    if err := os.make_directory(dst); err != nil {
        return err
    }

    handle, open_err := os.open(src)
    if open_err != nil {
        return open_err
    }
    defer os.close(handle)

    infos, dir_err := os.read_dir(handle, -1, context.allocator)
    if dir_err != nil {
        return dir_err
    }
    defer os.file_info_slice_delete(infos, context.allocator)

    for info in infos {
        child_dst, join_err := filepath.join({dst, info.name}, context.allocator)
        if join_err != nil {
            return join_err
        }
        defer delete(child_dst, context.allocator)

        if err := thor_copy_tree(info.fullpath, child_dst); err != nil {
            return err
        }
    }
    return nil
}

// True when `path` is `ancestor` itself or sits somewhere beneath it.
thor_path_within :: proc(path, ancestor: string) -> bool {
    a, b := path, ancestor
    if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
        a = abs
    }
    if abs, err := filepath.abs(ancestor, context.temp_allocator); err == nil {
        b = abs
    }
    if len(a) < len(b) || !strings.equal_fold(a[:len(b)], b) {
        return false
    }
    return len(a) == len(b) || a[len(b)] == '\\' || a[len(b)] == '/'
}

// Outcome of queueing an import. Already_There is not a failure: the caller
// falls back to opening the path, so a drop onto its own folder still does
// something.
Import_Result :: enum {
    Queued,
    Already_There,
    Failed,
}

// Checks a path dropped from outside the editor against `dst_dir` and queues the
// copy in `entries`, which thor_start_file_op then runs. A name collision is
// reported rather than overwritten — on disk, or against a copy queued earlier
// in the same drop, which is not on disk yet. Every failure flashes its reason,
// so no branch here can leave the drop looking ignored.
thor_queue_import :: proc(
    thor: ^Thor,
    entries: ^[dynamic]File_Op_Entry,
    src_path, dst_dir: string,
) -> Import_Result {
    name := file_base_name(src_path)
    new_path, join_err := filepath.join({dst_dir, name}, context.temp_allocator)
    if join_err != nil {
        log.warnf("Cannot import %q into %q: %v", src_path, dst_dir, join_err)
        thor_flash_status(thor, fmt.tprintf("Could not copy %s: %v", name, join_err), is_error = true)
        return .Failed
    }
    if thor_same_path(src_path, new_path) {
        return .Already_There
    }

    taken := os.exists(new_path)
    if !taken {
        for entry in entries^ {
            if thor_same_path(entry.dst, new_path) {
                taken = true
                break
            }
        }
    }
    if taken {
        log.warnf("Cannot import %q into %q: already exists", src_path, dst_dir)
        thor_flash_status(thor, fmt.tprintf("%s already exists here", name), is_error = true)
        return .Failed
    }
    // Copying a folder into itself would recurse until the disk gave out.
    if os.is_dir(src_path) && thor_path_within(new_path, src_path) {
        thor_flash_status(thor, "Cannot copy a folder into itself", is_error = true)
        return .Failed
    }

    append(entries, File_Op_Entry{src = strings.clone(src_path), dst = strings.clone(new_path)})
    return .Queued
}
