package odin

import "core:strings"
import "core:testing"

import lang ".."

@(private = "file")
SIBLING :: "package app\n\nother :: proc() {\n\t_ = zork\n}\n"

@(private = "file")
MAIN :: "package app\n\nmain :: proc() {\n\tother()\n}\n"

@(private = "file")
count_path :: proc(res: ^lang.Result, suffix: string) -> int {
    n := 0
    for d in res.report.items {
        if strings.has_suffix(d.path, suffix) {
            n += 1
        }
    }
    return n
}

@(test)
test_package_live_off_by_default :: proc(t: ^testing.T) {
    root := fixture(t, "pkg_live_off", {{"app/main.odin", MAIN}, {"app/other.odin", SIBLING}})
    e    := engine_create()
    defer engine_destroy(e)

    res := live_check(e, MAIN, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    testing.expect(t, res.ok)
    testing.expect_value(t, res.report.package_wide, false)
    testing.expect_value(t, count_path(&res, "other.odin"), 0)
}

@(test)
test_package_live_reports_siblings :: proc(t: ^testing.T) {
    root := fixture(
        t,
        "pkg_live_on",
        {{"app/main.odin", MAIN}, {"app/other.odin", SIBLING}, {"app/notes.txt", "zork"}, {".thor/odin-analyzer.lua", "return { package_diagnostics = true }"}},
    )
    e    := engine_create()
    defer engine_destroy(e)

    res := live_check(e, MAIN, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    testing.expect(t, res.ok)
    testing.expect_value(t, res.report.package_wide, true)
    testing.expect_value(t, count_path(&res, "main.odin"), 0)
    testing.expect_value(t, count_path(&res, "other.odin"), 1)
    for d in res.report.items {
        if strings.has_suffix(d.path, "other.odin") {
            testing.expect_value(t, d.code, CODE_UNDECLARED)
            testing.expect_value(t, d.line, 4)
        }
    }
}

@(test)
test_package_live_keeps_the_buffer_apart :: proc(t: ^testing.T) {
    root := fixture(
        t,
        "pkg_live_buffer",
        {{"app/main.odin", MAIN}, {"app/other.odin", SIBLING}, {".thor/odin-analyzer.lua", "return { package_diagnostics = true }"}},
    )
    e    := engine_create()
    defer engine_destroy(e)

    // The buffer of main.odin has its own error; the siblings come from disk.
    buffer := "package app\n\nmain :: proc() {\n\t_ = nope\n}\n"
    res    := live_check(e, buffer, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    testing.expect_value(t, count_path(&res, "main.odin"), 1)
    testing.expect_value(t, count_path(&res, "other.odin"), 1)
}
