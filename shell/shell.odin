// Running an external command and capturing what it writes. One-shot and
// blocking, so every caller belongs on a worker thread — the console's runner, a
// git status, a compiler check. It sits below the editor rather than inside it
// so the language backends can reach it too.
//
// `run` and `spawn` have one implementation per platform: shell_windows.odin
// drives the win32 calls itself (CREATE_NO_WINDOW keeps a console from flashing
// over the editor), shell_posix.odin runs the command under /bin/sh. Both take
//
//     run :: proc(command: string, cwd: string, timeout: time.Duration = 0) -> string
//
// where a `timeout` above zero kills the command once it passes and appends a
// note to the output — for the one caller that cannot leave the frame, a plugin
// calling thor.exec.
package shell
