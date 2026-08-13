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
//     run_status :: proc(command: string, cwd: string, timeout: time.Duration = 0) -> (output: string, code: int, ok: bool)
//     spawn :: proc(exe: string, arg: string, cwd: string) -> bool
//
// where a `timeout` above zero kills the command and everything it started once
// it passes, and appends a note to the output — for the one caller that cannot
// leave the frame, a plugin calling thor.exec. `spawn` passes `arg` as the one
// argument, or none at all when it is empty: an empty argument is not the same
// as no argument to a program that reads a path from it.
package shell

import "core:time"

// `run_status` without the status, for the callers that only want the output.
run :: proc(command: string, cwd: string, timeout: time.Duration = 0) -> string {
    output, _, _ := run_status(command, cwd, timeout)
    return output
}
