package watch

import "base:intrinsics"
import "core:time"

// The polling watcher body, for a platform with no event interface that covers a
// whole tree: snapshot the tree on an interval and report the difference. Kept
// platform-free, so the part that can go wrong is testable anywhere.

// How long between two snapshots, and how long the worker sleeps at a time. The
// interval keeps a large tree from costing a whole core; the slice keeps
// shutdown short.
@(private)
SCAN_INTERVAL :: 1 * time.Second

@(private)
SLEEP_SLICE :: 100 * time.Millisecond

// Snapshots the tree until `stopping` is set, emitting what moved between two
// snapshots. The caller supplies the flag its own watch_stop writes.
@(private)
poll_worker :: proc(w: ^Watcher, stopping: ^bool) {
    previous: Scan
    scan_tree(&previous, w.root, w.allocator)
    defer scan_destroy(&previous)

    for !intrinsics.atomic_load(stopping) {
        poll_sleep(stopping)
        if intrinsics.atomic_load(stopping) {
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
poll_sleep :: proc(stopping: ^bool) {
    slept: time.Duration
    for slept < SCAN_INTERVAL && !intrinsics.atomic_load(stopping) {
        time.sleep(SLEEP_SLICE)
        slept += SLEEP_SLICE
    }
}
