package watch

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// One snapshot of a directory tree, and the difference between two of them. The
// polling watcher takes a snapshot on an interval and reports what moved; the
// logic lives here, apart from the platform, so it can be tested on its own.

// How deep the walk goes. A cap is what stops a symbolic link that points back
// at an ancestor from looping forever.
@(private)
MAX_DEPTH :: 32

// One file or directory. `path` is only set once the whole tree is walked,
// because it borrows the snapshot's path buffer and that buffer moves while it
// grows.
@(private)
Scan_Entry :: struct {
    path:     string,
    end:      int, // where this path stops in the buffer; paths are stored in walk order
    modified: i64,
    size:     i64,
    is_dir:   bool,
}

// A whole tree, sorted by path so that two snapshots compare in one walk.
@(private)
Scan :: struct {
    paths:   strings.Builder, // every path, back to back
    entries: [dynamic]Scan_Entry,
}

// Walks `root` and records every file and directory under it, along with the
// write time and the size a later scan compares against.
@(private)
scan_tree :: proc(s: ^Scan, root: string, allocator: runtime.Allocator) {
    scan_reset(s, allocator)
    scan_directory(s, root, 0, allocator)
    scan_finish(s)
}

// Prepares `s` for a fresh walk: fresh buffers the first time (a zero Scan),
// else the existing ones are cleared and reused. The poll worker ping-pongs
// two Scans across passes instead of destroying and remaking one every
// interval, so steady state allocates nothing.
@(private)
scan_reset :: proc(s: ^Scan, allocator: runtime.Allocator) {
    if s.entries == nil {
        s.paths = strings.builder_make(allocator)
        s.entries = make([dynamic]Scan_Entry, allocator)
        return
    }
    strings.builder_reset(&s.paths)
    clear(&s.entries)
}

@(private)
scan_destroy :: proc(s: ^Scan) {
    strings.builder_destroy(&s.paths)
    delete(s.entries)
    s^ = {}
}

// True for a directory whose contents are noise no consumer needs watched:
// a package manager's dependency tree, or git's own object store. The
// directory itself is still recorded as an entry (its own create/delete still
// reports), only what is inside it goes unwalked.
@(private)
scan_skip_dir :: proc(parent, name: string) -> bool {
    if name == "node_modules" {
        return true
    }
    if (name == "objects" || name == "lfs") && filepath.base(parent) == ".git" {
        return true
    }
    return false
}

// Reads one directory and recurses into its subdirectories. A directory that
// cannot be read (removed while the walk runs, or not ours to read) counts as
// empty: the next scan reports whatever it finds there then.
@(private)
scan_directory :: proc(s: ^Scan, dir: string, depth: int, allocator: runtime.Allocator) {
    if depth >= MAX_DEPTH {
        return
    }
    infos, err := os.read_all_directory_by_path(dir, allocator)
    if err != nil {
        return
    }
    // The entries stay alive over the recursion, so the peak cost is one
    // directory listing per level, not one for the whole tree.
    defer os.file_info_slice_delete(infos, allocator)

    for info in infos {
        is_dir := info.type == .Directory
        scan_add(s, info.fullpath, info.modification_time._nsec, info.size, is_dir)
        if is_dir && !scan_skip_dir(dir, info.name) {
            scan_directory(s, info.fullpath, depth + 1, allocator)
        }
    }
}

@(private)
scan_add :: proc(s: ^Scan, path: string, modified: i64, size: i64, is_dir: bool) {
    strings.write_string(&s.paths, path)
    append(
        &s.entries,
        Scan_Entry {
            end = strings.builder_len(s.paths),
            modified = modified,
            size = size,
            is_dir = is_dir,
        },
    )
}

// Hands every entry its path and sorts the snapshot. Call once, after the walk.
@(private)
scan_finish :: proc(s: ^Scan) {
    buffer := strings.to_string(s.paths)
    start := 0
    for &entry in s.entries {
        entry.path = buffer[start:entry.end]
        start = entry.end
    }
    slice.sort_by(s.entries[:], proc(a, b: Scan_Entry) -> bool {
        return a.path < b.path
    })
}

// Reports every difference between two finished snapshots. The paths of the
// result borrow from `old` and `new`, so it only lives as long as they do.
//
// A directory reports Created and Deleted but never Modified: its write time
// moves whenever a child appears or goes, which is already one change of its own.
@(private)
scan_diff :: proc(old, new: Scan, allocator := context.temp_allocator) -> []Change {
    changes := make([dynamic]Change, allocator)
    i, j := 0, 0
    for i < len(old.entries) && j < len(new.entries) {
        before, after := old.entries[i], new.entries[j]
        switch {
        case before.path < after.path:
            append(&changes, Change {kind = .Deleted, path = before.path})
            i += 1
        case after.path < before.path:
            append(&changes, Change {kind = .Created, path = after.path})
            j += 1
        case:
            if !after.is_dir && (before.size != after.size || before.modified != after.modified) {
                append(&changes, Change {kind = .Modified, path = after.path})
            }
            i += 1
            j += 1
        }
    }
    for ; i < len(old.entries); i += 1 {
        append(&changes, Change {kind = .Deleted, path = old.entries[i].path})
    }
    for ; j < len(new.entries); j += 1 {
        append(&changes, Change {kind = .Created, path = new.entries[j].path})
    }
    return changes[:]
}
