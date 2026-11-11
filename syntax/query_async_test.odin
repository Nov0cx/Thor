package syntax

import "core:strings"
import "core:testing"
import "core:time"

import ts "../vendor/odin-tree-sitter"

// Waits up to `limit` for the compile of `lang_id` to land through query_poll.
@(private = "file")
wait_ready :: proc(h: ^Highlighter, lang_id: string, limit: time.Duration) -> bool {
    start := time.tick_now()
    for time.tick_since(start) < limit {
        query_poll(h)
        if query_ready(h, lang_id) {
            return true
        }
        time.sleep(5 * time.Millisecond)
    }
    return false
}

@(test)
test_query_ready_compiles_on_a_worker :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    testing.expect(t, !query_ready(&h, "lua"), "an uncompiled query reported ready")
    testing.expect(t, !query_ready(&h, "lua"), "a second ask started a second compile")
    testing.expect_value(t, len(h.compiling), 1)
    testing.expect(t, wait_ready(&h, "lua", 30 * time.Second), "the compile did not land")
    testing.expect_value(t, len(h.compiling), 0)

    spans := highlight(&h, "", "local x = 1", "lua", context.temp_allocator)
    testing.expect(t, len(spans) > 0, "the installed query gave no spans")
    testing.expect(t, query_ready(&h, "unknown"), "an unknown language must not wait")
}

// An override set while the default query compiles wins; the old compile is dropped.
@(test)
test_query_ready_drops_a_replaced_source :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    testing.expect(t, !query_ready(&h, "lua"), "an uncompiled query reported ready")
    _, err := set_highlights(&h, "lua", "(identifier) @variable")
    testing.expect_value(t, err, ts.Query_Error.None)
    testing.expect(t, wait_ready(&h, "lua", 30 * time.Second), "the override did not become ready")
    spans := highlight(&h, "", "local x = 1", "lua", context.temp_allocator)
    for span in spans {
        testing.expectf(t, span.capture == "variable", "a span of the replaced query survived: %q", span.capture)
    }
}

// A destroy while a compile runs waits for it and frees it.
@(test)
test_query_destroy_waits_for_a_compile :: proc(t: ^testing.T) {
    h := highlighter_create()
    testing.expect(t, !query_ready(&h, "odin"), "an uncompiled query reported ready")
    highlighter_destroy(&h)
}

// A large buffer with no resident tree parses on a worker; the tree it leaves serves the next parse.
@(test)
test_tree_ready_parses_on_a_worker :: proc(t: ^testing.T) {
    h := highlighter_create()
    defer highlighter_destroy(&h)

    b := strings.builder_make()
    defer strings.builder_destroy(&b)
    for strings.builder_len(b) < ASYNC_PARSE_MIN {
        strings.write_string(&b, "local value = 1\n")
    }
    source := strings.to_string(b)
    testing.expect(t, tree_ready(&h, "", source, "lua"), "a buffer with no path must not wait")
    testing.expect(t, tree_ready(&h, "small.lua", "local x = 1", "lua"), "a small buffer must not wait")
    testing.expect(t, !tree_ready(&h, "big.lua", source, "lua"), "a large buffer with no tree reported ready")

    start := time.tick_now()
    for !tree_ready(&h, "big.lua", source, "lua") && time.tick_since(start) < 30 * time.Second {
        time.sleep(5 * time.Millisecond)
    }
    testing.expect(t, tree_ready(&h, "big.lua", source, "lua"), "the parse did not land")
    testing.expect_value(t, len(h.parsing), 0)
    testing.expect(t, len(highlight(&h, "big.lua", source, "lua", context.temp_allocator)) > 0, "the resident tree gave no spans")
}

// A destroy while a first parse runs waits for it.
@(test)
test_tree_destroy_waits_for_a_parse :: proc(t: ^testing.T) {
    h      := highlighter_create()
    source := strings.repeat("local value = 1\n", ASYNC_PARSE_MIN / 8, context.temp_allocator)
    testing.expect(t, !tree_ready(&h, "big.lua", source, "lua"), "a large buffer with no tree reported ready")
    highlighter_destroy(&h)
}
