package thor

import "core:os"
import "core:strings"
import "core:testing"

// The launch argument decides what opens: a folder becomes the workspace, "."
// the launch directory, a file opens with its folder as the workspace, and a
// path that does not exist falls back to the launch directory.
// Run from the repository root: odin test thor
@(test)
test_startup_target :: proc(t: ^testing.T) {
    cwd, cwd_err := os.get_working_directory(context.temp_allocator)
    testing.expect(t, cwd_err == nil, "could not read the working directory")

    dot_ws, dot_file := thor_startup_target(".")
    defer delete(dot_ws)
    testing.expect(t, strings.equal_fold(dot_ws, cwd), "\".\" must open the launch directory")
    testing.expect_value(t, dot_file, "")

    TEST_PATH :: "thor_startup.tmp"
    write_err := os.write_entire_file(TEST_PATH, transmute([]u8) string("x"))
    testing.expect(t, write_err == nil, "could not create test file")
    defer os.remove(TEST_PATH)

    file_ws, file_path := thor_startup_target(TEST_PATH)
    defer delete(file_ws)
    defer delete(file_path)
    testing.expect(t, strings.equal_fold(file_ws, cwd), "a file argument must open its folder as the workspace")
    testing.expect(t, strings.has_suffix(file_path, TEST_PATH), "a file argument must be opened as a tab")

    missing_ws, missing_file := thor_startup_target("thor_does_not_exist_xyz")
    defer delete(missing_ws)
    testing.expect(t, strings.equal_fold(missing_ws, cwd), "a missing path must fall back to the launch directory")
    testing.expect_value(t, missing_file, "")
}
