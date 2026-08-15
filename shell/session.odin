package shell

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// A shell process kept alive with its streams piped, so one terminal runs many
// commands in one shell: a `cd` sticks and a loaded environment stays loaded.
// `run` is the one-shot counterpart.
//
// Each platform file supplies:
//
//     Session           :: struct { ... }
//     session_start     :: proc(profile: Profile, cwd: string) -> (^Session, bool)
//     session_write     :: proc(session: ^Session, text: string) -> bool
//     session_read      :: proc(session: ^Session, buf: []u8) -> int
//     session_interrupt :: proc(session: ^Session) -> bool
//     session_terminate :: proc(session: ^Session)
//     session_destroy   :: proc(session: ^Session)
//
// session_read blocks until the shell writes and returns 0 at the end of the
// stream, so it belongs on a reader thread. Shutdown is two steps:
// session_terminate kills the shell and is safe to call while the reader blocks,
// session_destroy releases the handles only after the reader is joined.
//
// session_interrupt reports false where the platform cannot signal a running
// command without a pseudo-terminal; the caller then restarts the session.

// A token no command output realistically carries, since a shell only prints it
// when the terminal asks. The time makes a second terminal (and a file that
// happens to quote an earlier one) collide with nothing.
end_token :: proc(id: int, allocator := context.allocator) -> string {
    return fmt.aprintf("__THOR_END_%d_%d__", id, time.now()._nsec, allocator = allocator)
}

// Splits `text` at the first complete end-marker line. `before` is the output
// that came ahead of it, `code` the exit status the marker carries, and `rest`
// everything after the marker's line. found is false while the marker is absent
// or its line has not arrived whole, in which case `rest` is all of `text`.
scan_end_marker :: proc(text: string, token: string) -> (before: string, code: int, rest: string, found: bool) {
    at := strings.index(text, token)
    if at < 0 {
        return "", 0, text, false
    }

    tail := text[at + len(token):]
    newline := strings.index_byte(tail, '\n')
    if newline < 0 {
        return "", 0, text, false
    }

    // The marker is written by this process, so the tail is a number for every
    // shipped profile. A tail without digits is a profile whose status expansion
    // did not run: report it as a failure, never as the 0 that reads as success.
    parsed, ok := strconv.parse_int(strings.trim_space(tail[:newline]))
    if !ok {
        parsed = -1
    }
    return trim_prompt_tail(text[:at]), parsed, tail[newline + 1:], true
}

// Length of the suffix of `text` that could still grow into `token`. Everything
// before it is safe to show at once, so a command that prompts without a newline
// is not held back until the next chunk.
partial_marker_len :: proc(text, token: string) -> int {
    n := min(len(token) - 1, len(text))
    for k := n; k > 0; k -= 1 {
        if text[len(text) - k:] == token[:k] {
            return k
        }
    }
    return 0
}

// Drops a run of blanks that follows the last newline. cmd.exe writes its prompt
// right before it reads the end-marker command, and that fragment is not output.
// Text that does not end in blanks-after-a-newline is returned whole, so a
// command whose last line has no newline keeps it.
trim_prompt_tail :: proc(text: string) -> string {
    end := len(text)
    for end > 0 && (text[end - 1] == ' ' || text[end - 1] == '\t' || text[end - 1] == '\r') {
        end -= 1
    }
    if end > 0 && text[end - 1] != '\n' {
        return text
    }
    return text[:end]
}
