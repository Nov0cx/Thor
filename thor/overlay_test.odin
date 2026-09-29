package thor

import "core:testing"

import "../editview"
import "../snippet"
import ui "../vendor/loom/loom"

// The row-level overlays are pure arithmetic over a row's bytes and its spans, so
// they are checked without a font atlas. font.measure reports 0 in a headless run,
// which leaves the swatch leads as the only width in play — which is exactly the
// part the markers and the underline have to agree with.

@(private = "file")
TEXT_X :: f32(40)

@(private = "file")
overlay_editor :: proc() -> editview.Editor {
    editor: editview.Editor
    editor.font_size = 16
    return editor
}

// One row spanning the whole of `text`.
@(private = "file")
whole_row :: proc(text: string) -> editview.Visual_Row {
    return {start = 0, end = len(text), line = 0, first = true}
}

// Indentation only: the scan stops at the first character that is neither a space
// nor a tab, and whitespace between words is left unmarked.
@(test)
test_markers_cover_the_indentation_only :: proc(t: ^testing.T) {
    editor := overlay_editor()
    row := `	  x y`
    markers := thor_row_markers(&editor, row, whole_row(row), nil, TEXT_X)

    testing.expect_value(t, len(markers), 3)
    testing.expect(t, markers[0].tab, "the first marker is the tab")
    testing.expect(t, !markers[1].tab, "the second is a space")
    testing.expect(t, !markers[2].tab, "the third is a space")

    // Each marker starts where the one before it ended, so the row reads as one
    // unbroken run of indentation.
    testing.expect_value(t, markers[0].x0, TEXT_X)
    for i in 1 ..< len(markers) {
        testing.expect_value(t, markers[i].x0, markers[i - 1].x1)
    }
}

// A row with no leading whitespace has nothing to mark.
@(test)
test_markers_of_an_unindented_row :: proc(t: ^testing.T) {
    editor := overlay_editor()
    row := "x  y"
    testing.expect_value(t, len(thor_row_markers(&editor, row, whole_row(row), nil, TEXT_X)), 0)
}

// A swatch gap opens before the literal that follows the indentation. It sits
// after the last space, not across it, or that space's dot drifts right by half
// the gap.
@(test)
test_a_swatch_gap_does_not_stretch_the_last_marker :: proc(t: ^testing.T) {
    editor := overlay_editor()
    row := `  "#1A1C23"`
    gap := editview.editor_swatch_span(&editor)

    buffer: [editview.MAX_ROW_SWATCHES]editview.Row_Swatch
    swatches := thor_row_swatches(row, buffer[:])
    testing.expect_value(t, len(swatches), 1)
    testing.expect_value(t, swatches[0].anchor, 2)

    spans := thor_row_spans(&editor, row, 0, len(row), swatches)
    testing.expect_value(t, ui.span_lead_before(spans, 2), gap)

    markers := thor_row_markers(&editor, row, whole_row(row), spans, TEXT_X)
    testing.expect_value(t, len(markers), 2)
    // Widths are zero here, so a marker carrying the gap would be gap wide.
    testing.expect_value(t, markers[1].x1 - markers[1].x0, f32(0))
    testing.expect_value(t, markers[1].x1, TEXT_X)
}

// A word the soft wrap split underlines on both of its rows, each taking its own
// share; a row the word misses takes none.
@(test)
test_the_link_is_clipped_to_its_row :: proc(t: ^testing.T) {
    first := editview.Visual_Row{start = 0, end = 10, line = 0, first = true}
    second := editview.Visual_Row{start = 10, end = 20, line = 0}

    start, end, ok := thor_row_link_bytes(first, 6, 14)
    testing.expect(t, ok, "the head of the word is on the first row")
    testing.expect_value(t, start, 6)
    testing.expect_value(t, end, 10)

    start, end, ok = thor_row_link_bytes(second, 6, 14)
    testing.expect(t, ok, "the tail is on the second")
    testing.expect_value(t, start, 10)
    testing.expect_value(t, end, 14)

    _, _, ok = thor_row_link_bytes(second, 0, 5)
    testing.expect(t, !ok, "a word above the row is not on it")

    _, _, ok = thor_row_link_bytes(first, 12, 16)
    testing.expect(t, !ok, "a word below the row is not on it either")

    // No word is hovered.
    _, _, ok = thor_row_link_bytes(first, -1, -1)
    testing.expect(t, !ok, "a negative range is no link")

    // A half-open range that ends where the row starts covers nothing.
    _, _, ok = thor_row_link_bytes(second, 5, 10)
    testing.expect(t, !ok, "a range ending at the row start covers no byte of it")
}

