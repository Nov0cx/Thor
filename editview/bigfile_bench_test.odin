package editview

import "core:log"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

import "../textedit"

// Set by `build.odin -- bench`; a plain test run skips the benchmark.
BENCH :: #config(THOR_BENCH, false)

BIG_FILE_KEYS :: 100

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

// One keystroke and the row update after it, with no fold and with one collapsed
// fold at the top: a fold forces a full row rebuild. 150k lines stay under the
// 8 MB cutoff where folds are on; 1M lines show how the cost scales.
@(test)
test_bench_fold_rows :: proc(t: ^testing.T) {
    when !BENCH {
        return
    }
    for lines in ([?]int{150_000, 1_000_000}) {
        for folded in ([?]bool{false, true}) {
            source := big_file_text(lines)
            defer delete(source)
            state: textedit.State
            textedit.init(&state)
            defer textedit.destroy(&state)
            textedit.set_text(&state, source)

            editor: Editor
            editor.state = &state
            editor.font_size = 16
            editor.foldable = make(map[int]int)
            editor.folded = make(map[int]int)
            defer delete(editor.foldable)
            defer delete(editor.folded)
            defer delete(editor.visual_rows)

            editor_set_folds(&editor, []Fold_Range{{start_line = 10, end_line = 20}})
            if folded {
                editor.folded[10] = textedit.state_line_start(&state, 10)
            }
            editor.folds_revision = state.revision
            editor_ensure_visual_rows(&editor)

            samples: [BIG_FILE_KEYS]time.Duration
            for i in 0 ..< BIG_FILE_KEYS {
                textedit.set_single_cursor(&state, textedit.state_line_start(&state, lines / 2))
                tick := time.tick_now()
                textedit.insert_text(&state, "x")
                editor_ensure_visual_rows(&editor)
                samples[i] = time.tick_since(tick)
            }
            slice.sort(samples[:])
            log.infof(
                "bench fold rows: %d lines, fold %v: median %.3f ms, worst %.3f ms",
                lines,
                folded,
                time.duration_milliseconds(samples[len(samples) / 2]),
                time.duration_milliseconds(samples[len(samples) - 1]),
            )
        }
    }
}
