package thor

import "core:testing"

// A wait ends only once no waited file has a tab.
@(test)
test_wait_satisfied :: proc(t: ^testing.T) {
    a     := Open_File{path = "src/a.txt"}
    other := Open_File{path = "src/b.txt"}

    testing.expect(t, thor_wait_satisfied({}, {}), "nothing to wait on")
    testing.expect(t, thor_wait_satisfied({"src/a.txt"}, {}), "no tab left")
    testing.expect(t, thor_wait_satisfied({"src/a.txt"}, {&other}), "an unrelated tab does not hold the wait")
    testing.expect(t, !thor_wait_satisfied({"src/a.txt"}, {&other, &a}), "the waited tab is still open")
    testing.expect(t, !thor_wait_satisfied({"src/b.txt", "src/a.txt"}, {&a}), "one waited tab is still open")

    // Windows folds case, POSIX does not.
    upper := Open_File{path = "src/A.TXT"}
    when ODIN_OS == .Windows {
        testing.expect(t, !thor_wait_satisfied({"src/a.txt"}, {&upper}))
    } else {
        testing.expect(t, thor_wait_satisfied({"src/a.txt"}, {&upper}))
    }
}

// --wait in every spelling, dropped from the paths, and refused without a file.
@(test)
test_cli_wait :: proc(t: ^testing.T) {
    testing.expect(t, !thor_cli_wait({"thor"}))
    testing.expect(t, !thor_cli_wait({"thor", "a.txt"}))
    for arg in ([?]string{"--wait", "-wait", "-w"}) {
        testing.expect(t, thor_cli_wait({"thor", arg, "a.txt"}))
        testing.expect(t, thor_cli_wait({"thor", "a.txt", arg}))
        testing.expect_value(t, thor_cli_action({"thor", arg, "a.txt"}), Cli_Action.Open)
        paths := thor_cli_paths({"thor", arg, "a.txt"})
        testing.expect_value(t, len(paths), 1)
        testing.expect_value(t, paths[0], "a.txt")
    }

    // Tests run from the repository root.
    testing.expect(t, thor_cli_has_file({"thor", "README.md"}))
    testing.expect(t, !thor_cli_has_file({"thor", "thor_does_not_exist_xyz"}))
    testing.expect(t, !thor_cli_has_file({"thor"}), "a folder is not a file")
    testing.expect(t, !thor_cli_has_file({}))
}
