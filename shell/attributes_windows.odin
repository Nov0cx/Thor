#+build windows
package shell

import win32 "core:sys/windows"

@(private)
PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: win32.DWORD_PTR(0x00020002)

// STARTUPINFOW with the attribute list behind it. The first field is the plain
// record, so a pointer to this is what CreateProcessW takes.
@(private)
STARTUPINFOEXW :: struct {
    StartupInfo:     win32.STARTUPINFOW,
    lpAttributeList: rawptr,
}

foreign import kernel32 "system:Kernel32.lib"

@(private)
@(default_calling_convention = "system")
foreign kernel32 {
    InitializeProcThreadAttributeList :: proc(lpAttributeList: rawptr, dwAttributeCount, dwFlags: win32.DWORD, lpSize: ^win32.SIZE_T) -> win32.BOOL ---
    UpdateProcThreadAttribute :: proc(lpAttributeList: rawptr, dwFlags: win32.DWORD, Attribute: win32.DWORD_PTR, lpValue: rawptr, cbSize: win32.SIZE_T, lpPreviousValue: rawptr, lpReturnSize: ^win32.SIZE_T) -> win32.BOOL ---
    DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
}

// A proc-thread attribute list with room for one attribute. Its size is asked
// for first, which is why the first call is expected to fail.
@(private)
attribute_list_make :: proc() -> ([]u8, bool) {
    size: win32.SIZE_T
    InitializeProcThreadAttributeList(nil, 1, 0, &size)
    if size == 0 {
        return nil, false
    }
    buffer := make([]u8, int(size))
    if !InitializeProcThreadAttributeList(raw_data(buffer), 1, 0, &size) {
        delete(buffer)
        return nil, false
    }
    return buffer, true
}

// Sets `attribute` to `value`. `value` must stay valid until the process starts.
@(private)
attribute_list_set :: proc(list: []u8, attribute: win32.DWORD_PTR, value: rawptr, size: int) -> bool {
    return bool(UpdateProcThreadAttribute(raw_data(list), 0, attribute, value, win32.SIZE_T(size), nil, nil))
}

@(private)
attribute_list_free :: proc(list: []u8) {
    if list != nil {
        DeleteProcThreadAttributeList(raw_data(list))
        delete(list)
    }
}

// Marks `handles` inheritable and builds the list that limits inheritance to
// them, so a start on another thread inherits none of them. `handles` holds no
// duplicate and must stay valid until the process starts.
@(private)
inherit_only :: proc(handles: []win32.HANDLE) -> ([]u8, bool) {
    for h in handles {
        if !win32.SetHandleInformation(h, win32.HANDLE_FLAG_INHERIT, win32.HANDLE_FLAG_INHERIT) {
            return nil, false
        }
    }
    list, ok := attribute_list_make()
    if !ok {
        return nil, false
    }
    if !attribute_list_set(list, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, raw_data(handles), len(handles) * size_of(win32.HANDLE)) {
        attribute_list_free(list)
        return nil, false
    }
    return list, true
}
