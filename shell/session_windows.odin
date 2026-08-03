#+build windows
package shell

import "core:fmt"
import "core:strings"
import win32 "core:sys/windows"

foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
    CreateJobObjectW         :: proc(attributes: rawptr, name: win32.LPCWSTR) -> win32.HANDLE ---
    SetInformationJobObject  :: proc(job: win32.HANDLE, class: i32, info: rawptr, length: win32.DWORD) -> win32.BOOL ---
    AssignProcessToJobObject :: proc(job: win32.HANDLE, process: win32.HANDLE) -> win32.BOOL ---
    TerminateJobObject       :: proc(job: win32.HANDLE, exit_code: win32.UINT) -> win32.BOOL ---
}

@(private = "file")
JobObjectExtendedLimitInformation :: 9

@(private = "file")
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x00002000

@(private = "file")
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
    PerProcessUserTimeLimit: win32.LARGE_INTEGER,
    PerJobUserTimeLimit:     win32.LARGE_INTEGER,
    LimitFlags:              win32.DWORD,
    MinimumWorkingSetSize:   win32.SIZE_T,
    MaximumWorkingSetSize:   win32.SIZE_T,
    ActiveProcessLimit:      win32.DWORD,
    Affinity:                win32.ULONG_PTR,
    PriorityClass:           win32.DWORD,
    SchedulingClass:         win32.DWORD,
}

@(private = "file")
IO_COUNTERS :: struct {
    ReadOperationCount:  win32.ULONGLONG,
    WriteOperationCount: win32.ULONGLONG,
    OtherOperationCount: win32.ULONGLONG,
    ReadTransferCount:   win32.ULONGLONG,
    WriteTransferCount:  win32.ULONGLONG,
    OtherTransferCount:  win32.ULONGLONG,
}

@(private = "file")
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo:                IO_COUNTERS,
    ProcessMemoryLimit:    win32.SIZE_T,
    JobMemoryLimit:        win32.SIZE_T,
    PeakProcessMemoryUsed: win32.SIZE_T,
    PeakJobMemoryUsed:     win32.SIZE_T,
}

// A live shell. The job object holds the shell and everything it starts, so
// terminating it also ends the grandchildren that keep the output pipe open —
// without it a killed shell can leave a build running and the reader blocked.
Session :: struct {
    process:  win32.HANDLE,
    thread:   win32.HANDLE,
    job:      win32.HANDLE,
    stdin_w:  win32.HANDLE,
    stdout_r: win32.HANDLE,
}

// Starts `profile` in `cwd` with stdin, stdout and stderr piped. Both output
// streams share one pipe, so the terminal sees them interleaved as a console
// would. The init commands are not sent here; the caller does that, so it can
// drop their output.
session_start :: proc(profile: Profile, cwd: string) -> (^Session, bool) {
    sa := win32.SECURITY_ATTRIBUTES {
        nLength        = size_of(win32.SECURITY_ATTRIBUTES),
        bInheritHandle = true,
    }

    stdout_r, stdout_w: win32.HANDLE
    if !win32.CreatePipe(&stdout_r, &stdout_w, &sa, 0) {
        return nil, false
    }
    stdin_r, stdin_w: win32.HANDLE
    if !win32.CreatePipe(&stdin_r, &stdin_w, &sa, 0) {
        win32.CloseHandle(stdout_r)
        win32.CloseHandle(stdout_w)
        return nil, false
    }
    // The parent's ends stay with the parent; keep them out of the child.
    win32.SetHandleInformation(stdout_r, win32.HANDLE_FLAG_INHERIT, 0)
    win32.SetHandleInformation(stdin_w, win32.HANDLE_FLAG_INHERIT, 0)

    si := win32.STARTUPINFOW {
        cb         = size_of(win32.STARTUPINFOW),
        dwFlags    = win32.STARTF_USESTDHANDLES,
        hStdInput  = stdin_r,
        hStdOutput = stdout_w,
        hStdError  = stdout_w,
    }
    pi: win32.PROCESS_INFORMATION

    cmdline := win32.utf8_to_wstring(command_line(profile), context.temp_allocator)
    wdir: win32.wstring
    if cwd != "" {
        wdir = win32.utf8_to_wstring(cwd, context.temp_allocator)
    }

    // Suspended so the job owns the shell before it can start a child of its own.
    flags := win32.DWORD(win32.CREATE_NO_WINDOW | win32.CREATE_SUSPENDED)
    ok := win32.CreateProcessW(nil, cmdline, nil, nil, true, flags, nil, wdir, &si, &pi)
    // The child owns the far ends now; the parent's copies must go so a read
    // sees the end of the stream when the shell exits.
    win32.CloseHandle(stdout_w)
    win32.CloseHandle(stdin_r)
    if !ok {
        win32.CloseHandle(stdout_r)
        win32.CloseHandle(stdin_w)
        return nil, false
    }

    session := new(Session)
    session.process = pi.hProcess
    session.thread = pi.hThread
    session.stdin_w = stdin_w
    session.stdout_r = stdout_r
    session.job = create_kill_on_close_job()
    if session.job != nil {
        AssignProcessToJobObject(session.job, pi.hProcess)
    }
    win32.ResumeThread(pi.hThread)
    return session, true
}

