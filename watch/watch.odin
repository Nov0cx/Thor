package watch

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"

// What happened to a path on disk. A rename surfaces as a Deleted of the old
// name and a Created of the new one, so consumers never have to correlate a pair.
Change_Kind :: enum u8 {
    Created,
    Modified,
    Deleted,
}

// A single filesystem change under the watched root. `path` is absolute with
// native separators (backslash on Windows). It is watcher-owned and only valid
// for the duration of the subscriber callback — copy it to keep it past that.
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

// Recursive async watch of one directory tree. A worker thread collects changes
// and hands them to the main thread, which drains them in watcher_poll and fans
// them out to subscribers. Deliberately generic: the explorer, the open-file
// buffers and (later) the language backend each subscribe without the watcher
// knowing about them.
Watcher :: struct {
    root:        string, // owned, absolute directory watched recursively
    allocator:   runtime.Allocator,
    subscribers: [dynamic]Subscriber,
    // Worker -> main hand-off. The worker appends under `mutex`; the main thread
    // drains `pending` each poll. Change paths are allocator-owned and freed
    // after they are dispatched.
    mutex:       sync.Mutex,
    pending:     [dynamic]Change,
    platform:    Platform, // what the platform's worker needs
    worker:      ^thread.Thread,
    running:     bool,
}

// The worker is platform code: watch_windows.odin blocks on
// ReadDirectoryChangesW, watch_posix.odin polls the tree. Each platform file
// supplies `Platform` plus four procedures — `watch_start` opens what the worker
// needs and reports whether the tree can be watched, `watch_worker` is the
// worker body, `watch_stop` makes that body return, and `watch_release` frees
// what watch_start opened.

// Starts watching `root` recursively. Returns false when the directory can't be
// watched; the Watcher is then inert and still safe to destroy. The worker thread
// runs until watcher_destroy.
watcher_init :: proc(w: ^Watcher, root: string) -> bool {
    w.allocator = context.allocator
    w.root = strings.clone(root)
    w.subscribers = make([dynamic]Subscriber)
    w.pending = make([dynamic]Change)

    if !watch_start(w) {
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
        watch_stop(w)
        thread.join(w.worker)
        thread.destroy(w.worker)
        w.running = false
    }
    watch_release(w)
    // Changes gathered but never polled still own their path strings.
    for change in w.pending {
        delete(change.path, w.allocator)
    }
    delete(w.pending)
    delete(w.subscribers)
    delete(w.root)
}

// Clones `path` into watcher-owned memory and queues the change for the main thread.
@(private)
watch_emit :: proc(w: ^Watcher, kind: Change_Kind, path: string) {
    change := Change {kind = kind, path = strings.clone(path, w.allocator)}
    sync.lock(&w.mutex)
    append(&w.pending, change)
    sync.unlock(&w.mutex)
}
