// Running an external command and capturing what it writes. One-shot and
// blocking, so every caller belongs on a worker thread — the console's runner, a
// git status, a compiler check. It sits below the editor rather than inside it
// so the language backends can reach it too.
//
// `run_status` and `spawn` have one implementation per platform:
// shell_windows.odin drives the win32 calls itself (CREATE_NO_WINDOW keeps a
// console from flashing over the editor), shell_posix.odin runs the command
// under /bin/sh. Both supply
//
//     run_status :: proc(command: string, cwd: string, timeout: time.Duration = 0, cancel: ^bool = nil) -> (output: string, code: int, ok: bool)
//     exec_status :: proc(exe: string, args: []string, cwd: string, timeout: time.Duration = 0, cancel: ^bool = nil) -> (output: string, code: int, ok: bool)
//     spawn :: proc(exe: string, arg: string, cwd: string) -> bool
//
// `exec_status` is `run_status` with no shell: the arguments are a list, so
// text from a file cannot become a second command.
//
// where a `timeout` above zero kills the command and everything it started once
// it passes, and appends a note to the output — for the one caller that cannot
// leave the frame, a plugin calling thor.exec. A `cancel` flag that another
// thread sets does the same kill within POLL_SLICE, and `ok` is false. `spawn`
// passes `arg` as the one argument, or none at all when it is empty: an empty
// argument is not the same as no argument to a program that reads a path from it.
package shell

import "core:fmt"
import "core:sync"
import "core:time"

// The longest a timed or cancellable command waits before it reads its deadline and its cancel flag again.
POLL_SLICE :: 50 * time.Millisecond

// `run_status` without the status, for the callers that only want the output.
run :: proc(command: string, cwd: string, timeout: time.Duration = 0) -> string {
    output, _, _ := run_status(command, cwd, timeout)
    return output
}

// True when the command must stop: `cancel` is set, or `timeout` has passed since `start`.
@(private)
stop_due :: proc(start: time.Tick, timeout: time.Duration, cancel: ^bool) -> bool {
    if cancel != nil && sync.atomic_load(cancel) {
        return true
    }
    return timeout > 0 && time.tick_since(start) >= timeout
}

// How long the next wait may block: POLL_SLICE, less when the deadline is nearer. Never negative.
@(private)
poll_wait :: proc(start: time.Tick, timeout: time.Duration) -> time.Duration {
    if timeout <= 0 {
        return POLL_SLICE
    }
    return clamp(timeout - time.tick_since(start), 0, POLL_SLICE)
}

// The note a stopped command adds to its output, in the temp allocator.
@(private)
stop_note :: proc(timeout: time.Duration, cancel: ^bool) -> string {
    if cancel != nil && sync.atomic_load(cancel) {
        return "[shell] command cancelled\n"
    }
    return fmt.tprintf("[shell] command stopped after %v\n", timeout)
}
