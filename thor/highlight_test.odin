package thor

import "core:testing"
import rl "vendor:raylib"

import "../widgets"

@(private = "file")
GRAMMAR := rl.Color{1, 0, 0, 255}
@(private = "file")
ANALYZER := rl.Color{0, 1, 0, 255}

@(private = "file")
span :: proc(start, end: int, color: rl.Color) -> widgets.Highlight_Span {
    return widgets.Highlight_Span{start, end, color}
}

// The editor walks the spans with one cursor that only moves forward, so a merge
// that leaves them unsorted or overlapping draws the wrong colors from there on.
@(private = "file")
expect_well_formed :: proc(t: ^testing.T, spans: []widgets.Highlight_Span) {
    prev := 0
    for s in spans {
        testing.expectf(t, s.start >= prev, "span at %d starts before the previous one ended (%d)", s.start, prev)
        testing.expectf(t, s.end > s.start, "empty span at %d", s.start)
        prev = s.end
    }
}

@(test)
test_overlay_replaces_and_clips :: proc(t: ^testing.T) {
    out := make([dynamic]widgets.Highlight_Span)
    defer delete(out)

    // One base span covering 0..20, with an analyzer token in the middle of it:
    // the base has to come out split around the token, not dropped and not
    // painted over it.
    base := []widgets.Highlight_Span{span(0, 20, GRAMMAR)}
    over := []widgets.Highlight_Span{span(5, 10, ANALYZER)}
    thor_overlay_spans(&out, base, over)

    expect_well_formed(t, out[:])
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], span(0, 5, GRAMMAR))
    testing.expect_value(t, out[1], span(5, 10, ANALYZER))
    testing.expect_value(t, out[2], span(10, 20, GRAMMAR))
}

@(test)
test_overlay_spanning_several_base_spans :: proc(t: ^testing.T) {
    out := make([dynamic]widgets.Highlight_Span)
    defer delete(out)

    // A token reaching across three base spans swallows the one it covers whole
    // and trims the two it only reaches into.
    base := []widgets.Highlight_Span {
        span(0, 10, GRAMMAR),
        span(10, 20, GRAMMAR),
        span(20, 30, GRAMMAR),
    }
    over := []widgets.Highlight_Span{span(5, 25, ANALYZER)}
    thor_overlay_spans(&out, base, over)

    expect_well_formed(t, out[:])
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], span(0, 5, GRAMMAR))
    testing.expect_value(t, out[1], span(5, 25, ANALYZER))
    testing.expect_value(t, out[2], span(25, 30, GRAMMAR))
}

@(test)
test_overlay_keeps_uncovered_base :: proc(t: ^testing.T) {
    out := make([dynamic]widgets.Highlight_Span)
    defer delete(out)

    // Both lists are sparse: the analyzer classifies identifiers the grammar
    // left uncolored, and colors nothing where the grammar already ran.
    base := []widgets.Highlight_Span{span(0, 4, GRAMMAR), span(30, 40, GRAMMAR)}
    over := []widgets.Highlight_Span{span(10, 15, ANALYZER), span(20, 22, ANALYZER)}
    thor_overlay_spans(&out, base, over)

    expect_well_formed(t, out[:])
    testing.expect_value(t, len(out), 4)
    testing.expect_value(t, out[0], span(0, 4, GRAMMAR))
    testing.expect_value(t, out[1], span(10, 15, ANALYZER))
    testing.expect_value(t, out[2], span(20, 22, ANALYZER))
    testing.expect_value(t, out[3], span(30, 40, GRAMMAR))
}

@(test)
test_overlay_with_empty_input :: proc(t: ^testing.T) {
    out := make([dynamic]widgets.Highlight_Span)
    defer delete(out)

    // No classification yet (a file the analyzer does not handle, or its first
    // result still in flight) leaves the grammar's spans exactly as they were.
    base := []widgets.Highlight_Span{span(0, 4, GRAMMAR), span(8, 12, GRAMMAR)}
    thor_overlay_spans(&out, base, nil)
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0], base[0])
    testing.expect_value(t, out[1], base[1])

    // And an unhighlighted buffer takes the classification on its own.
    clear(&out)
    over := []widgets.Highlight_Span{span(2, 6, ANALYZER)}
    thor_overlay_spans(&out, nil, over)
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], over[0])
}

@(test)
test_overlay_exact_and_adjacent :: proc(t: ^testing.T) {
    out := make([dynamic]widgets.Highlight_Span)
    defer delete(out)

    // The common case by far: the grammar colored the identifier as a plain
    // variable and the analyzer names it exactly, span for span. Neighbours that
    // merely touch the token must survive whole.
    base := []widgets.Highlight_Span {
        span(0, 5, GRAMMAR),
        span(5, 9, GRAMMAR),
        span(9, 14, GRAMMAR),
    }
    over := []widgets.Highlight_Span{span(5, 9, ANALYZER)}
    thor_overlay_spans(&out, base, over)

    expect_well_formed(t, out[:])
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], span(0, 5, GRAMMAR))
    testing.expect_value(t, out[1], span(5, 9, ANALYZER))
    testing.expect_value(t, out[2], span(9, 14, GRAMMAR))
}
