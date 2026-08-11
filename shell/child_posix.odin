#+build !windows
package shell

import "core:c"
import "core:strings"
import "core:sys/posix"

// A child process on three pipes. It leads its own process group, so a kill
// reaches everything it started instead of leaving a grandchild holding an output
// pipe open.
Child :: struct {
    pid:      posix.pid_t, // owned, reaped by child_alive or child_destroy
    group:    posix.pid_t,
    stdin_w:  posix.FD, // owned, -1 once closed
    stdout_r: posix.FD, // owned
    stderr_r: posix.FD, // owned
    reaped:   bool,     // the wait already ran, so child_destroy must not block on it
}

// Starts `spec` with stdin, stdout and stderr on three separate pipes.
child_start :: proc(spec: Child_Spec) -> (^Child, bool) {
    // Everything the child reads must exist before the fork: only
    // async-signal-safe calls are legal between fork and exec, which also rules
    // out setenv there — hence execve with a whole environment built here.
    argv := make([dynamic]cstring, 0, len(spec.args) + 2, context.temp_allocator)
    append(&argv, strings.clone_to_cstring(spec.exe, context.temp_allocator))
    for arg in spec.args {
        append(&argv, strings.clone_to_cstring(arg, context.temp_allocator))
    }
    append(&argv, nil)
    envp := environment_of(spec.env, context.temp_allocator)
    cwd_c: cstring
    if spec.cwd != "" {
        cwd_c = strings.clone_to_cstring(spec.cwd, context.temp_allocator)
    }

    // A write to a child that already exited must fail, not end the editor.
    posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

    in_fds, out_fds, err_fds, status_fds: [2]posix.FD
    if posix.pipe(&out_fds) != .OK {
        return nil, false
    }
    if posix.pipe(&err_fds) != .OK {
        close_fds(out_fds[0], out_fds[1])
        return nil, false
    }
    if posix.pipe(&in_fds) != .OK {
        close_fds(out_fds[0], out_fds[1], err_fds[0], err_fds[1])
        return nil, false
    }
    // A fork cannot report a failed exec, so the child sends its errno over this
    // pipe and a successful exec closes it instead. Without it a missing
    // executable would read as a server that started and died at once.
    if posix.pipe(&status_fds) != .OK {
        close_fds(out_fds[0], out_fds[1], err_fds[0], err_fds[1], in_fds[0], in_fds[1])
        return nil, false
    }

    pid := posix.fork()
    if pid < 0 {
        close_fds(out_fds[0], out_fds[1], err_fds[0], err_fds[1], in_fds[0], in_fds[1])
        close_fds(status_fds[0], status_fds[1])
        return nil, false
    }
    if pid == 0 {
        // Its own group, so a kill reaches the whole tree.
        posix.setpgid(0, 0)
        posix.dup2(in_fds[0], posix.STDIN_FILENO)
        posix.dup2(out_fds[1], posix.STDOUT_FILENO)
        posix.dup2(err_fds[1], posix.STDERR_FILENO)
        posix.close(in_fds[0])
        posix.close(in_fds[1])
        posix.close(out_fds[0])
        posix.close(out_fds[1])
        posix.close(err_fds[0])
        posix.close(err_fds[1])
        posix.close(status_fds[0])
        // Closed by a successful exec, which is how the parent reads success.
        // A failure here would leave it open across a successful exec too,
        // hanging start_succeeded's read instead of ending it with success.
        if posix.fcntl(status_fds[1], .SETFD, posix.FD_CLOEXEC) < 0 {
            report_start_failure(status_fds[1])
        }
        // The parent ignores it so a write after the child exits fails cleanly;
        // an exec preserves that disposition, so the child itself must not inherit it.
        posix.signal(.SIGPIPE, auto_cast posix.SIG_DFL)
        if cwd_c != nil && posix.chdir(cwd_c) != .OK {
            report_start_failure(status_fds[1])
        }
        posix.execve(argv[0], raw_data(argv[:]), raw_data(envp))
        report_start_failure(status_fds[1]) // execve only returns when it failed
    }

    // The child owns the far ends now; the parent's copies must go so a read sees
    // the end of a stream when the child exits.
    close_fds(in_fds[0], out_fds[1], err_fds[1], status_fds[1])
    // Also set in the parent, since either side may run first.
    posix.setpgid(pid, pid)

    // Blocks only until the exec settles. A byte means it failed, and the child
    // is already gone, so it is reaped here rather than left as a zombie.
    started := start_succeeded(status_fds[0])
    posix.close(status_fds[0])
    if !started {
        close_fds(in_fds[1], out_fds[0], err_fds[0])
        status: c.int
        for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {
        }
        return nil, false
    }

    child := new(Child)
    child.pid = pid
    child.group = pid
    child.stdin_w = in_fds[1]
    child.stdout_r = out_fds[0]
    child.stderr_r = err_fds[0]
    return child, true
}

