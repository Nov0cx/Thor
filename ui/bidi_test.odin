package ui

import "core:testing"

import hb "../vendor/odin-harfbuzz/harfbuzz"

// The runs must tile the line with no gap and no overlap, whatever their visual
// order, or a shaped line drops or repeats characters.
@(private = "file")
expect_covers :: proc(t: ^testing.T, runs: []Shape_Run, line: string, loc := #caller_location) {
    covered := 0
    for run in runs {
        testing.expect(t, run.start < run.end, "empty run", loc = loc)
        covered += run.end - run.start
    }
    testing.expect_value(t, covered, len(line), loc = loc)

    ordered := make([]Shape_Run, len(runs), context.temp_allocator)
    copy(ordered, runs)
    for i in 1 ..< len(ordered) {
        for j := i; j > 0 && ordered[j].start < ordered[j - 1].start; j -= 1 {
            ordered[j], ordered[j - 1] = ordered[j - 1], ordered[j]
        }
    }
    next := 0
    for run in ordered {
        testing.expect_value(t, run.start, next, loc = loc)
        next = run.end
    }
}

@(test)
test_shape_itemize :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    // An ASCII line takes the fast path: one left-to-right Latin run.
    {
        line := "if (x == 1) { return 0 }"
        runs := shape_itemize(line)
        testing.expect_value(t, len(runs), 1)
        if len(runs) == 1 {
            testing.expect_value(t, runs[0].start, 0)
            testing.expect_value(t, runs[0].end, len(line))
            testing.expect_value(t, runs[0].script, hb.script_t.SCRIPT_LATIN)
            testing.expect_value(t, runs[0].level, 0)
        }
        testing.expect_value(t, len(shape_itemize("")), 0)
    }

    // Punctuation, spaces and digits take the script of the text around them, so
    // a line of Latin code stays one run on the scanned path too.
    {
        line := "äbc = 123 + x;"
        runs := shape_itemize(line)
        expect_covers(t, runs, line)
        testing.expect_value(t, len(runs), 1)
        if len(runs) == 1 {
            testing.expect_value(t, runs[0].script, hb.script_t.SCRIPT_LATIN)
            testing.expect_value(t, runs[0].level, 0)
        }
    }

    // A right-to-left script gets an odd level, which is what makes shape_into
    // ask HarfBuzz for right-to-left order.
    {
        line := "abc שלום"
        runs := shape_itemize(line)
        expect_covers(t, runs, line)
        testing.expect_value(t, len(runs), 2)
        if len(runs) == 2 {
            testing.expect_value(t, runs[0].start, 0)
            testing.expect_value(t, runs[0].end, 4)
            testing.expect_value(t, runs[0].script, hb.script_t.SCRIPT_LATIN)
            testing.expect_value(t, runs[0].level, 0)

            testing.expect_value(t, runs[1].start, 4)
            testing.expect_value(t, runs[1].end, len(line))
            testing.expect_value(t, runs[1].script, hb.script_t.SCRIPT_HEBREW)
            testing.expect_value(t, runs[1].level, 1)
        }
    }

    // The base direction stays left to right: a line that starts right to left
    // still starts on the left.
    {
        line := "שלום abc"
        runs := shape_itemize(line)
        expect_covers(t, runs, line)
        testing.expect(t, len(runs) >= 2, "expected a right-to-left run and a left-to-right one")
        if len(runs) >= 2 {
            testing.expect_value(t, runs[0].start, 0)
            testing.expect_value(t, runs[0].level, 1)
            testing.expect_value(t, runs[len(runs) - 1].level, 0)
            testing.expect_value(t, runs[len(runs) - 1].end, len(line))
        }
    }

    // Rule L2: a number inside right-to-left text keeps its own left-to-right
    // order and moves to the left of the text it follows.
    {
        line := "שלום 123"
        runs := shape_itemize(line)
        expect_covers(t, runs, line)
        testing.expect_value(t, len(runs), 2)
        if len(runs) == 2 {
            testing.expect_value(t, runs[0].start, 9)
            testing.expect_value(t, runs[0].end, len(line))
            testing.expect_value(t, runs[0].level, 2)

            testing.expect_value(t, runs[1].start, 0)
            testing.expect_value(t, runs[1].end, 9)
            testing.expect_value(t, runs[1].level, 1)
        }
    }

    // A right-to-left span between two left-to-right ones reverses on its own;
    // the code around it keeps its order.
    {
        line := "x := \"العربية\" + y"
        runs := shape_itemize(line)
        expect_covers(t, runs, line)

        rtl := 0
        for run in runs {
            if run.level % 2 == 1 {
                rtl += 1
                testing.expect_value(t, run.script, hb.script_t.SCRIPT_ARABIC)
            }
        }
        testing.expect_value(t, rtl, 1)
        testing.expect_value(t, runs[0].start, 0)
        testing.expect_value(t, runs[len(runs) - 1].end, len(line))
    }
}
