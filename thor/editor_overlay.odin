// The editor pane's overlays: the whitespace markers, the go-to-definition
// underline and the snippet stop boxes inside a row, and the three cards that
// float over the pane. Every one reads state `editview` already holds; none of it
// is retained here.
package thor

import "core:strings"

import "../editview"
import "../font"
import "../render"
import ui "../vendor/loom/loom"

// Padding inside a card, and the gap between a card and the line it points at.
@(private = "file")
CARD_PAD_X :: f32(8)
@(private = "file")
CARD_PAD_Y :: f32(4)
@(private = "file")
CARD_GAP :: f32(4)

// Left inset of a candidate's text inside the completion box.
@(private = "file")
COMPLETION_TEXT_X :: f32(8)

// Dot size as a fraction of the character height, and the alpha the markers are
// drawn at, so indentation reads as texture and not as text.
@(private = "file")
WHITESPACE_DOT_SCALE :: f32(0.14)
@(private = "file")
WHITESPACE_ALPHA :: u8(130)

// One whitespace marker on a row: the pen span the character occupies, and
// whether it is a tab.
Row_Marker :: struct {
    x0, x1: f32,
    tab:    bool,
}

// The leading-whitespace markers of one row, in the temp allocator. Spans come
// from `thor_row_x`, so a marker sits under the column it stands for even on a
// row that reserves a swatch gap. Indentation only: the scan stops at the first
// character that is not a space or a tab.
thor_row_markers :: proc(
    editor: ^editview.Editor,
    text: string,
    row: editview.Visual_Row,
    spans: []ui.Text_Span,
    text_x: f32,
) -> []Row_Marker {
    out := make([dynamic]Row_Marker, 0, 16, context.temp_allocator)
    prev := text_x
    for pos := row.start; pos < row.end && pos < len(text); pos += 1 {
        b := text[pos]
        if b != ' ' && b != '\t' {
            break
        }
        rel := pos - row.start
        next := text_x + thor_row_x(editor, text, row.start, row.end, pos + 1, spans)
        // A gap opening before the next byte sits after this character, not
        // across it, so the marker keeps the character's own advance.
        lead := ui.span_lead_before(spans, rel + 1) - ui.span_lead_before(spans, rel)
        append(&out, Row_Marker{x0 = prev, x1 = next - lead, tab = b == '\t'})
        prev = next
    }
    if len(out) == 0 {
        return nil
    }
    return out[:]
}

// Marks the leading whitespace of one row: a dot per space, an arrow per tab.
@(private)
thor_paint_row_whitespace :: proc(
    thor: ^Thor,
    editor: ^editview.Editor,
    text: string,
    row: editview.Visual_Row,
    spans: []ui.Text_Span,
    text_x, row_y: f32,
) {
    color := thor.theme.disabled
    color.a = WHITESPACE_ALPHA
    size := f32(editor.font_size)
    mid_y := row_y + render.half_leading(size) + size * 0.5
    dot := max(1, size * WHITESPACE_DOT_SCALE)

    for marker in thor_row_markers(editor, text, row, spans, text_x) {
        if marker.tab {
            thor_paint_tab_arrow(marker.x0, marker.x1, mid_y, dot, color)
            continue
        }
        ui.paint_rect(
            {marker.x0 + (marker.x1 - marker.x0 - dot) * 0.5, mid_y - dot * 0.5, dot, dot},
            color,
            {},
            true,
        )
    }
}

// An arrow from x0 to x1 standing for one tab. A tab too narrow for the head (a
// font that gives it almost no advance) gets the shaft only.
@(private = "file")
thor_paint_tab_arrow :: proc(x0, x1, y, size: f32, color: ui.Color) {
    left := x0 + size
    right := x1 - size
    if right <= left {
        return
    }
    ui.paint_line({left, y}, {right, y}, 1, color)
    if right - left < size * 2 {
        return
    }
    ui.paint_line({right - size, y - size}, {right, y}, 1, color)
    ui.paint_line({right - size, y + size}, {right, y}, 1, color)
}

// The part of [lo, hi) that falls on `row`. A wrapped line holds a word over two
// rows, so each underlines its own share. `lo` below zero means no word is
// hovered; ok=false when the range misses the row.
thor_row_link_bytes :: proc(row: editview.Visual_Row, lo, hi: int) -> (start, end: int, ok: bool) {
    if lo < 0 || hi <= row.start || lo >= row.end {
        return 0, 0, false
    }
    start = max(lo, row.start)
    end = min(hi, row.end)
    return start, end, end > start
}

