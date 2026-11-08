package odin

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import lang ".."

// Set by `build.odin -- bench`; a plain test run skips the benchmarks.
BENCH :: #config(THOR_BENCH, false)

// With this set, a measure over its budget fails the test; otherwise it is logged as a warning.
STRICT :: #config(THOR_BENCH_STRICT, false)

// Budgets of plan 7, in milliseconds.
BUDGET_DIAGNOSTICS_MS :: 50.0
BUDGET_COMPLETION_MS :: 30.0

// The workload: one of Thor's largest sources, in Thor's own workspace.
@(private = "file")
BENCH_FILE :: "editview/editor.odin"

@(private = "file")
bench_source :: proc() -> (string, bool) {
    data, err := os.read_entire_file(BENCH_FILE, context.allocator)
    if err != nil {
        return "", false
    }
    defer delete(data)
    text, _ := strings.replace_all(string(data), "\r\n", "\n")
    return text, true
}

// The median and p95 of `samples`, in milliseconds.
@(private = "file")
percentiles :: proc(samples: []time.Duration) -> (median, p95: f64) {
    slice.sort(samples)
    return time.duration_milliseconds(samples[len(samples) / 2]), time.duration_milliseconds(samples[len(samples) * 95 / 100])
}

@(private = "file")
bench_free_completions :: proc(res: ^lang.Result) {
    for item in res.completions {
        delete(item.label)
        delete(item.kind)
        delete(item.detail)
        delete(item.insert)
        delete(item.filter)
        delete(item.sort)
        for edit in item.extra_edits {
            delete(edit.path)
            delete(edit.old_text)
            delete(edit.new_text)
        }
        delete(item.extra_edits)
    }
    delete(res.completions)
}

// Warm live diagnostics for the file.
@(test)
test_bench_diagnostics :: proc(t: ^testing.T) {
    when !BENCH {
        return
    }
    src, ok := bench_source()
    if !testing.expect(t, ok, "the benchmark file could not be read") {
        return
    }
    defer delete(src)
    e := engine_create()
    defer engine_destroy(e)

    start := time.tick_now()
    first := live_check(e, src, ".", BENCH_FILE)
    cold := time.tick_since(start)
    free_live(&first)
    samples: [20]time.Duration
    for i in 0 ..< len(samples) {
        start = time.tick_now()
        res := live_check(e, src, ".", BENCH_FILE)
        samples[i] = time.tick_since(start)
        free_live(&res)
        free_all(context.temp_allocator)
    }
    median, p95 := percentiles(samples[:])
    log.infof("bench diagnostics: cold %.1f ms, warm median %.1f ms, p95 %.1f ms (budget %.0f)", time.duration_milliseconds(cold), median, p95, BUDGET_DIAGNOSTICS_MS)
    over_budget(t, p95 <= BUDGET_DIAGNOSTICS_MS, "diagnostics p95 %.1f ms is over %.0f", p95, BUDGET_DIAGNOSTICS_MS)
}

// A completion list for a name prefix typed in a function body of the file.
@(test)
test_bench_completion :: proc(t: ^testing.T) {
    when !BENCH {
        return
    }
    src, ok := bench_source()
    if !testing.expect(t, ok, "the benchmark file could not be read") {
        return
    }
    defer delete(src)
    anchor := strings.index(src, "\n    return")
    if anchor < 0 {
        anchor = strings.index(src, "\n\treturn")
    }
    if !testing.expect(t, anchor >= 0, "no return statement in the benchmark file") {
        return
    }
    typed := "ed"
    text := strings.concatenate({src[:anchor + 1], typed, src[anchor + 1:]})
    defer delete(text)
    e := engine_create()
    defer engine_destroy(e)

    request :: proc(e: ^Engine, text: string, offset: int) -> (time.Duration, int) {
        req := lang.Request {
            kind      = .Completion,
            path      = BENCH_FILE,
            ext       = ".odin",
            source    = text,
            offset    = offset,
            end       = offset,
            workspace = ".",
        }
        res := lang.Result{kind = .Completion}
        start := time.tick_now()
        resolve(e, &req, &res)
        elapsed := time.tick_since(start)
        n := len(res.completions)
        bench_free_completions(&res)
        free_all(context.temp_allocator)
        return elapsed, n
    }

    cold, count := request(e, text, anchor + 1 + len(typed))
    samples: [20]time.Duration
    for i in 0 ..< len(samples) {
        samples[i], count = request(e, text, anchor + 1 + len(typed))
    }
    median, p95 := percentiles(samples[:])
    log.infof("bench completion: %d items, cold %.1f ms, warm median %.1f ms, p95 %.1f ms (budget %.0f)", count, time.duration_milliseconds(cold), median, p95, BUDGET_COMPLETION_MS)
    testing.expect(t, count > 0, "the completion list is empty")
    over_budget(t, p95 <= BUDGET_COMPLETION_MS, "completion p95 %.1f ms is over %.0f", p95, BUDGET_COMPLETION_MS)
}

// The first completion of an engine that was prewarmed, against one that was not.
@(test)
test_bench_cold_prewarm :: proc(t: ^testing.T) {
    when !BENCH {
        return
    }
    src, ok := bench_source()
    if !testing.expect(t, ok, "the benchmark file could not be read") {
        return
    }
    defer delete(src)
    anchor := strings.index(src, "\n    return")
    if !testing.expect(t, anchor >= 0, "no return statement in the benchmark file") {
        return
    }
    typed := "ed"
    text := strings.concatenate({src[:anchor + 1], typed, src[anchor + 1:]})
    defer delete(text)

    first :: proc(e: ^Engine, text: string, offset: int) -> (time.Duration, int) {
        req := lang.Request {
            kind      = .Completion,
            path      = BENCH_FILE,
            ext       = ".odin",
            source    = text,
            offset    = offset,
            end       = offset,
            workspace = ".",
        }
        res := lang.Result{kind = .Completion}
        start := time.tick_now()
        resolve(e, &req, &res)
        elapsed := time.tick_since(start)
        n := len(res.completions)
        bench_free_completions(&res)
        free_all(context.temp_allocator)
        return elapsed, n
    }

    plain := engine_create()
    plain_time, plain_count := first(plain, text, anchor + 1 + len(typed))
    engine_destroy(plain)

    warm := engine_create()
    defer engine_destroy(warm)
    engine_prewarm(warm, ".")
    engine_prewarm_wait(warm)
    warm_time, warm_count := first(warm, text, anchor + 1 + len(typed))
    log.infof(
        "bench cold prewarm: first completion %.1f ms without, %.1f ms after prewarm",
        time.duration_milliseconds(plain_time),
        time.duration_milliseconds(warm_time),
    )
    testing.expect_value(t, warm_count, plain_count)
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
