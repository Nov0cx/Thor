#+build darwin, freebsd, openbsd, netbsd
package watch

import "base:intrinsics"
import "core:os"

// Polling watcher: no portable event interface covers a whole tree here, so the
// worker snapshots it on an interval and reports the difference (poll.odin).
// FSEvents (macOS) and kqueue would each replace this with real events; Linux
// already has its own worker (watch_linux.odin).
Platform :: struct {
    stopping: bool, // read between sleeps, so a shutdown waits at most one slice
}

@(private)
watch_start :: proc(w: ^Watcher) -> bool {
    // The worker only scans, so nothing else would report an unwatchable root.
    if !os.is_dir(w.root) {
        return false
    }
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
    poll_worker(w, &w.platform.stopping)
}
