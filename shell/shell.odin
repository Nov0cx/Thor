// Running an external command and capturing what it writes. One-shot and
// blocking, so every caller belongs on a worker thread — the console's runner, a
// git status, a compiler check. It sits below the editor rather than inside it
// so the language backends can reach it too.
package shell

import "core:fmt"
import "core:strings"
import win32 "core:sys/windows"

// Runs `command` via cmd.exe in `cwd` with stdout+stderr piped; blocks until it
// exits. The returned output is owned by context.allocator.
run :: proc(command: string, cwd: string) -> string {
    sa := win32.SECURITY_ATTRIBUTES {
        nLength        = size_of(win32.SECURITY_ATTRIBUTES),
        bInheritHandle = true,
    }

    read_pipe, write_pipe: win32.HANDLE
    if !win32.CreatePipe(&read_pipe, &write_pipe, &sa, 0) {
        return strings.clone("[shell] could not create pipe\n")
    }
    defer win32.CloseHandle(read_pipe)
    // The read end stays with the parent; keep it out of the child.
    win32.SetHandleInformation(read_pipe, win32.HANDLE_FLAG_INHERIT, 0)

    si := win32.STARTUPINFOW {
        cb         = size_of(win32.STARTUPINFOW),
        dwFlags    = win32.STARTF_USESTDHANDLES,
        hStdOutput = write_pipe,
        hStdError  = write_pipe,
    }
    pi: win32.PROCESS_INFORMATION

    full := fmt.tprintf("cmd.exe /d /c %s", command)
    cmdline := win32.utf8_to_wstring(full, context.temp_allocator)
    wdir := win32.utf8_to_wstring(cwd, context.temp_allocator)

    ok := win32.CreateProcessW(nil, cmdline, nil, nil, true, win32.CREATE_NO_WINDOW, nil, wdir, &si, &pi)
    // Close the parent's copy of the write end so ReadFile sees EOF when the
    // child (the only remaining writer) exits.
    win32.CloseHandle(write_pipe)
    if !ok {
        return strings.clone("[shell] could not start command\n")
    }
    defer {
        win32.CloseHandle(pi.hProcess)
        win32.CloseHandle(pi.hThread)
    }

    builder := strings.builder_make()
    buf: [4096]u8
    for {
        read: win32.DWORD
        if !win32.ReadFile(read_pipe, &buf[0], len(buf), &read, nil) || read == 0 {
            break
        }
        strings.write_bytes(&builder, buf[:read])
    }
    win32.WaitForSingleObject(pi.hProcess, win32.INFINITE)
    return strings.to_string(builder)
}
