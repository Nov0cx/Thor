package thor

import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import "core:thread"
import "core:time"

import "../setting"
import "../textedit"
import "../ui"
import "../widgets"

// One open document. The textedit state lives here (not in the editor widget)
// so undo history and cursors survive tab switches; the editor only borrows
// a pointer to it.
Open_File :: struct {
    path:               string, // owned
    name:               string, // slice into path, do not free separately
    state:              textedit.State,
    loaded:             bool,
    load_failed:        bool,
    saving:             bool,
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
}

// Loaded via a memory mapping on a worker thread; the main thread copies the
// view into the piece table and unmaps. The worker makes no Odin heap
// allocations: the record is allocated/freed on the main thread, and appends
// to the finished queues go through their (mutex-guarded) allocator.
Load_Job :: struct {
    owner:   ^Thor,
    file:    ^Open_File,
    path:    string, // borrowed from file; valid while pending_jobs > 0
    worker:  ^thread.Thread,
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

thor_active_open_file :: proc(thor: ^Thor) -> ^Open_File {
    index := ui.signal_get(&thor.active_file)
    if index < 0 || index >= len(thor.open_files) {
        return nil
    }
    return thor.open_files[index]
}

thor_open_file :: proc(thor: ^Thor, path: string) {
    for file, index in thor.open_files {
        if file.path == path {
            thor_set_active_file(thor, index)
            return
        }
    }

    file := new(Open_File)
    file.path = strings.clone(path)
    file.name = file_base_name(file.path)
    textedit.init(&file.state)
    append(&thor.open_files, file)

    file.pending_jobs += 1
    thor.inflight_jobs += 1
    job := new(Load_Job)
    job.owner = thor
    job.file = file
    job.path = file.path
    job.worker = thread.create_and_start_with_poly_data(job, load_worker)

    thor_set_active_file(thor, len(thor.open_files) - 1)
}

thor_close_file :: proc(thor: ^Thor, index: int) {
    if index < 0 || index >= len(thor.open_files) {
        return
    }
    file := thor.open_files[index]
    ordered_remove(&thor.open_files, index)

    active := ui.signal_get(&thor.active_file)
    if active > index {
        active -= 1
    } else if active == index {
        active = min(index, len(thor.open_files) - 1)
    }
    thor_set_active_file(thor, active)

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

    // Keep the visible buffer's highlighting current (parse only the active file).
    if file := thor_active_open_file(thor); file != nil && file.loaded {
        if !file.highlighted || file.state.revision != file.highlight_revision {
            thor_update_highlights(thor, file)
        }
    }
}

thor_process_io :: proc(thor: ^Thor) {
    loads := make([dynamic]^Load_Job, context.temp_allocator)
    saves := make([dynamic]^Save_Job, context.temp_allocator)
    console := make([dynamic]^Console_Job, context.temp_allocator)

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
    clear(&thor.finished_loads)
    clear(&thor.finished_saves)
    clear(&thor.finished_console)
    sync.unlock(&thor.io_mutex)

    for job in loads {
        thread.join(job.worker)
        thread.destroy(job.worker)

        file := job.file
        if job.ok {
            content := job.size > 0 ? string(job.data[:job.size]) : ""
            textedit.set_text(&file.state, content)
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

        if !file.closed && file == thor_active_open_file(thor) {
            thor_set_active_file(thor, ui.signal_get(&thor.active_file))
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
}

thor_free_open_file :: proc(file: ^Open_File) {
    textedit.destroy(&file.state)
    delete(file.highlights)
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
