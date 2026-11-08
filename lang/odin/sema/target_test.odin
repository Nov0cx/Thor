package odinsema

import "core:testing"

@(test)
test_file_name_in_build :: proc(t: ^testing.T) {
    win := Target{os = .Windows, arch = .amd64, tests = true}
    lin := Target{os = .Linux, arch = .arm64}

    Case :: struct {
        path:     string,
        win, lin: bool,
    }
    cases := []Case {
        {"pkg/plain.odin", true, true},
        {"pkg/shell_windows.odin", true, false},
        {"pkg/shell_linux.odin", false, true},
        {"pkg\\shell_darwin.odin", false, false},
        {"pkg/shell_posix.odin", true, true},
        {"pkg/simd_amd64.odin", true, false},
        {"pkg/simd_arm64.odin", false, true},
        {"pkg/sys_linux_arm64.odin", false, true},
        {"pkg/sys_linux_amd64.odin", false, false},
        {"pkg/sys_amd64_windows.odin", true, false},
        {"pkg/thing_test.odin", true, false},
        {"pkg/_test.odin", true, true},
        {"pkg/.hidden.odin", false, false},
        {"pkg/thing_WINDOWS.odin", true, false},
        {"pkg/thing_wasi.odin", false, false},
        {"pkg/thing_freestanding.odin", false, false},
        {"pkg/windows.odin", true, true},
    }
    for c in cases {
        testing.expectf(t, file_name_in_build(c.path, win) == c.win, "%s on windows: want %v", c.path, c.win)
        testing.expectf(t, file_name_in_build(c.path, lin) == c.lin, "%s on linux: want %v", c.path, c.lin)
    }
}

@(test)
test_build_tag_holds :: proc(t: ^testing.T) {
    win := Target{os = .Windows, arch = .amd64}
    lin := Target{os = .Linux, arch = .arm64}
    mac := Target{os = .Darwin, arch = .arm64}

    Case :: struct {
        expr:          string,
        win, lin, mac: bool,
    }
    cases := []Case {
        {"", true, true, true},
        {"windows", true, false, false},
        {"!windows", false, true, true},
        {"linux, darwin", false, true, true},
        {"linux amd64, darwin", false, false, true},
        {"arm64 !darwin", false, true, false},
        {"ignore", false, false, false},
        {"windows, ignore", true, false, false},
        {"bogus", false, false, false},
        {"amd64", true, false, false},
    }
    for c in cases {
        testing.expectf(t, build_tag_holds(c.expr, win) == c.win, "%q on windows: want %v", c.expr, c.win)
        testing.expectf(t, build_tag_holds(c.expr, lin) == c.lin, "%q on linux: want %v", c.expr, c.lin)
        testing.expectf(t, build_tag_holds(c.expr, mac) == c.mac, "%q on darwin: want %v", c.expr, c.mac)
    }
}

@(test)
test_file_in_build_tags :: proc(t: ^testing.T) {
    win := Target{os = .Windows, arch = .amd64}
    lin := Target{os = .Linux, arch = .amd64}

    posix := []string{"#+build !windows"}
    testing.expect(t, !file_in_build("a/shell_posix.odin", posix, win))
    testing.expect(t, file_in_build("a/shell_posix.odin", posix, lin))

    two := []string{"#+build linux, windows", "#+build amd64"}
    testing.expect(t, file_in_build("a/x.odin", two, win))
    testing.expect(t, !file_in_build("a/x.odin", two, Target{os = .Linux, arch = .arm64}))

    other := []string{"#+private file", "#+feature dynamic-literals"}
    testing.expect(t, file_in_build("a/x.odin", other, win))

    testing.expect(t, !file_in_build("a/x_linux.odin", {}, win), "the suffix decides before the tags")
    testing.expect(t, !file_in_build("a/x.odin", {"#+build ignore"}, win))

    host := target_host()
    testing.expect(t, host.os != .Unknown)
    testing.expect(t, host.arch != .Unknown)
    testing.expect(t, host.tests)
}