// A live snippet session with two stops: the placeholder the caret is on, its
// mirror, and the exit stop at the end.
@(private = "file")
snippet_editor :: proc(editor: ^editview.Editor, stops: ..snippet.Stop) {
    editor.snippet_active = true
    for stop in stops {
        append(&editor.snippet_stops, stop)
    }
}

// Every occurrence of the tabstop the caret is on is active; a later stop is not.
@(test)
test_a_mirror_carries_the_active_mark :: proc(t: ^testing.T) {
    editor := overlay_editor()
    defer delete(editor.snippet_stops)
    snippet_editor(
        &editor,
        snippet.Stop{start = 2, end = 5, index = 1},
        snippet.Stop{start = 8, end = 11, index = 1},
        snippet.Stop{start = 14, end = 17, index = 2},
    )

    stops := thor_row_stops(&editor, editview.Visual_Row{start = 0, end = 20, first = true})
    testing.expect_value(t, len(stops), 3)
    testing.expect(t, stops[0].active, "the caret is on the first stop")
    testing.expect(t, stops[1].active, "so its mirror is marked too")
    testing.expect(t, !stops[2].active, "the next tabstop is not")
}

// A placeholder a soft wrap split is boxed on both rows, each taking its own
// share, and a row it misses takes none.
@(test)
test_a_stop_is_clipped_to_its_row :: proc(t: ^testing.T) {
    editor := overlay_editor()
    defer delete(editor.snippet_stops)
    snippet_editor(&editor, snippet.Stop{start = 6, end = 14, index = 1})

    first := editview.Visual_Row{start = 0, end = 10, first = true}
    second := editview.Visual_Row{start = 10, end = 20}

    head := thor_row_stops(&editor, first)
    testing.expect_value(t, len(head), 1)
    testing.expect_value(t, head[0].start, 6)
    testing.expect_value(t, head[0].end, 10)

    tail := thor_row_stops(&editor, second)
    testing.expect_value(t, len(tail), 1)
    testing.expect_value(t, tail[0].start, 10)
    testing.expect_value(t, tail[0].end, 14)

    testing.expect_value(t, len(thor_row_stops(&editor, editview.Visual_Row{start = 20, end = 30})), 0)
}

// An empty stop has no byte to clip, so the row it sits in claims it. Two rows
// meeting at its offset would both, which is why the continuation row declines.
@(test)
test_an_empty_stop_is_marked_once :: proc(t: ^testing.T) {
    editor := overlay_editor()
    defer delete(editor.snippet_stops)
    snippet_editor(&editor, snippet.Stop{start = 10, end = 10, index = 0})

    head := thor_row_stops(&editor, editview.Visual_Row{start = 0, end = 10, first = true})
    testing.expect_value(t, len(head), 1)
    testing.expect_value(t, head[0].start, 10)
    testing.expect_value(t, head[0].end, 10)

    testing.expect_value(t, len(thor_row_stops(&editor, editview.Visual_Row{start = 10, end = 20})), 0)
    testing.expect_value(
        t,
        len(thor_row_stops(&editor, editview.Visual_Row{start = 10, end = 20, first = true})),
        1,
    )
}

// Nothing is marked when no session is live, even with stops still in the list.
@(test)
test_no_stops_without_a_live_session :: proc(t: ^testing.T) {
    editor := overlay_editor()
    defer delete(editor.snippet_stops)
    snippet_editor(&editor, snippet.Stop{start = 2, end = 5, index = 1})
    editor.snippet_active = false

    testing.expect_value(t, len(thor_row_stops(&editor, editview.Visual_Row{start = 0, end = 20, first = true})), 0)
}
