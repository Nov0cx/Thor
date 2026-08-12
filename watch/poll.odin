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
//
// Two owned snapshots are ping-ponged by swapping which pointer is `previous`
// and which is `current`, instead of destroying and remaking one every
// interval: each is a separate allocation, so resetting one for the next
// walk never invalidates the entry paths scan_diff is about to read from the
// other, and steady state allocates nothing.
@(private)
poll_worker :: proc(w: ^Watcher, stopping: ^bool) {
    a, b: Scan
    scan_tree(&a, w.root, w.allocator)
    defer scan_destroy(&a)
    defer scan_destroy(&b)

    previous := &a
    current := &b
    for !intrinsics.atomic_load(stopping) {
        poll_sleep(stopping)
        if intrinsics.atomic_load(stopping) {
            break
        }

        scan_tree(current, w.root, w.allocator)
        for change in scan_diff(previous^, current^) {
            watch_emit(w, change.kind, change.path)
        }
        previous, current = current, previous
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
