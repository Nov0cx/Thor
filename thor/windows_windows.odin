#+build windows
package thor

// Windows half of the multi-window records. A record carries the HWND, so the
// window is proved live from the handle and raised with user32.

import "core:log"
import win32 "core:sys/windows"
import rl "vendor:raylib"

Window_Handle :: win32.HWND

// user32.lib cannot be linked (its CloseWindow/ShowCursor collide with
// raylib's), so the handful of window calls used here are resolved at runtime —
// the same trick as thor/dialogs_windows.odin and ui/keymap_windows.odin.
@(private = "file")
Is_Window_Proc :: #type proc "system" (hwnd: win32.HWND) -> win32.BOOL
@(private = "file")
Is_Iconic_Proc :: #type proc "system" (hwnd: win32.HWND) -> win32.BOOL
@(private = "file")
Show_Window_Proc :: #type proc "system" (hwnd: win32.HWND, cmd: win32.c_int) -> win32.BOOL
@(private = "file")
Set_Foreground_Proc :: #type proc "system" (hwnd: win32.HWND) -> win32.BOOL
@(private = "file")
Window_Pid_Proc :: #type proc "system" (hwnd: win32.HWND, pid: ^win32.DWORD) -> win32.DWORD

@(private = "file")
User32 :: struct {
    is_window:      Is_Window_Proc,
    is_iconic:      Is_Iconic_Proc,
    show_window:    Show_Window_Proc,
    set_foreground: Set_Foreground_Proc,
    window_pid:     Window_Pid_Proc,
}

@(private = "file")
user32: User32

@(private = "file")
user32_resolved := false

foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
    LoadLibraryA   :: proc(name: cstring) -> rawptr ---
    GetProcAddress :: proc(module: rawptr, name: cstring) -> rawptr ---
}

// Resolves the user32 entry points once. Every caller must tolerate a nil proc:
// without them a folder simply opens in a new window instead of raising the old.
@(private = "file")
thor_load_user32 :: proc() -> ^User32 {
    if user32_resolved {
        return &user32
    }
    user32_resolved = true

    lib := LoadLibraryA("user32.dll")
    if lib == nil {
        log.warn("Could not load user32.dll; existing windows cannot be raised")
        return &user32
    }
    user32.is_window = cast(Is_Window_Proc) GetProcAddress(lib, "IsWindow")
    user32.is_iconic = cast(Is_Iconic_Proc) GetProcAddress(lib, "IsIconic")
    user32.show_window = cast(Show_Window_Proc) GetProcAddress(lib, "ShowWindow")
    user32.set_foreground = cast(Set_Foreground_Proc) GetProcAddress(lib, "SetForegroundWindow")
    user32.window_pid = cast(Window_Pid_Proc) GetProcAddress(lib, "GetWindowThreadProcessId")
    return &user32
}

@(private = "file")
SW_RESTORE :: 9

// This window's handle, widened for the record.
thor_native_window :: proc() -> i64 {
    return cast(i64) cast(uintptr) rl.GetWindowHandle()
}

// A record is live while its handle names a window the recorded process still
// owns; a recycled handle describes a dead window.
thor_window_live :: proc(hwnd: i64, pid: int) -> (Window_Handle, Window_State) {
    u32 := thor_load_user32()
    if u32.is_window == nil || u32.window_pid == nil {
        return nil, .Unknown
    }

    handle := cast(win32.HWND) cast(uintptr) cast(uint) hwnd
    if hwnd != 0 && u32.is_window(handle) {
        owner: win32.DWORD
        u32.window_pid(handle, &owner)
        if cast(int) owner == pid {
            return handle, .Live
        }
    }
    return nil, .Gone
}

// Brings an existing window to the front. A minimized window is restored first —
// an unconditional restore would un-maximize one that is merely behind. The
// foreground handover is allowed because the calling window currently holds it.
thor_focus_window :: proc(hwnd: Window_Handle) {
    u32 := thor_load_user32()
    if u32.is_iconic != nil && u32.show_window != nil && u32.is_iconic(hwnd) {
        u32.show_window(hwnd, SW_RESTORE)
    }
    if u32.set_foreground != nil {
        u32.set_foreground(hwnd)
    }
}
