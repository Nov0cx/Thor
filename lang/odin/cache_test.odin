// The resident tree cache: incremental reparses match a cold parse, and a
// per-path slot is evicted rather than reused across buffers.
package odin

import "core:c/libc"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:thread"

import "../../treecache"
import ts "../../vendor/odin-tree-sitter"

@(test)
test_incremental_reparse_tracks_edits :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Every request after the first re-parses off this path's resident tree, so
    // a mis-described edit span would misplace the declaration.
    expect_add :: proc(t: ^testing.T, e: ^Engine, src, label: string) {
        loc, ok := resolve_offset(e, src, strings.index(src, "add(1, 2)"))
        defer delete(loc.path)
        testing.expectf(t, ok, "%s: expected to resolve the call to add", label)
        if ok {
            want := strings.index(src, "add ::")
            testing.expectf(t, loc.start == want, "%s: got start %d, want %d", label, loc.start, want)
        }
    }

    header := "package demo\n\n"
    body := "add :: proc(x: int, y: int) -> int {\n\treturn x + y\n}\n\nmain :: proc() {\n\ttotal := add(1, 2)\n\t_ = total\n}\n"
    first := strings.concatenate({header, body}, context.temp_allocator)

    // Cold: a full parse that seeds the cache.
    expect_add(t, e, first, "cold parse")

    // An insertion above shifts every later offset; removing it shifts them back.
    inserted := strings.concatenate({header, "MAX :: 64\n\n", body}, context.temp_allocator)
    expect_add(t, e, inserted, "insert above")
    expect_add(t, e, first, "delete above")

    // A replacement inside the body leaves the declaration where it is.
    swapped, _ := strings.replace(first, "return x + y", "return y + x", 1, context.temp_allocator)
    expect_add(t, e, swapped, "replace in body")

    // Renaming the target itself edits both the declaration and the call.
    renamed, _ := strings.replace_all(first, "add", "sum", context.temp_allocator)
    loc, ok := resolve_offset(e, renamed, strings.index(renamed, "sum(1, 2)"))
    defer delete(loc.path)
    testing.expect(t, ok, "expected the renamed symbol to resolve")
    if ok {
        want := strings.index(renamed, "sum ::")
        testing.expectf(t, loc.start == want, "rename: got start %d, want %d", loc.start, want)
    }
}

@(test)
test_tree_cache_is_per_path :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // Two buffers resident at once: alternating between them must not diff one
    // against the other's source.
    a := "package demo\n\nalpha :: proc() -> int {\n\treturn 1\n}\n\nuse_a :: proc() {\n\t_ = alpha()\n}\n"
    b := "package demo\n\nbeta :: proc() -> int {\n\treturn 2\n}\n\nuse_b :: proc() {\n\t_ = beta()\n}\n"

    for round in 0 ..< 3 {
        la, oka := resolve_offset(e, a, strings.index(a, "alpha()"), "", "a.odin")
        defer delete(la.path)
        testing.expectf(t, oka, "round %d: expected alpha to resolve", round)
        if oka {
            want := strings.index(a, "alpha ::")
            testing.expectf(t, la.start == want, "round %d alpha: got %d, want %d", round, la.start, want)
        }

        lb, okb := resolve_offset(e, b, strings.index(b, "beta()"), "", "b.odin")
        defer delete(lb.path)
        testing.expectf(t, okb, "round %d: expected beta to resolve", round)
        if okb {
            want := strings.index(b, "beta ::")
            testing.expectf(t, lb.start == want, "round %d beta: got %d, want %d", round, lb.start, want)
        }
    }
}

@(test)
test_tree_cache_evicts_and_reparses :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    // More buffers than slots: the least recently used is retired, and its next
    // request parses cold rather than off a freed tree.
    src := "package demo\n\ntarget :: proc() -> int {\n\treturn 1\n}\n\nuse :: proc() {\n\t_ = target()\n}\n"
    at := strings.index(src, "target()")
    want := strings.index(src, "target ::")

    for i in 0 ..< treecache.SLOTS + 2 {
        path := fmt.tprintf("file%d.odin", i)
        loc, ok := resolve_offset(e, src, at, "", path)
        defer delete(loc.path)
        testing.expectf(t, ok, "%s: expected target to resolve", path)
        if ok {
            testing.expectf(t, loc.start == want, "%s: got %d, want %d", path, loc.start, want)
        }
    }

    loc, ok := resolve_offset(e, src, at, "", "file0.odin")
    defer delete(loc.path)
    testing.expect(t, ok, "expected the evicted buffer to re-parse and resolve")
    testing.expectf(t, loc.start == want, "evicted: got %d, want %d", loc.start, want)
}

