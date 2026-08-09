package shell

import "core:strings"

// A child process with stdin, stdout and stderr on three separate pipes. The
// sibling of `Session`, which merges stderr into stdout on purpose so a terminal
// shows the two interleaved. A language server logs to stderr, and merged that
// text lands inside the protocol's frame stream and desynchronises the parser,
// so a server needs the streams apart.
//
// Each platform file supplies:
//
//     Child           :: struct { ... }
//     child_start     :: proc(spec: Child_Spec) -> (^Child, bool)
//     child_write     :: proc(child: ^Child, bytes: []u8) -> bool
//     child_read_out  :: proc(child: ^Child, buf: []u8) -> int
//     child_read_err  :: proc(child: ^Child, buf: []u8) -> int
//     child_close_in  :: proc(child: ^Child)
//     child_alive     :: proc(child: ^Child) -> bool
//     child_terminate :: proc(child: ^Child)
//     child_destroy   :: proc(child: ^Child)
//
// child_read_out and child_read_err block until the child writes and return 0 at
// the end of their stream, so each belongs on a reader thread of its own.
// child_close_in signals the end of input without ending the process, which is
// how a filter learns to finish.
//
// child_start reports a program that could not be started on both platforms. A
// fork cannot fail, so the POSIX side carries the exec's errno back over a pipe
// of its own; otherwise a missing executable would read as a server that started
// and died at once.
//
// Shutdown is three steps, one more than a Session because there are two
// readers: child_terminate ends the process and is safe to call while a reader
// blocks, both reader threads are joined, and only then child_destroy releases
// the handles.
Child_Spec :: struct {
    exe:  string,
    args: []string, // borrowed for the call
    cwd:  string,   // empty inherits the parent's working directory
    env:  []string, // "K=V" overlay on the parent environment; empty inherits
}

// The name of a "K=V" environment entry, empty when it carries no '='. Whether
// two names match is the platform's own question — Windows compares them without
// case and POSIX exactly — so only the split is shared.
@(private)
environment_name :: proc(entry: string) -> string {
    at := strings.index_byte(entry, '=')
    return at < 0 ? "" : entry[:at]
}
