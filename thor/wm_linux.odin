#+build linux
package thor

// Linux half of the window-manager calls. raylib runs GLFW on X11 (also under
// XWayland), so a titlebar or edge drag is given to the window manager with
// _NET_WM_MOVERESIZE, as GTK and Qt do.

import "core:log"

import "vendor:x11/xlib"

import "../platform"

// GLFW's own connection, in raylib's static library. The pointer grab of a
// press belongs to this connection, so only it can release the grab.
@(default_calling_convention = "c")
foreign _ {
    glfwGetX11Display :: proc() -> ^xlib.Display ---
    glfwGetX11Window  :: proc(window: rawptr) -> xlib.Window ---
}

@(private = "file")
x11_error_code: u8

@(private = "file")
x11_error_record :: proc "c"(display: ^xlib.Display, event: ^xlib.XErrorEvent) -> i32 {
    x11_error_code = event.error_code
    return 0
}

// Xlib's default error handler ends the process, so X calls here run under a handler that records the error.
@(private = "file")
x11_trap_begin :: proc() -> proc "c"(display: ^xlib.Display, event: ^xlib.XErrorEvent) -> i32 {
    x11_error_code = 0
    return xlib.SetErrorHandler(x11_error_record)
}

// Waits for the server to answer the trapped calls, then restores the old handler. False when one failed.
@(private = "file")
x11_trap_end :: proc(display: ^xlib.Display, old: proc "c"(display: ^xlib.Display, event: ^xlib.XErrorEvent) -> i32) -> bool {
    xlib.Sync(display, false)
    xlib.SetErrorHandler(old)
    if x11_error_code != 0 {
        log.warnf("X11 request failed with error code %d", x11_error_code)
        return false
    }
    return true
}

@(private = "file")
NET_WM_MOVERESIZE_MOVE :: 8

@(private = "file")
Wm_State :: struct {
    checked:    bool,
    supported:  bool,
    moveresize: xlib.Atom,
}

@(private = "file")
wm_state: Wm_State

@(private = "file")
thor_x11 :: proc() -> (display: ^xlib.Display, window: xlib.Window, ok: bool) {
    // raylib's window handle on Linux is the GLFWwindow, not the X11 window.
    handle := platform.window_native_handle()
    if handle == nil {
        return nil, 0, false
    }
    display = glfwGetX11Display()
    if display == nil {
        return nil, 0, false
    }
    window = glfwGetX11Window(handle)
    return display, window, window != 0
}

// Whether the window manager lists _NET_WM_MOVERESIZE in _NET_SUPPORTED. Asked once.
@(private = "file")
thor_wm_supports_moveresize :: proc(display: ^xlib.Display) -> bool {
    if wm_state.checked {
        return wm_state.supported
    }
    wm_state.checked = true
    root           := xlib.DefaultRootWindow(display)
    supported_atom := xlib.InternAtom(display, "_NET_SUPPORTED", true)
    wm_state.moveresize = xlib.InternAtom(display, "_NET_WM_MOVERESIZE", true)
    if supported_atom == 0 || wm_state.moveresize == 0 {
        return false
    }
    act_type: xlib.Atom
    act_format: i32
    nitems, after: uint
    data: rawptr
    status := xlib.GetWindowProperty(display, root, supported_atom, 0, 4096, false, xlib.XA_ATOM, &act_type, &act_format, &nitems, &after, &data)
    if status != 0 || data == nil {
        return false
    }
    defer xlib.Free(data)
    if act_format != 32 {
        return false
    }
    atoms := ([^]xlib.Atom)(data)[:nitems]
    for atom in atoms {
        if atom == wm_state.moveresize {
            wm_state.supported = true
            break
        }
    }
    if !wm_state.supported {
        log.info("The window manager has no _NET_WM_MOVERESIZE; Thor moves the window itself.")
    }
    return wm_state.supported
}

// The _NET_WM_MOVERESIZE direction of a drag: 8 moves, 0..7 size from an edge
// or corner, clockwise from the top-left.
window_moveresize_direction :: proc(edges: Window_Edges) -> int {
    switch edges {
    case {.Left, .Top}:
        return 0
    case {.Top}:
        return 1
    case {.Right, .Top}:
        return 2
    case {.Right}:
        return 3
    case {.Right, .Bottom}:
        return 4
    case {.Bottom}:
        return 5
    case {.Left, .Bottom}:
        return 6
    case {.Left}:
        return 7
    }
    return NET_WM_MOVERESIZE_MOVE
}

// The cursor in desktop coordinates, from the X server and not from the last
// queued motion event.
thor_cursor_screen :: proc() -> (pos: [2]f32, ok: bool) {
    display, window, x11 := thor_x11()
    if !x11 {
        return {}, false
    }
    root, child: xlib.Window
    root_x, root_y, win_x, win_y: i32
    mask: xlib.KeyMask
    old     := x11_trap_begin()
    queried := xlib.QueryPointer(display, window, &root, &child, &root_x, &root_y, &win_x, &win_y, &mask)
    if !x11_trap_end(display, old) || !queried {
        return {}, false
    }
    return {f32(root_x), f32(root_y)}, true
}

// Gives a held left-button drag to the window manager: a move when `edges` is
// empty, else a resize from those edges. False when the window manager cannot
// take it, and the caller then moves the window itself.
thor_wm_begin_drag :: proc(edges: Window_Edges) -> bool {
    display, window, x11 := thor_x11()
    if !x11 || !thor_wm_supports_moveresize(display) {
        return false
    }
    root, child: xlib.Window
    root_x, root_y, win_x, win_y: i32
    mask: xlib.KeyMask
    old     := x11_trap_begin()
    queried := xlib.QueryPointer(display, window, &root, &child, &root_x, &root_y, &win_x, &win_y, &mask)
    if !x11_trap_end(display, old) || !queried {
        return false
    }

    old = x11_trap_begin()
    defer x11_trap_end(display, old)

    xlib.UngrabPointer(display, xlib.CurrentTime)

    msg: xlib.XEvent
    msg.xclient = {type = .ClientMessage, window = window, message_type = wm_state.moveresize, format = 32}
    msg.xclient.data.l = {int(root_x), int(root_y), window_moveresize_direction(edges), 1, 1}
    // XSendEvent returns zero only when the event could not be converted.
    if i32(xlib.SendEvent(display, root, false, {.SubstructureRedirect, .SubstructureNotify}, &msg)) == 0 {
        return false
    }

    // The window manager takes the real release, so GLFW would keep the button
    // down and the next press would not read as a press.
    release: xlib.XEvent
    release.xbutton = {
        type = .ButtonRelease,
        send_event = true,
        display = display,
        window = window,
        root = root,
        time = xlib.CurrentTime,
        x = win_x,
        y = win_y,
        x_root = root_x,
        y_root = root_y,
        state = {.Button1Mask},
        button = .Button1,
        same_screen = true,
    }
    xlib.SendEvent(display, window, false, {.ButtonRelease}, &release)
    xlib.Flush(display)
    return true
}
