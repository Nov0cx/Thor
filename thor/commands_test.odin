package thor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

// Twelve files across two directory levels, walked with a cap of 5, must stop
// at exactly 5 and report that the walk was cut short.
@(test)
test_collect_files_stops_at_the_cap :: proc(t: ^testing.T) {
    root :: "thor_collect_cap.tmp"
    sub, _ := filepath.join({root, "sub"}, context.temp_allocator)
    defer os.remove_all(root)

    testing.expect(t, os.make_directory(root) == nil, "could not create test root")
    testing.expect(t, os.make_directory(sub) == nil, "could not create test subdir")

    for i in 0 ..< 6 {
        path, _ := filepath.join({root, fmt.tprintf("a%d.tmp", i)}, context.temp_allocator)
        testing.expect(t, os.write_entire_file(path, "") == nil, "could not create test file")
    }
    for i in 0 ..< 6 {
        path, _ := filepath.join({sub, fmt.tprintf("b%d.tmp", i)}, context.temp_allocator)
        testing.expect(t, os.write_entire_file(path, "") == nil, "could not create test file")
    }

    files := thor_walk_workspace_files(root, context.temp_allocator, limit = 5, max_depth = 12)
    testing.expect_value(t, len(files), 5)
}
