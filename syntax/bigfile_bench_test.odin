package syntax

import "core:log"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

// Set by `build.odin -- bench`; a plain test run skips the benchmark.
BENCH :: #config(THOR_BENCH, false)

BIG_FILE_LINES  :: 250_000
BIG_FILE_EDITS  :: 4
BIG_FILE_WINDOW :: 4096

@(private = "file")
big_file_text :: proc(lines: int, edit_at: int, edited: bool) -> string {
    b := strings.builder_make()
    for i in 0 ..< lines {
        strings.write_string(&b, "    value_")
        strings.write_int(&b, i)
        strings.write_string(&b, " :: proc(x: int) -> int { return x + ")
        strings.write_int(&b, i)
        strings.write_string(&b, " }\n")
        if edited && i == edit_at {
            strings.write_string(&b, "    extra :: 1\n")
        }
    }
    return strings.to_string(b)
}

// The first parse and the window highlight after a one-line edit in a 50 MB
// Odin buffer: the diff, the clone and the re-parse the main thread pays.
@(test)
test_bench_big_file_highlight :: proc(t: ^testing.T) {
    when !BENCH {
        return
    }
    base := big_file_text(BIG_FILE_LINES, 0, false)
    defer delete(base)
    edited := big_file_text(BIG_FILE_LINES, BIG_FILE_LINES / 2, true)
    defer delete(edited)
    h := highlighter_create()
    defer highlighter_destroy(&h)

    start := time.tick_now()
    _ = highlight_range(&h, "big.odin", base, "odin", 0, BIG_FILE_WINDOW, context.temp_allocator)
    log.infof("bench big file: %d MB, first highlight %.1f ms", len(base) >> 20, time.duration_milliseconds(time.tick_since(start)))

    samples: [BIG_FILE_EDITS]time.Duration
    for i in 0 ..< BIG_FILE_EDITS {
        source := i % 2 == 0 ? edited : base
        tick   := time.tick_now()
        _ = highlight_range(&h, "big.odin", source, "odin", 0, BIG_FILE_WINDOW, context.temp_allocator)
        samples[i] = time.tick_since(tick)
    }
    slice.sort(samples[:])
    log.infof(
        "bench big file: highlight after edit median %.1f ms, worst %.1f ms",
        time.duration_milliseconds(samples[len(samples) / 2]),
        time.duration_milliseconds(samples[len(samples) - 1]),
    )

    // What a large buffer pays instead: its window parsed alone and uncached.
    fragment := base[len(base) / 2:][:32 << 10]
    start = time.tick_now()
    _ = highlight_range(&h, "", fragment, "odin", 0, max(int), context.temp_allocator)
    log.infof("bench big file: 32 KB window parsed alone %.1f ms", time.duration_milliseconds(time.tick_since(start)))
}
