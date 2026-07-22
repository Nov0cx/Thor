package watch

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

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
    root := fmt.tprintf("%s\\thor_watch_test_%d", os.get_env("TEMP", context.temp_allocator), time.now()._nsec)
    if err := os.make_directory(root); err != nil {
        testing.fail_now(t, fmt.tprintf("could not create temp dir %q: %v", root, err))
    }
    defer os.remove(root)

    w: Watcher
    ok := watcher_init(&w, root)
    testing.expect(t, ok, "watcher_init should succeed on a real directory")
    defer watcher_destroy(&w)

    sink: Sink
    defer sink_destroy(&sink)
    watcher_subscribe(&w, sink_collect, &sink)

    file := fmt.tprintf("%s\\hello.txt", root)

    // Create.
    _ = os.write_entire_file(file, transmute([]u8) string("hi"))
    pump_until(&w, &sink, proc(s: ^Sink) -> bool {
        for c in s.changes {
            if c.kind == .Created || c.kind == .Modified {
                return true
            }
        }
        return false
    })
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

@(test)
test_watch_init_bad_dir :: proc(t: ^testing.T) {
    w: Watcher
    ok := watcher_init(&w, "Z:\\definitely\\not\\a\\real\\path\\thor")
    testing.expect(t, !ok, "watcher_init should fail on a nonexistent directory")
    // Destroy must be safe on an inert watcher and must not leak.
    watcher_destroy(&w)
}
