package thor

import "core:testing"
import rl "vendor:raylib"

import ui "../vendor/loom/loom"
import "../editview"
import "../lang"
@(private = "file")
GRAMMAR := ui.Color{1, 0, 0, 255}
@(private = "file")
ANALYZER := ui.Color{0, 1, 0, 255}

@(private = "file")
span :: proc(start, end: int, color: ui.Color) -> editview.Highlight_Span {
    return editview.Highlight_Span{start, end, color}
}

// The editor walks the spans with one cursor that only moves forward, so a merge
// that leaves them unsorted or overlapping draws the wrong colors from there on.
@(private = "file")
expect_well_formed :: proc(t: ^testing.T, spans: []editview.Highlight_Span) {
    prev := 0
    for s in spans {
        testing.expectf(t, s.start >= prev, "span at %d starts before the previous one ended (%d)", s.start, prev)
        testing.expectf(t, s.end > s.start, "empty span at %d", s.start)
        prev = s.end
    }
}

@(test)
test_overlay_replaces_and_clips :: proc(t: ^testing.T) {
    out := make([dynamic]editview.Highlight_Span)
    defer delete(out)

    // One base span covering 0..20, with an analyzer token in the middle of it:
    // the base has to come out split around the token, not dropped and not
    // painted over it.
    base := []editview.Highlight_Span{span(0, 20, GRAMMAR)}
    over := []editview.Highlight_Span{span(5, 10, ANALYZER)}
    thor_overlay_spans(&out, base, over)

    expect_well_formed(t, out[:])
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], span(0, 5, GRAMMAR))
    testing.expect_value(t, out[1], span(5, 10, ANALYZER))
    testing.expect_value(t, out[2], span(10, 20, GRAMMAR))
}

@(test)
test_overlay_spanning_several_base_spans :: proc(t: ^testing.T) {
    out := make([dynamic]editview.Highlight_Span)
    defer delete(out)

    // A token reaching across three base spans swallows the one it covers whole
    // and trims the two it only reaches into.
    base := []editview.Highlight_Span {
        span(0, 10, GRAMMAR),
        span(10, 20, GRAMMAR),
        span(20, 30, GRAMMAR),
    }
    over := []editview.Highlight_Span{span(5, 25, ANALYZER)}
    thor_overlay_spans(&out, base, over)

    expect_well_formed(t, out[:])
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], span(0, 5, GRAMMAR))
    testing.expect_value(t, out[1], span(5, 25, ANALYZER))
    testing.expect_value(t, out[2], span(25, 30, GRAMMAR))
}

@(test)
test_overlay_keeps_uncovered_base :: proc(t: ^testing.T) {
    out := make([dynamic]editview.Highlight_Span)
    defer delete(out)

    // Both lists are sparse: the analyzer classifies identifiers the grammar
    // left uncolored, and colors nothing where the grammar already ran.
    base := []editview.Highlight_Span{span(0, 4, GRAMMAR), span(30, 40, GRAMMAR)}
    over := []editview.Highlight_Span{span(10, 15, ANALYZER), span(20, 22, ANALYZER)}
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
    out := make([dynamic]editview.Highlight_Span)
    defer delete(out)

    // No classification yet (a file the analyzer does not handle, or its first
    // result still in flight) leaves the grammar's spans exactly as they were.
    base := []editview.Highlight_Span{span(0, 4, GRAMMAR), span(8, 12, GRAMMAR)}
    thor_overlay_spans(&out, base, nil)
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0], base[0])
    testing.expect_value(t, out[1], base[1])

    // And an unhighlighted buffer takes the classification on its own.
    clear(&out)
    over := []editview.Highlight_Span{span(2, 6, ANALYZER)}
    thor_overlay_spans(&out, nil, over)
    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], over[0])
}

@(test)
test_overlay_exact_and_adjacent :: proc(t: ^testing.T) {
    out := make([dynamic]editview.Highlight_Span)
    defer delete(out)

    // The common case by far: the grammar colored the identifier as a plain
    // variable and the analyzer names it exactly, span for span. Neighbours that
    // merely touch the token must survive whole.
    base := []editview.Highlight_Span {
        span(0, 5, GRAMMAR),
        span(5, 9, GRAMMAR),
        span(9, 14, GRAMMAR),
    }
    over := []editview.Highlight_Span{span(5, 9, ANALYZER)}
    thor_overlay_spans(&out, base, over)

    expect_well_formed(t, out[:])
    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], span(0, 5, GRAMMAR))
    testing.expect_value(t, out[1], span(5, 9, ANALYZER))
    testing.expect_value(t, out[2], span(9, 14, GRAMMAR))
}

@(private = "file")
token :: proc(start, end: int, kind := lang.Token_Kind.Local) -> lang.Semantic_Token {
    return lang.Semantic_Token{start, end, kind}
}

// The reported fault in its smallest form: the classification names bytes of the
// text it ran over, and an edit above them moves every later name. Merged at the
// old offsets it colors part of an identifier and swallows the next one.
@(test)
test_rebase_moves_tokens_an_edit_displaced :: proc(t: ^testing.T) {
    out := make([dynamic]lang.Semantic_Token)
    defer delete(out)

    old_text := "aa bbbb cccc\n"
    new_text := "aa XY bbbb cccc\n" // three bytes inserted after "aa "
    tokens := []lang.Semantic_Token{token(0, 2), token(3, 7), token(8, 12)}
    thor_rebase_semantic(&out, tokens, old_text, new_text)

    testing.expect_value(t, len(out), 3)
    testing.expect_value(t, out[0], token(0, 2))  // below the edit: unmoved
    testing.expect_value(t, out[1], token(6, 10)) // above it: moved by +3
    testing.expect_value(t, out[2], token(11, 15))
    testing.expect_value(t, new_text[out[1].start:out[1].end], "bbbb")
    testing.expect_value(t, new_text[out[2].start:out[2].end], "cccc")
}

