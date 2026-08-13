#+build !windows
package shell

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// Run from the repository root: odin test shell

// A directory of its own under the system temporary directory. TMPDIR is unset on
// the CI runners, where /tmp is what it names.
@(private = "file")
temp_dir :: proc(name: string) -> string {
    base := os.get_env("TMPDIR", context.temp_allocator)
    if base == "" {
        base = "/tmp"
    }
    path, err := filepath.join(
        {strings.trim_right(base, "/"), fmt.tprintf("%s_%d", name, os.get_pid())},
        context.temp_allocator,
    )
    if err != nil {
        return ""
    }
    return path
}

// The timeout kills the process group, not the shell alone: a command that leaves
// a child in the background must not outlive the call. The child writes its
// marker a second after the kill, so a marker on disk is the leak.
@(test)
test_run_timeout_kills_the_background_child :: proc(t: ^testing.T) {
    root := temp_dir("thor_shell_group")
    if root == "" {
        testing.fail_now(t, "could not name a temporary directory")
    }
    if err := os.make_directory(root); err != nil && !os.is_dir(root) {
        testing.fail_now(t, fmt.tprintf("could not create %q: %v", root, err))
    }
    defer os.remove(root)

    // Named relative to the working directory the command runs in, so the test
    // carries no absolute path of its own.
    marker, join_err := filepath.join({root, "late"}, context.temp_allocator)
    if join_err != nil {
        testing.fail_now(t, "could not name the marker")
    }
    os.remove(marker)
    defer os.remove(marker)

    output := run("(sleep 1; echo done > late) & sleep 20", root, 200 * time.Millisecond)
    defer delete(output)
    testing.expect(t, strings.contains(output, "[shell] command stopped"), "the command was not stopped")

    // Past when the background child would have written, had it survived.
    time.sleep(2 * time.Second)
    testing.expect(t, !os.exists(marker), "a background child outlived the timeout")
}