@(test)
test_incremental_tree_matches_cold_parse :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    parser := ts.parser_new()
    defer ts.parser_delete(parser)
    ts.parser_set_language(parser, e.language)

    // Walk one buffer through a series of edits and, after each, compare the
    // incrementally re-parsed tree against a parse of the same text from
    // scratch. A mis-described edit span shows up here as a divergent tree even
    // when a lookup happens to land on the right offset anyway.
    steps := []string {
        `package demo

add :: proc(x: int) -> int {
	return x
}
`,
        `package demo

add :: proc(x: int) -> int {
	return x + 1
}
`,
        `package demo

MAX :: 64

add :: proc(x: int) -> int {
	return x + 1
}
`,
        `package demo

MAX :: 64

add :: proc(x, y: int) -> int {
	return x + y
}
`,
        `package demo

MAX :: 64

sum :: proc(x, y: int) -> int {
	return x + y
}
`,
        `package demo

sum :: proc(x, y: int) -> int {
	return x + y
}
`,
        `package demo

Point :: struct {
	x: int,
}
`,
        // A multi-byte rune edited one byte in: the span must cover the whole rune.
        `package demo

Point :: struct {
	x: int,
	label: string, // naïve
}
`,
        `package demo

Point :: struct {
	x: int,
	label: string, // naive
}
`,
    }

    for src, i in steps {
        incremental := treecache.for_source(&e.trees, parser, "buffer.odin", "odin", src)
        defer ts.tree_delete(incremental)
        cold := ts.parser_parse_string(parser, src)
        defer ts.tree_delete(cold)

        got := ts.node_string(ts.tree_root_node(incremental))
        defer libc.free(rawptr(got))
        want := ts.node_string(ts.tree_root_node(cold))
        defer libc.free(rawptr(want))

        testing.expectf(
            t,
            string(got) == string(want),
            "step %d: incremental tree diverged\n got: %s\nwant: %s",
            i,
            got,
            want,
        )
    }
}

@(private = "file")
CONCURRENT_ROUNDS :: 24

@(private = "file")
Worker :: struct {
    engine: ^Engine,
    path:   string,
    steps:  []string,
    failed: int, // first round whose tree diverged, -1 when every round matched
}

// One worker: its own parser, its own path, cycling through its steps. Compares
// every tree the cache returns against a cold parse of the same text, which a
// tree freed or re-parsed under it would fail.
@(private = "file")
parse_rounds :: proc(w: ^Worker) {
    parser := ts.parser_new()
    defer ts.parser_delete(parser)
    ts.parser_set_language(parser, w.engine.language)

    for round in 0 ..< CONCURRENT_ROUNDS {
        src := w.steps[round % len(w.steps)]
        incremental := treecache.for_source(&w.engine.trees, parser, w.path, "odin", src)
        if incremental == nil {
            w.failed = round
            return
        }
        defer ts.tree_delete(incremental)
        cold := ts.parser_parse_string(parser, src)
        defer ts.tree_delete(cold)

        got := ts.node_string(ts.tree_root_node(incremental))
        defer libc.free(rawptr(got))
        want := ts.node_string(ts.tree_root_node(cold))
        defer libc.free(rawptr(want))

        if string(got) != string(want) {
            w.failed = round
            return
        }
    }
}

// The cache locks one entry rather than the whole cache, so these workers
// overlap. More paths than slots keeps entries retiring under load, and the two
// workers sharing a path contend on one entry — neither may see another's tree.
@(test)
test_concurrent_parses_stay_consistent :: proc(t: ^testing.T) {
    e := engine_create()
    defer engine_destroy(e)

    paths := []string {
        "conc0.odin",
        "conc1.odin",
        "conc2.odin",
        "conc3.odin",
        "conc4.odin",
        "conc5.odin",
        "conc6.odin",
        "conc7.odin",
        "conc8.odin",
        "conc9.odin",
        "conc0.odin",
        "conc1.odin",
    }

    workers := make([]Worker, len(paths), context.temp_allocator)
    threads := make([]^thread.Thread, len(paths), context.temp_allocator)
    for path, i in paths {
        name := fmt.tprintf("f%d", i)
        // Steps that differ per worker, so a tree taken from the wrong entry
        // reads as a divergence rather than a coincidental match.
        steps := make([]string, 3, context.temp_allocator)
        steps[0] = fmt.tprintf("package demo\n\n%s :: proc(x: int) -> int {{\n\treturn x\n}}\n", name)
        steps[1] = fmt.tprintf("package demo\n\n%s :: proc(x: int) -> int {{\n\treturn x + 1\n}}\n", name)
        steps[2] = fmt.tprintf("package demo\n\nMAX :: 64\n\n%s :: proc(x, y: int) -> int {{\n\treturn x + y\n}}\n", name)
        workers[i] = Worker{engine = e, path = path, steps = steps, failed = -1}
        threads[i] = thread.create_and_start_with_poly_data(&workers[i], parse_rounds)
    }

    for handle in threads {
        thread.join(handle)
        thread.destroy(handle)
    }

    for w, i in workers {
        testing.expectf(t, w.failed < 0, "worker %d (%s): tree diverged at round %d", i, w.path, w.failed)
    }
}