// A deletion above the tokens, which is the reported screenshot's own case: the
// offsets ran ahead of the text and colored `scro|ll_inertia`.
@(test)
test_rebase_moves_tokens_back_after_a_deletion :: proc(t: ^testing.T) {
    out := make([dynamic]lang.Semantic_Token)
    defer delete(out)

    old_text := "aa XY bbbb\n"
    new_text := "aa bbbb\n"
    thor_rebase_semantic(&out, []lang.Semantic_Token{token(0, 2), token(6, 10)}, old_text, new_text)

    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[1], token(3, 7))
    testing.expect_value(t, new_text[out[1].start:out[1].end], "bbbb")
}

// A token the edit runs through named bytes that are gone. Trimming it to what
// is left paints half an identifier, so it is dropped and the grammar's color
// stands until the next classification lands.
@(test)
test_rebase_drops_a_token_the_edit_reached_into :: proc(t: ^testing.T) {
    out := make([dynamic]lang.Semantic_Token)
    defer delete(out)

    old_text := "alpha beta\n"
    new_text := "alZZpha beta\n" // typed inside "alpha"
    thor_rebase_semantic(&out, []lang.Semantic_Token{token(0, 5), token(6, 10)}, old_text, new_text)

    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, new_text[out[0].start:out[0].end], "beta")
}

// An unchanged buffer is the identity, which is what lets the merge key on the
// text and not on the revision: a reload returns the revision to 0, so an equal
// revision proves nothing.
@(test)
test_rebase_is_identity_on_an_unchanged_buffer :: proc(t: ^testing.T) {
    out := make([dynamic]lang.Semantic_Token)
    defer delete(out)

    src := "alpha beta gamma\n"
    tokens := []lang.Semantic_Token{token(0, 5), token(6, 10), token(11, 16)}
    thor_rebase_semantic(&out, tokens, src, src)

    testing.expect_value(t, len(out), len(tokens))
    for tok, i in out {
        testing.expect_value(t, tok, tokens[i])
    }
}

// A reload to unrelated text keeps nothing: every token's bytes are inside the
// change, so the file falls back to the grammar's colors until it is re-asked.
@(test)
test_rebase_drops_everything_after_a_wholesale_replacement :: proc(t: ^testing.T) {
    out := make([dynamic]lang.Semantic_Token)
    defer delete(out)

    thor_rebase_semantic(&out, []lang.Semantic_Token{token(0, 5), token(6, 10)}, "alpha beta\n", "zulu\n")
    testing.expect_value(t, len(out), 0)
}

// The editor walks the merged spans with one cursor that only moves forward, so
// a token overlapping the one before it is dropped whole. Trimming its front is
// exactly the part-colored identifier the fault shows.
@(test)
test_semantic_spans_drop_an_overlapping_token :: proc(t: ^testing.T) {
    out := make([dynamic]editview.Highlight_Span)
    defer delete(out)

    colors: [lang.Token_Kind]ui.Color
    colors[.Local] = ANALYZER
    tokens := []lang.Semantic_Token{token(0, 10), token(4, 14), token(20, 24)}
    thor_semantic_spans(&out, tokens, colors, {.Local}, 0, 100)

    expect_well_formed(t, out[:])
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0], span(0, 10, ANALYZER))
    testing.expect_value(t, out[1], span(20, 24, ANALYZER))
}

// The overlay covers only the window the grammar answered for; a token outside
// it would color bytes with no base span under them.
@(test)
test_semantic_spans_clip_to_the_window :: proc(t: ^testing.T) {
    out := make([dynamic]editview.Highlight_Span)
    defer delete(out)

    colors: [lang.Token_Kind]ui.Color
    colors[.Local] = ANALYZER
    tokens := []lang.Semantic_Token{token(0, 4), token(8, 14), token(18, 24), token(30, 34)}
    thor_semantic_spans(&out, tokens, colors, {.Local}, 10, 20)

    expect_well_formed(t, out[:])
    testing.expect_value(t, len(out), 2)
    testing.expect_value(t, out[0], span(10, 14, ANALYZER))
    testing.expect_value(t, out[1], span(18, 20, ANALYZER))
}

// A kind the language's plugin maps to no role keeps the color the grammar gave
// it, rather than taking the default foreground.
@(test)
test_semantic_spans_skip_an_unmapped_kind :: proc(t: ^testing.T) {
    out := make([dynamic]editview.Highlight_Span)
    defer delete(out)

    colors: [lang.Token_Kind]ui.Color
    colors[.Local] = ANALYZER
    tokens := []lang.Semantic_Token{token(0, 4, .Unresolved), token(8, 14, .Local)}
    thor_semantic_spans(&out, tokens, colors, {.Local}, 0, 100)

    testing.expect_value(t, len(out), 1)
    testing.expect_value(t, out[0], span(8, 14, ANALYZER))
}
