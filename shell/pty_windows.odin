#+build windows
package shell

import "core:fmt"
import "core:strings"
import win32 "core:sys/windows"

// The Windows pseudo-console. ConPTY runs the console host itself and hands
// back one pipe each way, so what arrives is the same VT stream a POSIX
// pseudo-terminal produces.

@(private = "file")
HPCON :: distinct rawptr

@(private = "file")
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: win32.DWORD_PTR(0x00020016)

// STARTUPINFOW with the attribute list behind it. The first field is the plain
// record, so a pointer to this is what CreateProcessW takes.
@(private = "file")
STARTUPINFOEXW :: struct {
    StartupInfo:   win32.STARTUPINFOW,
    lpAttributeList: rawptr,
}

foreign import kernel32 "system:Kernel32.lib"

@(private = "file")
@(default_calling_convention = "system")
foreign kernel32 {
    CreatePseudoConsole :: proc(size: win32.COORD, hInput, hOutput: win32.HANDLE, dwFlags: win32.DWORD, phPC: ^HPCON) -> win32.HRESULT ---
    ResizePseudoConsole :: proc(hPC: HPCON, size: win32.COORD) -> win32.HRESULT ---
    ClosePseudoConsole :: proc(hPC: HPCON) ---
    InitializeProcThreadAttributeList :: proc(lpAttributeList: rawptr, dwAttributeCount, dwFlags: win32.DWORD, lpSize: ^win32.SIZE_T) -> win32.BOOL ---
    UpdateProcThreadAttribute :: proc(lpAttributeList: rawptr, dwFlags: win32.DWORD, Attribute: win32.DWORD_PTR, lpValue: rawptr, cbSize: win32.SIZE_T, lpPreviousValue: rawptr, lpReturnSize: ^win32.SIZE_T) -> win32.BOOL ---
    DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
}

Pty :: struct {
    process:   win32.HANDLE, // owned
    thread:    win32.HANDLE, // owned
    job:       win32.HANDLE, // owned, nil when the job could not be made or assigned
    console:   HPCON,        // owned, nil after pty_terminate closes it
    input:     win32.HANDLE, // owned, the end this process writes to
    output:    win32.HANDLE, // owned, the end this process reads from
    attribute: []u8,         // owned, the proc-thread attribute list the console is named in
}

// Starts `profile` in `cwd` on a pseudo-console of `cols` x `rows`.
pty_start :: proc(profile: Profile, cwd: string, cols, rows: int) -> (^Pty, bool) {
    cols, rows := pty_clamp_size(cols, rows)

    // Two pipes: one the console host reads the shell's input from, one it
    // writes the shell's output to. Neither end is inheritable; the console
    // takes the two it needs by handle.
    in_read, in_write: win32.HANDLE
    if !win32.CreatePipe(&in_read, &in_write, nil, 0) {
        return nil, false
    }
    out_read, out_write: win32.HANDLE
    if !win32.CreatePipe(&out_read, &out_write, nil, 0) {
        win32.CloseHandle(in_read)
        win32.CloseHandle(in_write)
        return nil, false
    }

    console: HPCON
    size := win32.COORD{win32.SHORT(cols), win32.SHORT(rows)}
    hr := CreatePseudoConsole(size, in_read, out_write, 0, &console)
    // The console owns copies of those two ends now.
    win32.CloseHandle(in_read)
    win32.CloseHandle(out_write)
    if hr != 0 {
        win32.CloseHandle(in_write)
        win32.CloseHandle(out_read)
        return nil, false
    }

    attribute, attribute_ok := attribute_list(console)
    if !attribute_ok {
        ClosePseudoConsole(console)
        win32.CloseHandle(in_write)
        win32.CloseHandle(out_read)
        return nil, false
    }

    si := STARTUPINFOEXW {
        StartupInfo = {cb = size_of(STARTUPINFOEXW)},
        lpAttributeList = raw_data(attribute),
    }
    pi: win32.PROCESS_INFORMATION

    // The child reads TERM to decide what it may send; ConPTY itself sets none.
    win32.SetEnvironmentVariableW(
        win32.utf8_to_wstring("TERM", context.temp_allocator),
        win32.utf8_to_wstring(PTY_TERM, context.temp_allocator),
    )
    win32.SetEnvironmentVariableW(
        win32.utf8_to_wstring("COLORTERM", context.temp_allocator),
        win32.utf8_to_wstring("truecolor", context.temp_allocator),
    )

    cmdline := win32.utf8_to_wstring(command_line(profile), context.temp_allocator)
    wdir: win32.wstring
    if cwd != "" {
        wdir = win32.utf8_to_wstring(cwd, context.temp_allocator)
    }

    // Not suspended: a client of a pseudo-console attaches to it while its own
    // libraries start, and a suspended one fails that with a DLL init error.
    flags := win32.DWORD(win32.EXTENDED_STARTUPINFO_PRESENT)
    ok := win32.CreateProcessW(
        nil,
        cmdline,
        nil,
        nil,
        false,
        flags,
        nil,
        wdir,
        cast(^win32.STARTUPINFOW) &si,
        &pi,
    )
    if !ok {
        DeleteProcThreadAttributeList(raw_data(attribute))
        delete(attribute)
        ClosePseudoConsole(console)
        win32.CloseHandle(in_write)
        win32.CloseHandle(out_read)
        return nil, false
    }

    pty := new(Pty)
    pty.process = pi.hProcess
    pty.thread = pi.hThread
    pty.console = console
    pty.input = in_write
    pty.output = out_read
    pty.attribute = attribute
    // A parent job without JOB_OBJECT_LIMIT_BREAKAWAY_OK refuses the assignment;
    // the job must go, or terminate hits an empty job and skips the fallback.
    pty.job = create_kill_on_close_job()
    if pty.job != nil && !AssignProcessToJobObject(pty.job, pi.hProcess) {
        win32.CloseHandle(pty.job)
        pty.job = nil
    }
    return pty, true
}

