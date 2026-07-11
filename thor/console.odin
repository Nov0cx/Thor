package thor

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import "core:thread"

import "../widgets"

// A shell command run on a worker thread; output is appended to the console on
// the main thread. The output buffer uses the owner's (mutex-guarded) allocator
// so the main thread can free it.
Console_Job :: struct {
    owner:     ^Thor,
    command:   string, // owned
    allocator: runtime.Allocator,
    worker:    ^thread.Thread,
    output:    string, // owned, freed on the main thread
}

// Console_Run_Proc: launches `command` under cmd.exe in the workspace directory.
thor_console_run :: proc(data: rawptr, command: string) {
    thor := cast(^Thor) data

    job := new(Console_Job)
    job.owner = thor
    job.command = strings.clone(command)
    job.allocator = context.allocator

    thor.inflight_jobs += 1
    job.worker = thread.create_and_start_with_poly_data(job, console_worker)
}

@(private = "file")
console_worker :: proc(job: ^Console_Job) {
    // Output uses the owner's allocator (freed on the main thread); scratch
    // stays on the worker's temp.
    context.allocator = job.allocator
    defer free_all(context.temp_allocator)

    job.output = run_command(job.command, job.owner.workspace_dir)

    sync.lock(&job.owner.io_mutex)
    append(&job.owner.finished_console, job)
    sync.unlock(&job.owner.io_mutex)
}

// Runs `command` via cmd.exe with stdout+stderr piped; blocks until it exits.
@(private = "file")
run_command :: proc(command: string, cwd: string) -> string {
    sa := win32.SECURITY_ATTRIBUTES {
        nLength        = size_of(win32.SECURITY_ATTRIBUTES),
        bInheritHandle = true,
    }

    read_pipe, write_pipe: win32.HANDLE
    if !win32.CreatePipe(&read_pipe, &write_pipe, &sa, 0) {
        return strings.clone("[console] could not create pipe\n")
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
        return strings.clone("[console] could not start command\n")
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
