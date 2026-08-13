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
// (/proc/sys/fs/inotify/max_user_watches); a tree over that cap would be watched
// only in part, so the polling worker (poll.odin) takes the whole tree instead —
// as it does when inotify does not start at all.
Platform :: struct {
    fd:       linux.Fd,
    watches:  map[linux.Wd]string, // watch descriptor -> directory; paths are owned
    stopping: bool,
    polling:  bool, // atomic: inotify is gone, so the poller runs instead
    open:     bool, // `fd` is a live descriptor; a zeroed Platform owns nothing
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
    w.platform.polling = false

    fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
    if err != .NONE {
        w.platform.polling = true
        return true
    }
    w.platform.fd = fd
    w.platform.open = true
    w.platform.watches = make(map[linux.Wd]string, w.allocator)

    // Not even the root: the process is out of watches, so poll the tree rather
    // than watch nothing.
    if !watch_add(w, w.root) {
        w.platform.polling = true
        inotify_close(w)
        return true
    }
    watch_add_children(w, w.root, 0)
    // The walk ran out of watches: a tree watched only in part loses changes
    // without a sign, so the poller takes all of it.
    if w.platform.polling {
        inotify_close(w)
    }
    return true
}

@(private)
watch_stop :: proc(w: ^Watcher) {
    intrinsics.atomic_store(&w.platform.stopping, true)
}

@(private)
watch_release :: proc(w: ^Watcher) {
    inotify_close(w)
}

// Frees the watches and closes the descriptor. Safe twice and on a watcher that
// never opened one: the worker calls it when it degrades, watch_release again at
// shutdown.
@(private = "file")
inotify_close :: proc(w: ^Watcher) {
    for _, path in w.platform.watches {
        delete(path, w.allocator)
    }
    delete(w.platform.watches)
    w.platform.watches = nil
    if w.platform.open {
        linux.close(w.platform.fd)
        w.platform.open = false
    }
}

@(private)
watch_worker :: proc(w: ^Watcher) {
    context.allocator = w.allocator
    if intrinsics.atomic_load(&w.platform.polling) {
        poll_worker(w, &w.platform.stopping)
        return
    }

    // Read into a u64 array: an event header must be aligned, and the kernel
    // aligns each one against the start of the buffer it was given.
    words: [EVENT_BUFFER / size_of(u64)]u64
    buffer := slice.to_bytes(words[:])

    for !intrinsics.atomic_load(&w.platform.stopping) {
        // A watch that could not be added left the tree watched only in part.
        if intrinsics.atomic_load(&w.platform.polling) {
            watch_degrade(w)
            return
        }
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

// Drops inotify and finishes the session on the poller. The root change is the
// usual "events were lost" hint: it covers what changed before the first snapshot.
@(private = "file")
watch_degrade :: proc(w: ^Watcher) {
    inotify_close(w)
    if intrinsics.atomic_load(&w.platform.stopping) {
        return
    }
    watch_emit(w, .Modified, w.root)
    poll_worker(w, &w.platform.stopping)
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
    // The kernel dropped events once the queue filled; wd is -1, so it can't be
    // resolved to a directory. Emit one change on the root so subscribers do a
    // full rescan instead of silently missing whatever was lost.
    if .Q_OVERFLOW in mask {
        watch_emit(w, .Modified, w.root)
        return
    }
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
        // reads them off disk, so only the watches have to catch up. A dependency
        // tree made here is skipped, or an install would consume the cap at once.
        if .ISDIR in mask && !scan_skip_dir(dir, name) && watch_add(w, path) {
            watch_add_children(w, path, 0)
        }
    case .DELETE in mask, .MOVED_FROM in mask:
        watch_emit(w, .Deleted, path)
    case .CLOSE_WRITE in mask:
        watch_emit(w, .Modified, path)
    }
}

// Whether the error is the cap on watches rather than a directory that went away
// or one that is not ours to read. ENOSPC is max_user_watches, EMFILE the
// instance limit newer kernels report there, ENOMEM the kernel's own.
@(private)
watch_exhausted :: proc(err: linux.Errno) -> bool {
    return err == .ENOSPC || err == .EMFILE || err == .ENOMEM
}

// Watches one directory. False when the directory went away between the walk and
// the call, and when the process is out of watches — that one also sets
// `polling`, which hands the whole tree to the poller.
@(private = "file")
watch_add :: proc(w: ^Watcher, dir: string) -> bool {
    path := strings.clone_to_cstring(dir, w.allocator)
    defer delete(path, w.allocator)

    wd, err := linux.inotify_add_watch(w.platform.fd, path, EVENTS)
    if err != .NONE {
        if watch_exhausted(err) {
            intrinsics.atomic_store(&w.platform.polling, true)
        }
        return false
    }
    // A directory watched twice answers with the descriptor it already has. The
    // descriptor follows the inode, so a directory renamed inside the tree comes
    // back that way under its new path; keep the path, not the entry.
    if known, taken := w.platform.watches[wd]; taken {
        if known == dir {
            return true
        }
        delete(known, w.allocator)
        w.platform.watches[wd] = strings.clone(dir, w.allocator)
        return true
    }
    w.platform.watches[wd] = strings.clone(dir, w.allocator)
    return true
}

// Watches every directory under `dir`. The depth cap is what stops a symbolic
// link that points back at an ancestor from looping forever, as in scan.odin.
@(private = "file")
watch_add_children :: proc(w: ^Watcher, dir: string, depth: int) {
    if depth >= MAX_DEPTH || intrinsics.atomic_load(&w.platform.polling) {
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
        // A dependency tree or git's object store is noise no consumer needs, and
        // watching it is what exhausts the cap. The poller skips them as well.
        if info.type != .Directory || scan_skip_dir(dir, info.name) {
            continue
        }
        if watch_add(w, info.fullpath) {
            watch_add_children(w, info.fullpath, depth + 1)
        } else if intrinsics.atomic_load(&w.platform.polling) {
            return
        }
    }
}
