#+build !windows
package shell

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"

// How long a bounded wait sleeps between two attempts to reap the shell.
@(private = "file")
REAP_INTERVAL :: 2 * time.Millisecond

// Runs `command` under /bin/sh in `cwd` with stdout+stderr piped; blocks until it
// exits. The shell leads its own process group, so a timeout ends everything it
// started instead of leaving a backgrounded child running. A `timeout` above zero
// kills the command when that time passes and marks the output. `ok` is false
// when the command never ran to completion — a pipe or start failure, a failed
// wait, or a timeout — and only then is `code` meaningless. The returned output
// is owned by context.allocator.
run_status :: proc(command: string, cwd: string, timeout: time.Duration = 0) -> (output: string, code: int, ok: bool) {
    // Everything the child reads must exist before the fork: only
    // async-signal-safe calls are legal between fork and exec.
    command_c := strings.clone_to_cstring(command, context.temp_allocator)
    cwd_c: cstring
    if cwd != "" {
        cwd_c = strings.clone_to_cstring(cwd, context.temp_allocator)
    }
    argv := [?]cstring {"/bin/sh", "-c", command_c, nil}

    out_fds, status_fds: [2]posix.FD
    if posix.pipe(&out_fds) != .OK {
        return strings.clone("[shell] could not create pipe\n"), -1, false
    }
    // A fork cannot report a failed exec, so the child sends its errno over this
    // pipe and a successful exec closes it instead.
    if posix.pipe(&status_fds) != .OK {
        close_fds(out_fds[0], out_fds[1])
        return strings.clone("[shell] could not create pipe\n"), -1, false
    }

    pid := posix.fork()
    if pid < 0 {
        close_fds(out_fds[0], out_fds[1], status_fds[0], status_fds[1])
        return strings.clone("[shell] could not start command\n"), -1, false
    }
    if pid == 0 {
        // Its own group, so the kill reaches the whole tree the command started.
        posix.setpgid(0, 0)
        // No input: a command that prompts reads the end of the stream instead of
        // the editor's own stdin.
        null := posix.open("/dev/null", {.RDWR})
        if null < 0 {
            report_start_failure(status_fds[1])
        }
        posix.dup2(null, posix.STDIN_FILENO)
        // Both streams share the write end, so the output keeps its interleaving.
        posix.dup2(out_fds[1], posix.STDOUT_FILENO)
        posix.dup2(out_fds[1], posix.STDERR_FILENO)
        if null > posix.STDERR_FILENO {
            posix.close(null)
        }
        close_fds(out_fds[0], out_fds[1], status_fds[0])
        // Closed by a successful exec, which is how the parent reads success.
        if posix.fcntl(status_fds[1], .SETFD, posix.FD_CLOEXEC) < 0 {
            report_start_failure(status_fds[1])
        }
        // A terminal or a language server sets SIGPIPE to SIG_IGN for the whole
        // process and an exec keeps that, so a pipeline here must not inherit it.
        posix.signal(.SIGPIPE, auto_cast posix.SIG_DFL)
        if cwd_c != nil && posix.chdir(cwd_c) != .OK {
            report_start_failure(status_fds[1])
        }
        posix.execv(argv[0], raw_data(argv[:]))
        report_start_failure(status_fds[1]) // execv only returns when it failed
    }

    // The child owns the far ends now; the parent's copy of the write end must go
    // so the read sees the end of the stream when the child exits.
    close_fds(out_fds[1], status_fds[1])
    // Also set in the parent, since either side may run first.
    posix.setpgid(pid, pid)

    started := start_succeeded(status_fds[0])
    posix.close(status_fds[0])
    if !started {
        posix.close(out_fds[0])
        wait_for(pid)
        return strings.clone("[shell] could not start command\n"), -1, false
    }
    defer posix.close(out_fds[0])

    start := time.tick_now()
    timed_out := false
    builder := strings.builder_make()
    buf: [4096]u8
    for {
        // A read cannot be cut short, so a timed command waits on the pipe with
        // the time it has left instead.
        if timeout > 0 {
            left := timeout - time.tick_since(start)
            if left <= 0 {
                timed_out = true
                break
            }
            fds := [1]posix.pollfd{{fd = out_fds[0], events = {.IN}}}
            ready := posix.poll(raw_data(fds[:]), 1, c.int(time.duration_milliseconds(left)))
            if ready < 0 {
                if posix.errno() == .EINTR {
                    continue
                }
                break
            }
            if ready == 0 {
                timed_out = true
                break
            }
        }
        read := read_fd(out_fds[0], buf[:])
        if read <= 0 {
            break
        }
        strings.write_bytes(&builder, buf[:read])
    }

    if timeout <= 0 {
        // The wait also reaps the child; a failure leaves it to init.
        status, waited := wait_for(pid)
        if !waited {
            strings.write_string(&builder, "[shell] could not wait for the command\n")
            return strings.to_string(builder), -1, false
        }
        return strings.to_string(builder), exit_status(status), true
    }

    // The end of the stream does not prove the command exited: it can close its
    // output and keep running. Give it only the time it has left.
    if !timed_out {
        left := max(timeout - time.tick_since(start), time.Duration(1))
        if status, waited := wait_until(pid, left); waited {
            return strings.to_string(builder), exit_status(status), true
        }
        timed_out = true
    }
    // The whole group, so a command that left a child in the background dies with
    // it. `pid` is the group and never the editor's own; a group that never formed
    // answers ESRCH and the single kill covers it.
    if posix.killpg(pid, .SIGKILL) != .OK && posix.kill(pid, .SIGKILL) != .OK {
        strings.write_string(&builder, "[shell] could not stop the command\n")
    }
    // A killed child is still unreaped, so this wait collects it.
    if _, waited := wait_for(pid); !waited {
        strings.write_string(&builder, "[shell] could not wait for the command\n")
    }
    fmt.sbprintf(&builder, "[shell] command stopped after %v\n", timeout)
    return strings.to_string(builder), -1, false
}

