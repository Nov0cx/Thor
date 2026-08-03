#+build windows
package thor

import win32 "core:sys/windows"

// A whole file mapped read-only. A load worker opens one and the main thread
// closes it once the bytes are in the piece table, so the read costs no heap.
File_Map :: struct {
    view:    rawptr,
    mapping: win32.HANDLE,
    handle:  win32.HANDLE,
}

// Maps `path` and hands back its bytes. An empty file maps to an empty slice
// and still succeeds. The slice is valid until file_map_close.
file_map_open :: proc(m: ^File_Map, path: string) -> ([]u8, bool) {
    m.handle = win32.INVALID_HANDLE_VALUE

    wide_path := win32.utf8_to_wstring(path, context.temp_allocator)
    m.handle = win32.CreateFileW(
        wide_path,
        win32.GENERIC_READ,
        win32.FILE_SHARE_READ,
        nil,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL,
        nil,
    )
    if m.handle == win32.INVALID_HANDLE_VALUE {
        return nil, false
    }

    size: win32.LARGE_INTEGER
    if !win32.GetFileSizeEx(m.handle, &size) {
        return nil, false
    }
    // A zero-length mapping is an error on Windows, so an empty file stops here.
    if size == 0 {
        return nil, true
    }

    m.mapping = win32.CreateFileMappingW(m.handle, nil, win32.PAGE_READONLY, 0, 0, nil)
    if m.mapping == nil {
        return nil, false
    }
    m.view = win32.MapViewOfFile(m.mapping, win32.FILE_MAP_READ, 0, 0, 0)
    if m.view == nil {
        return nil, false
    }
    return (cast([^]u8) m.view)[:size], true
}

// Releases the mapping. Safe on a map that never opened, and on one opened twice.
file_map_close :: proc(m: ^File_Map) {
    if m.view != nil {
        win32.UnmapViewOfFile(m.view)
        m.view = nil
    }
    if m.mapping != nil {
        win32.CloseHandle(m.mapping)
        m.mapping = nil
    }
    if m.handle != win32.INVALID_HANDLE_VALUE && m.handle != nil {
        win32.CloseHandle(m.handle)
        m.handle = win32.INVALID_HANDLE_VALUE
    }
}
