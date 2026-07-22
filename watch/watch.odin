package watch

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import win32 "core:sys/windows"

// What happened to a path on disk. A rename surfaces as a Deleted of the old
// name and a Created of the new one, so consumers never have to correlate a pair.
Change_Kind :: enum u8 {
    Created,
    Modified,
    Deleted,
}

// A single filesystem change under the watched root. `path` is absolute with
// native (backslash) separators. It is watcher-owned and only valid for the
// duration of the subscriber callback — copy it to keep it past that.
Change :: struct {
    kind: Change_Kind,
    path: string,
}

// Delivered on the main thread (from watcher_poll) once per change. `data` is the
// opaque pointer supplied at subscribe time.
Callback :: #type proc(data: rawptr, change: Change)

@(private)
Subscriber :: struct {
    callback: Callback,
    data:     rawptr,
}

// Recursive async watch of one directory tree, built on ReadDirectoryChangesW.
// A worker thread blocks on overlapped directory reads and hands parsed changes
// to the main thread, which drains them in watcher_poll and fans them out to
// subscribers. Deliberately generic: the explorer, the open-file buffers and
// (later) the language backend each subscribe without the watcher knowing about
// them.
Watcher :: struct {
    root:        string, // owned, absolute directory watched recursively
    allocator:   runtime.Allocator,
    subscribers: [dynamic]Subscriber,
    // Worker -> main hand-off. The worker appends under `mutex`; the main thread
    // drains `pending` each poll. Change paths are allocator-owned and freed
    // after they are dispatched.
    mutex:       sync.Mutex,
    pending:     [dynamic]Change,
    dir_handle:  win32.HANDLE,
    stop_event:  win32.HANDLE, // signalled to break the worker's wait on shutdown
    worker:      ^thread.Thread,
    running:     bool,
}

// Change buffer handed to ReadDirectoryChangesW. 64 KiB holds a large burst of
// entries; on overflow the OS reports zero bytes and we emit one root change so
// consumers fall back to a full rescan.
@(private)
BUFFER_SIZE :: 64 * 1024

@(private)
NOTIFY_FILTER :: win32.FILE_NOTIFY_CHANGE_FILE_NAME |
    win32.FILE_NOTIFY_CHANGE_DIR_NAME |
    win32.FILE_NOTIFY_CHANGE_LAST_WRITE |
    win32.FILE_NOTIFY_CHANGE_SIZE |
    win32.FILE_NOTIFY_CHANGE_CREATION

// Starts watching `root` recursively. Returns false when the directory can't be
// opened for watching; the Watcher is then inert and still safe to destroy. The
// worker thread runs until watcher_destroy.
watcher_init :: proc(w: ^Watcher, root: string) -> bool {
    w.allocator = context.allocator
    w.root = strings.clone(root)
    w.subscribers = make([dynamic]Subscriber)
    w.pending = make([dynamic]Change)

    wide := win32.utf8_to_wstring(root, context.temp_allocator)
    w.dir_handle = win32.CreateFileW(
        wide,
        win32.FILE_LIST_DIRECTORY,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        nil,
        win32.OPEN_EXISTING,
        win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED,
        nil,
    )
    if w.dir_handle == win32.INVALID_HANDLE_VALUE {
        return false
    }

    // Manual-reset, initially unsignalled: SetEvent on shutdown wakes the worker's
    // wait and it stays woken so the wait can't miss it.
    w.stop_event = win32.CreateEventW(nil, true, false, nil)
    if w.stop_event == nil {
        win32.CloseHandle(w.dir_handle)
        w.dir_handle = win32.INVALID_HANDLE_VALUE
        return false
    }

    w.running = true
    w.worker = thread.create_and_start_with_poly_data(w, watch_worker)
    return true
}

// Registers a subscriber. Meant to be called at setup, before the poll loop runs;
// like watcher_poll it touches `subscribers` on the main thread only.
watcher_subscribe :: proc(w: ^Watcher, callback: Callback, data: rawptr) {
    if !w.running {
        return
    }
    append(&w.subscribers, Subscriber {callback = callback, data = data})
}

// Drains the changes gathered since the last call and delivers each to every
// subscriber. Call once per frame on the main thread. Change paths are freed
// after dispatch, so a subscriber must copy anything it keeps.
watcher_poll :: proc(w: ^Watcher) {
    if !w.running {
        return
    }

    changes := make([dynamic]Change, context.temp_allocator)
    sync.lock(&w.mutex)
    for change in w.pending {
        append(&changes, change)
    }
    clear(&w.pending)
    sync.unlock(&w.mutex)

    for change in changes {
        for sub in w.subscribers {
            sub.callback(sub.data, change)
        }
        delete(change.path, w.allocator)
    }
}