// The attribute list that names the pseudo-console to the new process. Its size
// is asked for first, which is why the call is expected to fail once. The
// pseudo-console attribute is the handle itself, not a pointer to it.
@(private = "file")
attribute_list :: proc(console: HPCON) -> ([]u8, bool) {
    size: win32.SIZE_T
    InitializeProcThreadAttributeList(nil, 1, 0, &size)
    if size == 0 {
        return nil, false
    }
    buffer := make([]u8, int(size))
    if !InitializeProcThreadAttributeList(raw_data(buffer), 1, 0, &size) {
        delete(buffer)
        return nil, false
    }
    if !UpdateProcThreadAttribute(
        raw_data(buffer),
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        rawptr(console),
        size_of(HPCON),
        nil,
        nil,
    ) {
        DeleteProcThreadAttributeList(raw_data(buffer))
        delete(buffer)
        return nil, false
    }
    return buffer, true
}

// Writes to the shell's input. The caller terminates lines itself.
pty_write :: proc(pty: ^Pty, data: string) -> bool {
    if pty == nil || pty.input == nil {
        return false
    }
    if len(data) == 0 {
        return true
    }
    bytes := transmute([]u8) data
    for sent := 0; sent < len(bytes); {
        written: win32.DWORD
        if !win32.WriteFile(
            pty.input,
            &bytes[sent],
            win32.DWORD(len(bytes) - sent),
            &written,
            nil,
        ) || written == 0 {
            return false
        }
        sent += int(written)
    }
    return true
}

// Blocks until the shell writes, and returns 0 at the end of the stream.
pty_read :: proc(pty: ^Pty, buf: []u8) -> int {
    if pty == nil || len(buf) == 0 {
        return 0
    }
    read: win32.DWORD
    if !win32.ReadFile(pty.output, &buf[0], win32.DWORD(len(buf)), &read, nil) {
        return 0
    }
    return int(read)
}

// Tells the console the grid changed, so the shell re-wraps and a full-screen
// program redraws.
pty_resize :: proc(pty: ^Pty, cols, rows: int) -> bool {
    if pty == nil || pty.console == nil {
        return false
    }
    cols, rows := pty_clamp_size(cols, rows)
    return ResizePseudoConsole(pty.console, {win32.SHORT(cols), win32.SHORT(rows)}) == 0
}

// Ends the shell and everything it started, so a reader blocked in pty_read
// comes back with 0. Safe to call while that reader runs.
pty_terminate :: proc(pty: ^Pty) {
    if pty == nil {
        return
    }
    // The job kill also reaches the grandchildren it holds; a process kill alone
    // does not, but it is what is left when the job itself refuses to die.
    if pty.job == nil || !TerminateJobObject(pty.job, 0) {
        win32.TerminateProcess(pty.process, 0)
    }
    // Closing the console ends the output pipe, which is what wakes the reader.
    // It waits for the client to go, so the kill above comes first.
    if pty.console != nil {
        ClosePseudoConsole(pty.console)
        pty.console = nil
    }
    if pty.input != nil {
        win32.CloseHandle(pty.input)
        pty.input = nil
    }
}

// Releases the handles and the record. Only legal once the reader is joined.
pty_destroy :: proc(pty: ^Pty) {
    if pty == nil {
        return
    }
    if pty.console != nil {
        ClosePseudoConsole(pty.console)
    }
    if pty.input != nil {
        win32.CloseHandle(pty.input)
    }
    win32.CloseHandle(pty.output)
    win32.CloseHandle(pty.thread)
    win32.CloseHandle(pty.process)
    if pty.job != nil {
        win32.CloseHandle(pty.job)
    }
    if pty.attribute != nil {
        DeleteProcThreadAttributeList(raw_data(pty.attribute))
        delete(pty.attribute)
    }
    free(pty)
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
