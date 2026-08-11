#+build windows
package odin

import win32 "core:sys/windows"
import "base:runtime"
import "core:strings"

// Resolves `path` to the spelling Windows itself considers canonical: opening
// the handle already follows symlinks and reparse points and dereferences an
// 8.3 short name to the real one, so GetFinalPathNameByHandleW's answer settles
// both mismatches index_package_dir can hit. False on any open/query failure
// (missing path, access denied) — callers keep their existing fallback then.
// FILE_FLAG_BACKUP_SEMANTICS is what lets a directory open, not just a file.
path_real :: proc(path: string, allocator: runtime.Allocator) -> (string, bool) {
    wide_path := win32.utf8_to_wstring(path, context.temp_allocator)
    handle := win32.CreateFileW(
        wide_path,
        0,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        nil,
        win32.OPEN_EXISTING,
        win32.FILE_FLAG_BACKUP_SEMANTICS,
        nil,
    )
    if handle == win32.INVALID_HANDLE_VALUE {
        return "", false
    }
    defer win32.CloseHandle(handle)

    buf := make([]u16, win32.MAX_PATH_WIDE, context.temp_allocator)
    n := win32.GetFinalPathNameByHandleW(handle, win32.wstring(raw_data(buf)), win32.DWORD(len(buf)), 0)
    if n == 0 || int(n) >= len(buf) {
        return "", false
    }

    resolved, err := win32.wstring_to_utf8(win32.wstring(raw_data(buf)), int(n), context.temp_allocator)
    if err != nil {
        return "", false
    }
    // Strip the extended-length prefix GetFinalPathNameByHandleW always adds:
    // `\\?\UNC\server\share\...` becomes `\\server\share\...`, `\\?\C:\...`
    // becomes `C:\...`.
    if strings.has_prefix(resolved, `\\?\UNC\`) {
        return strings.concatenate({`\\`, resolved[len(`\\?\UNC\`):]}, allocator), true
    }
    if strings.has_prefix(resolved, `\\?\`) {
        return strings.clone(resolved[len(`\\?\`):], allocator), true
    }
    return strings.clone(resolved, allocator), true
}

// The volume's 8.3 alias for `path`, if it has one. path_test.odin uses this to
// prove path_real resolves the alias back to the canonical spelling; equal to
// `path` when short-name generation is off on that volume.
@(private)
path_short_form :: proc(path: string, allocator: runtime.Allocator) -> (string, bool) {
    wide_path := win32.utf8_to_wstring(path, context.temp_allocator)
    buf := make([]u16, win32.MAX_PATH_WIDE, context.temp_allocator)
    n := win32.GetShortPathNameW(wide_path, win32.wstring(raw_data(buf)), win32.DWORD(len(buf)))
    if n == 0 || int(n) >= len(buf) {
        return "", false
    }
    short, err := win32.wstring_to_utf8(win32.wstring(raw_data(buf)), int(n), allocator)
    return short, err == nil
}
