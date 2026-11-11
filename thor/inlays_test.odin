package thor

import "core:testing"

import "../editview"
import "../textedit"
import ui "../vendor/loom/loom"

// A hint before the edit keeps its offset, one after it moves, one inside it is dropped.
@(test)
test_inlays_rebase_onto_an_edit :: proc(t: ^testing.T) {
    old_text := "g(1)\nf(ab)\nh(2)"
    new_text := "g(1)\nf(xyz)\nh(2)"
    inlays   := []editview.Inlay{{offset = 2}, {offset = 7}, {offset = 8}, {offset = 12}}
    out      := make([dynamic]editview.Inlay, context.temp_allocator)
    thor_rebase_inlays(&out, inlays, old_text, new_text)

    testing.expect_value(t, len(out), 3)
    if len(out) == 3 {
        testing.expect_value(t, out[0].offset, 2)
        testing.expect_value(t, out[1].offset, 7)
        testing.expect_value(t, out[2].offset, 13)
    }
}

// An inlay and a swatch at one anchor open one gap; an inlay at the end of a row belongs to it
// only when the row ends its line.
@(test)
test_inlay_gaps_merge_with_swatches :: proc(t: ^testing.T) {
    state: textedit.State
    textedit.init(&state)
    defer textedit.destroy(&state)
    text := `f("#1A1C23")` + "\nx"
    textedit.set_text(&state, text)

    editor: editview.Editor
    editor.font_size = 16
    editor.state = &state
    inlays := []editview.Inlay{{offset = 2, label = "c:", parameter = true, pad_right = true}, {offset = 12, label = ": T"}}
    editview.editor_set_inlays(&editor, inlays)

    row := text[:12]
    buffer: [editview.MAX_ROW_SWATCHES]editview.Row_Swatch
    swatches := thor_row_swatches(row, buffer[:])
    testing.expect_value(t, len(swatches), 1)

    gaps := thor_row_gaps(&editor, 0, 12, swatches)
    testing.expect_value(t, len(gaps), 2)
    if len(gaps) == 2 {
        testing.expect_value(t, gaps[0].anchor, 2)
        testing.expect_value(t, gaps[0].width, editview.editor_swatch_span(&editor) + editview.editor_inlay_width(&editor, inlays[0]))
        testing.expect_value(t, gaps[1].anchor, 12)
    }
    spans := thor_row_spans(&editor, row, 0, 12, swatches)
    testing.expect_value(t, ui.span_lead_before(spans, 2), gaps[0].width)

    // A wrapped row ending at the hint does not take it; the next row does.
    testing.expect_value(t, len(editview.editor_row_inlays(&editor, text, 0, 2)), 0)
    testing.expect_value(t, len(editview.editor_row_inlays(&editor, text, 2, 12)), 2)
}
