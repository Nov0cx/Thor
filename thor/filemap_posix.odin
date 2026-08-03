#+build !windows
package thor

import "core:c"
import "core:strings"
import "core:sys/posix"

// A whole file mapped read-only. A load worker opens one and the main thread
// closes it once the bytes are in the piece table, so the read costs no heap.
File_Map :: struct {
    data: []u8, // the mapping, page-aligned; empty when the file was
}

// Maps `path` and hands back its bytes. An empty file maps to an empty slice
// and still succeeds. The slice is valid until file_map_close.
file_map_open :: proc(m: ^File_Map, path: string) -> ([]u8, bool) {
    path_c := strings.clone_to_cstring(path, context.temp_allocator)

    // Read-only is the empty flag set: O_RDONLY is zero.
    fd := posix.open(path_c, {})
    if fd < 0 {
        return nil, false
    }
    // The mapping keeps the file alive on its own, so the descriptor can go.
    defer posix.close(fd)

    info: posix.stat_t
    if posix.fstat(fd, &info) != .OK {
        return nil, false
    }
    // A zero-length mapping is an error; a directory or a device fails at mmap.
    if info.st_size <= 0 {
        return nil, true
    }

    size := cast(int) info.st_size
    address := posix.mmap(nil, c.size_t(size), {.READ}, {.PRIVATE}, fd, 0)
    if address == posix.MAP_FAILED {
        return nil, false
    }

    m.data = (cast([^]u8) address)[:size]
    return m.data, true
}

// Releases the mapping. Safe on a map that never opened, and on one opened twice.
file_map_close :: proc(m: ^File_Map) {
    if len(m.data) > 0 {
        posix.munmap(raw_data(m.data), c.size_t(len(m.data)))
    }
    m.data = nil
}
