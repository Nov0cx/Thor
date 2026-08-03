#+build !windows
package watch

import "base:intrinsics"
import "core:time"

// POSIX watcher: no portable event interface covers a whole tree, so the worker
// takes a snapshot of it on an interval and reports the difference. inotify
// (Linux) and FSEvents (macOS) would each replace this with real events.
Platform :: struct {
    stopping: bool, // read between sleeps, so a shutdown waits at most one slice
}

// How long between two snapshots, and how long the worker sleeps at a time. The
// interval keeps a large tree from costing a whole core; the slice keeps
// shutdown short.
@(private)
SCAN_INTERVAL :: 1 * time.Second

@(private)
SLEEP_SLICE :: 100 * time.Millisecond

@(private)
watch_start :: proc(w: ^Watcher) -> bool {
    w.platform.stopping = false
    return true
}

@(private)
watch_stop :: proc(w: ^Watcher) {
    intrinsics.atomic_store(&w.platform.stopping, true)
}

@(private)
watch_release :: proc(w: ^Watcher) {
}

@(private)
watch_worker :: proc(w: ^Watcher) {
    context.allocator = w.allocator

    previous: Scan
    scan_tree(&previous, w.root, w.allocator)
    defer scan_destroy(&previous)

    for !intrinsics.atomic_load(&w.platform.stopping) {
        watch_sleep(w)
        if intrinsics.atomic_load(&w.platform.stopping) {
            break
        }

        current: Scan
        scan_tree(&current, w.root, w.allocator)
        for change in scan_diff(previous, current) {
            watch_emit(w, change.kind, change.path)
        }
        // The changes borrow both snapshots, so the old one goes only after the
        // last one is queued.
        scan_destroy(&previous)
        previous = current
        free_all(context.temp_allocator)
    }
}

// Sleeps one interval, but wakes often enough to see a shutdown.
@(private)
watch_sleep :: proc(w: ^Watcher) {
    slept: time.Duration
    for slept < SCAN_INTERVAL && !intrinsics.atomic_load(&w.platform.stopping) {
        time.sleep(SLEEP_SLICE)
        slept += SLEEP_SLICE
    }
}
