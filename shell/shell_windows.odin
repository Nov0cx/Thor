#+build windows
package shell

import "core:fmt"
import "core:strings"
import win32 "core:sys/windows"
import "core:time"

// Runs `command` via cmd.exe in `cwd` with stdout+stderr piped; blocks until it
// exits. A `timeout` above zero ends the command and everything it started when
// that time passes, and marks the output. `ok` is false when the command never
// ran to completion — a pipe or start failure, or a timeout — and only then is
// `code` meaningless. The returned output is owned by context.allocator.
run_status :: proc(command: string, cwd: string, timeout: time.Duration = 0) -> (output: string, code: int, ok: bool) {
    sa := win32.SECURITY_ATTRIBUTES {
        nLength        = size_of(win32.SECURITY_ATTRIBUTES),
        bInheritHandle = true,
    }

    read_pipe, write_pipe: win32.HANDLE
    if !win32.CreatePipe(&read_pipe, &write_pipe, &sa, 0) {
        return strings.clone("[shell] could not create pipe\n"), -1, false
    }
    defer win32.CloseHandle(read_pipe)
    // The read end stays with the parent; keep it out of the child. An end
    // that stays inheritable would reach the child and hold the pipe open
    // after it exits, so a failure here ends the start.
    if !win32.SetHandleInformation(read_pipe, win32.HANDLE_FLAG_INHERIT, 0) {
        win32.CloseHandle(write_pipe)
        return strings.clone("[shell] could not create pipe\n"), -1, false
    }

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

    // A timed command starts suspended, so the job holds it before it can start
    // a child of its own that the kill would miss.
    job: win32.HANDLE
    flags := win32.DWORD(win32.CREATE_NO_WINDOW)
    if timeout > 0 {
        job = create_kill_on_close_job()
        if job != nil {
            flags |= win32.CREATE_SUSPENDED
        }
    }

    started := win32.CreateProcessW(nil, cmdline, nil, nil, true, flags, nil, wdir, &si, &pi)
    // Close the parent's copy of the write end so ReadFile sees EOF when the
    // child (the only remaining writer) exits.
    win32.CloseHandle(write_pipe)
    if !started {
        if job != nil {
            win32.CloseHandle(job)
        }
        return strings.clone("[shell] could not start command\n"), -1, false
    }
    defer {
        win32.CloseHandle(pi.hProcess)
        win32.CloseHandle(pi.hThread)
        // The job kills whatever is left in it as it closes, so no child of the
        // command outlives the call.
        if job != nil {
            win32.CloseHandle(job)
        }
    }
    if job != nil {
        // A parent job without JOB_OBJECT_LIMIT_BREAKAWAY_OK refuses the
        // assignment; the job must go, or the kill hits an empty job.
        if !AssignProcessToJobObject(job, pi.hProcess) {
            win32.CloseHandle(job)
            job = nil
        }
        win32.ResumeThread(pi.hThread)
    }

    start := time.tick_now()
    timed_out := false
    builder := strings.builder_make()
    buf: [4096]u8
    for {
        // ReadFile cannot be cut short, so a timed command reads only what the
        // pipe already holds and sleeps between polls.
        if timeout > 0 {
            if time.tick_since(start) >= timeout {
                timed_out = true
                break
            }
            avail: u32
            if !win32.PeekNamedPipe(read_pipe, nil, 0, nil, &avail, nil) {
                break
            }
            if avail == 0 {
                // The pipe is empty, so the child cannot be blocked writing to a
                // full one: the wait itself doubles as the sleep between polls,
                // woken early the moment the process exits instead of noticing
                // up to one slice late.
                remaining := time.duration_milliseconds(timeout - time.tick_since(start))
                wait_ms := win32.DWORD(min(remaining, 50))
                if win32.WaitForSingleObject(pi.hProcess, wait_ms) != win32.WAIT_OBJECT_0 {
                    continue
                }
                // The command can write and exit between the wait and the peek.
                if !win32.PeekNamedPipe(read_pipe, nil, 0, nil, &avail, nil) || avail == 0 {
                    break
                }
            }
        }
        read: win32.DWORD
        if !win32.ReadFile(read_pipe, &buf[0], len(buf), &read, nil) || read == 0 {
            break
        }
        strings.write_bytes(&builder, buf[:read])
    }

    if timeout <= 0 {
        win32.WaitForSingleObject(pi.hProcess, win32.INFINITE)
        status, got := exit_code(pi.hProcess)
        return strings.to_string(builder), status, got
    }
    // The end of the stream does not prove the command exited: it can close its
    // output and keep running. Give it only the time it has left.
    if !timed_out {
        left := timeout - time.tick_since(start)
        wait_ms := win32.DWORD(0)
        if left > 0 {
            wait_ms = win32.DWORD(time.duration_milliseconds(left))
        }
        timed_out = win32.WaitForSingleObject(pi.hProcess, wait_ms) != win32.WAIT_OBJECT_0
    }
    if timed_out {
        // The job kill also reaches the grandchildren it holds; a process
        // kill alone does not, but it is the best that is left when the job
        // itself refuses to die.
        if job == nil || !TerminateJobObject(job, 1) {
            win32.TerminateProcess(pi.hProcess, 1)
        }
        fmt.sbprintf(&builder, "[shell] command stopped after %v\n", timeout)
        return strings.to_string(builder), -1, false
    }
    status, got := exit_code(pi.hProcess)
    return strings.to_string(builder), status, got
}

// STILL_ACTIVE, which core:sys/windows does not declare. A process that reports
// it has not exited, so it has no status yet.
@(private = "file")
STILL_ACTIVE :: win32.DWORD(259)

// Exit status of an exited process.
@(private = "file")
exit_code :: proc(process: win32.HANDLE) -> (int, bool) {
    status: win32.DWORD
    if !win32.GetExitCodeProcess(process, &status) || status == STILL_ACTIVE {
        return -1, false
    }
    return int(status), true
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
