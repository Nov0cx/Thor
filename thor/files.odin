package thor

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import "core:thread"
import "core:time"
import rl "vendor:raylib"

import "../setting"
import "../textedit"
import "../ui"
import "../widgets"

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
    // Tab was closed while a load/save thread still references this record;
    // it is freed on the main thread once pending_jobs drops to zero.
    closed:             bool,
    pending_jobs:       int,
    saved_revision:     u64,
    last_seen_revision: u64,
    last_edit:          time.Tick,
    // Syntax highlight spans and the buffer revision they were computed from.
    highlights:         [dynamic]widgets.Highlight_Span,
    highlight_revision: u64,
    highlighted:        bool,
    // Foldable line ranges, recomputed alongside the highlights.
    folds:              [dynamic]widgets.Fold_Range,
    // Compiler diagnostics from the last `odin check` of this file's package,
    // and the buffer revision they were computed against. Shown only while the
    // buffer still matches that revision (an edit clears them until re-checked).
    diagnostics:        [dynamic]widgets.Diagnostic,
    diagnostics_revision: u64,
    // Image files bypass the text pipeline: the pixels load into a GPU texture
    // and show in the image view instead of the editor. `loaded` stays false.
    is_image:           bool,
    texture:            rl.Texture2D,
    texture_loaded:     bool,
}

