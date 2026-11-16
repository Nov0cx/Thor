#+build !windows
package platform

// POSIX half of the DirectInput block around window creation: there is nothing
// to block. GLFW reads the joysticks from /dev/input, or from IOKit on macOS,
// and neither costs measurable time (see platform/dinput_windows.odin).

@(private)
dinput_suppress :: proc() -> bool {
    return false
}

@(private)
dinput_restore :: proc() {}