// Reaps `pid`. False when no status could be collected, which leaves the child to
// init.
@(private = "file")
wait_for :: proc(pid: posix.pid_t) -> (status: c.int, ok: bool) {
    for {
        if posix.waitpid(pid, &status, {}) == pid {
            return status, true
        }
        if posix.errno() == .EINTR {
            continue
        }
        return 0, false
    }
}

// Waits up to `left` for `pid` and reaps it. False also covers a failed wait,
// which the caller treats as a timeout — both end in the kill.
@(private = "file")
wait_until :: proc(pid: posix.pid_t, left: time.Duration) -> (status: c.int, ok: bool) {
    start := time.tick_now()
    for {
        reaped := posix.waitpid(pid, &status, {.NOHANG})
        if reaped == pid {
            return status, true
        }
        if reaped < 0 && posix.errno() != .EINTR {
            return 0, false
        }
        if time.tick_since(start) >= left {
            return 0, false
        }
        time.sleep(REAP_INTERVAL)
    }
}

// The status of a finished command: its exit status, or the signal that ended it.
@(private = "file")
exit_status :: proc(status: c.int) -> int {
    if posix.WIFEXITED(status) {
        return int(posix.WEXITSTATUS(status))
    }
    return int(posix.WTERMSIG(status))
}

// Starts `exe` with one argument and leaves it running: no pipes, no wait. The
// counterpart to `run` for a process that outlives the call — a second editor
// window. An empty `arg` is no argument at all, not an empty one, which a
// program that reads a path from it would take for the working directory. The
// child forks a second time so init adopts the window, which keeps the editor
// from having to reap a process it no longer tracks. Returns whether the
// process started.
spawn :: proc(exe: string, arg: string, cwd: string) -> bool {
    // Everything the child reads must exist before the fork: only
    // async-signal-safe calls are legal between fork and exec.
    exe_c := strings.clone_to_cstring(exe, context.temp_allocator)
    cwd_c: cstring
    if cwd != "" {
        cwd_c = strings.clone_to_cstring(cwd, context.temp_allocator)
    }
    argv := [3]cstring{exe_c, nil, nil}
    if arg != "" {
        argv[1] = strings.clone_to_cstring(arg, context.temp_allocator)
    }

    pid := posix.fork()
    if pid < 0 {
        return false
    }
    if pid == 0 {
        if posix.fork() == 0 {
            // Its own session: a Ctrl+C in a debug console stops here.
            posix.setsid()
            if cwd_c != nil && posix.chdir(cwd_c) != .OK {
                posix._exit(1)
            }
            posix.execv(exe_c, raw_data(argv[:]))
            posix._exit(1) // execv only returns when it failed
        }
        posix._exit(0)
    }

    // The intermediate child exits at once; reaping it here leaves no zombie.
    status: c.int
    for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {
    }
    return true
}
