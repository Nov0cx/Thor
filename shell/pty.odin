package shell

// A shell running on a pseudo-terminal: the child believes it talks to a real
// terminal, so it draws its own prompt, colours its output and runs full-screen
// programs. One process per terminal tab, alive across commands, which is what
// makes a `cd` stick and a loaded environment stay loaded.
//
// Each platform file supplies:
//
//     Pty           :: struct { ... }
//     pty_start     :: proc(profile: Profile, cwd: string, cols, rows: int) -> (^Pty, bool)
//     pty_write     :: proc(pty: ^Pty, data: string) -> bool
//     pty_read      :: proc(pty: ^Pty, buf: []u8) -> int
//     pty_resize    :: proc(pty: ^Pty, cols, rows: int) -> bool
//     pty_terminate :: proc(pty: ^Pty)
//     pty_destroy   :: proc(pty: ^Pty)
//
// pty_read blocks until the shell writes and returns 0 at the end of the stream,
// so it belongs on a reader thread. Shutdown is two steps: pty_terminate ends
// the shell and everything it started and is safe to call while the reader
// blocks, pty_destroy releases the handles once that reader is joined.
//
// There is no interrupt call: ctrl + c is a byte the terminal writes, and the
// pseudo-terminal turns it into the signal, the same as on a real console.

// What the shell is told it is running on. xterm-256color is what a program
// reads to decide it may send colour and cursor addressing.
PTY_TERM :: "xterm-256color"

// Clamps a requested grid to something a pseudo-terminal accepts. A panel can
// be laid out at zero size for a frame, and a shell asked for zero columns
// writes nothing ever again.
pty_clamp_size :: proc(cols, rows: int) -> (int, int) {
    return clamp(cols, 1, 2000), clamp(rows, 1, 2000)
}
