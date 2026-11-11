#+build darwin, freebsd, openbsd, netbsd
package shell

import "core:sys/posix"

// Opens a pipe with both ends close-on-exec. A fork on another thread between
// the two calls can copy an end, which close_inherited in that child undoes.
@(private)
pipe_cloexec :: proc(fds: ^[2]posix.FD) -> bool {
    if posix.pipe(fds) != .OK {
        return false
    }
    if posix.fcntl(fds[0], .SETFD, posix.FD_CLOEXEC) < 0 || posix.fcntl(fds[1], .SETFD, posix.FD_CLOEXEC) < 0 {
        close_fds(fds[0], fds[1])
        return false
    }
    return true
}

// Closes every descriptor from 3 up except `keep` (-1 keeps none). Runs in a
// forked child, so only async-signal-safe calls; `limit` is fd_limit of the parent.
@(private)
close_inherited :: proc "contextless"(keep: int, limit: int) {
    close_each(3, limit, keep)
}
