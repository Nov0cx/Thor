package odin

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"

import lang ".."

@(private = "file")
BODY_CACHE_SRC :: `package app

import "core:strings"

keep: string

pass :: proc(s: string) -> string {
	return s
}
escapes :: proc(s: string) {
	t := strings.clone(s, context.temp_allocator)
	keep = t
}
through :: proc(s: string) {
	t := strings.clone(s, context.temp_allocator)
	keep = pass(t)
}
quiet :: proc(s: string) -> int {
	return len(s)
}
`

// The report as "line:col message" lines.
@(private = "file")
report_lines :: proc(res: ^lang.Result) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    for d in res.report.items {
        append(&out, fmt.tprintf("%d:%d %s", d.line, d.col, d.message))
    }
    return out[:]
}

@(private = "file")
walks :: proc(e: ^Engine) -> int {
    return sync.atomic_load(&e.bodies.walks)
}

// The report of `src` from a fresh engine, with no cache.
@(private = "file")
fresh_lines :: proc(root, src: string) -> []string {
    e := engine_create()
    defer engine_destroy(e)
    res := live_check(e, src, root, fixture_path(root, "app/main.odin"))
    defer free_live(&res)
    return report_lines(&res)
}

@(private = "file")
expect_same :: proc(t: ^testing.T, got, want: []string, loc := #caller_location) {
    if !testing.expectf(t, len(got) == len(want), "got %v, want %v", got, want, loc = loc) {
        return
    }
    for g, i in got {
        testing.expect_value(t, g, want[i], loc = loc)
    }
}

// An edit inside one body walks that body again; the other declarations reuse their errors at their new lines.
@(test)
test_body_cache_walks_only_the_edited_body :: proc(t: ^testing.T) {
    root := fixture(t, "body_cache_edit", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e    := engine_create()
    defer engine_destroy(e)
    path := fixture_path(root, "app/main.odin")

    first := live_check(e, BODY_CACHE_SRC, root, path)
    free_live(&first)
    before := walks(e)

    again := live_check(e, BODY_CACHE_SRC, root, path)
    expect_same(t, report_lines(&again), fresh_lines(root, BODY_CACHE_SRC))
    free_live(&again)
    // `through` reads the body of `pass`, so it is walked each time.
    testing.expect_value(t, walks(e) - before, 1)

    edited, _ := strings.replace(BODY_CACHE_SRC, "\treturn s\n", "\n\treturn s\n", 1, context.temp_allocator)
    before = walks(e)
    res := live_check(e, edited, root, path)
    defer free_live(&res)
    testing.expect_value(t, walks(e) - before, 2)
    lines := report_lines(&res)
    testing.expect(t, len(lines) > 0, "the escapes are reported")
    expect_same(t, lines, fresh_lines(root, edited))
}

// A change outside the bodies walks every declaration again.
@(test)
test_body_cache_outline_change_walks_all :: proc(t: ^testing.T) {
    root := fixture(t, "body_cache_outline", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e    := engine_create()
    defer engine_destroy(e)
    path := fixture_path(root, "app/main.odin")

    first := live_check(e, BODY_CACHE_SRC, root, path)
    free_live(&first)
    total := walks(e)

    edited, _ := strings.replace(BODY_CACHE_SRC, "keep: string", "keep: string\nother: int", 1, context.temp_allocator)
    before    := walks(e)
    res       := live_check(e, edited, root, path)
    defer free_live(&res)
    testing.expect_value(t, walks(e) - before, total + 1)
    expect_same(t, report_lines(&res), fresh_lines(root, edited))
}

// A body that reads another body follows an edit of that body.
@(test)
test_body_cache_follows_a_read_body :: proc(t: ^testing.T) {
    root := fixture(t, "body_cache_alias", {{".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`}})
    e    := engine_create()
    defer engine_destroy(e)
    path := fixture_path(root, "app/main.odin")

    first      := live_check(e, BODY_CACHE_SRC, root, path)
    with_alias := report_lines(&first)
    free_live(&first)

    edited, _ := strings.replace(BODY_CACHE_SRC, "\treturn s\n", "\treturn strings.clone(s)\n", 1, context.temp_allocator)
    res       := live_check(e, edited, root, path)
    defer free_live(&res)
    without := report_lines(&res)
    expect_same(t, without, fresh_lines(root, edited))
    testing.expect(t, len(without) < len(with_alias), "the escape through `pass` is gone")
}

// A change to another file of the package drops the cached errors.
@(test)
test_body_cache_follows_other_files :: proc(t: ^testing.T) {
    src :: `package app

use :: proc() {
	x: int = helper()
	_ = x
}
`
    root := fixture(
        t,
        "body_cache_other",
        {
            {".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`},
            {"app/helper.odin", "package app\n\nhelper :: proc() -> int { return 1 }\n"},
        },
    )
    e    := engine_create()
    defer engine_destroy(e)
    e.db.workspace_interval = 0
    path := fixture_path(root, "app/main.odin")

    first := live_check(e, src, root, path)
    testing.expect_value(t, len(first.report.items), 0)
    free_live(&first)

    other := fixture(
        t,
        "body_cache_other",
        {
            {".thor/odin-analyzer.lua", `return { target = { os = "windows", arch = "amd64" } }`},
            {"app/helper.odin", "package app\n\nhelper :: proc() -> string { return \"\" }\n"},
        },
    )
    res   := live_check(e, src, other, path)
    defer free_live(&res)
    expect_same(t, report_lines(&res), fresh_lines(other, src))
    testing.expect(t, len(res.report.items) > 0, "the new type of helper is seen")
}
