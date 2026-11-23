#+build darwin, freebsd, openbsd, netbsd
package watch

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/kqueue"
import "core:sys/posix"

// kqueue watcher: one descriptor per directory and per file of the tree. A
// directory event says only that its entries changed, so that one directory is
// listed again and compared with the names it had. A tree over the descriptor
// budget, or a kqueue that does not start, hands the whole tree to the polling
// worker (poll.odin).
Platform :: struct {
    kq:       kqueue.KQ,
    nodes:    map[posix.FD]Kq_Node, // owned
    fds:      map[string]posix.FD,  // keys borrow Kq_Node.path
    limit:    int,                  // descriptors this watcher may hold
    stopping: bool,
    polling:  bool, // kqueue is gone, so the poller runs instead
    open:     bool, // `kq` is a live descriptor
}

// One watched path.
@(private)
Kq_Node :: struct {
    path:     string, // owned
    is_dir:   bool,
    children: map[string]bool, // owned keys; directory only: entry name -> is a directory
}

// The vnode events worth a report.
@(private = "file")
VNODE_EVENTS :: kqueue.VNode_Flags{.Delete, .Write, .Extend, .Rename, .Revoke}

// How long one wait for events lasts before the worker reads `stopping`.
@(private = "file")
WAIT_NSEC :: 100_000_000

// Events are read in batches.
@(private = "file")
EVENT_BATCH :: 64

// The smallest and the largest descriptor budget, whatever RLIMIT_NOFILE says.
@(private = "file")
LIMIT_MIN :: 64
@(private = "file")
LIMIT_MAX :: 1 << 16

// O_EVTONLY on macOS: a descriptor for events only, which does not keep a volume busy.
@(private = "file")
open_flags :: proc() -> posix.O_Flags {
    flags := posix.O_Flags{.CLOEXEC}
    when ODIN_OS == .Darwin {
        flags += transmute(posix.O_Flags)i32(0x8000)
    }
    return flags
}

@(private)
watch_start :: proc(w: ^Watcher) -> bool {
    if !os.is_dir(w.root) {
        log.warnf("watch: %q is not a folder", w.root)
        return false
    }
    // The caller owns the temp allocations made before this call.
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    w.platform.stopping = false
    w.platform.polling = false

    kq, err := kqueue.kqueue()
    if err != .NONE {
        log.warnf("watch: kqueue did not start (%v); polling %q", err, w.root)
        w.platform.polling = true
        return true
    }
    w.platform.kq = kq
    w.platform.open = true
    w.platform.nodes = make(map[posix.FD]Kq_Node, w.allocator)
    w.platform.fds = make(map[string]posix.FD, w.allocator)
    w.platform.limit = descriptor_limit()

    // A tree watched only in part loses changes without a sign, so the poller takes all of it.
    if !kq_add_tree(w, w.root, 0) || w.platform.polling || len(w.platform.nodes) == 0 {
        w.platform.polling = true
        kq_close(w)
    }
    return true
}

@(private)
watch_stop :: proc(w: ^Watcher) {
    intrinsics.atomic_store(&w.platform.stopping, true)
}

@(private)
watch_release :: proc(w: ^Watcher) {
    kq_close(w)
}

@(private)
watch_worker :: proc(w: ^Watcher) {
    context.allocator = w.allocator
    if !w.platform.open {
        poll_worker(w, &w.platform.stopping)
        return
    }

    events: [EVENT_BATCH]kqueue.KEvent
    timeout := posix.timespec{tv_nsec = WAIT_NSEC}
    for !intrinsics.atomic_load(&w.platform.stopping) {
        if w.platform.polling {
            kq_degrade(w)
            return
        }
        n, err := kqueue.kevent(w.platform.kq, nil, events[:], &timeout)
        if err != .NONE {
            if err != .EINTR {
                log.warnf("watch: waiting on kqueue failed (%v); polling %q", err, w.root)
                w.platform.polling = true
            }
            continue
        }
        for event in events[:n] {
            kq_event(w, posix.FD(event.ident), event.fflags.vnode)
        }
        free_all(context.temp_allocator)
    }
}

// Half the soft descriptor limit, so the rest of the process keeps its files.
@(private = "file")
descriptor_limit :: proc() -> int {
    limit: posix.rlimit
    if posix.getrlimit(.NOFILE, &limit) != .OK {
        return LIMIT_MIN
    }
    if limit.rlim_cur >= posix.rlim_t(LIMIT_MAX * 2) {
        return LIMIT_MAX
    }
    return max(int(limit.rlim_cur) / 2, LIMIT_MIN)
}

// Closes every descriptor and frees the nodes. Safe twice and on a watcher that never opened kqueue.
@(private = "file")
kq_close :: proc(w: ^Watcher) {
    for fd, &node in w.platform.nodes {
        posix.close(fd)
        node_free(w, &node)
    }
    delete(w.platform.nodes)
    delete(w.platform.fds)
    w.platform.nodes = nil
    w.platform.fds = nil
    if w.platform.open {
        posix.close(w.platform.kq)
        w.platform.open = false
    }
}

@(private = "file")
node_free :: proc(w: ^Watcher, node: ^Kq_Node) {
    for name in node.children {
        delete(name, w.allocator)
    }
    delete(node.children)
    delete(node.path, w.allocator)
}

