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

@(private = "file")
startup_targets_cleanup :: proc(workspace: string, files: [dynamic]string) {
    delete(workspace)
    for path in files {
        delete(path)
    }
    delete(files)
}

// Every file argument opens as a tab, in the order given, and the first folder
// is the workspace. A second folder is refused: one window holds one workspace.
@(test)
test_startup_targets_opens_every_file :: proc(t: ^testing.T) {
    cwd, cwd_err := os.get_working_directory(context.temp_allocator)
    testing.expect(t, cwd_err == nil, "could not read the working directory")

    FIRST :: "thor_startup_multi_a.tmp"
    SECOND :: "thor_startup_multi_b.tmp"
    for path in ([]string {FIRST, SECOND}) {
        testing.expect(t, os.write_entire_file(path, transmute([]u8) string("x")) == nil, "could not create test file")
    }
    defer os.remove(FIRST)
    defer os.remove(SECOND)

    // A folder first, then two files: the folder is the workspace and both files
    // open, the last one active.
    ws, files := thor_startup_targets({".", FIRST, SECOND})
    defer startup_targets_cleanup(ws, files)
    testing.expect(t, strings.equal_fold(ws, cwd), "the folder argument becomes the workspace")
    testing.expect_value(t, len(files), 2)
    testing.expect(t, strings.has_suffix(files[0], FIRST), "the files keep the order given")
    testing.expect(t, strings.has_suffix(files[1], SECOND), "the files keep the order given")

    // A file first still contributes its own tab, ahead of the rest.
    file_ws, file_files := thor_startup_targets({FIRST, SECOND})
    defer startup_targets_cleanup(file_ws, file_files)
    testing.expect(t, strings.equal_fold(file_ws, cwd), "the first file's folder becomes the workspace")
    testing.expect_value(t, len(file_files), 2)
    testing.expect(t, strings.has_suffix(file_files[0], FIRST), "the first file opens first")
}

// A later folder and a path that does not exist are both skipped, and neither
// may retarget the workspace the first argument chose.
@(test)
test_startup_targets_ignores_a_second_folder :: proc(t: ^testing.T) {
    cwd, cwd_err := os.get_working_directory(context.temp_allocator)
    testing.expect(t, cwd_err == nil, "could not read the working directory")

    PATH :: "thor_startup_multi_c.tmp"
    testing.expect(t, os.write_entire_file(PATH, transmute([]u8) string("x")) == nil, "could not create test file")
    defer os.remove(PATH)

    ws, files := thor_startup_targets({PATH, ".", "thor_does_not_exist_xyz"})
    defer startup_targets_cleanup(ws, files)
    testing.expect(t, strings.equal_fold(ws, cwd), "the workspace stays the first argument's folder")
    testing.expect_value(t, len(files), 1)
    testing.expect(t, strings.has_suffix(files[0], PATH), "only the real file opens")

    // No arguments at all: nothing to open, and no workspace claimed.
    empty_ws, empty_files := thor_startup_targets({})
    defer startup_targets_cleanup(empty_ws, empty_files)
    testing.expect_value(t, empty_ws, "")
    testing.expect_value(t, len(empty_files), 0)
}
