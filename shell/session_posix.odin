#+build !windows
package shell

import "core:c"
import "core:strings"
import "core:sys/posix"

// A live shell. The child leads its own process group, so an interrupt reaches
// the command it runs without ending the shell itself.
Session :: struct {
    pid:      posix.pid_t,
    group:    posix.pid_t,
    stdin_w:  posix.FD,
    stdout_r: posix.FD,
}

// Starts `profile` in `cwd` with stdin, stdout and stderr piped. Both output
// streams share one pipe, so the terminal sees them interleaved as a console
// would. The init commands are not sent here; the caller does that, so it can
// drop their output.
session_start :: proc(profile: Profile, cwd: string) -> (^Session, bool) {
    // Everything the child reads must exist before the fork: only
    // async-signal-safe calls are legal between fork and exec.
    argv := make([dynamic]cstring, 0, len(profile.args) + 2, context.temp_allocator)
    append(&argv, strings.clone_to_cstring(profile.exe, context.temp_allocator))
    for arg in profile.args {
        append(&argv, strings.clone_to_cstring(arg, context.temp_allocator))
    }
    append(&argv, nil)
    cwd_c: cstring
    if cwd != "" {
        cwd_c = strings.clone_to_cstring(cwd, context.temp_allocator)
    }

    // A write to a shell that already exited must fail, not end the editor.
    posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

    in_fds, out_fds: [2]posix.FD
    if posix.pipe(&in_fds) != .OK {
        return nil, false
    }
    if posix.pipe(&out_fds) != .OK {
        posix.close(in_fds[0])
        posix.close(in_fds[1])
        return nil, false
    }

    pid := posix.fork()
    if pid < 0 {
        posix.close(in_fds[0])
        posix.close(in_fds[1])
        posix.close(out_fds[0])
        posix.close(out_fds[1])
        return nil, false
    }
    if pid == 0 {
        // Its own group: session_interrupt signals the group, which hits the
        // command in the foreground and leaves the shell running.
        posix.setpgid(0, 0)
        posix.dup2(in_fds[0], posix.STDIN_FILENO)
        posix.dup2(out_fds[1], posix.STDOUT_FILENO)
        posix.dup2(out_fds[1], posix.STDERR_FILENO)
        posix.close(in_fds[0])
        posix.close(in_fds[1])
        posix.close(out_fds[0])
        posix.close(out_fds[1])
        if cwd_c != nil && posix.chdir(cwd_c) != .OK {
            posix._exit(1)
        }
        posix.execv(argv[0], raw_data(argv[:]))
        posix._exit(1) // execv only returns when it failed
    }

    // The child owns the far ends now; the parent's copies must go so a read
    // sees the end of the stream when the shell exits.
    posix.close(in_fds[0])
    posix.close(out_fds[1])
    // Also set in the parent, since either side may run first.
    posix.setpgid(pid, pid)

    session := new(Session)
    session.pid = pid
    session.group = pid
    session.stdin_w = in_fds[1]
    session.stdout_r = out_fds[0]
    return session, true
}

// Writes to the shell's stdin. The caller terminates lines itself.
session_write :: proc(session: ^Session, text: string) -> bool {
    if session == nil || session.stdin_w < 0 {
        return false
    }
    if len(text) == 0 {
        return true
    }
    data := transmute([]u8) text
    for sent := 0; sent < len(data); {
        rest := data[sent:]
        written := posix.write(session.stdin_w, raw_data(rest), c.size_t(len(rest)))
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

// Blocks until the shell writes, and returns 0 at the end of the stream.
session_read :: proc(session: ^Session, buf: []u8) -> int {
    if session == nil || len(buf) == 0 {
        return 0
    }
    for {
        read := posix.read(session.stdout_r, raw_data(buf), c.size_t(len(buf)))
        if read < 0 {
            if posix.errno() == .EINTR {
                continue
            }
            return 0
        }
        return int(read)
    }
}

// Interrupts the running command the way Ctrl+C does, leaving the shell alive.
session_interrupt :: proc(session: ^Session) -> bool {
    if session == nil {
        return false
    }
    return posix.killpg(session.group, .SIGINT) == .OK
}

// Ends the shell and everything it started, so a reader blocked in session_read
// comes back with 0. Safe to call while that reader runs.
session_terminate :: proc(session: ^Session) {
    if session == nil {
        return
    }
    if session.stdin_w >= 0 {
        posix.close(session.stdin_w)
        session.stdin_w = -1
    }
    // The whole group, so a build the shell started dies with it instead of
    // holding the output pipe open.
    if posix.killpg(session.group, .SIGKILL) != .OK {
        posix.kill(session.pid, .SIGKILL)
    }
}

// Releases the descriptors and the session. Only legal once the reader is
// joined.
session_destroy :: proc(session: ^Session) {
    if session == nil {
        return
    }
    if session.stdin_w >= 0 {
        posix.close(session.stdin_w)
    }
    posix.close(session.stdout_r)
    // The wait reaps the shell; a failure leaves it to init.
    status: c.int
    for posix.waitpid(session.pid, &status, {}) < 0 && posix.errno() == .EINTR {
    }
    free(session)
}
