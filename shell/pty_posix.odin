#+build !windows
package shell

import "core:c"
import "core:strings"
import "core:sys/posix"

// The POSIX pseudo-terminal. The child leads its own session with the slave
// side as its controlling terminal, which is what makes ctrl + c a signal and
// job control work at all.

when ODIN_OS == .Darwin {
    foreign import libc "system:System"
} else {
    foreign import libc "system:c"
}

@(default_calling_convention = "c")
foreign libc {
    ioctl :: proc(fd: posix.FD, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

// The window-size and controlling-terminal requests are not POSIX, so their
// numbers come from each kernel's own header.
when ODIN_OS == .Linux {
    TIOCSWINSZ :: c.ulong(0x5414)
    TIOCSCTTY :: c.ulong(0x540e)
} else {
    TIOCSWINSZ :: c.ulong(0x80087467)
    TIOCSCTTY :: c.ulong(0x20007461)
}

@(private = "file")
Winsize :: struct {
    ws_row, ws_col:       u16,
    ws_xpixel, ws_ypixel: u16,
}

Pty :: struct {
    pid:    posix.pid_t, // owned, reaped by pty_destroy
    group:  posix.pid_t,
    master: posix.FD, // owned, -1 after pty_terminate closes it
}

// Starts `profile` in `cwd` on a pseudo-terminal of `cols` x `rows`.
pty_start :: proc(profile: Profile, cwd: string, cols, rows: int) -> (^Pty, bool) {
    cols, rows := pty_clamp_size(cols, rows)

    // Everything the child reads must exist before the fork: only
    // async-signal-safe calls are legal between fork and exec.
    argv := make([dynamic]cstring, 0, len(profile.args) + 2, context.temp_allocator)
    append(&argv, strings.clone_to_cstring(profile.exe, context.temp_allocator))
    for arg in profile.args {
        append(&argv, strings.clone_to_cstring(arg, context.temp_allocator))
    }
    append(&argv, nil)
    envp := child_environment(context.temp_allocator)
    cwd_c: cstring
    if cwd != "" {
        cwd_c = strings.clone_to_cstring(cwd, context.temp_allocator)
    }

    // A write to a shell that already exited must fail, not end the editor.
    posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)

    master := posix.posix_openpt({.RDWR, .NOCTTY})
    if master < 0 {
        return nil, false
    }
    if posix.grantpt(master) != .OK || posix.unlockpt(master) != .OK {
        posix.close(master)
        return nil, false
    }
    slave_name := posix.ptsname(master)
    if slave_name == nil {
        posix.close(master)
        return nil, false
    }
    // Cloned before the fork: ptsname returns a static buffer another thread
    // may overwrite.
    slave_path := strings.clone_to_cstring(string(slave_name), context.temp_allocator)

    size := Winsize {
        ws_row = u16(rows),
        ws_col = u16(cols),
    }
    ioctl(master, TIOCSWINSZ, &size)

    pid := posix.fork()
    if pid < 0 {
        posix.close(master)
        return nil, false
    }
    if pid == 0 {
        // A new session, then the slave as its controlling terminal: without
        // both, no signal from a keystroke reaches the command.
        posix.setsid()
        slave := posix.open(slave_path, {.RDWR})
        if slave < 0 {
            posix._exit(1)
        }
        ioctl(slave, TIOCSCTTY, 0)
        posix.dup2(slave, posix.STDIN_FILENO)
        posix.dup2(slave, posix.STDOUT_FILENO)
        posix.dup2(slave, posix.STDERR_FILENO)
        if slave > posix.STDERR_FILENO {
            posix.close(slave)
        }
        posix.close(master)
        // The parent ignores it so a write after the shell exits fails cleanly;
        // an exec preserves that disposition, so the shell must not inherit it.
        posix.signal(.SIGPIPE, auto_cast posix.SIG_DFL)
        if cwd_c != nil && posix.chdir(cwd_c) != .OK {
            posix._exit(1)
        }
        posix.execve(argv[0], raw_data(argv[:]), raw_data(envp))
        posix._exit(1) // execve only returns when it failed
    }

    pty := new(Pty)
    pty.pid = pid
    // setsid put the child in a group of its own, named by its own pid.
    pty.group = pid
    pty.master = master
    return pty, true
}

// The environment the shell starts in: this process's, with the two variables
// that say what terminal it is talking to.
@(private = "file")
child_environment :: proc(allocator := context.allocator) -> []cstring {
    out := make([dynamic]cstring, 0, 64, allocator)
    for i := 0; posix.environ[i] != nil; i += 1 {
        entry := string(posix.environ[i])
        if strings.has_prefix(entry, "TERM=") || strings.has_prefix(entry, "COLORTERM=") {
            continue
        }
        append(&out, strings.clone_to_cstring(entry, allocator))
    }
    append(&out, strings.clone_to_cstring(strings.concatenate({"TERM=", PTY_TERM}, allocator), allocator))
    append(&out, cstring("COLORTERM=truecolor"))
    append(&out, nil)
    return out[:]
}

// Writes to the shell's input. The caller terminates lines itself.
pty_write :: proc(pty: ^Pty, data: string) -> bool {
    if pty == nil || pty.master < 0 {
        return false
    }
    if len(data) == 0 {
        return true
    }
    bytes := transmute([]u8) data
    for sent := 0; sent < len(bytes); {
        rest := bytes[sent:]
        written := posix.write(pty.master, raw_data(rest), c.size_t(len(rest)))
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

// Blocks until the shell writes, and returns 0 at the end of the stream. A
// pseudo-terminal whose child is gone answers EIO, which is that end.
pty_read :: proc(pty: ^Pty, buf: []u8) -> int {
    if pty == nil || len(buf) == 0 {
        return 0
    }
    for {
        read := posix.read(pty.master, raw_data(buf), c.size_t(len(buf)))
        if read < 0 {
            if posix.errno() == .EINTR {
                continue
            }
            return 0
        }
        return int(read)
    }
}

// Tells the terminal the grid changed. The kernel sends SIGWINCH with it, which
// is how a full-screen program learns to redraw.
pty_resize :: proc(pty: ^Pty, cols, rows: int) -> bool {
    if pty == nil || pty.master < 0 {
        return false
    }
    cols, rows := pty_clamp_size(cols, rows)
    size := Winsize {
        ws_row = u16(rows),
        ws_col = u16(cols),
    }
    return ioctl(pty.master, TIOCSWINSZ, &size) == 0
}

// Ends the shell and everything it started, so a reader blocked in pty_read
// comes back with 0. Safe to call while that reader runs.
pty_terminate :: proc(pty: ^Pty) {
    if pty == nil {
        return
    }
    // The whole group, so a build the shell started dies with it instead of
    // holding the terminal open.
    if posix.killpg(pty.group, .SIGKILL) != .OK {
        posix.kill(pty.pid, .SIGKILL)
    }
    if pty.master >= 0 {
        posix.close(pty.master)
        pty.master = -1
    }
}

// Releases the descriptor and reaps the shell. Only legal once the reader is
// joined.
pty_destroy :: proc(pty: ^Pty) {
    if pty == nil {
        return
    }
    if pty.master >= 0 {
        posix.close(pty.master)
    }
    status: c.int
    for posix.waitpid(pty.pid, &status, {}) < 0 && posix.errno() == .EINTR {
    }
    free(pty)
}
