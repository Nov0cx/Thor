package shell

import "core:strings"
import "core:testing"
import "core:time"

// Run from the repository root: odin test shell

// A command that never ends on its own. Windows has no `sleep`, and `timeout`
// wants a console it does not have here.
@(private = "file")
SLOW_COMMAND :: "ping -n 20 127.0.0.1" when ODIN_OS == .Windows else "sleep 20"

// The timeout is what keeps thor.exec from holding the frame: a command that
// outlives it is killed and the call comes back on time.
@(test)
test_run_timeout_stops_a_slow_command :: proc(t: ^testing.T) {
    start := time.tick_now()
    output := run(SLOW_COMMAND, ".", 300 * time.Millisecond)
    defer delete(output)

    elapsed := time.tick_since(start)
    testing.expectf(t, elapsed < 10 * time.Second, "the call took %v", elapsed)
    testing.expect(t, strings.contains(output, "[shell] command stopped"), "the output has no stop note")
}

// A command that finishes inside its timeout is not touched by it: the output
// is the command's alone.
@(test)
test_run_timeout_keeps_a_fast_command :: proc(t: ^testing.T) {
    output := run("echo thor", ".", 20 * time.Second)
    defer delete(output)

    testing.expect(t, strings.contains(output, "thor"), "the command's output is missing")
    testing.expect(t, !strings.contains(output, "[shell] command stopped"), "the command was stopped")
}

// Zero means no timeout, which every caller on a worker thread relies on.
@(test)
test_run_without_timeout_reads_to_the_end :: proc(t: ^testing.T) {
    output := run("echo thor", ".")
    defer delete(output)

    testing.expect(t, strings.contains(output, "thor"), "the command's output is missing")
}
