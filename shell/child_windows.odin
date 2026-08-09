#+build windows
package shell

import "core:strings"
import win32 "core:sys/windows"

// A child process on three pipes. The job object holds it and everything it
// starts, so terminating it also ends the grandchildren that keep an output pipe
// open.
Child :: struct {
    process:  win32.HANDLE, // owned
    thread:   win32.HANDLE, // owned
    job:      win32.HANDLE, // owned, nil when the job could not be made or assigned
    stdin_w:  win32.HANDLE, // owned, nil once closed
    stdout_r: win32.HANDLE, // owned
    stderr_r: win32.HANDLE, // owned
}

// Starts `spec` with stdin, stdout and stderr on three separate pipes.
child_start :: proc(spec: Child_Spec) -> (^Child, bool) {
    sa := win32.SECURITY_ATTRIBUTES {
        nLength        = size_of(win32.SECURITY_ATTRIBUTES),
        bInheritHandle = true,
    }

    in_r, in_w, out_r, out_w, err_r, err_w: win32.HANDLE
    if !win32.CreatePipe(&out_r, &out_w, &sa, 0) {
        return nil, false
    }
    if !win32.CreatePipe(&err_r, &err_w, &sa, 0) {
        close_handles(out_r, out_w)
        return nil, false
    }
    if !win32.CreatePipe(&in_r, &in_w, &sa, 0) {
        close_handles(out_r, out_w, err_r, err_w)
        return nil, false
    }
    // The parent's ends stay with the parent; keep them out of the child. An end
    // that stays inheritable would reach a later child and hold the pipe open
    // after this process exits, so a failure here ends the start.
    if !win32.SetHandleInformation(out_r, win32.HANDLE_FLAG_INHERIT, 0) ||
       !win32.SetHandleInformation(err_r, win32.HANDLE_FLAG_INHERIT, 0) ||
       !win32.SetHandleInformation(in_w, win32.HANDLE_FLAG_INHERIT, 0) {
        close_handles(out_r, out_w, err_r, err_w, in_r, in_w)
        return nil, false
    }

    si := win32.STARTUPINFOW {
        cb         = size_of(win32.STARTUPINFOW),
        dwFlags    = win32.STARTF_USESTDHANDLES,
        hStdInput  = in_r,
        hStdOutput = out_w,
        hStdError  = err_w,
    }
    pi: win32.PROCESS_INFORMATION

    cmdline := win32.utf8_to_wstring(command_line_of(spec), context.temp_allocator)
    wdir: win32.wstring
    if spec.cwd != "" {
        wdir = win32.utf8_to_wstring(spec.cwd, context.temp_allocator)
    }

    // Suspended so the job owns the process before it can start a child of its own.
    flags := win32.DWORD(win32.CREATE_NO_WINDOW | win32.CREATE_SUSPENDED)
    environment: win32.LPVOID
    if len(spec.env) > 0 {
        block, block_ok := environment_block(spec.env, context.temp_allocator)
        if !block_ok {
            close_handles(out_r, out_w, err_r, err_w, in_r, in_w)
            return nil, false
        }
        environment = win32.LPVOID(raw_data(block))
        flags |= win32.CREATE_UNICODE_ENVIRONMENT
    }

    ok := win32.CreateProcessW(nil, cmdline, nil, nil, true, flags, environment, wdir, &si, &pi)
    // The child owns the far ends now; the parent's copies must go so a read sees
    // the end of a stream when the child exits.
    close_handles(out_w, err_w, in_r)
    if !ok {
        close_handles(out_r, err_r, in_w)
        return nil, false
    }

    child := new(Child)
    child.process = pi.hProcess
    child.thread = pi.hThread
    child.stdin_w = in_w
    child.stdout_r = out_r
    child.stderr_r = err_r
    // A parent job without JOB_OBJECT_LIMIT_BREAKAWAY_OK refuses the assignment;
    // the job must go, or terminate hits an empty job and skips the fallback.
    child.job = create_kill_on_close_job()
    if child.job != nil && !AssignProcessToJobObject(child.job, pi.hProcess) {
        win32.CloseHandle(child.job)
        child.job = nil
    }
    win32.ResumeThread(pi.hThread)
    return child, true
}

// Writes to the child's stdin.
child_write :: proc(child: ^Child, bytes: []u8) -> bool {
    if child == nil || child.stdin_w == nil {
        return false
    }
    if len(bytes) == 0 {
        return true
    }
    for sent := 0; sent < len(bytes); {
        written: win32.DWORD
        if !win32.WriteFile(child.stdin_w, &bytes[sent], win32.DWORD(len(bytes) - sent), &written, nil) ||
           written == 0 {
            return false
        }
        sent += int(written)
    }
    return true
}

// Blocks until the child writes to stdout, and returns 0 at the end of the stream.
child_read_out :: proc(child: ^Child, buf: []u8) -> int {
    return child == nil ? 0 : read_pipe(child.stdout_r, buf)
}

// Blocks until the child writes to stderr, and returns 0 at the end of the stream.
child_read_err :: proc(child: ^Child, buf: []u8) -> int {
    return child == nil ? 0 : read_pipe(child.stderr_r, buf)
}

