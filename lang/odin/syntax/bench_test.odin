package odinsyntax

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

// Set by `build.odin -- bench`; a plain test run skips the benchmarks.
BENCH :: #config(THOR_BENCH, false)

// With this set, a measure over its budget fails the test; otherwise it is logged as a warning.
STRICT :: #config(THOR_BENCH_STRICT, false)

// Budgets of plan 4.8, in milliseconds.
BUDGET_PARSE_10K_MS   :: 8.0
BUDGET_REPARSE_P95_MS :: 0.5
BUDGET_TREE_RATIO     :: 8.0

// The file at `path` with CRLF collapsed to LF.
@(private = "file")
bench_source :: proc(path: string) -> (string, bool) {
    data, err := os.read_entire_file(path, context.allocator)
    if err != nil {
        return "", false
    }
    defer delete(data)
    text, _ := strings.replace_all(string(data), "\r\n", "\n")
    return text, true
}

// Cold parse of Thor's largest editor source, scaled to 10k lines, and the size of the tree.
@(test)
test_bench_parse :: proc(t: ^testing.T) {
    when !BENCH {
        return
    }
    src, ok := bench_source("editview/editor.odin")
    if !testing.expect(t, ok, "editview/editor.odin could not be read") {
        return
    }
    defer delete(src)
    lines := strings.count(src, "\n") + 1
    best  := max(time.Duration)
    ratio: f64
    for _ in 0 ..< 20 {
        start       := time.tick_now()
        result, err := parse(src)
        best = min(best, time.tick_since(start))
        if err == nil {
            ratio = f64(result.tree.arena.total_used) / f64(len(src))
            parse_destroy(&result)
        }
        free_all(context.temp_allocator)
    }
    per_10k := time.duration_milliseconds(best) * 10000 / f64(lines)
    log.infof("bench parse: %d lines in %.2f ms, %.2f ms per 10k lines (budget %.1f)", lines, time.duration_milliseconds(best), per_10k, BUDGET_PARSE_10K_MS)
    log.infof("bench tree: %.1f bytes per source byte (budget %.1f)", ratio, BUDGET_TREE_RATIO)
    over_budget(t, per_10k <= BUDGET_PARSE_10K_MS, "parse %.2f ms per 10k lines is over %.1f", per_10k, BUDGET_PARSE_10K_MS)
    over_budget(t, ratio <= BUDGET_TREE_RATIO, "tree %.1f bytes per byte is over %.1f", ratio, BUDGET_TREE_RATIO)
}

// p95 of one keystroke reparse in the same file.
@(test)
test_bench_reparse :: proc(t: ^testing.T) {
    when !BENCH {
        return
    }
    src, ok := bench_source("editview/editor.odin")
    if !testing.expect(t, ok, "editview/editor.odin could not be read") {
        return
    }
    defer delete(src)
    anchor := strings.index(src, "\n    return")
    if anchor < 0 {
        anchor = strings.index(src, "\n\treturn")
    }
    if !testing.expect(t, anchor >= 0, "no return statement in editor.odin") {
        return
    }
    cur, err := parse(src)
    if !testing.expect_value(t, err, nil) {
        return
    }
    defer parse_destroy(&cur)
    typed := "x := foo(bar, 1) // and a comment\n"
    times := make([dynamic]time.Duration, 0, len(typed) * 8, context.temp_allocator)
    for _ in 0 ..< 8 {
        for n in 1 ..= len(typed) {
            text          := strings.concatenate({src[:anchor + 1], typed[:n], src[anchor + 1:]}, context.temp_allocator)
            start         := time.tick_now()
            next, _, rerr := reparse(&cur, text)
            elapsed       := time.tick_since(start)
            if !testing.expect_value(t, rerr, nil) {
                return
            }
            cur = next
            append(&times, elapsed)
        }
        // Back to the original text, so each round starts alike.
        next, _, rerr := reparse(&cur, src)
        if !testing.expect_value(t, rerr, nil) {
            return
        }
        cur = next
    }
    slice.sort(times[:])
    p95 := time.duration_milliseconds(times[len(times) * 95 / 100])
    log.infof(
        "bench reparse: %d keystrokes, median %.3f ms, p95 %.3f ms (budget %.1f)",
        len(times),
        time.duration_milliseconds(times[len(times) / 2]),
        p95,
        BUDGET_REPARSE_P95_MS,
    )
    over_budget(t, p95 <= BUDGET_REPARSE_P95_MS, "reparse p95 %.3f ms is over %.1f", p95, BUDGET_REPARSE_P95_MS)
}

// Fails the test in strict mode, else logs a warning, when `within` is false.
@(private = "file")
over_budget :: proc(t: ^testing.T, within: bool, format: string, args: ..any, loc := #caller_location) {
    if within {
        return
    }
    when STRICT {
        testing.expectf(t, false, format, ..args, loc = loc)
    } else {
        log.warnf(format, ..args, location = loc)
    }
}