// Underlines the part of [lo, hi) that falls on this row: the ctrl + hover
// affordance for go-to-definition.
@(private)
thor_paint_row_link :: proc(
    thor: ^Thor,
    editor: ^editview.Editor,
    text: string,
    row: editview.Visual_Row,
    spans: []ui.Text_Span,
    text_x, row_y: f32,
    lo, hi: int,
) {
    start, end, ok := thor_row_link_bytes(row, lo, hi)
    if !ok {
        return
    }
    x0 := text_x + thor_row_x(editor, text, row.start, row.end, start, spans)
    x1 := text_x + thor_row_x(editor, text, row.start, row.end, end, spans)
    if x1 <= x0 {
        return
    }
    size := f32(editor.font_size)
    y := row_y + render.half_leading(size) + size - 1
    ui.paint_rect({x0, y, x1 - x0, 1}, thor.theme.foreground, {}, true)
}

// One snippet stop's mark on a row, in bytes, and whether it belongs to the
// tabstop the caret is on. An empty stop has start == end.
Row_Stop :: struct {
    start, end: int,
    active:     bool,
}

// The live snippet session's stops that fall on `row`, in the temp allocator.
// Mirrors share a tabstop number, so every occurrence of the number the caret is
// on is marked and the rest read as what tab reaches next.
thor_row_stops :: proc(editor: ^editview.Editor, row: editview.Visual_Row) -> []Row_Stop {
    if !editor.snippet_active || len(editor.snippet_stops) == 0 {
        return nil
    }
    active := editor.snippet_stops[editor.snippet_at].index
    out := make([dynamic]Row_Stop, 0, len(editor.snippet_stops), context.temp_allocator)
    for stop in editor.snippet_stops {
        if stop.end > stop.start {
            if start, end, ok := thor_row_link_bytes(row, stop.start, stop.end); ok {
                append(&out, Row_Stop{start = start, end = end, active = stop.index == active})
            }
            continue
        }
        // An empty stop covers no byte to clip. A soft wrap makes two rows meet
        // at one offset; the row above it keeps the mark.
        if stop.start < row.start || stop.start > row.end {
            continue
        }
        if stop.start == row.start && !row.first {
            continue
        }
        append(&out, Row_Stop{start = stop.start, end = stop.start, active = stop.index == active})
    }
    if len(out) == 0 {
        return nil
    }
    return out[:]
}

// Boxes the live snippet session's stops on one row: the tabstop the caret is on
// in the accent, the ones tab still reaches dim. An empty stop is a tick, having
// no width to box.
@(private)
thor_paint_row_snippet_stops :: proc(
    thor: ^Thor,
    editor: ^editview.Editor,
    text: string,
    row: editview.Visual_Row,
    spans: []ui.Text_Span,
    text_x, row_y: f32,
) {
    size := f32(editor.font_size)
    y := row_y + render.half_leading(size)
    for stop in thor_row_stops(editor, row) {
        color := stop.active ? thor.theme.accent_color : thor.theme.disabled
        x0 := text_x + thor_row_x(editor, text, row.start, row.end, stop.start, spans)
        x1 := text_x + thor_row_x(editor, text, row.start, row.end, stop.end, spans)
        if x1 - x0 < 1 {
            ui.paint_line({x0, y}, {x0, y + size}, 1, color)
            continue
        }
        thor_paint_box({x0, y, x1 - x0, size}, color)
    }
}

// A one-pixel outline over the glyphs.
@(private = "file")
thor_paint_box :: proc(rect: ui.Rect, color: ui.Color) {
    x1 := rect.x + rect.w
    y1 := rect.y + rect.h
    ui.paint_line({rect.x, rect.y}, {x1, rect.y}, 1, color)
    ui.paint_line({rect.x, y1}, {x1, y1}, 1, color)
    ui.paint_line({rect.x, rect.y}, {rect.x, y1}, 1, color)
    ui.paint_line({x1, rect.y}, {x1, y1}, 1, color)
}

// The three cards that stand over the pane. Each returns at once when its own
// state says it is down.
@(private)
thor_editor_overlays :: proc(thor: ^Thor, editor: ^editview.Editor) {
    thor_completion_card(thor, editor)
    thor_hover_card(thor, editor)
    thor_signature_card(thor, editor)
}

