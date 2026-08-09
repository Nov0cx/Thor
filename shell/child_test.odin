package shell

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Run from the repository root: odin test shell

// A command that never ends on its own. Windows has no `sleep`, and `timeout`
// wants a console it does not have here. run_test.odin keeps its own copy,
// file-private there as here.
@(private = "file")
SLOW_COMMAND :: "ping -n 20 127.0.0.1" when ODIN_OS == .Windows else "sleep 20"

// How long a test waits for a killed process to be gone.
@(private = "file")
KILL_TIMEOUT :: 5 * time.Second

// The property the whole LSP transport rests on: a server's stderr log must not
// reach the frame parser. Shell profiles want the two streams merged; a server
// wants them apart.
@(test)
test_child_keeps_stderr_separate :: proc(t: ^testing.T) {
    command := "echo out & echo err 1>&2" when ODIN_OS == .Windows else "echo out; echo err 1>&2"
    child, ok := start_shell_child(command)
    if !testing.expect(t, ok, "the child did not start") {
        return
    }
    defer child_destroy(child)
    defer child_terminate(child)

    // Both are a few bytes, far inside one pipe's buffer, so draining them one
    // after the other cannot deadlock.
    out := read_stream(child, true)
    defer delete(out)
    err := read_stream(child, false)
    defer delete(err)

    testing.expectf(t, strings.contains(out, "out"), "stdout was %q", out)
    testing.expectf(t, !strings.contains(out, "err"), "stderr reached stdout: %q", out)
    testing.expectf(t, strings.contains(err, "err"), "stderr was %q", err)
    testing.expectf(t, !strings.contains(err, "out"), "stdout reached stderr: %q", err)
}

// What a request round trip needs: bytes written to stdin reach the process, and
// closing stdin ends its input without killing it.
@(test)
test_child_writes_stdin :: proc(t: ^testing.T) {
    filter := "sort" when ODIN_OS == .Windows else "cat"
    child, ok := start_shell_child(filter)
    if !testing.expect(t, ok, "the child did not start") {
        return
    }
    defer child_destroy(child)
    defer child_terminate(child)

    testing.expect(t, child_write(child, transmute([]u8) string("alpha\nbeta\n")), "the write failed")
    child_close_in(child)

    out := read_stream(child, true)
    defer delete(out)
    alpha := strings.index(out, "alpha")
    beta := strings.index(out, "beta")
    testing.expectf(t, alpha >= 0 && beta >= 0, "the input did not come back: %q", out)
    testing.expectf(t, alpha < beta, "the order was lost: %q", out)
}

// A server's environment overlay must reach it, since that is how a configured
// entry passes a flag no argument carries.
@(test)
test_child_env_overlay :: proc(t: ^testing.T) {
    command := "echo %THOR_CHILD_TEST%" when ODIN_OS == .Windows else "echo $THOR_CHILD_TEST"
    child, ok := start_shell_child(command, "", {"THOR_CHILD_TEST=marker"})
    if !testing.expect(t, ok, "the child did not start") {
        return
    }
    defer child_destroy(child)
    defer child_terminate(child)

    out := read_stream(child, true)
    defer delete(out)
    testing.expectf(t, strings.contains(out, "marker"), "the overlay did not reach the child: %q", out)
}

// An overlay replaces one name and leaves the rest of the environment alone, so a
// server still finds PATH and everything else it needs.
@(test)
test_child_env_overlay_keeps_the_parent :: proc(t: ^testing.T) {
    if os.get_env("PATH", context.temp_allocator) == "" {
        return
    }
    command := "echo [%PATH%]" when ODIN_OS == .Windows else "echo [$PATH]"
    child, ok := start_shell_child(command, "", {"THOR_CHILD_TEST=marker"})
    if !testing.expect(t, ok, "the child did not start") {
        return
    }
    defer child_destroy(child)
    defer child_terminate(child)

    out := read_stream(child, true)
    defer delete(out)
    testing.expectf(t, !strings.contains(out, "[]"), "PATH was lost: %q", out)
}

// The working directory decides what a server indexes, so it must be the one the
// spec names and not the editor's own.
@(test)
test_child_cwd :: proc(t: ^testing.T) {
    command := "cd" when ODIN_OS == .Windows else "pwd"
    child, ok := start_shell_child(command, "assets")
    if !testing.expect(t, ok, "the child did not start") {
        return
    }
    defer child_destroy(child)
    defer child_terminate(child)

    out := read_stream(child, true)
    defer delete(out)
    testing.expectf(t, strings.contains(out, "assets"), "the working directory was %q", out)
}

// A crashed or killed server must read as dead, or a restart never runs.
@(test)
test_child_alive_until_terminated :: proc(t: ^testing.T) {
    child, ok := start_shell_child(SLOW_COMMAND)
    if !testing.expect(t, ok, "the child did not start") {
        return
    }
    defer child_destroy(child)

    testing.expect(t, child_alive(child), "a running child read as dead")
    child_terminate(child)

    // The kill is not instant on either platform.
    start := time.tick_now()
    for child_alive(child) && time.tick_since(start) < KILL_TIMEOUT {
        time.sleep(10 * time.Millisecond)
    }
    testing.expect(t, !child_alive(child), "a killed child read as live")
}

// A program that is not there is a start that failed, on both platforms. A fork
// cannot fail, so the POSIX side has to carry the exec's errno back itself.
@(test)
test_child_start_rejects_a_missing_program :: proc(t: ^testing.T) {
    child, ok := child_start({exe = "thor-no-such-program-exists"})
    testing.expect(t, !ok, "a missing program started")
    testing.expect(t, child == nil, "a failed start left a child")
    if ok {
        child_terminate(child)
        child_destroy(child)
    }
}

// Runs `command` through the platform's shell. On Windows the arguments must
// reach cmd.exe unquoted, because it re-parses everything after /c itself — which
// is why each command here is split on spaces rather than passed whole.
@(private = "file")
start_shell_child :: proc(command: string, cwd := "", env: []string = nil) -> (^Child, bool) {
    when ODIN_OS == .Windows {
        args := make([dynamic]string, context.temp_allocator)
        append(&args, "/c")
        append(&args, ..strings.split(command, " ", context.temp_allocator))
        return child_start({exe = "cmd.exe", args = args[:], cwd = cwd, env = env})
    } else {
        return child_start({exe = "/bin/sh", args = {"-c", command}, cwd = cwd, env = env})
    }
}

// Everything one stream carries, to the end of it. The allocator owns the result.
@(private = "file")
read_stream :: proc(child: ^Child, stdout: bool) -> string {
    builder := strings.builder_make()
    buf: [1024]u8
    for {
        read := stdout ? child_read_out(child, buf[:]) : child_read_err(child, buf[:])
        if read <= 0 {
            break
        }
        strings.write_bytes(&builder, buf[:read])
    }
    return strings.to_string(builder)
}