// Signals the end of input without ending the process, so a filter finishes and
// a server that exits on a closed stdin does so on its own.
child_close_in :: proc(child: ^Child) {
    if child == nil || child.stdin_w == nil {
        return
    }
    win32.CloseHandle(child.stdin_w)
    child.stdin_w = nil
}

// Whether the process still runs.
child_alive :: proc(child: ^Child) -> bool {
    if child == nil {
        return false
    }
    return win32.WaitForSingleObject(child.process, 0) != win32.WAIT_OBJECT_0
}

// Ends the process and everything it started, so a reader blocked in a read comes
// back with 0. Safe to call while those readers run.
child_terminate :: proc(child: ^Child) {
    if child == nil {
        return
    }
    child_close_in(child)
    if child.job != nil {
        TerminateJobObject(child.job, 0)
    } else {
        win32.TerminateProcess(child.process, 0)
    }
}

// Releases the handles and the child. Only legal once both readers are joined.
child_destroy :: proc(child: ^Child) {
    if child == nil {
        return
    }
    close_handles(child.stdin_w, child.stdout_r, child.stderr_r, child.thread, child.process, child.job)
    free(child)
}

@(private = "file")
read_pipe :: proc(handle: win32.HANDLE, buf: []u8) -> int {
    if len(buf) == 0 {
        return 0
    }
    read: win32.DWORD
    if !win32.ReadFile(handle, &buf[0], win32.DWORD(len(buf)), &read, nil) {
        return 0
    }
    return int(read)
}

@(private = "file")
close_handles :: proc(handles: ..win32.HANDLE) {
    for handle in handles {
        if handle != nil {
            win32.CloseHandle(handle)
        }
    }
}

// The command line CreateProcessW parses. Quoting follows the rule the C runtime
// parses back: an argument that is empty or holds a space, tab or quote is
// quoted, and a run of backslashes is doubled where a quote follows it. A server
// argument like --query-driver=C:\x y\* needs that; the shell profiles do not,
// which is why session_windows.odin keeps a looser one of its own.
@(private = "file")
command_line_of :: proc(spec: Child_Spec) -> string {
    builder := strings.builder_make(context.temp_allocator)
    append_argument(&builder, spec.exe)
    for arg in spec.args {
        strings.write_byte(&builder, ' ')
        append_argument(&builder, arg)
    }
    return strings.to_string(builder)
}

@(private = "file")
append_argument :: proc(builder: ^strings.Builder, arg: string) {
    if arg != "" && !strings.contains_any(arg, " \t\"") {
        strings.write_string(builder, arg)
        return
    }
    strings.write_byte(builder, '"')
    backslashes := 0
    for index in 0 ..< len(arg) {
        switch arg[index] {
        case '\\':
            backslashes += 1
        case '"':
            // Each backslash ahead of the quote is doubled, and the quote itself
            // escaped, so the parser reads them as literals.
            for _ in 0 ..< backslashes + 1 {
                strings.write_byte(builder, '\\')
            }
            backslashes = 0
        case:
            backslashes = 0
        }
        strings.write_byte(builder, arg[index])
    }
    // A backslash run that ends the argument would escape the closing quote.
    for _ in 0 ..< backslashes {
        strings.write_byte(builder, '\\')
    }
    strings.write_byte(builder, '"')
}

// The parent's environment with `overlay` applied, as the double-NUL-terminated
// UTF-16 block CREATE_UNICODE_ENVIRONMENT wants. Names are matched without case,
// which is how Windows compares them.
@(private = "file")
environment_block :: proc(overlay: []string, allocator := context.allocator) -> ([]u16, bool) {
    parent := win32.GetEnvironmentStringsW()
    if parent == nil {
        return nil, false
    }
    defer win32.FreeEnvironmentStringsW(parent)

    block := make([dynamic]u16, allocator)
    // The block is a run of NUL-terminated entries closed by one more NUL.
    entry := ([^]u16)(parent)
    for entry[0] != 0 {
        length := 0
        for entry[length] != 0 {
            length += 1
        }
        text, err := win32.wstring_to_utf8(win32.wstring(entry), length, context.temp_allocator)
        entry = entry[length + 1:]
        if err != nil {
            continue
        }
        // An entry the overlay names is dropped here and written below. One that
        // starts with '=' is a drive's current directory and has no name to
        // match, so it is always kept.
        if len(text) > 0 && text[0] != '=' && overlay_has(overlay, environment_name(text)) {
            continue
        }
        if !append_wide(&block, text) {
            delete(block)
            return nil, false
        }
    }
    for text in overlay {
        if !append_wide(&block, text) {
            delete(block)
            return nil, false
        }
    }
    append(&block, u16(0)) // the block's own terminator, after the last entry's
    return block[:], true
}

@(private = "file")
append_wide :: proc(block: ^[dynamic]u16, text: string) -> bool {
    wide := win32.utf8_to_utf16(text, context.temp_allocator)
    if wide == nil && text != "" {
        return false
    }
    append(block, ..wide)
    append(block, u16(0))
    return true
}

@(private = "file")
overlay_has :: proc(overlay: []string, name: string) -> bool {
    if name == "" {
        return false
    }
    for entry in overlay {
        if strings.equal_fold(environment_name(entry), name) {
            return true
        }
    }
    return false
}
