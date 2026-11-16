package platform

// The window, the frame and the event pump. raylib owns one window per process,
// so every call here acts on that one window.
//
// This package is the only one that imports vendor:raylib. Every other package
// talks to the window, the input, the GPU and the clipboard through it.

import "core:log"
import "core:strings"
import rl "vendor:raylib"

import ui "../vendor/loom/loom"

// Window creation flags.
Window_Flag :: enum u8 {
    Undecorated,
    Resizable,
}

Window_Flags :: bit_set[Window_Flag]

// Creates the window and its GL context. Blocks DirectInput for the length of
// the call (see dinput_windows.odin). Returns false when no window stands.
window_open :: proc(width, height: i32, title: string, flags: Window_Flags) -> bool {
    when !ODIN_DEBUG {
        rl.SetTraceLogLevel(.WARNING)
    }
    config: rl.ConfigFlags
    if .Undecorated in flags {
        config += {.WINDOW_UNDECORATED}
    }
    if .Resizable in flags {
        config += {.WINDOW_RESIZABLE}
    }
    rl.SetConfigFlags(config)

    suppressed := dinput_suppress()
    rl.InitWindow(width, height, strings.clone_to_cstring(title, context.temp_allocator))
    if suppressed {
        dinput_restore()
    }
    if !rl.IsWindowReady() {
        log.error("Could not create the window")
        return false
    }
    // The escape key belongs to the editor.
    rl.SetExitKey(.KEY_NULL)
    return true
}

window_close :: proc() {
    rl.CloseWindow()
}

// True once the window and its GL context exist.
window_ready :: proc() -> bool {
    return rl.IsWindowReady()
}

// True when the user asked the window to close.
window_should_close :: proc() -> bool {
    return rl.WindowShouldClose()
}

// The size of the drawable area in pixels.
window_size :: proc() -> [2]i32 {
    return {rl.GetScreenWidth(), rl.GetScreenHeight()}
}

// The window origin in desktop coordinates.
window_position :: proc() -> [2]f32 {
    return rl.GetWindowPosition()
}

window_set_position :: proc(x, y: i32) {
    rl.SetWindowPosition(x, y)
}

window_set_size :: proc(width, height: i32) {
    rl.SetWindowSize(width, height)
}

window_set_min_size :: proc(width, height: i32) {
    rl.SetWindowMinSize(width, height)
}

window_minimize :: proc() {
    rl.MinimizeWindow()
}

window_maximize :: proc() {
    rl.MaximizeWindow()
}

window_restore :: proc() {
    rl.RestoreWindow()
}

window_toggle_borderless :: proc() {
    rl.ToggleBorderlessWindowed()
}

// True on the frame the window size changed.
window_resized :: proc() -> bool {
    return rl.IsWindowResized()
}

// True when the window covers the screen, borderless or fullscreen.
window_covers_screen :: proc() -> bool {
    return rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) || rl.IsWindowFullscreen()
}

// The DPI scale of the monitor the window is on.
window_dpi_scale :: proc() -> [2]f32 {
    return rl.GetWindowScaleDPI()
}

// The native window: an HWND on Windows, an X11 Window or NSWindow elsewhere.
window_native_handle :: proc() -> rawptr {
    return rl.GetWindowHandle()
}

// Sets the window and taskbar icon from an image file. False when it does not decode.
window_set_icon :: proc(path: string) -> bool {
    image := rl.LoadImage(strings.clone_to_cstring(path, context.temp_allocator))
    if image.data == nil {
        return false
    }
    rl.SetWindowIcon(image)
    rl.UnloadImage(image)
    return true
}

window_set_target_fps :: proc(fps: i32) {
    rl.SetTargetFPS(fps)
}

// Sets the mouse cursor shape.
window_set_cursor :: proc(c: ui.Cursor) {
    shape: rl.MouseCursor
    switch c {
    case .Default:
        shape = .DEFAULT
    case .Pointer:
        shape = .POINTING_HAND
    case .Text:
        shape = .IBEAM
    case .Resize_H:
        shape = .RESIZE_EW
    case .Resize_V:
        shape = .RESIZE_NS
    case .Resize_NWSE:
        shape = .RESIZE_NWSE
    case .Resize_NESW:
        shape = .RESIZE_NESW
    case .Grab:
        shape = .POINTING_HAND
    case .Grabbing:
        shape = .RESIZE_ALL
    case .Not_Allowed:
        shape = .NOT_ALLOWED
    }
    rl.SetMouseCursor(shape)
}

// Starts a frame on the window and clears it to `clear`.
frame_begin :: proc(clear: ui.Color) {
    rl.BeginDrawing()
    rl.ClearBackground(rl.Color(clear))
}

// Presents the frame, waits for the frame rate and polls the input.
frame_end :: proc() {
    rl.EndDrawing()
}

// Polls the input of a frame that is not drawn. frame_end polls it otherwise.
poll_events :: proc() {
    rl.PollInputEvents()
}
