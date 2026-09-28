package thor

import "core:testing"

import "../editview"
import ui "../vendor/loom/loom"

// The swatch gap has to be one number in three places: the width Loom lays the
// row out with, the caret x the view paints at, and the byte a click resolves
// to. Loom is driven here with a fixed-advance backend, so every width below is
// exact and no font atlas is needed.

@(private = "file")
CELL :: f32(10)

@(private = "file")
swatch_run :: proc(font: ui.Font, size: f32, text: string, spacing: f32, user: rawptr) -> f32 {
    n := 0
    for _ in text {
        n += 1
    }
    return CELL * f32(n)
}

@(private = "file")
swatch_metrics :: proc(font: ui.Font, size: f32, user: rawptr) -> ui.Font_Metrics {
    s := size > 0 ? size : 16
    return {ascent = s * 0.75, descent = s * -0.25, line_gap = 0}
}

@(private = "file")
swatch_ctx :: proc(ctx: ^ui.Context) {
    b := ui.noop_backend()
    b.measure_run = swatch_run
    b.font_metrics = swatch_metrics
    ui.init(ctx, ui.Config{backend = b})
}

@(private = "file")
swatch_frame :: proc(ctx: ^ui.Context) {
    ui.begin_frame(ui.Input{dt = 0.016, viewport = {1200, 800}})
}

@(private = "file")
ROW :: `"bg": "#1A1C23",`

// The gap opens before the opening quote of the literal, not before the '#'.
@(private = "file")
ANCHOR :: 6

@(private = "file")
row_spans_for :: proc(editor: ^editview.Editor) -> ([]ui.Text_Span, []editview.Row_Swatch) {
    buffer := make([]editview.Row_Swatch, editview.MAX_ROW_SWATCHES, context.temp_allocator)
    count := editview.editor_scan_swatches(ROW, buffer)
    swatches := buffer[:count]
    return thor_row_spans(editor, ROW, 0, len(ROW), swatches), swatches
}

@(test)
test_swatch_scan_anchors_before_the_quote :: proc(t: ^testing.T) {
    buffer: [editview.MAX_ROW_SWATCHES]editview.Row_Swatch
    count := editview.editor_scan_swatches(ROW, buffer[:])
    testing.expect_value(t, count, 1)
    testing.expect_value(t, buffer[0].anchor, ANCHOR)
    testing.expect_value(t, buffer[0].color, ui.Color{0x1A, 0x1C, 0x23, 0xFF})
}

// Without a highlight to ride on, the anchor still cuts the row, so the run
// builder opens the gap there.
@(test)
test_row_spans_carry_the_gap :: proc(t: ^testing.T) {
    editor: editview.Editor
    editor.font_size = 16
    gap := editview.editor_swatch_span(&editor)

    spans, _ := row_spans_for(&editor)
    testing.expect_value(t, len(spans), 1)
    testing.expect_value(t, spans[0].start, ANCHOR)
    testing.expect_value(t, spans[0].lead, gap)
    testing.expect_value(t, ui.span_lead_before(spans, ANCHOR - 1), f32(0))
    testing.expect_value(t, ui.span_lead_before(spans, ANCHOR), gap)
    testing.expect_value(t, ui.span_lead_before(spans, len(ROW)), gap)
}

// A highlight covering the anchor is split there, so its colour survives and
// the gap still cuts the row.
@(test)
test_a_highlight_over_the_anchor_is_split :: proc(t: ^testing.T) {
    editor: editview.Editor
    editor.font_size = 16
    gap := editview.editor_swatch_span(&editor)
    red := ui.Color{255, 0, 0, 255}
    highlights := []editview.Highlight_Span{{start = 0, end = len(ROW), color = red}}
    editor.highlights = highlights

    spans, _ := row_spans_for(&editor)
    testing.expect_value(t, len(spans), 2)
    testing.expect_value(t, spans[0].start, 0)
    testing.expect_value(t, spans[0].end, ANCHOR)
    testing.expect_value(t, spans[0].lead, f32(0))
    testing.expect_value(t, spans[0].color, red)
    testing.expect_value(t, spans[1].start, ANCHOR)
    testing.expect_value(t, spans[1].end, len(ROW))
    testing.expect_value(t, spans[1].lead, gap)
    testing.expect_value(t, spans[1].color, red)
}

// What the whole feature rests on: the row Loom lays out is wider by the gap,
// the caret past the anchor sits past it, and a click comes back to the byte it
// was taken from.
@(test)
test_the_gap_moves_the_text_the_caret_and_the_hit_test :: proc(t: ^testing.T) {
    ctx: ui.Context
    swatch_ctx(&ctx)
    defer ui.destroy(&ctx)

    editor: editview.Editor
    editor.font_size = 16
    gap := editview.editor_swatch_span(&editor)

    props := ui.Props{font_size = 16, text_wrap = .None}
    it: ui.Interaction
    spans: []ui.Text_Span
    for _ in 0 ..< 2 {
        swatch_frame(&ctx)
        spans, _ = row_spans_for(&editor)
        it = ui.leaf({key = "row", text = ROW, spans = spans, props = props})
        ui.end_frame()
    }

    testing.expect_value(t, it.rect.w, CELL * f32(len(ROW)) + gap)

    swatch_frame(&ctx)
    // Before the anchor nothing moved; at and after it, everything is past the gap.
    testing.expect_value(t, ui.caret_x(ROW, ANCHOR - 1, props, spans), CELL * f32(ANCHOR - 1))
    testing.expect_value(t, ui.caret_x(ROW, ANCHOR, props, spans), CELL * f32(ANCHOR) + gap)
    testing.expect_value(t, ui.caret_x(ROW, len(ROW), props, spans), CELL * f32(len(ROW)) + gap)

    for at in ([]int{0, 3, ANCHOR, ANCHOR + 1, len(ROW) - 1, len(ROW)}) {
        x := ui.caret_x(ROW, at, props, spans)
        testing.expectf(
            t,
            ui.offset_at(ROW, x, props, spans) == at,
            "a click at the x of byte %v comes back to it, not %v",
            at,
            ui.offset_at(ROW, x, props, spans),
        )
    }
    ui.end_frame()
}

// The editor's own offset maths is what editor_pos_at resolves a click with; it
// has to report the same gap the spans do, or the two disagree by one swatch.
@(test)
test_editview_and_the_spans_report_the_same_gap :: proc(t: ^testing.T) {
    editor: editview.Editor
    editor.font_size = 16

    spans, swatches := row_spans_for(&editor)
    gap := editview.editor_swatch_span(&editor)
    for at in ([]int{0, ANCHOR - 1, ANCHOR, ANCHOR + 4, len(ROW)}) {
        mine: f32
        for swatch in swatches {
            if swatch.anchor <= at {
                mine += gap
            }
        }
        testing.expect_value(t, ui.span_lead_before(spans, at), mine)
    }
}
