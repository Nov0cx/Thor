#+build !windows
package thor

// POSIX half of the multi-window records. No window identity crosses a process
// boundary here — raylib's window pointer is process-local and neither X11 nor
// Wayland is reachable without a binding — so a record proves the process and a
// raise goes through whatever desktop helper the machine has.

import "core:fmt"
import "core:log"
import "core:sys/posix"
import "core:time"

import "../shell"

// How long a raise helper may run. It only talks to the window manager, so it
// answers at once or not at all, and the frame must not wait on it either way.
@(private = "file")
RAISE_TIMEOUT :: 500 * time.Millisecond

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

// Brings the window of `ref.pid` to the front through a desktop helper, and
// reports whether it went. False is an ordinary answer, not a fault: Wayland
// ignores xdotool, the helpers are optional packages, and the macOS path needs
// the Accessibility permission. The caller says so rather than claiming a raise.
thor_focus_window :: proc(ref: Window_Ref) -> bool {
    if ref.pid <= 0 {
        return false
    }
    command, ok := thor_raise_command(ref.pid)
    if !ok {
        return false
    }
    output, code, ran := shell.run_status(command, ".", RAISE_TIMEOUT)
    defer delete(output)
    if !ran || code != 0 {
        log.debugf("Could not raise the window of process %d: %s", ref.pid, output)
        return false
    }
    return true
}

// The helper that raises a window by its process id, when the machine has one.
@(private = "file")
thor_raise_command :: proc(pid: int) -> (string, bool) {
    when ODIN_OS == .Darwin {
        // System Events addresses a process by its unix id, which is the only
        // identity the record carries.
        return fmt.tprintf(
            `osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is %d) to true'`,
            pid,
        ), true
    } else {
        // xdotool activates the match itself; wmctrl needs the window id looked
        // up in its own listing first, and an empty id must fail rather than
        // report a raise that never happened.
        if _, found := shell.which("xdotool", context.temp_allocator); found {
            return fmt.tprintf("xdotool search --onlyvisible --pid %d windowactivate %%1", pid), true
        }
        if _, found := shell.which("wmctrl", context.temp_allocator); found {
            return fmt.tprintf(
                `id=$(wmctrl -lp | awk '$3=="%d" {print $1; exit}'); [ -n "$id" ] && wmctrl -ia "$id"`,
                pid,
            ), true
        }
        return "", false
    }
}