// The candidate list under the caret. The box comes from
// `editview.editor_completion_rects`, which the press, the wheel and the hover
// hit-test read as well, so the card the user sees is the one they can click.
// Pass-through: the pane owns that hit test, and a clickable card would take the
// press before it.
@(private = "file")
thor_completion_card :: proc(thor: ^Thor, editor: ^editview.Editor) {
    box, row_h, top, ok := editview.editor_completion_rects(editor)
    if !ok || row_h <= 0 {
        return
    }

    ui.scope(
        {
            key = "completion",
            // Clipped: the box is capped at 420px, so a long candidate would
            // otherwise run out past the border.
            flags = {.Floating, .Pass_Through, .Clip},
            props = {
                position = .Fixed,
                inset = {l = box.x, t = box.y},
                w = ui.Px(box.w),
                h = ui.Px(box.h),
                bg = thor.theme.second_background,
                radius = ui.rad(6),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = {offset = {0, 4}, blur = 16, color = thor.theme.contrast},
            },
        },
    )

    visible := min(len(editor.completion_rows) - top, editview.COMPLETION_MAX_ROWS)
    for i in 0 ..< visible {
        index := top + i
        y := 2 + f32(i) * row_h
        if index == editor.completion_selected {
            ui.paint_rect({0, y, box.w, row_h}, thor.theme.selection_background)
        }
        candidate := editor.completion_rows[index]
        // A buffer word carries no tint of its own.
        color := candidate.color.a == 0 ? thor.theme.foreground : candidate.color
        ui.push_id_int(i64(i))
        ui.leaf(
            {
                key = "row",
                text = candidate.text,
                props = {
                    position = .Absolute,
                    inset = {COMPLETION_TEXT_X, y, 0, 0},
                    w = ui.FIT,
                    h = ui.Px(row_h),
                    color = color,
                    font = thor.font_mono,
                    font_size = f32(editor.font_size),
                    text_wrap = .None,
                },
            },
        )
        ui.pop_id()
    }
}

// What a dwell resolved, over the symbol it describes. A diagnostic tints the
// border with its severity.
@(private = "file")
thor_hover_card :: proc(thor: ^Thor, editor: ^editview.Editor) {
    if !editor.hover_active || editor.hover_text == "" {
        return
    }
    border := editor.hover_accent
    if border.a == 0 {
        border = thor.theme.accent_color
    }
    thor_editor_card(thor, editor, "hover", editor.hover_text, editor.hover_start, border)
}

// The enclosing call's signature, over the caret.
@(private = "file")
thor_signature_card :: proc(thor: ^Thor, editor: ^editview.Editor) {
    if !editor.signature_active || editor.signature_text == "" {
        return
    }
    thor_editor_card(
        thor,
        editor,
        "signature",
        editor.signature_text,
        editor.signature_anchor,
        thor.theme.accent_color,
    )
}

// One card of monospaced lines, anchored above byte `anchor` and flipped below it
// when there is no room, then nudged sideways to stay inside the pane. The box is
// measured here rather than fitted by Loom, so its place is right on the frame it
// appears rather than the one after.
@(private = "file")
thor_editor_card :: proc(
    thor: ^Thor,
    editor: ^editview.Editor,
    key, text: string,
    anchor: int,
    border: ui.Color,
) {
    x, y, line_h, ok := editview.editor_screen_at(editor, anchor)
    if !ok || line_h <= 0 {
        return
    }

    lines := 0
    text_w: f32
    rest := text
    for line in strings.split_lines_iterator(&rest) {
        lines += 1
        text_w = max(text_w, f32(font.measure(line, editor.font_size, "")))
    }
    if lines == 0 {
        return
    }

    // A word wider than the wrap budget keeps its own line, and a pane too narrow
    // to wrap in leaves the text whole, so the box is capped at the pane and the
    // node clips what does not fit rather than hanging over the explorer.
    width := min(text_w + CARD_PAD_X * 2, editor.view.w)
    height := f32(lines) * line_h + CARD_PAD_Y * 2

    box_x := x
    box_y := y - height - CARD_GAP
    if box_y < editor.view.y {
        box_y = y + line_h + CARD_GAP // flip below the line
    }
    if box_x + width > editor.view.x + editor.view.w {
        box_x = editor.view.x + editor.view.w - width - CARD_GAP
    }
    box_x = max(box_x, editor.view.x)

    ui.scope(
        {
            key = key,
            flags = {.Floating, .Pass_Through, .Clip},
            props = {
                position = .Fixed,
                inset = {l = box_x, t = box_y},
                w = ui.Px(width),
                h = ui.Px(height),
                dir = .Column,
                pad = ui.xy(CARD_PAD_X, CARD_PAD_Y),
                bg = thor.theme.second_background,
                radius = ui.rad(6),
                border = {width = ui.all(1), color = border},
                shadow = {offset = {0, 4}, blur = 16, color = thor.theme.contrast},
            },
        },
    )

    index := 0
    rest = text
    for line in strings.split_lines_iterator(&rest) {
        ui.push_id_int(i64(index))
        ui.leaf(
            {
                key = "line",
                text = line,
                props = {
                    w = ui.Grow(1),
                    h = ui.Px(line_h),
                    color = thor.theme.foreground,
                    font = thor.font_mono,
                    font_size = f32(editor.font_size),
                    text_wrap = .None,
                },
            },
        )
        ui.pop_id()
        index += 1
    }
}
