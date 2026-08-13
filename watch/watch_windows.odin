#+build windows
package watch

import "core:strings"
import win32 "core:sys/windows"

// Windows watcher: one overlapped ReadDirectoryChangesW over the whole tree, so
// the OS reports the changes and the worker only translates them.
Platform :: struct {
    dir_handle: win32.HANDLE,
    stop_event: win32.HANDLE, // signalled to break the worker's wait on shutdown
}

// Change buffer handed to ReadDirectoryChangesW. 64 KiB holds a large burst of
// entries; on overflow the OS reports zero bytes and we emit one root change so
// consumers fall back to a full rescan.
@(private)
BUFFER_SIZE :: 64 * 1024

@(private)
NOTIFY_FILTER :: win32.FILE_NOTIFY_CHANGE_FILE_NAME |
    win32.FILE_NOTIFY_CHANGE_DIR_NAME |
    win32.FILE_NOTIFY_CHANGE_LAST_WRITE |
    win32.FILE_NOTIFY_CHANGE_SIZE |
    win32.FILE_NOTIFY_CHANGE_CREATION

@(private)
watch_start :: proc(w: ^Watcher) -> bool {
    wide := win32.utf8_to_wstring(w.root, context.temp_allocator)
    w.platform.dir_handle = win32.CreateFileW(
        wide,
        win32.FILE_LIST_DIRECTORY,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        nil,
        win32.OPEN_EXISTING,
        win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED,
        nil,
    )
    if w.platform.dir_handle == win32.INVALID_HANDLE_VALUE {
        return false
    }

    // Manual-reset, initially unsignalled: SetEvent on shutdown wakes the worker's
    // wait and it stays woken so the wait can't miss it.
    w.platform.stop_event = win32.CreateEventW(nil, true, false, nil)
    if w.platform.stop_event == nil {
        win32.CloseHandle(w.platform.dir_handle)
        w.platform.dir_handle = win32.INVALID_HANDLE_VALUE
        return false
    }
    return true
}

@(private)
watch_stop :: proc(w: ^Watcher) {
    win32.SetEvent(w.platform.stop_event)
}

@(private)
watch_release :: proc(w: ^Watcher) {
    if w.platform.stop_event != nil {
        win32.CloseHandle(w.platform.stop_event)
        w.platform.stop_event = nil
    }
    if w.platform.dir_handle != win32.INVALID_HANDLE_VALUE && w.platform.dir_handle != nil {
        win32.CloseHandle(w.platform.dir_handle)
        w.platform.dir_handle = win32.INVALID_HANDLE_VALUE
    }
}

@(private)
watch_worker :: proc(w: ^Watcher) {
    context.allocator = w.allocator

    buffer := make([]u8, BUFFER_SIZE, w.allocator)
    defer delete(buffer, w.allocator)

    overlapped: win32.OVERLAPPED
    overlapped.hEvent = win32.CreateEventW(nil, true, false, nil)
    if overlapped.hEvent == nil {
        return
    }
    defer win32.CloseHandle(overlapped.hEvent)

    for {
        win32.ResetEvent(overlapped.hEvent)
        bytes: win32.DWORD
        ok := win32.ReadDirectoryChangesW(
            w.platform.dir_handle,
            raw_data(buffer),
            u32(len(buffer)),
            true, // recursive
            NOTIFY_FILTER,
            &bytes,
            &overlapped,
            nil,
        )
        if !ok {
            break
        }

        // Block until either the read completes or shutdown signals stop_event.
        handles := [2]win32.HANDLE {overlapped.hEvent, w.platform.stop_event}
        signalled := win32.WaitForMultipleObjects(2, &handles[0], false, win32.INFINITE)
        if signalled != win32.WAIT_OBJECT_0 {
            // stop_event (index 1) or a wait failure: cancel the pending read, then
            // block for its completion so the kernel is done writing into `buffer`
            // and `overlapped` before this frame frees them.
            win32.CancelIo(w.platform.dir_handle)
            transferred: win32.DWORD
            win32.GetOverlappedResult(w.platform.dir_handle, &overlapped, &transferred, true)
            break
        }

        transferred: win32.DWORD
        if !win32.GetOverlappedResult(w.platform.dir_handle, &overlapped, &transferred, false) {
            break
        }
        if transferred == 0 {
            // Too many changes to report individually; the entries were dropped.
            // Emit one change on the root so subscribers do a full rescan.
            watch_emit(w, .Modified, w.root)
            continue
        }

        watch_parse(w, buffer[:transferred])
        free_all(context.temp_allocator)
    }
}

// Walks the FILE_NOTIFY_INFORMATION chain, turning each entry into a Change with
// an absolute native path and queuing it for the main thread.
@(private)
watch_parse :: proc(w: ^Watcher, data: []u8) {
    offset := 0
    for offset < len(data) {
        info := cast(^win32.FILE_NOTIFY_INFORMATION) raw_data(data[offset:])

        // file_name is a WCHAR run of file_name_length bytes, reported relative to
        // the watched root and already using backslash separators.
        name_wchars := int(info.file_name_length) / size_of(win32.WCHAR)
        name_ptr := cast([^]u16) &info.file_name
        rel, conv_err := win32.utf16_to_utf8(name_ptr[:name_wchars], context.temp_allocator)
        if conv_err == nil && rel != "" {
            path := strings.concatenate({w.root, "\\", rel}, context.temp_allocator)
            kind: Change_Kind
            switch info.action {
            case win32.FILE_ACTION_ADDED, win32.FILE_ACTION_RENAMED_NEW_NAME:
                kind = .Created
            case win32.FILE_ACTION_REMOVED, win32.FILE_ACTION_RENAMED_OLD_NAME:
                kind = .Deleted
            case:
                kind = .Modified
            }
            watch_emit(w, kind, path)
        }

        if info.next_entry_offset == 0 {
            break
        }
        offset += int(info.next_entry_offset)
    }
}
