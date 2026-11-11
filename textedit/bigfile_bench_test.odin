package textedit

import "core:log"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

// Set by `build.odin -- bench`; a plain test run skips the benchmark.
BENCH :: #config(THOR_BENCH, false)

BIG_FILE_LINES :: 1_000_000
BIG_FILE_KEYS  :: 200

// The buffer a 50 MB source file makes, built by `lines` lines of one shape.
@(private = "file")
big_file_text :: proc(lines: int) -> string {
    b := strings.builder_make()
    for i in 0 ..< lines {
        strings.write_string(&b, "    value_")
        strings.write_int(&b, i)
        strings.write_string(&b, " :: proc(x: int) -> int { return x + ")
        strings.write_int(&b, i)
        strings.write_string(&b, " }\n")
    }
    return strings.to_string(b)
}

@(private = "file")
big_file_report :: proc(name: string, samples: []time.Duration) {
    slice.sort(samples)
    median := time.duration_milliseconds(samples[len(samples) / 2])
    worst  := time.duration_milliseconds(samples[len(samples) - 1])
    log.infof("bench big file: %s median %.3f ms, worst %.3f ms", name, median, worst)
}

// Load and the cost of one keystroke at the start, middle and end of a 1M-line
// buffer: the snapshot patch and the line-table patch every edit pays.
@(test)
test_bench_big_file :: proc(t: ^testing.T) {
    when !BENCH {
        return
    }
    source := big_file_text(BIG_FILE_LINES)
    defer delete(source)
    state: State
    init(&state)
    defer destroy(&state)

    start := time.tick_now()
    set_text(&state, source)
    log.infof("bench big file: %d MB, set_text %.1f ms", len(source) >> 20, time.duration_milliseconds(time.tick_since(start)))
    start = time.tick_now()
    _ = text(&state)
    log.infof("bench big file: first snapshot %.1f ms", time.duration_milliseconds(time.tick_since(start)))
    start = time.tick_now()
    count := state_line_count(&state)
    log.infof("bench big file: first line table %.1f ms, %d lines", time.duration_milliseconds(time.tick_since(start)), count)

    places := [?]struct {
        name: string,
        line: int,
    }{{"start", 0}, {"middle", BIG_FILE_LINES / 2}, {"end", BIG_FILE_LINES - 2}}
    for place in places {
        for key, label in ([?]string{"x", "\n"}) {
            samples: [BIG_FILE_KEYS]time.Duration
            for i in 0 ..< BIG_FILE_KEYS {
                set_single_cursor(&state, state_line_start(&state, place.line))
                tick := time.tick_now()
                insert_text(&state, key)
                _ = text(&state)
                _ = state_line_index(&state, primary_cursor(&state).caret)
                samples[i] = time.tick_since(tick)
            }
            big_file_report(strings.concatenate({place.name, label == 0 ? " char" : " newline"}, context.temp_allocator), samples[:])
        }
    }
}