// Writes to the child's stdin.
child_write :: proc(child: ^Child, bytes: []u8) -> bool {
    if child == nil || child.stdin_w < 0 {
        return false
    }
    if len(bytes) == 0 {
        return true
    }
    for sent := 0; sent < len(bytes); {
        rest := bytes[sent:]
        written := posix.write(child.stdin_w, raw_data(rest), c.size_t(len(rest)))
        if written < 0 {
            if posix.errno() == .EINTR {
                continue
            }
            return false
        }
        if written == 0 {
            return false
        }
        sent += int(written)
    }
    return true
}

// Blocks until the child writes to stdout, and returns 0 at the end of the stream.
child_read_out :: proc(child: ^Child, buf: []u8) -> int {
    return child == nil ? 0 : read_fd(child.stdout_r, buf)
}

// Blocks until the child writes to stderr, and returns 0 at the end of the stream.
child_read_err :: proc(child: ^Child, buf: []u8) -> int {
    return child == nil ? 0 : read_fd(child.stderr_r, buf)
}

// Signals the end of input without ending the process, so a filter finishes and
// a server that exits on a closed stdin does so on its own.
child_close_in :: proc(child: ^Child) {
    if child == nil || child.stdin_w < 0 {
        return
    }
    posix.close(child.stdin_w)
    child.stdin_w = -1
}

// Whether the process still runs. The wait is what makes the answer true: a
// kill(pid, 0) reaches a zombie too, so it would report a child that has already
// exited as live. A wait that reaps latches, since only one wait can.
child_alive :: proc(child: ^Child) -> bool {
    if child == nil {
        return false
    }
    if child.reaped {
        return false
    }
    status: c.int
    reaped := posix.waitpid(child.pid, &status, {.NOHANG})
    if reaped == child.pid {
        child.reaped = true
        return false
    }
    // A failed wait means no such child, which is not a live one either.
    return reaped == 0
}

// Ends the process and everything it started, so a reader blocked in a read comes
// back with 0. Safe to call while those readers run.
child_terminate :: proc(child: ^Child) {
    if child == nil {
        return
    }
    child_close_in(child)
    // The whole group, so a process the child started dies with it instead of
    // holding an output pipe open.
    if posix.killpg(child.group, .SIGKILL) != .OK {
        posix.kill(child.pid, .SIGKILL)
    }
}

// Releases the descriptors and the child. Only legal once both readers are joined.
child_destroy :: proc(child: ^Child) {
    if child == nil {
        return
    }
    close_fds(child.stdin_w, child.stdout_r, child.stderr_r)
    // The wait reaps the child; a failure leaves it to init.
    if !child.reaped {
        status: c.int
        for posix.waitpid(child.pid, &status, {}) < 0 && posix.errno() == .EINTR {
        }
    }
    free(child)
}

// Tells the parent the exec never happened and ends the forked child. Only
// async-signal-safe calls, since this runs between fork and exec.
@(private = "file")
report_start_failure :: proc(status_w: posix.FD) -> ! {
    code := u8(posix.errno())
    posix.write(status_w, &code, 1)
    posix._exit(1)
}

// Whether the exec went through: a successful one closes the write end, so the
// read ends at once with nothing. A byte is the errno the child could not use.
@(private = "file")
start_succeeded :: proc(status_r: posix.FD) -> bool {
    code: u8
    for {
        read := posix.read(status_r, &code, 1)
        if read < 0 && posix.errno() == .EINTR {
            continue
        }
        return read <= 0
    }
}

@(private = "file")
read_fd :: proc(fd: posix.FD, buf: []u8) -> int {
    if len(buf) == 0 {
        return 0
    }
    for {
        read := posix.read(fd, raw_data(buf), c.size_t(len(buf)))
        if read < 0 {
            if posix.errno() == .EINTR {
                continue
            }
            return 0
        }
        return int(read)
    }
}

@(private = "file")
close_fds :: proc(fds: ..posix.FD) {
    for fd in fds {
        if fd >= 0 {
            posix.close(fd)
        }
    }
}

// The parent's environment with `overlay` applied, NUL-terminated for execve.
// Names are matched exactly, which is how POSIX compares them.
@(private = "file")
environment_of :: proc(overlay: []string, allocator := context.allocator) -> []cstring {
    envp := make([dynamic]cstring, allocator)
    if len(overlay) == 0 {
        // Inheriting is passing the parent's own block through.
        for index := 0; posix.environ[index] != nil; index += 1 {
            append(&envp, posix.environ[index])
        }
        append(&envp, nil)
        return envp[:]
    }
    for index := 0; posix.environ[index] != nil; index += 1 {
        entry := string(posix.environ[index])
        // An entry the overlay names is dropped here and written below.
        if overlay_has(overlay, environment_name(entry)) {
            continue
        }
        append(&envp, posix.environ[index])
    }
    for entry in overlay {
        append(&envp, strings.clone_to_cstring(entry, allocator))
    }
    append(&envp, nil)
    return envp[:]
}

@(private = "file")
overlay_has :: proc(overlay: []string, name: string) -> bool {
    if name == "" {
        return false
    }
    for entry in overlay {
        if environment_name(entry) == name {
            return true
        }
    }
    return false
}
