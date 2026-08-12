package watch

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// A unique path under the OS temp directory, with native separators. TEMP is
// Windows only; POSIX names it TMPDIR and leaves it unset on the CI runners.
@(private = "file")
temp_path :: proc(name: string) -> string {
    base := os.get_env("TEMP", context.temp_allocator)
    when ODIN_OS != .Windows {
        if base == "" {
            base = os.get_env("TMPDIR", context.temp_allocator)
        }
        if base == "" {
            base = "/tmp"
        }
    }
    base = strings.trim_right(base, "/\\")
    joined, _ := filepath.join({base, fmt.tprintf("%s_%d", name, time.now()._nsec)}, context.temp_allocator)
    return joined
}

// Collects the changes a watcher delivers, so a test can assert on them after
// pumping the poll loop.
@(private = "file")
Sink :: struct {
    changes: [dynamic]Change, // owned copies (path cloned), freed by sink_destroy
}

@(private = "file")
sink_collect :: proc(data: rawptr, change: Change) {
    sink := cast(^Sink) data
    append(&sink.changes, Change {kind = change.kind, path = strings.clone(change.path)})
}

@(private = "file")
sink_destroy :: proc(sink: ^Sink) {
    for c in sink.changes {
        delete(c.path)
    }
    delete(sink.changes)
}

@(private = "file")
sink_clear :: proc(sink: ^Sink) {
    for c in sink.changes {
        delete(c.path)
    }
    clear(&sink.changes)
}

@(private = "file")
sink_has :: proc(sink: ^Sink, kind: Change_Kind, path: string) -> bool {
    for c in sink.changes {
        if c.kind == kind && strings.equal_fold(c.path, path) {
            return true
        }
    }
    return false
}

@(private = "file")
sink_saw_content_change :: proc(sink: ^Sink) -> bool {
    for c in sink.changes {
        if c.kind == .Created || c.kind == .Modified {
            return true
        }
    }
    return false
}

// Pumps watcher_poll until `pred` holds or the deadline passes, so the test does
// not depend on how quickly the OS delivers directory notifications.
@(private = "file")
pump_until :: proc(w: ^Watcher, sink: ^Sink, pred: proc(^Sink) -> bool, timeout := 3 * time.Second) {
    deadline := time.tick_now()
    for time.duration_seconds(time.tick_since(deadline)) < time.duration_seconds(timeout) {
        watcher_poll(w)
        if pred(sink) {
            return
        }
        time.sleep(15 * time.Millisecond)
    }
    watcher_poll(w)
}

@(test)
test_watch_create_modify_delete :: proc(t: ^testing.T) {
    // A unique temp directory to watch.
    root := temp_path("thor_watch_test")
    if err := os.make_directory(root); err != nil {
        testing.fail_now(t, fmt.tprintf("could not create temp dir %q: %v", root, err))
    }
    defer os.remove(root)

    // The watcher reports the path the OS gives it, which is resolved: darwin
    // reads an opened path back with F_GETPATH, and the temp directory sits
    // behind a symbolic link there (/var -> /private/var). The paths to compare
    // against must pass through the same resolution, which is what the editor
    // does too (thor_same_path).
    if resolved, err := filepath.abs(root, context.temp_allocator); err == nil {
        root = resolved
    }

    w: Watcher
    ok := watcher_init(&w, root)
    testing.expect(t, ok, "watcher_init should succeed on a real directory")
    defer watcher_destroy(&w)

    sink: Sink
    defer sink_destroy(&sink)
    watcher_subscribe(&w, sink_collect, &sink)

    file, _ := filepath.join({root, "hello.txt"}, context.temp_allocator)

    // Create. The worker starts asynchronously, so a write that lands before it
    // is watching is never reported: the polling watcher already has the file in
    // its first snapshot, and the Windows one has no read call posted yet. The
    // write is repeated until a change arrives, which reports Modified once the
    // file exists.
    for _ in 0 ..< 5 {
        _ = os.write_entire_file(file, transmute([]u8) string("hi"))
        pump_until(&w, &sink, sink_saw_content_change, 1500 * time.Millisecond)
        if sink_saw_content_change(&sink) {
            break
        }
    }
    testing.expect(t, sink_has(&sink, .Created, file) || sink_has(&sink, .Modified, file),
        "expected a create/modify change for the new file")

    // Delete.
    sink_clear(&sink)
    os.remove(file)
    pump_until(&w, &sink, proc(s: ^Sink) -> bool {
        for c in s.changes {
            if c.kind == .Deleted {
                return true
            }
        }
        return false
    })
    testing.expect(t, sink_has(&sink, .Deleted, file), "expected a delete change for the removed file")
}

// An absolute path that cannot exist, in the syntax of the host: a Windows one
// is not absolute on POSIX, which would resolve it against the working directory.
@(private = "file")
MISSING_DIR :: "Z:\\definitely\\not\\a\\real\\path\\thor" when ODIN_OS == .Windows else "/definitely/not/a/real/path/thor"

@(test)
test_watch_init_bad_dir :: proc(t: ^testing.T) {
    w: Watcher
    ok := watcher_init(&w, MISSING_DIR)
    testing.expect(t, !ok, "watcher_init should fail on a nonexistent directory")
    // Destroy must be safe on an inert watcher and must not leak.
    watcher_destroy(&w)
}

// A burst larger than WATCH_DRAIN_MAX is spread over more than one poll: one
// call dispatches only the cap and leaves the rest queued. No real watcher is
// started here (watcher_init's platform worker is a separate OS thread with
// its own shutdown timing, exercised by test_watch_destroy_twice already) —
// `w` is hand-built with `running` set and torn down by hand, so this stays a
// pure test of watcher_poll's in-memory queue capping, with `w.pending`'s
// leftover tail deleted by hand standing in for what a real destroy frees.
@(test)
test_watcher_poll_caps_one_drain :: proc(t: ^testing.T) {
    w: Watcher
    w.allocator = context.allocator
    w.pending = make([dynamic]Change)
    w.subscribers = make([dynamic]Subscriber)
    w.running = true
    defer {
        for c in w.pending {
            delete(c.path, w.allocator)
        }
        delete(w.pending)
        delete(w.subscribers)
    }

    sink: Sink
    defer sink_destroy(&sink)
    watcher_subscribe(&w, sink_collect, &sink)

    for i in 0 ..< WATCH_DRAIN_MAX + 50 {
        watch_emit(&w, .Modified, fmt.tprintf("file_%d.tmp", i))
    }

    watcher_poll(&w)
    testing.expect_value(t, len(sink.changes), WATCH_DRAIN_MAX)
    testing.expect_value(t, len(w.pending), 50)
}

// Closing the workspace destroys the watcher and quitting destroys it again, so
// the second destroy must free nothing twice.
@(test)
test_watch_destroy_twice :: proc(t: ^testing.T) {
    root := temp_path("thor_watch_twice")
    if err := os.make_directory(root); err != nil {
        testing.fail_now(t, fmt.tprintf("could not create temp dir %q: %v", root, err))
    }
    defer os.remove(root)

    w: Watcher
    testing.expect(t, watcher_init(&w, root), "watcher_init should succeed on a real directory")
    sink: Sink
    defer sink_destroy(&sink)
    watcher_subscribe(&w, sink_collect, &sink)

    watcher_destroy(&w)
    testing.expect(t, !w.running, "a destroyed watcher must read as inert")
    watcher_destroy(&w)
    // A poll after both must be a no-op rather than a read of freed memory.
    watcher_poll(&w)
}
