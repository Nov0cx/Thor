#+build linux
package watch

import "base:intrinsics"
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

// A fresh directory of its own under the system temporary directory. TMPDIR is
// unset on the CI runners, where /tmp is what it would name.
@(private = "file")
temp_root :: proc(t: ^testing.T, name: string) -> string {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    root, join_err := filepath.join(
        {strings.trim_right(base, "/"), fmt.tprintf("%s_%d", name, time.now()._nsec)},
        context.temp_allocator,
    )
    if join_err != nil {
        testing.fail_now(t, "could not name a temp dir")
    }
    if err := os.make_directory(root); err != nil {
        testing.fail_now(t, fmt.tprintf("could not create temp dir %q: %v", root, err))
    }
    return root
}

// inotify keys a watch on the inode, so a directory renamed inside the tree
// comes back with the descriptor it already had. Its stored path has to follow
// the rename, or every later event under it is reported at a path that is gone.
@(test)
test_watch_rename_reports_the_new_path :: proc(t: ^testing.T) {
    root := temp_root(t, "thor_watch_rename")
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

// Only the cap hands the tree to the poller. A directory that went away between
// the walk and the call, or one that is not ours to read, is normal and must
// leave inotify running.
@(test)
test_watch_exhausted_only_for_the_cap :: proc(t: ^testing.T) {
    testing.expect(t, watch_exhausted(.ENOSPC), "the watch cap must degrade")
    testing.expect(t, watch_exhausted(.EMFILE), "the instance limit must degrade")
    testing.expect(t, watch_exhausted(.ENOMEM), "a kernel allocation failure must degrade")
    testing.expect(t, !watch_exhausted(.ENOENT), "a vanished directory is normal")
    testing.expect(t, !watch_exhausted(.EACCES), "an unreadable directory is normal")
}

// Running out of watches mid-session drops inotify and finishes on the poller,
// rather than leaving the tree watched only in part. The flag is set here the way
// a failed inotify_add_watch sets it; driving the real cap needs root over a
// process-global /proc knob. Freeing twice fails this under the tracking allocator.
@(test)
test_watch_degrade_falls_back_to_polling :: proc(t: ^testing.T) {
    root := temp_root(t, "thor_watch_degrade")
    defer os.remove(root)

    w: Watcher
    testing.expect(t, watcher_init(&w, root), "watcher_init should succeed on a real directory")
    defer watcher_destroy(&w)

    seen: Seen
    defer seen_destroy(&seen)
    watcher_subscribe(&w, seen_collect, &seen)

    intrinsics.atomic_store(&w.platform.polling, true)
    // The root change is the hint that covers what was missed before the first
    // snapshot; its arrival is also how the test knows the degrade happened.
    pump_for(&w, &seen, root, 2 * time.Second)
    testing.expect(t, seen_has(&seen, root), "no root resync hint on the degrade")

    // A fresh name per attempt: a rewrite of one file inside a snapshot interval
    // can keep its size and write time, which is no difference to report.
    reported := false
    for attempt in 0 ..< 5 {
        file, _ := filepath.join(
            {root, fmt.tprintf("after_%d.txt", attempt)},
            context.temp_allocator,
        )
        defer os.remove(file)
        if err := os.write_entire_file(file, transmute([]u8) string("hi")); err != nil {
            continue
        }
        pump_for(&w, &seen, file, 3 * time.Second)
        if seen_has(&seen, file) {
            reported = true
            break
        }
    }
    testing.expect(t, reported, "the poller never took over")
}

// A dependency tree is noise no consumer needs, and watching it is what exhausts
// the cap. The directory itself still reports; what is inside it does not.
@(test)
test_watch_skips_a_dependency_tree :: proc(t: ^testing.T) {
    root := temp_root(t, "thor_watch_skip")
    defer os.remove(root)

    heavy, _ := filepath.join({root, "node_modules"}, context.temp_allocator)
    if err := os.make_directory(heavy); err != nil {
        testing.fail_now(t, fmt.tprintf("could not create %q: %v", heavy, err))
    }
    defer os.remove(heavy)

    w: Watcher
    testing.expect(t, watcher_init(&w, root), "watcher_init should succeed on a real directory")
    defer watcher_destroy(&w)

    seen: Seen
    defer seen_destroy(&seen)
    watcher_subscribe(&w, seen_collect, &seen)

    // A file beside it proves the watcher is running, so the negative below is a
    // skipped directory rather than a watcher that reported nothing at all.
    inside, _ := filepath.join({heavy, "dep.txt"}, context.temp_allocator)
    beside, _ := filepath.join({root, "own.txt"}, context.temp_allocator)
    defer os.remove(inside)
    defer os.remove(beside)

    _ = os.write_entire_file(inside, transmute([]u8) string("dep"))
    _ = os.write_entire_file(beside, transmute([]u8) string("own"))
    pump_for(&w, &seen, beside, 2 * time.Second)

    testing.expect(t, seen_has(&seen, beside), "a file in the workspace was never reported")
    testing.expect(t, !seen_has(&seen, inside), "a file under node_modules was reported")
}