// Drops kqueue and finishes the session on the poller, with the root change as the "events were lost" hint.
@(private = "file")
kq_degrade :: proc(w: ^Watcher) {
    kq_close(w)
    if intrinsics.atomic_load(&w.platform.stopping) {
        return
    }
    watch_emit(w, .Modified, w.root)
    poll_worker(w, &w.platform.stopping)
}

// Watches one path. False when it went away or could not be opened; at the
// descriptor budget it also sets `polling`.
@(private = "file")
kq_add :: proc(w: ^Watcher, path: string, is_dir: bool) -> bool {
    if _, known := w.platform.fds[path]; known {
        return true
    }
    if len(w.platform.nodes) >= w.platform.limit {
        log.warnf("watch: %d descriptors in use at %q; polling %q", w.platform.limit, path, w.root)
        w.platform.polling = true
        return false
    }
    cpath := strings.clone_to_cstring(path, context.temp_allocator)
    fd    := posix.open(cpath, open_flags())
    if fd < 0 {
        if errno := posix.errno(); errno == .EMFILE || errno == .ENFILE {
            log.warnf("watch: out of descriptors at %q (%v); polling %q", path, errno, w.root)
            w.platform.polling = true
        }
        return false
    }
    change := kqueue.KEvent{ident = uintptr(fd), filter = .VNode, flags = {.Add, .Clear}}
    change.fflags.vnode = VNODE_EVENTS
    if _, err := kqueue.kevent(w.platform.kq, {change}, nil, nil); err != .NONE {
        posix.close(fd)
        return false
    }
    node := Kq_Node{path = strings.clone(path, w.allocator), is_dir = is_dir}
    if is_dir {
        node.children = make(map[string]bool, w.allocator)
    }
    w.platform.nodes[fd] = node
    w.platform.fds[node.path] = fd
    return true
}

// Watches a directory, its entries and every directory below it. False when the budget ran out.
@(private = "file")
kq_add_tree :: proc(w: ^Watcher, dir: string, depth: int) -> bool {
    if !kq_add(w, dir, true) {
        return !w.platform.polling
    }
    if depth >= MAX_DEPTH {
        return true
    }
    infos, err := os.read_all_directory_by_path(dir, w.allocator)
    if err != nil {
        return true
    }
    defer os.file_info_slice_delete(infos, w.allocator)

    fd := w.platform.fds[dir]
    for info in infos {
        is_dir := info.type == .Directory
        // The recursion grows the map, so the node is looked up again each time.
        node   := &w.platform.nodes[fd]
        node.children[strings.clone(info.name, w.allocator)] = is_dir
        ok := true
        if is_dir {
            if !scan_skip_dir(dir, info.name) {
                ok = kq_add_tree(w, info.fullpath, depth + 1)
            }
        } else {
            ok = kq_add(w, info.fullpath, false) || !w.platform.polling
        }
        if !ok {
            return false
        }
    }
    return true
}

// Stops watching a path and everything below it.
@(private = "file")
kq_remove_tree :: proc(w: ^Watcher, path: string) {
    prefix := strings.concatenate({path, "/"}, context.temp_allocator)
    gone   := make([dynamic]posix.FD, context.temp_allocator)
    for key, fd in w.platform.fds {
        if key == path || strings.has_prefix(key, prefix) {
            append(&gone, fd)
        }
    }
    for fd in gone {
        node := w.platform.nodes[fd]
        delete_key(&w.platform.fds, node.path)
        delete_key(&w.platform.nodes, fd)
        posix.close(fd)
        node_free(w, &node)
    }
}

@(private = "file")
kq_event :: proc(w: ^Watcher, fd: posix.FD, flags: kqueue.VNode_Flags) {
    node, known := w.platform.nodes[fd]
    if !known {
        return
    }
    if .Delete in flags || .Rename in flags || .Revoke in flags {
        // Below the root the parent's listing reports it.
        if node.path == w.root {
            watch_emit(w, .Deleted, w.root)
        }
        kq_remove_tree(w, node.path)
        return
    }
    if !node.is_dir {
        watch_emit(w, .Modified, node.path)
        return
    }
    if .Write in flags {
        kq_relist(w, fd)
    }
}

// Lists a directory again and reports what came and went since the last listing.
@(private = "file")
kq_relist :: proc(w: ^Watcher, fd: posix.FD) {
    dir        := w.platform.nodes[fd].path
    infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
    if err != nil {
        return
    }
    now := make(map[string]bool, len(infos), context.temp_allocator)
    for info in infos {
        now[info.name] = info.type == .Directory
    }

    gone := make([dynamic]string, context.temp_allocator)
    for name, was_dir in w.platform.nodes[fd].children {
        if is_dir, still := now[name]; !still || is_dir != was_dir {
            append(&gone, name)
        }
    }
    for name in gone {
        path := strings.concatenate({dir, "/", name}, context.temp_allocator)
        watch_emit(w, .Deleted, path)
        kq_remove_tree(w, path)
        node   := &w.platform.nodes[fd]
        key, _ := delete_key(&node.children, name)
        delete(key, w.allocator)
    }

    for info in infos {
        node := &w.platform.nodes[fd]
        if _, had := node.children[info.name]; had {
            continue
        }
        is_dir := info.type == .Directory
        node.children[strings.clone(info.name, w.allocator)] = is_dir
        watch_emit(w, .Created, info.fullpath)
        if is_dir {
            if !scan_skip_dir(dir, info.name) {
                kq_add_tree(w, info.fullpath, 0)
            }
        } else {
            kq_add(w, info.fullpath, false)
        }
        if w.platform.polling {
            return
        }
    }
}
