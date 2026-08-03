#+build windows
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

// Starts `exe` with one argument and leaves it running: no pipes, no wait, both
// handles closed at once. The counterpart to `run` for a process that outlives
// the call — a second editor window. Its own process group keeps a Ctrl+C in a
// debug console from reaching it. Returns whether the process started.
spawn :: proc(exe: string, arg: string, cwd: string) -> bool {
    si := win32.STARTUPINFOW {
        cb = size_of(win32.STARTUPINFOW),
    }
    pi: win32.PROCESS_INFORMATION

    // Both are quoted: a path with spaces would otherwise split into arguments.
    full := fmt.tprintf("\"%s\" \"%s\"", exe, arg)
    // CreateProcessW writes into the command line buffer, so it must be writable.
    cmdline := win32.utf8_to_wstring(full, context.temp_allocator)
    wdir: win32.wstring
    if cwd != "" {
        wdir = win32.utf8_to_wstring(cwd, context.temp_allocator)
    }

    if !win32.CreateProcessW(nil, cmdline, nil, nil, false, win32.CREATE_NEW_PROCESS_GROUP, nil, wdir, &si, &pi) {
        return false
    }
    win32.CloseHandle(pi.hProcess)
    win32.CloseHandle(pi.hThread)
    return true
}