// Loaded via a memory mapping on a worker thread; the main thread copies the
// view into the piece table and unmaps. The worker makes no Odin heap allocs.
Load_Job :: struct {
    owner:   ^Thor,
    file:    ^Open_File,
    path:    string, // borrowed from file; valid while pending_jobs > 0
    worker:  ^thread.Thread,
    // Reload of an already-open buffer after an external disk change, rather than
    // the initial open: the reap diffs the bytes and only replaces a clean buffer.
    reload:  bool,
    ok:      bool,
    binary:  bool,
    data:    [^]u8,
    size:    int,
    view:    rawptr,
    mapping: win32.HANDLE,
    handle:  win32.HANDLE,
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

@(private = "file")
load_worker :: proc(job: ^Load_Job) {
    job.handle = win32.INVALID_HANDLE_VALUE
    defer {
        free_all(context.temp_allocator)
        sync.lock(&job.owner.io_mutex)
        append(&job.owner.finished_loads, job)
        sync.unlock(&job.owner.io_mutex)
    }

    wide_path := win32.utf8_to_wstring(job.path, context.temp_allocator)
    job.handle = win32.CreateFileW(
        wide_path,
        win32.GENERIC_READ,
        win32.FILE_SHARE_READ,
        nil,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL,
        nil,
    )
    if job.handle == win32.INVALID_HANDLE_VALUE {
        return
    }

    size: win32.LARGE_INTEGER
    if !win32.GetFileSizeEx(job.handle, &size) {
        return
    }
    if size == 0 {
        job.ok = true
        return
    }

    job.mapping = win32.CreateFileMappingW(job.handle, nil, win32.PAGE_READONLY, 0, 0, nil)
    if job.mapping == nil {
        return
    }
    job.view = win32.MapViewOfFile(job.mapping, win32.FILE_MAP_READ, 0, 0, 0)
    if job.view == nil {
        return
    }

    job.data = cast([^]u8) job.view
    job.size = cast(int) size

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

// Shortest trailing directory that distinguishes `file` from other open files
// sharing its base name. A slice into file.path; the caller copies and normalizes.
@(private = "file")
thor_disambiguating_dir :: proc(thor: ^Thor, file: ^Open_File) -> string {
    dir := file_dir(file.path)
    max_depth := max(dir_segment_count(dir), 1)

    for depth in 1 ..= max_depth {
        tail := dir_tail(dir, depth)
        unique := true
        for other in thor.open_files {
            if other == file || other.name != file.name {
                continue
            }
            if dir_tail(file_dir(other.path), depth) == tail {
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
    for file in thor.open_files {
        collision := false
        for other in thor.open_files {
            if other != file && other.name == file.name {
                collision = true
                break
            }
        }

        old := file.tab_label
        if !collision {
            file.tab_label = strings.clone(file.name)
        } else {
            suffix := thor_disambiguating_dir(thor, file)
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
        if file.path == canonical {
            thor_set_active_file(thor, index)
            return
        }
    }

    file := new(Open_File)
    file.path = strings.clone(canonical)
    file.name = file_base_name(file.path)
    textedit.init(&file.state)
    append(&thor.open_files, file)

    // Images load straight into a texture (GL context is on this thread) and
    // skip the text loader; everything else goes through the async piece-table load.
    if thor_is_image_path(file.name) {
        file.is_image = true
        thor_load_image(file)
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
// by the file watcher). Skips a buffer with unsaved edits (the user's changes
// win), one already being saved or reloaded, images, and files that never
// finished their initial load. Goes through the same async mapping path as a
// fresh load; the reap (thor_apply_reload) diffs the bytes and only replaces a
// clean buffer, so our own saves echoing back through the watcher are no-ops.
thor_reload_file :: proc(thor: ^Thor, file: ^Open_File) {
    if file.closed || file.is_image || file.load_failed || file.saving || file.reloading {
        return
    }
    if !file.loaded {
        return // initial load still in flight; it will bring the current bytes
    }
    if file.state.revision != file.saved_revision {
        return // unsaved edits; never clobber them
    }

    file.reloading = true
    file.pending_jobs += 1
    thor.inflight_jobs += 1
    job := new(Load_Job)
    job.owner = thor
    job.file = file
    job.path = file.path
    job.reload = true
    job.worker = thread.create_and_start_with_poly_data(job, load_worker)
}

// Applies a reload job's freshly mapped bytes to its open buffer, if they differ
// from what's shown and the buffer is still unedited. Returns true when the
// buffer was replaced, so the caller re-binds panes; a false leaves the buffer
// untouched (unreadable file, a stale edit landed, or disk already matches).
@(private = "file")
thor_apply_reload :: proc(thor: ^Thor, job: ^Load_Job) -> bool {
    file := job.file
    if !job.ok {
        return false // deleted / locked / now binary: keep the current buffer
    }
    // The user may have started editing while the reload was in flight.
    if file.state.revision != file.saved_revision {
        return false
    }
    content := job.size > 0 ? string(job.data[:job.size]) : ""
    if content == textedit.text(&file.state) {
        return false // disk already matches (e.g. our own save coming back around)
    }

    // Keep the caret roughly where it was rather than snapping to the top.
    caret := textedit.primary_cursor(&file.state).caret
    textedit.set_text(&file.state, content)
    textedit.set_single_cursor(&file.state, min(caret, len(content)))
    file.saved_revision = file.state.revision // set_text zeroed it; stay clean
    file.last_seen_revision = file.state.revision
    file.highlighted = false // re-highlighted by the per-frame pass
    thor_clear_file_diagnostics(file)
    file.diagnostics_revision = 0
    return true
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

thor_close_file :: proc(thor: ^Thor, index: int) {
    if index < 0 || index >= len(thor.open_files) {
        return
    }
    file := thor.open_files[index]
    if thor.last_active_file == file {
        thor.last_active_file = nil
    }
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

thor_save_file :: proc(thor: ^Thor, file: ^Open_File) {
    if !file.loaded || file.saving || file.closed {
        return
    }
    if file.state.revision == file.saved_revision {
        return
    }

    file.saving = true
    file.pending_jobs += 1
    thor.inflight_jobs += 1

    job := new(Save_Job)
    job.owner = thor
    job.file = file
    job.path = file.path
    job.text = strings.clone(textedit.text(&file.state))
    job.revision = file.state.revision
    job.worker = thread.create_and_start_with_poly_data(job, save_worker)
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
}

// Re-parses the file shown in `pane` if its highlights are missing or stale.
@(private = "file")
thor_highlight_pane_file :: proc(thor: ^Thor, pane: int) {
    index := thor.pane_file[pane]
    if index < 0 || index >= len(thor.open_files) {
        return
    }
    file := thor.open_files[index]
    if file.loaded && (!file.highlighted || file.state.revision != file.highlight_revision) {
        thor_update_highlights(thor, file)
    }
}

thor_process_io :: proc(thor: ^Thor) {
    loads := make([dynamic]^Load_Job, context.temp_allocator)
    saves := make([dynamic]^Save_Job, context.temp_allocator)
    console := make([dynamic]^Console_Job, context.temp_allocator)
    git := make([dynamic]^Git_Status_Job, context.temp_allocator)
    diagnostics := make([dynamic]^Diagnostics_Job, context.temp_allocator)

    sync.lock(&thor.io_mutex)
    for job in thor.finished_loads {
        append(&loads, job)
    }
    for job in thor.finished_saves {
        append(&saves, job)
    }
    for job in thor.finished_console {
        append(&console, job)
    }
    for job in thor.finished_git {
        append(&git, job)
    }
    for job in thor.finished_diagnostics {
        append(&diagnostics, job)
    }
    clear(&thor.finished_loads)
    clear(&thor.finished_saves)
    clear(&thor.finished_console)
    clear(&thor.finished_git)
    clear(&thor.finished_diagnostics)
    sync.unlock(&thor.io_mutex)

    for job in loads {
        thread.join(job.worker)
        thread.destroy(job.worker)

        file := job.file
        reload := job.reload
        changed := false
        if reload {
            changed = thor_apply_reload(thor, job)
        } else if job.ok {
            content := job.size > 0 ? string(job.data[:job.size]) : ""
            textedit.set_text(&file.state, content)
            file.loaded = true
            file.saved_revision = 0
            file.last_seen_revision = 0
            changed = true
        } else {
            file.load_failed = true
            if job.binary {
                log.warnf("Refusing to open binary file %q", job.path)
            } else {
                log.warnf("Failed to load %q", job.path)
            }
        }

        if job.view != nil {
            win32.UnmapViewOfFile(job.view)
        }
        if job.mapping != nil {
            win32.CloseHandle(job.mapping)
        }
        if job.handle != win32.INVALID_HANDLE_VALUE {
            win32.CloseHandle(job.handle)
        }
        free(job)

        file.pending_jobs -= 1
        thor.inflight_jobs -= 1
        if reload {
            file.reloading = false
        }

        // A fresh load always re-binds (to show the buffer or the failure
        // placeholder); a reload only when it actually replaced the buffer.
        if !file.closed && (!reload || changed) {
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
            // A fresh save of an Odin file re-runs the compiler for its package.
            if !file.closed && strings.has_suffix(file.name, ".odin") {
                thor_run_diagnostics_for_file(thor, file.path)
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

    for job in console {
        thread.join(job.worker)
        thread.destroy(job.worker)

        widgets.console_append(thor.console, job.output)
        widgets.console_command_finished(thor.console)

        delete(job.output)
        delete(job.command)
        free(job)
        thor.inflight_jobs -= 1
    }

    for job in git {
        thor_apply_git_status(thor, job)
    }

    for job in diagnostics {
        thor_reap_diagnostics(thor, job)
    }

    // A save or a console command may have changed the working tree; refresh
    // the status so the explorer highlighting stays current.
    if len(saves) > 0 || len(console) > 0 {
        thor_refresh_git_status(thor)
    }
}

thor_free_open_file :: proc(file: ^Open_File) {
    if file.texture_loaded {
        rl.UnloadTexture(file.texture)
    }
    textedit.destroy(&file.state)
    delete(file.highlights)
    delete(file.folds)
    thor_clear_file_diagnostics(file)
    delete(file.diagnostics)
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

// Tree widget callback: Delete was pressed on a file. Opens a confirmation
// dialog; the actual removal happens in thor_confirm_delete on acceptance.
thor_tree_delete :: proc(data: rawptr, path: string) {
    thor := cast(^Thor) data

    delete(thor.pending_delete_path)
    thor.pending_delete_path = strings.clone(path)

    delete(thor.delete_prompt)
    thor.delete_prompt = strings.concatenate({"Delete \"", file_base_name(path), "\"?"})

    widgets.command_palette_confirm(
        thor.command_palette,
        &thor.ui_context,
        thor.delete_prompt,
        thor_confirm_delete,
        thor,
    )
}

// Confirmation accepted: close any tab for the file, remove it from disk, and
// refresh the explorer and git status.
thor_confirm_delete :: proc(data: rawptr) {
    thor := cast(^Thor) data
    path := thor.pending_delete_path
    if path == "" {
        return
    }

    for file, index in thor.open_files {
        if thor_same_path(file.path, path) {
            thor_close_file(thor, index)
            break
        }
    }

    if err := os.remove(path); err != nil {
        log.warnf("Failed to delete %q: %v", path, err)
    }

    delete(thor.pending_delete_path)
    thor.pending_delete_path = ""

    widgets.tree_refresh(thor.tree)
    thor_refresh_git_status(thor)
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
