// Running an external command and capturing what it writes. One-shot and
// blocking, so every caller belongs on a worker thread — the console's runner, a
// git status, a compiler check. It sits below the editor rather than inside it
// so the language backends can reach it too.
//
// `run` and `spawn` have one implementation per platform: shell_windows.odin
// drives the win32 calls itself (CREATE_NO_WINDOW keeps a console from flashing
// over the editor), shell_posix.odin runs the command under /bin/sh.
package shell
