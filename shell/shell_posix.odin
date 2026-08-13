#+build !windows
package shell

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// Runs `command` under /bin/sh in `cwd` with stdout+stderr piped; blocks until it
// exits. A `timeout` above zero kills the command when that time passes and
// marks the output. The kill reaches the shell only, so a command that puts a
// child in the background leaves it running. `ok` is false when the command
// never ran to completion — a pipe or start failure, a failed wait, or a
// timeout — and only then is `code` meaningless. The returned output is owned by
// context.allocator.
run_status :: proc(command: string, cwd: string, timeout: time.Duration = 0) -> (output: string, code: int, ok: bool) {
    read_pipe, write_pipe, pipe_err := os.pipe()
    if pipe_err != nil {
        return strings.clone("[shell] could not create pipe\n"), -1, false
    }
    defer os.close(read_pipe)

    argv := [?]string {"/bin/sh", "-c", command}
    // Both streams share the write end, so the output keeps its interleaving.
    process, start_err := os.process_start(
        {working_dir = cwd, command = argv[:], stdout = write_pipe, stderr = write_pipe},
    )
    // Close the parent's copy of the write end so the read sees EOF when the
    // child (the only remaining writer) exits.
    os.close(write_pipe)
    if start_err != nil {
        return strings.clone("[shell] could not start command\n"), -1, false
    }

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
            fds := [1]posix.pollfd{{fd = posix.FD(os.fd(read_pipe)), events = {.IN}}}
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
        read, read_err := os.read(read_pipe, buf[:])
        if read_err != nil || read <= 0 {
            break
        }
        strings.write_bytes(&builder, buf[:read])
    }

    if timeout <= 0 {
        // The wait also reaps the child; a failure leaves it to init.
        state, wait_err := os.process_wait(process)
        if wait_err != nil {
            strings.write_string(&builder, "[shell] could not wait for the command\n")
            return strings.to_string(builder), -1, false
        }
        return strings.to_string(builder), state.exit_code, true
    }

    // The end of the stream does not prove the command exited: it can close its
    // output and keep running. Give it only the time it has left.
    if !timed_out {
        state, wait_err := os.process_wait(process, max(timeout - time.tick_since(start), time.Duration(1)))
        if wait_err == nil {
            return strings.to_string(builder), state.exit_code, true
        }
        timed_out = true
    }
    if kill_err := os.process_kill(process); kill_err != nil {
        strings.write_string(&builder, "[shell] could not stop the command\n")
    }
    // A killed child is still unreaped, so this wait collects it.
    if _, wait_err := os.process_wait(process); wait_err != nil {
        strings.write_string(&builder, "[shell] could not wait for the command\n")
    }
    fmt.sbprintf(&builder, "[shell] command stopped after %v\n", timeout)
    return strings.to_string(builder), -1, false
}

// Starts `exe` with one argument and leaves it running: no pipes, no wait. The
// counterpart to `run` for a process that outlives the call — a second editor
// window. The child forks a second time so init adopts the window, which keeps
// the editor from having to reap a process it no longer tracks. Returns whether
// the process started.
spawn :: proc(exe: string, arg: string, cwd: string) -> bool {
    // Everything the child reads must exist before the fork: only
    // async-signal-safe calls are legal between fork and exec.
    exe_c := strings.clone_to_cstring(exe, context.temp_allocator)
    arg_c := strings.clone_to_cstring(arg, context.temp_allocator)
    cwd_c: cstring
    if cwd != "" {
        cwd_c = strings.clone_to_cstring(cwd, context.temp_allocator)
    }
    argv := [?]cstring {exe_c, arg_c, nil}

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