// Stops the worker and releases everything. Safe on an inert (failed-init) watcher.
watcher_destroy :: proc(w: ^Watcher) {
    if w.running {
        win32.SetEvent(w.stop_event)
        thread.join(w.worker)
        thread.destroy(w.worker)
        w.running = false
    }
    if w.stop_event != nil {
        win32.CloseHandle(w.stop_event)
        w.stop_event = nil
    }
    if w.dir_handle != win32.INVALID_HANDLE_VALUE && w.dir_handle != nil {
        win32.CloseHandle(w.dir_handle)
        w.dir_handle = win32.INVALID_HANDLE_VALUE
    }
    // Changes gathered but never polled still own their path strings.
    for change in w.pending {
        delete(change.path, w.allocator)
    }
    delete(w.pending)
    delete(w.subscribers)
    delete(w.root)
}

@(private)
watch_worker :: proc(w: ^Watcher) {
    context.allocator = w.allocator

    buffer := make([]u8, BUFFER_SIZE, w.allocator)
    defer delete(buffer, w.allocator)

    overlapped: win32.OVERLAPPED
    overlapped.hEvent = win32.CreateEventW(nil, true, false, nil)
    if overlapped.hEvent == nil {
        return
    }
    defer win32.CloseHandle(overlapped.hEvent)

    for {
        win32.ResetEvent(overlapped.hEvent)
        bytes: win32.DWORD
        ok := win32.ReadDirectoryChangesW(
            w.dir_handle,
            raw_data(buffer),
            u32(len(buffer)),
            true, // recursive
            NOTIFY_FILTER,
            &bytes,
            &overlapped,
            nil,
        )
        if !ok {
            break
        }

        // Block until either the read completes or shutdown signals stop_event.
        handles := [2]win32.HANDLE {overlapped.hEvent, w.stop_event}
        signalled := win32.WaitForMultipleObjects(2, &handles[0], false, win32.INFINITE)
        if signalled != win32.WAIT_OBJECT_0 {
            // stop_event (index 1) or a wait failure: cancel the pending read and exit.
            win32.CancelIo(w.dir_handle)
            break
        }

        transferred: win32.DWORD
        if !win32.GetOverlappedResult(w.dir_handle, &overlapped, &transferred, false) {
            break
        }
        if transferred == 0 {
            // Too many changes to report individually; the entries were dropped.
            // Emit one change on the root so subscribers do a full rescan.
            watch_emit(w, .Modified, w.root)
            continue
        }

        watch_parse(w, buffer[:transferred])
    }
}

// Walks the FILE_NOTIFY_INFORMATION chain, turning each entry into a Change with
// an absolute native path and queuing it for the main thread.
@(private)
watch_parse :: proc(w: ^Watcher, data: []u8) {
    offset := 0
    for offset < len(data) {
        info := cast(^win32.FILE_NOTIFY_INFORMATION) raw_data(data[offset:])

        // file_name is a WCHAR run of file_name_length bytes, reported relative to
        // the watched root and already using backslash separators.
        name_wchars := int(info.file_name_length) / size_of(win32.WCHAR)
        name_ptr := cast([^]u16) &info.file_name
        rel, conv_err := win32.utf16_to_utf8(name_ptr[:name_wchars], context.temp_allocator)
        if conv_err == nil && rel != "" {
            path := strings.concatenate({w.root, "\\", rel}, context.temp_allocator)
            kind: Change_Kind
            switch info.action {
            case win32.FILE_ACTION_ADDED, win32.FILE_ACTION_RENAMED_NEW_NAME:
                kind = .Created
            case win32.FILE_ACTION_REMOVED, win32.FILE_ACTION_RENAMED_OLD_NAME:
                kind = .Deleted
            case:
                kind = .Modified
            }
            watch_emit(w, kind, path)
        }

        if info.next_entry_offset == 0 {
            break
        }
        offset += int(info.next_entry_offset)
    }
}

// Clones `path` into watcher-owned memory and queues the change for the main thread.
@(private)
watch_emit :: proc(w: ^Watcher, kind: Change_Kind, path: string) {
    change := Change {kind = kind, path = strings.clone(path, w.allocator)}
    sync.lock(&w.mutex)
    append(&w.pending, change)
    sync.unlock(&w.mutex)
}
