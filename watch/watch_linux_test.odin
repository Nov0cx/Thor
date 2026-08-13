#+build linux
package watch

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// Paths a watcher reported, kept so the test can assert on them after the poll
// loop was pumped.
@(private = "file")
Seen :: struct {
    paths: [dynamic]string, // owned
}

@(private = "file")
seen_collect :: proc(data: rawptr, change: Change) {
    seen := cast(^Seen) data
    append(&seen.paths, strings.clone(change.path))
}

@(private = "file")
seen_destroy :: proc(seen: ^Seen) {
    for path in seen.paths {
        delete(path)
    }
    delete(seen.paths)
}

@(private = "file")
seen_has :: proc(seen: ^Seen, path: string) -> bool {
    for reported in seen.paths {
        if reported == path {
            return true
        }
    }
    return false
}

// Pumps watcher_poll until `path` is reported or the deadline passes.
@(private = "file")
pump_for :: proc(w: ^Watcher, seen: ^Seen, path: string, timeout: time.Duration) {
    start := time.tick_now()
    for time.tick_since(start) < timeout {
        watcher_poll(w)
        if seen_has(seen, path) {
            return
        }
        time.sleep(15 * time.Millisecond)
    }
    watcher_poll(w)
}

// inotify keys a watch on the inode, so a directory renamed inside the tree
// comes back with the descriptor it already had. Its stored path has to follow
// the rename, or every later event under it is reported at a path that is gone.
@(test)
test_watch_rename_reports_the_new_path :: proc(t: ^testing.T) {
    // TMPDIR is unset on the CI runners, where /tmp is what it would name.
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    root, _ := filepath.join(
        {strings.trim_right(base, "/"), fmt.tprintf("thor_watch_rename_%d", time.now()._nsec)},
        context.temp_allocator,
    )
    if err := os.make_directory(root); err != nil {
        testing.fail_now(t, fmt.tprintf("could not create temp dir %q: %v", root, err))
    }
    defer os.remove(root)

    before, _ := filepath.join({root, "before"}, context.temp_allocator)
    after, _ := filepath.join({root, "after"}, context.temp_allocator)
    if err := os.make_directory(before); err != nil {
        testing.fail_now(t, fmt.tprintf("could not create %q: %v", before, err))
    }
    defer os.remove(after)

    w: Watcher
    testing.expect(t, watcher_init(&w, root), "watcher_init should succeed on a real directory")
    defer watcher_destroy(&w)

    seen: Seen
    defer seen_destroy(&seen)
    watcher_subscribe(&w, seen_collect, &seen)

    if err := os.rename(before, after); err != nil {
        testing.fail_now(t, fmt.tprintf("could not rename %q: %v", before, err))
    }

    // The write is repeated because the worker may not have read the rename yet;
    // the queue keeps its order, so the directory's own event is always consumed
    // before an event for a file inside it.
    stale, _ := filepath.join({before, "note.txt"}, context.temp_allocator)
    file, _ := filepath.join({after, "note.txt"}, context.temp_allocator)
    defer os.remove(file)
    for _ in 0 ..< 5 {
        _ = os.write_entire_file(file, transmute([]u8) string("hi"))
        pump_for(&w, &seen, file, 1500 * time.Millisecond)
        if seen_has(&seen, file) {
            break
        }
    }

    testing.expect(t, seen_has(&seen, file), "the file in the renamed directory was never reported")
    testing.expect(t, !seen_has(&seen, stale), "a change was reported under the pre-rename path")
}
