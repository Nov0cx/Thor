#+build !windows
package thor

// POSIX half of the DirectInput block around window creation: there is nothing
// to block. GLFW reads the joysticks from /dev/input, or from IOKit on macOS,
// and neither costs measurable time (see thor/dinput_windows.odin).

dinput_suppress :: proc() -> bool {
    return false
}

dinput_restore :: proc() {
}
