#+build !windows
package thor

// POSIX half of the multi-window records. X11 and Wayland give no portable way
// to raise another process's window, so a record only proves the process: the
// folder counts as taken, but the other window is not brought to the front.

import "core:sys/posix"

// Always nil: no window handle crosses a process boundary here.
Window_Handle :: rawptr

// Nothing worth recording; raylib's window pointer is process-local.
thor_native_window :: proc() -> i64 {
    return 0
}

// Whether the recorded process still runs. Signal 0 asks without delivering
// anything, and EPERM means it runs under another user. A recycled pid reads as
// live and keeps the folder held.
thor_window_live :: proc(hwnd: i64, pid: int) -> (Window_Handle, Window_State) {
    if pid <= 0 {
        return nil, .Gone
    }
    if posix.kill(posix.pid_t(pid), .NONE) == .OK {
        return nil, .Live
    }
    if posix.errno() == .EPERM {
        return nil, .Live
    }
    return nil, .Gone
}

// Raising is not ours to do; the desktop decides what comes forward.
thor_focus_window :: proc(hwnd: Window_Handle) {
}
