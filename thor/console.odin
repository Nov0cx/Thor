package thor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
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

// A source location parsed from a console line: the path slice plus 1-based
// line/col and the byte span of the clickable text within the line.
Console_Location :: struct {
    path:       string,
    line:       int,
    col:        int,
    span_start: int,
    span_end:   int,
}

// Parses a compiler/tool error line for a `PATH(LINE[:COL])` source location —
// the form odin, MSVC, and similar emit (the separator may be ':' or ','). The
// path must carry a file extension so an ordinary "(1:2)" run in prose does not
// match. Returns the location and whether one was found.
parse_console_location :: proc(raw: string) -> (Console_Location, bool) {
    line := strings.trim_right(raw, "\r")

    for i := 0; i < len(line); i += 1 {
        if line[i] != '(' {
            continue
        }
        // "(LINE" — at least one digit.
        j := i + 1
        ls := j
        for j < len(line) && line[j] >= '0' && line[j] <= '9' {
            j += 1
        }
        if j == ls {
            continue
        }
        lineno, _ := strconv.parse_int(line[ls:j])

        // Optional ":COL" / ",COL".
        colno := 0
        if j < len(line) && (line[j] == ':' || line[j] == ',') {
            k := j + 1
            cs := k
            for k < len(line) && line[k] >= '0' && line[k] <= '9' {
                k += 1
            }
            if k == cs {
                continue
            }
            colno, _ = strconv.parse_int(line[cs:k])
            j = k
        }

        if j >= len(line) || line[j] != ')' {
            continue
        }

        raw_path := line[:i]
        path := strings.trim_space(raw_path)
        if !path_has_extension(path) {
            continue
        }

        return Console_Location {
            path       = path,
            line       = lineno,
            col        = colno,
            span_start = leading_space_count(raw_path),
            span_end   = j + 1,
        }, true
    }
    return {}, false
}

// True when the basename of `path` has a short alphanumeric extension. Filters
// out prose so only real file references become clickable links.
@(private = "file")
path_has_extension :: proc(path: string) -> bool {
    base := path
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '/' || path[i] == '\\' {
            base = path[i + 1:]
            break
        }
    }
    dot := strings.last_index_byte(base, '.')
    if dot <= 0 || dot == len(base) - 1 {
        return false
    }
    ext := base[dot + 1:]
    if len(ext) > 8 {
        return false
    }
    for c in transmute([]u8) ext {
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
            return false
        }
    }
    return true
}

@(private = "file")
leading_space_count :: proc(s: string) -> int {
    n := 0
    for n < len(s) && (s[n] == ' ' || s[n] == '\t') {
        n += 1
    }
    return n
}

// Console_Link_Proc: reports the clickable span of a scrollback line that names
// an existing source file, for the hover underline.
thor_console_link :: proc(data: rawptr, line: string) -> (start: int, end: int, ok: bool) {
    thor := cast(^Thor) data
    loc, found := parse_console_location(line)
    if !found {
        return 0, 0, false
    }
    if !os.exists(thor_console_resolve_path(thor, loc.path)) {
        return 0, 0, false
    }
    return loc.span_start, loc.span_end, true
}

// Console_Activate_Proc: opens the source file named by a clicked scrollback
// line at its reported line/column.
thor_console_activate :: proc(data: rawptr, line: string) {
    thor := cast(^Thor) data
    loc, found := parse_console_location(line)
    if !found {
        return
    }
    abs := thor_console_resolve_path(thor, loc.path)
    if !os.exists(abs) {
        return
    }
    thor_goto_file_line_col(thor, abs, loc.line, max(loc.col, 1))
}

// Resolves a console-reported path against the workspace directory when it is
// relative (tool output prints paths relative to where the command ran).
@(private = "file")
thor_console_resolve_path :: proc(thor: ^Thor, path: string) -> string {
    if filepath.is_abs(path) {
        return path
    }
    joined, err := filepath.join({thor.workspace_dir, path}, context.temp_allocator)
    if err != nil {
        return path
    }
    return joined
}

// Runs `command` via cmd.exe with stdout+stderr piped; blocks until it exits.
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
