#+build linux
package watch

import "base:intrinsics"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"

// Linux watcher: inotify reports a change when it happens, so nothing walks the
// tree on an interval. inotify watches one directory at a time, so a watch is
// added for every directory of the tree at startup and for every directory made
// later. A machine caps the watches per user
// (/proc/sys/fs/inotify/max_user_watches), and a tree over that cap is watched
// only in part — the polling worker (poll.odin) takes over only when inotify is
// unavailable altogether.
Platform :: struct {
    fd:       linux.Fd,
    watches:  map[linux.Wd]string, // watch descriptor -> directory; paths are owned
    stopping: bool,
    polling:  bool, // inotify did not start, so the poller runs instead
}

// The events worth a report. CLOSE_WRITE rather than MODIFY: a writer that
// flushes in parts is still one change, and a reload wants the finished file.
@(private = "file")
EVENTS :: linux.Inotify_Event_Mask {
    .CREATE,
    .DELETE,
    .MOVED_FROM,
    .MOVED_TO,
    .CLOSE_WRITE,
}

// How long a wait for events lasts before the worker reads `stopping`, in
// milliseconds; the shutdown latency of the poller.
@(private = "file")
POLL_TIMEOUT :: 100

// Events are read in batches. 8 KiB holds around 200 of them.
@(private = "file")
EVENT_BUFFER :: 8 * 1024

@(private)
watch_start :: proc(w: ^Watcher) -> bool {
    if !os.is_dir(w.root) {
        return false
    }
    w.platform.stopping = false

    fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
    if err != .NONE {
        w.platform.polling = true
        return true
    }
    w.platform.fd = fd
    w.platform.watches = make(map[linux.Wd]string, w.allocator)

    // Not even the root: the process is out of watches, so poll the tree rather
    // than watch nothing.
    if !watch_add(w, w.root) {
        watch_release(w)
        w.platform.polling = true
        return true
    }
    watch_add_children(w, w.root, 0)
    return true
}

@(private)
watch_stop :: proc(w: ^Watcher) {
    intrinsics.atomic_store(&w.platform.stopping, true)
}

@(private)
watch_release :: proc(w: ^Watcher) {
    if w.platform.polling {
        return
    }
    for _, path in w.platform.watches {
        delete(path, w.allocator)
    }
    delete(w.platform.watches)
    w.platform.watches = nil
    linux.close(w.platform.fd)
}

@(private)
watch_worker :: proc(w: ^Watcher) {
    context.allocator = w.allocator
    if w.platform.polling {
        poll_worker(w, &w.platform.stopping)
        return
    }

    // Read into a u64 array: an event header must be aligned, and the kernel
    // aligns each one against the start of the buffer it was given.
    words: [EVENT_BUFFER / size_of(u64)]u64
    buffer := slice.to_bytes(words[:])

    for !intrinsics.atomic_load(&w.platform.stopping) {
        fds := []linux.Poll_Fd {{fd = w.platform.fd, events = {.IN}}}
        // A wait that ends in a signal or an error reads `stopping` and waits
        // again; nothing is lost, the events stay queued.
        if ready, err := linux.poll(fds, POLL_TIMEOUT); err != .NONE || ready <= 0 {
            continue
        }
        n, err := linux.read(w.platform.fd, buffer)
        if err != .NONE || n <= 0 {
            continue
        }
        watch_consume(w, buffer[:n])
        free_all(context.temp_allocator)
    }
}

// Splits a read into its events. Each is a header, then a name padded with NULs
// to align the one after it.
@(private = "file")
watch_consume :: proc(w: ^Watcher, buffer: []u8) {
    HEADER :: size_of(linux.Inotify_Event)
    offset := 0
    for offset + HEADER <= len(buffer) {
        event := cast(^linux.Inotify_Event) raw_data(buffer[offset:])
        next := offset + HEADER + int(event.len)
        if next > len(buffer) {
            break
        }
        name := ""
        if event.len > 0 {
            name = string(cstring(raw_data(buffer[offset + HEADER:next])))
        }
        watch_event(w, event.wd, event.mask, name)
        offset = next
    }
}

// Reports one event, and follows a new directory so its own changes are watched.
@(private = "file")
watch_event :: proc(w: ^Watcher, wd: linux.Wd, mask: linux.Inotify_Event_Mask, name: string) {
    // The watch is gone with its directory. The parent reported the directory
    // itself, so this only releases what it held.
    if .IGNORED in mask {
        _, path := delete_key(&w.platform.watches, wd)
        delete(path, w.allocator)
        return
    }
    dir, known := w.platform.watches[wd]
    if !known || name == "" {
        return
    }

    path := strings.concatenate({dir, "/", name}, context.temp_allocator)
    switch {
    case .CREATE in mask, .MOVED_TO in mask:
        watch_emit(w, .Created, path)
        // A directory moved in arrives with its contents; the explorer refresh
        // reads them off disk, so only the watches have to catch up.
        if .ISDIR in mask && watch_add(w, path) {
            watch_add_children(w, path, 0)
        }
    case .DELETE in mask, .MOVED_FROM in mask:
        watch_emit(w, .Deleted, path)
    case .CLOSE_WRITE in mask:
        watch_emit(w, .Modified, path)
    }
}

// Watches one directory. A failure is the watch limit or a directory that went
// away between the walk and the call; the tree is then watched only in part.
@(private = "file")
watch_add :: proc(w: ^Watcher, dir: string) -> bool {
    path := strings.clone_to_cstring(dir, w.allocator)
    defer delete(path, w.allocator)

    wd, err := linux.inotify_add_watch(w.platform.fd, path, EVENTS)
    if err != .NONE {
        return false
    }
    // A directory watched twice answers with the descriptor it already has.
    if _, taken := w.platform.watches[wd]; taken {
        return true
    }
    w.platform.watches[wd] = strings.clone(dir, w.allocator)
    return true
}

// Watches every directory under `dir`. The depth cap is what stops a symbolic
// link that points back at an ancestor from looping forever, as in scan.odin.
@(private = "file")
watch_add_children :: proc(w: ^Watcher, dir: string, depth: int) {
    if depth >= MAX_DEPTH {
        return
    }
    infos, err := os.read_all_directory_by_path(dir, w.allocator)
    if err != nil {
        return
    }
    // The listing stays alive over the recursion, so the peak cost is one
    // directory listing per level, not one for the whole tree.
    defer os.file_info_slice_delete(infos, w.allocator)

    for info in infos {
        if info.type != .Directory {
            continue
        }
        if watch_add(w, info.fullpath) {
            watch_add_children(w, info.fullpath, depth + 1)
        }
    }
}
