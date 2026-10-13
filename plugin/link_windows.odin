#+build windows
package plugin

import "core:strings"
import win32 "core:sys/windows"

// The longest path FindFirstFileW takes with no `\\?\` prefix.
@(private = "file")
SHORT_PATH_MAX :: 247

// What `path` is, read from its directory entry so the link is not followed.
// os.lstat does not report a reparse point here, so the tag is read directly.
@(private)
path_link_state :: proc(path: string) -> Link_State {
    // FindFirstFileW would match a pattern against other names.
    if strings.contains_any(path, "*?") {
        return .Unknown
    }
    name := path
    if len(path) > SHORT_PATH_MAX {
        if len(path) < 3 || path[1] != ':' || !is_slash(path[2]) {
            return .Unknown
        }
        back, _ := strings.replace_all(path, "/", `\`, context.temp_allocator)
        name = strings.concatenate({`\\?\`, back}, context.temp_allocator)
    }
    wide := win32.utf8_to_wstring(name, context.temp_allocator)
    if wide == nil {
        return .Unknown
    }

    data: win32.WIN32_FIND_DATAW
    handle := win32.FindFirstFileW(wide, &data)
    if handle == win32.INVALID_HANDLE_VALUE {
        switch win32.GetLastError() {
        case win32.ERROR_FILE_NOT_FOUND, win32.ERROR_PATH_NOT_FOUND:
            return .Missing
        }
        return .Unknown
    }
    win32.FindClose(handle)

    if data.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT == 0 {
        return .Plain
    }
    switch data.dwReserved0 {
    case win32.IO_REPARSE_TAG_SYMLINK, win32.IO_REPARSE_TAG_MOUNT_POINT:
        return .Link
    }
    return .Plain
}

@(private = "file")
is_slash :: proc(ch: byte) -> bool {
    return ch == '/' || ch == '\\'
}
