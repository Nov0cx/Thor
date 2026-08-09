package thor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// thor_recent_workspaces / thor_record_recent_workspace persist to
// sessions/recent.json, the same file a real run uses, so the test backs up
// and restores whatever is there and only ever records folders it created
// itself. Run from the repository root: odin test thor
@(test)
test_recent_workspaces :: proc(t: ^testing.T) {
    backup, backup_err := os.read_entire_file(RECENT_WORKSPACES_FILE, context.temp_allocator)
    had_backup := backup_err == nil
    defer {
        if had_backup {
            _ = os.write_entire_file(RECENT_WORKSPACES_FILE, backup)
        } else {
            os.remove(RECENT_WORKSPACES_FILE)
        }
    }

    dir_a := "thor_recent_test_a"
    dir_b := "thor_recent_test_b"
    testing.expect(t, os.make_directory(dir_a) == nil, "could not create test dir")
    testing.expect(t, os.make_directory(dir_b) == nil, "could not create test dir")
    defer os.remove(dir_a)
    defer os.remove(dir_b)

    thor_record_recent_workspace(dir_a)
    thor_record_recent_workspace(dir_b)
    order := thor_recent_workspaces(context.temp_allocator)
    testing.expect(t, len(order) >= 2, "expected at least two recorded workspaces")
    testing.expect(t, strings.equal_fold(order[0], dir_b), "most recently recorded must lead")
    testing.expect(t, strings.equal_fold(order[1], dir_a), "second most recent must follow")

    // Re-recording an existing entry moves it to the front instead of duplicating it.
    thor_record_recent_workspace(dir_a)
    deduped := thor_recent_workspaces(context.temp_allocator)
    testing.expect(t, strings.equal_fold(deduped[0], dir_a), "re-recorded entry must move to the front")
    dup_count := 0
    for p in deduped {
        if strings.equal_fold(p, dir_a) {
            dup_count += 1
        }
    }
    testing.expect_value(t, dup_count, 1)

    // A folder that no longer exists is dropped from the list.
    os.remove(dir_b)
    pruned := thor_recent_workspaces(context.temp_allocator)
    for p in pruned {
        testing.expect(t, !strings.equal_fold(p, dir_b), "a deleted folder must not be listed")
    }

    // The list never grows past the cap.
    cap_dirs: [RECENT_WORKSPACES_MAX + 1]string
    for i in 0 ..< len(cap_dirs) {
        cap_dirs[i] = fmt.tprintf("thor_recent_test_cap_%d", i)
        testing.expect(t, os.make_directory(cap_dirs[i]) == nil, "could not create test dir")
        thor_record_recent_workspace(cap_dirs[i])
    }
    defer for dir in cap_dirs {
        os.remove(dir)
    }
    capped := thor_recent_workspaces(context.temp_allocator)
    testing.expect(t, len(capped) <= RECENT_WORKSPACES_MAX, "recent workspaces must stay capped")
    testing.expect(
        t,
        strings.equal_fold(capped[0], cap_dirs[len(cap_dirs) - 1]),
        "the most recently recorded folder must still lead",
    )
}
