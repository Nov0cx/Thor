#+build darwin, freebsd, openbsd, netbsd
package thor

// No window-manager drag and no desktop cursor here; the caller moves the
// window itself from the window position plus the mouse.

thor_cursor_screen :: proc() -> (pos: [2]f32, ok: bool) {
    return {}, false
}

thor_wm_begin_drag :: proc(edges: Window_Edges) -> bool {
    return false
}
