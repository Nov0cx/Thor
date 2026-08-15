#+build windows
package thor

import "core:os"
import win32 "core:sys/windows"

// The AttachConsole process id that names the parent process.
@(private = "file")
ATTACH_PARENT_PROCESS :: ~win32.DWORD(0)

// Attaches the console of the invoking shell and rebinds os.stdout to it: a
// release binary links the windows subsystem, so it starts with no console and
// a null stdout handle. A redirection passes a handle without a console, so a
// handle that is already there is kept. Quiet when there is no parent console —
// Explorer started the process and nobody reads the output.
cli_attach_console :: proc() {
    if win32.GetStdHandle(win32.STD_OUTPUT_HANDLE) == nil {
        if !win32.AttachConsole(ATTACH_PARENT_PROCESS) {
            return
        }
    }
    handle := win32.GetStdHandle(win32.STD_OUTPUT_HANDLE)
    if handle == nil || handle == win32.INVALID_HANDLE_VALUE {
        return
    }
    os.stdout = os.new_file(uintptr(handle), "<stdout>")
}
