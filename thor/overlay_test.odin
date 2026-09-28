package thor

import "core:testing"

import "../editview"
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
