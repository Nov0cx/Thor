package lsp

import "../../shell"

// Where a server's bytes come from and go. The rest of the package speaks only
// through this vtable, so a test plays a scripted server in-process — with no
// child, no installed server and no display, which is what the four CI platforms
// need.
//
// `read_out` and `read_err` block until the server writes and answer 0 at the end
// of their stream, which is the server's death, so each belongs on a reader
// thread of its own. `close` ends the server's input and is safe to call while
// those readers block; a well-behaved server then exits on its own and both
// readers see the end. `terminate` is the kill for one that does not. `destroy`
// is legal only once both reader threads are joined.
Transport :: struct {
    data:      rawptr,
    write:     proc(data: rawptr, bytes: []u8) -> bool,
    read_out:  proc(data: rawptr, buf: []u8) -> int,
    read_err:  proc(data: rawptr, buf: []u8) -> int,
    close:     proc(data: rawptr),
    terminate: proc(data: rawptr),
    destroy:   proc(data: rawptr),
}

// A transport over a child process. `shell.Child` is named nowhere else in this
// package: stdout and stderr arrive on separate pipes, which is the whole reason
// the child is not a shell.Session — a server's stderr log merged into stdout
// would land inside the frame stream.
transport_child :: proc(spec: shell.Child_Spec) -> (Transport, bool) {
    child, ok := shell.child_start(spec)
    if !ok {
        return {}, false
    }
    return Transport {
        data = child,
        write = proc(data: rawptr, bytes: []u8) -> bool {
            return shell.child_write((^shell.Child)(data), bytes)
        },
        read_out = proc(data: rawptr, buf: []u8) -> int {
            return shell.child_read_out((^shell.Child)(data), buf)
        },
        read_err = proc(data: rawptr, buf: []u8) -> int {
            return shell.child_read_err((^shell.Child)(data), buf)
        },
        close = proc(data: rawptr) {
            shell.child_close_in((^shell.Child)(data))
        },
        terminate = proc(data: rawptr) {
            shell.child_terminate((^shell.Child)(data))
        },
        destroy = proc(data: rawptr) {
            shell.child_destroy((^shell.Child)(data))
        },
    }, true
}
