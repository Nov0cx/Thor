#+build linux
package shell

import "core:sys/linux"

// Opens a pipe with both ends close-on-exec in one call, so no fork on another
// thread can copy an end before the flag is set. `T` is posix.FD.
@(private)
pipe_cloexec :: proc(fds: ^[2]$T) -> bool {
    pipes: [2]linux.Fd
    if linux.pipe2(&pipes, {.CLOEXEC}) != .NONE {
        return false
    }
    fds[0] = T(pipes[0])
    fds[1] = T(pipes[1])
    return true
}

// Closes every descriptor from 3 up except `keep` (-1 keeps none). Runs in a
// forked child, so only async-signal-safe calls; `limit` is fd_limit of the parent.
@(private)
close_inherited :: proc "contextless"(keep: int, limit: int) {
    low := 3
    if keep >= 3 {
        if keep > 3 && linux.close_range(linux.Fd(low), linux.Fd(keep - 1), {}) != .NONE {
            close_each(low, keep, keep)
        }
        low = keep + 1
    }
    // close_range needs Linux 5.9.
    if linux.close_range(linux.Fd(low), linux.Fd(max(i32)), {}) != .NONE {
        close_each(low, limit, keep)
    }
}