// Writes to the shell's stdin. The caller terminates lines itself.
session_write :: proc(session: ^Session, text: string) -> bool {
    if session == nil || len(text) == 0 {
        return session != nil
    }
    data := transmute([]u8) text
    for sent := 0; sent < len(data); {
        written: win32.DWORD
        if !win32.WriteFile(session.stdin_w, &data[sent], win32.DWORD(len(data) - sent), &written, nil) || written == 0 {
            return false
        }
        sent += int(written)
    }
    return true
}

// Blocks until the shell writes, and returns 0 at the end of the stream.
session_read :: proc(session: ^Session, buf: []u8) -> int {
    if session == nil || len(buf) == 0 {
        return 0
    }
    read: win32.DWORD
    if !win32.ReadFile(session.stdout_r, &buf[0], win32.DWORD(len(buf)), &read, nil) {
        return 0
    }
    return int(read)
}

// Windows cannot deliver a console interrupt to a process started without a
// console, so the caller restarts the session instead.
session_interrupt :: proc(session: ^Session) -> bool {
    return false
}

// Ends the shell and everything it started, so a reader blocked in session_read
// comes back with 0. Safe to call while that reader runs.
session_terminate :: proc(session: ^Session) {
    if session == nil {
        return
    }
    if session.stdin_w != nil {
        win32.CloseHandle(session.stdin_w)
        session.stdin_w = nil
    }
    if session.job != nil {
        TerminateJobObject(session.job, 0)
    } else {
        win32.TerminateProcess(session.process, 0)
    }
}

// Releases the handles and the session. Only legal once the reader is joined.
session_destroy :: proc(session: ^Session) {
    if session == nil {
        return
    }
    if session.stdin_w != nil {
        win32.CloseHandle(session.stdin_w)
    }
    win32.CloseHandle(session.stdout_r)
    win32.CloseHandle(session.thread)
    win32.CloseHandle(session.process)
    if session.job != nil {
        win32.CloseHandle(session.job)
    }
    free(session)
}

// A job whose processes die with it. Returns nil when the job cannot be set up,
// which only costs the caller the child-tree cleanup.
@(private = "file")
create_kill_on_close_job :: proc() -> win32.HANDLE {
    job := CreateJobObjectW(nil, nil)
    if job == nil {
        return nil
    }
    limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, size_of(limits)) {
        win32.CloseHandle(job)
        return nil
    }
    return job
}

// The command line CreateProcessW parses. Each part is quoted on its own: a
// shell installed under Program Files would otherwise split into arguments.
@(private = "file")
command_line :: proc(profile: Profile) -> string {
    builder := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&builder, `"%s"`, profile.exe)
    for arg in profile.args {
        if strings.contains(arg, " ") {
            fmt.sbprintf(&builder, ` "%s"`, arg)
        } else {
            fmt.sbprintf(&builder, " %s", arg)
        }
    }
    return strings.to_string(builder)
}
