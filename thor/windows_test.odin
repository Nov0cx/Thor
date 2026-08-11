package thor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Run from the repository root: odin test thor

// Two spellings of one folder — different case, different separators — must key
// the same record and session files, or Windows path casing would let a folder
// be claimed twice.
@(test)
test_window_file_keying :: proc(t: ^testing.T) {
    a := thor_window_file("D:\\Thor\\Sub")
    b := thor_window_file("D:/Thor/Sub")
    testing.expect_value(t, a, b)
    testing.expect(t, strings.has_suffix(a, ".json"), "a record file must be JSON")
    testing.expect(t, !strings.contains(thor_path_key("D:\\Thor"), "\\"), "a path key must hold no separators")

    // Case-insensitive keying only holds where the host filesystem is: Windows.
    when ODIN_OS == .Windows {
        c := thor_window_file("d:/thor/sub")
        testing.expect_value(t, a, c)
    }
}

// A hyphen in a folder name must not read as a separator. Both spellings mapped
// to one key before, so two unrelated folders shared a session file and one
// "already open" window record.
@(test)
test_path_key_separates_hyphens_from_separators :: proc(t: ^testing.T) {
    testing.expect(
        t,
        thor_path_key("C:\\foo-bar") != thor_path_key("C:\\foo\\bar"),
        "a hyphenated folder must not key like a nested one",
    )
    testing.expect(
        t,
        thor_path_key("C:\\a\\b-c") != thor_path_key("C:\\a-b\\c"),
        "moving the hyphen must change the key",
    )

    // Case-insensitive keying only holds where the host filesystem is: Windows.
    when ODIN_OS == .Windows {
        testing.expect_value(t, thor_path_key("C:\\foo-bar"), thor_path_key("c:/FOO-BAR/"))
    }
}

// A key ends up in a filename, so it holds no separator, no drive colon and no
// unbounded length whatever the path looks like.
@(test)
test_path_key_is_filename_safe :: proc(t: ^testing.T) {
    LONG :: "C:\\a very long workspace path\\with spaces and \"quotes\"\\and/deep/nesting/that/keeps/going/on"
    key := thor_path_key(LONG)
    testing.expect(t, !strings.contains_any(key, "\\/:*?\"<>|"), "a key must hold no unsafe character")
    testing.expect(t, len(key) <= 84, "a key must stay bounded") // 64 readable + a rune + '-' + 16 hex
    testing.expect_value(t, len(thor_path_key("C:\\a")), len("c--a-") + 16)
}

// Writes a record file directly, standing in for another window's claim.
@(private = "file")
write_test_record :: proc(t: ^testing.T, workspace: string, pid: int, hwnd: i64) -> string {
    if !os.is_dir("sessions/windows") {
        os.make_directory("sessions")
        os.make_directory("sessions/windows")
    }
    path := strings.clone(thor_window_file(workspace))
    body := fmt.tprintf("{{\"workspace\":%q,\"pid\":%d,\"hwnd\":%d}}", workspace, pid, hwnd)
    err := os.write_entire_file(path, transmute([]u8) body)
    testing.expect(t, err == nil, "could not write the test window record")
    return path
}

// A record whose window is gone describes a crashed process. Reading it must
// report the folder free and take the file away, so the folder does not stay
// unopenable forever.
@(test)
test_stale_window_record_is_pruned :: proc(t: ^testing.T) {
    WORKSPACE :: "D:\\thor-window-test-stale"
    path := write_test_record(t, WORKSPACE, 0x7FFFFFF0, 0)
    defer delete(path)
    defer os.remove(path)

    hwnd, ok := thor_workspace_window(WORKSPACE)
    testing.expect(t, !ok, "a record with no live window must read as free")
    testing.expect(t, hwnd == nil, "a stale record must hand back no window")
    testing.expect(t, !os.exists(path), "a stale record must be removed")
}

// Our own claim is not "another window": a folder this process already holds
// must not look occupied to itself, or reopening it would raise nothing.
@(test)
test_own_record_is_not_another_window :: proc(t: ^testing.T) {
    WORKSPACE :: "D:\\thor-window-test-self"
    path := write_test_record(t, WORKSPACE, os.get_pid(), 0)
    defer delete(path)
    defer os.remove(path)

    _, ok := thor_workspace_window(WORKSPACE)
    testing.expect(t, !ok, "this process's own record must not count as another window")
    testing.expect(t, os.exists(path), "our own record must not be pruned")
}

// Unregistering only drops our own claim. A record another window wrote (it took
// the folder over after us) has to survive, or that window would stop being found.
@(test)
test_unregister_leaves_foreign_records :: proc(t: ^testing.T) {
    FOREIGN :: "D:\\thor-window-test-foreign"
    foreign_path := write_test_record(t, FOREIGN, 0x7FFFFFF1, 0)
    defer delete(foreign_path)
    defer os.remove(foreign_path)

    thor_unregister_window(FOREIGN)
    testing.expect(t, os.exists(foreign_path), "another window's record must be left alone")

    OWN :: "D:\\thor-window-test-own"
    own_path := write_test_record(t, OWN, os.get_pid(), 0)
    defer delete(own_path)
    defer os.remove(own_path)

    thor_unregister_window(OWN)
    testing.expect(t, !os.exists(own_path), "our own record must be removed")
}
