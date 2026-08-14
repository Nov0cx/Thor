package widgets

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

import "../ui"

// The welcome page's "Tip of the Day" card. Drawn in the settings modal's style
// — the same rounded box, header line and icon buttons — so the two read as one
// design. The owner fills it with one tip and answers the arrows; the card holds
// no tip list of its own.

// Fired by the arrows. `delta` is -1 for the previous tip and +1 for the next.
Tip_Step_Proc :: #type proc(data: rawptr, delta: int)

// Fired by the close box and by the "never again" line under it. `never_again`
// says which: the box closes this card, the line asks for no more tips at all.
Tip_Close_Proc :: #type proc(data: rawptr, never_again: bool)

// Where the card sits in the bounds it gets. `Fill` takes them, for a card in a
// column; `Float` puts a box of float_width in the bottom right corner, for the
// card that opens over the editor.
Tip_Placement :: enum {
    Fill,
    Float,
}

@(private = "file")
TIP_PAD :: f32(16)
// Header height, which the separator lies on the bottom edge of.
@(private = "file")
TIP_HEADER_HEIGHT :: f32(34)
@(private = "file")
TIP_ARROW_SIZE :: f32(24)
@(private = "file")
TIP_ICON_SIZE :: i32(16)
// Distance a floating card keeps from the edges of the area it floats over.
@(private = "file")
TIP_FLOAT_MARGIN :: f32(16)

// The line that turns the tip of the day off for good.
TIP_NEVER_TEXT :: "Don't show tips again"

Tip_Card :: struct {
    using widget: ui.Widget,
    title:            string, // owned
    body:             string, // owned
    shortcut:         string, // owned
    // Which tip of how many, for the footer. A count of 0 hides the arrows.
    index:            int,
    count:            int,
    on_step:          Tip_Step_Proc,
    step_data:        rawptr,
    // Set only on a card that can be closed, which is what draws the close box
    // and the "never again" line.
    on_close:         Tip_Close_Proc,
    close_data:       rawptr,
    placement:        Tip_Placement,
    float_width:      f32,
    font_size:        i32,
    title_font_size:  i32,
    background_color: rl.Color,
    border_color:     rl.Color,
    text_color:       rl.Color,
    muted_color:      rl.Color,
    accent_color:     rl.Color,
}

tip_card_vtable := ui.Widget_VTable {
    layout = tip_card_layout,
    handle_event = tip_card_handle_event,
    draw = tip_card_draw,
    destroy = tip_card_destroy,
}

tip_card_create :: proc(id: string) -> ^Tip_Card {
    card := new(Tip_Card)
    ui.widget_init(&card.widget, id, tip_card_vtable)
    card.font_size = 15
    card.title_font_size = 17
    card.background_color = rl.Color {23, 26, 37, 255}
    card.border_color = rl.Color {52, 58, 74, 255}
    card.text_color = rl.Color {228, 232, 241, 255}
    card.muted_color = rl.Color {138, 146, 166, 255}
    card.accent_color = rl.Color {110, 160, 240, 255}
    card.min_size = rl.Vector2 {0, 160}
    card.float_width = 380
    return card
}

// Makes the card float in the bottom right corner of the bounds it gets,
// instead of taking them.
tip_card_set_float :: proc(card: ^Tip_Card, width: f32) -> ^Tip_Card {
    card.placement = .Float
    card.float_width = width
    return card
}

// Gives the card a close box and the line that turns tips off. A card without
// this shows neither.
tip_card_set_on_close :: proc(card: ^Tip_Card, on_close: Tip_Close_Proc, data: rawptr) -> ^Tip_Card {
    card.on_close = on_close
    card.close_data = data
    return card
}

tip_card_set_colors :: proc(card: ^Tip_Card, background, border, text, muted, accent: rl.Color) -> ^Tip_Card {
    card.background_color = background
    card.border_color = border
    card.text_color = text
    card.muted_color = muted
    card.accent_color = accent
    return card
}

tip_card_set_on_step :: proc(card: ^Tip_Card, on_step: Tip_Step_Proc, data: rawptr) -> ^Tip_Card {
    card.on_step = on_step
    card.step_data = data
    return card
}

// Points the card at one tip. Clones, so the owner may pass a tip that a
// settings reload is about to free.
tip_card_set_tip :: proc(card: ^Tip_Card, title, body, shortcut: string, index, count: int) {
    delete(card.title)
    delete(card.body)
    delete(card.shortcut)
    card.title = strings.clone(title)
    card.body = strings.clone(body)
    card.shortcut = strings.clone(shortcut)
    card.index = index
    card.count = count
}

// The close box, at the right of the header. An empty rectangle on a card that
// cannot be closed.
tip_card_close_rect :: proc(card: ^Tip_Card) -> rl.Rectangle {
    if card.on_close == nil {
        return {}
    }
    return rl.Rectangle {
        card.bounds.x + card.bounds.width - TIP_PAD - TIP_ARROW_SIZE,
        card.bounds.y + (TIP_HEADER_HEIGHT - TIP_ARROW_SIZE) * 0.5,
        TIP_ARROW_SIZE,
        TIP_ARROW_SIZE,
    }
}

// The previous- and next-tip boxes, left of the close box. Both are empty
// rectangles while there is no more than one tip to step through.
tip_card_arrow_rects :: proc(card: ^Tip_Card) -> (previous, next: rl.Rectangle) {
    if card.count <= 1 {
        return {}, {}
    }
    y := card.bounds.y + (TIP_HEADER_HEIGHT - TIP_ARROW_SIZE) * 0.5
    right := card.bounds.x + card.bounds.width - TIP_PAD
    if close := tip_card_close_rect(card); close.width > 0 {
        right = close.x - 4
    }
    next = rl.Rectangle {right - TIP_ARROW_SIZE, y, TIP_ARROW_SIZE, TIP_ARROW_SIZE}
    previous = rl.Rectangle {next.x - TIP_ARROW_SIZE - 4, y, TIP_ARROW_SIZE, TIP_ARROW_SIZE}
    return
}

// The "never again" line, on the bottom edge of a card that can be closed.
tip_card_never_rect :: proc(card: ^Tip_Card) -> rl.Rectangle {
    if card.on_close == nil {
        return {}
    }
    height := cast(f32) ui.text_line_height(card.font_size)
    return rl.Rectangle {
        card.bounds.x + TIP_PAD,
        card.bounds.y + card.bounds.height - TIP_PAD - height,
        cast(f32) ui.measure_text(TIP_NEVER_TEXT, card.font_size),
        height,
    }
}

// Height the card needs at `width`: the header, then the wrapped title, body and
// chord, then the "never again" line where there is one. The body of a tip is a
// paragraph, so a fixed height would either clip the long ones or leave a gap
// under the short ones.
tip_card_content_height :: proc(card: ^Tip_Card, width: f32) -> f32 {
    if card.title == "" || width <= 0 {
        return 0
    }
    text_width := max(1, width - TIP_PAD * 2)

    height := TIP_HEADER_HEIGHT + 12
    height += cast(f32) len(ui.wrap_text(card.title, text_width, card.title_font_size)) *
        cast(f32) ui.text_line_height(card.title_font_size)
    height += 4
    height += cast(f32) len(ui.wrap_text(card.body, text_width, card.font_size)) *
        cast(f32) ui.text_line_height(card.font_size)
    if card.shortcut != "" {
        height += 4 + cast(f32) ui.text_line_height(card.font_size)
    }
    if card.on_close != nil {
        height += 10 + cast(f32) ui.text_line_height(card.font_size)
    }
    return height + TIP_PAD
}

tip_card_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    card := cast(^Tip_Card) widget
    if card.placement == .Float {
        // The box is measured and placed in the same pass, so a floating card
        // needs no second frame to settle after its tip changes.
        width := min(card.float_width, max(1, bounds.width - TIP_FLOAT_MARGIN * 2))
        height := min(tip_card_content_height(card, width), max(1, bounds.height - TIP_FLOAT_MARGIN * 2))
        card.bounds = rl.Rectangle {
            bounds.x + bounds.width - width - TIP_FLOAT_MARGIN,
            bounds.y + bounds.height - height - TIP_FLOAT_MARGIN,
            width,
            height,
        }
        return
    }

    card.bounds = bounds
    // The height follows the text, which needs the width this layout just gave.
    // The parent stack reads min_size before it lays a child out, so the new
    // height lands on the next frame; the welcome page is static, so it never
    // shows.
    card.min_size.y = tip_card_content_height(card, bounds.width)
}

tip_card_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    card := cast(^Tip_Card) widget
    if event.kind != .Click {
        return false
    }

    if card.on_close != nil {
        if rl.CheckCollisionPointRec(event.mouse_position, tip_card_close_rect(card)) {
            card.on_close(card.close_data, false)
            return true
        }
        if rl.CheckCollisionPointRec(event.mouse_position, tip_card_never_rect(card)) {
            card.on_close(card.close_data, true)
            return true
        }
    }

    if card.on_step == nil {
        return false
    }
    previous, next := tip_card_arrow_rects(card)
    if rl.CheckCollisionPointRec(event.mouse_position, previous) {
        card.on_step(card.step_data, -1)
        return true
    }
    if rl.CheckCollisionPointRec(event.mouse_position, next) {
        card.on_step(card.step_data, 1)
        return true
    }
    return false
}

tip_card_draw :: proc(widget: ^ui.Widget, ctx: ^ui.Context) {
    card := cast(^Tip_Card) widget
    if card.title == "" {
        return
    }

    rl.DrawRectangleRounded(card.bounds, SETTINGS_ROUNDNESS, 8, card.background_color)
    rl.DrawRectangleRoundedLinesEx(card.bounds, SETTINGS_ROUNDNESS, 8, 1, card.border_color)

    ui.begin_clip(card.bounds)
    defer ui.end_clip()

    // Header: the icon, the label, the counter and the two arrows.
    header_y := cast(i32) (card.bounds.y + (TIP_HEADER_HEIGHT - cast(f32) TIP_ICON_SIZE) * 0.5)
    ui.draw_icon("bulb", cast(i32) (card.bounds.x + TIP_PAD), header_y, TIP_ICON_SIZE, card.accent_color)
    ui.draw_text(
        "Tip of the Day",
        cast(i32) (card.bounds.x + TIP_PAD + cast(f32) TIP_ICON_SIZE + 8),
        cast(i32) (card.bounds.y + (TIP_HEADER_HEIGHT - cast(f32) card.font_size) * 0.5),
        card.font_size,
        card.muted_color,
    )
    tip_card_draw_header_controls(card, ctx)

    rl.DrawRectangleRec(
        rl.Rectangle {card.bounds.x + 1, card.bounds.y + TIP_HEADER_HEIGHT, card.bounds.width - 2, 1},
        rl.Color {card.muted_color.r, card.muted_color.g, card.muted_color.b, 45},
    )

    x := cast(i32) (card.bounds.x + TIP_PAD)
    y := card.bounds.y + TIP_HEADER_HEIGHT + 12
    width := card.bounds.width - TIP_PAD * 2

    for line in ui.wrap_text(card.title, width, card.title_font_size) {
        ui.draw_text(line, x, cast(i32) y, card.title_font_size, card.text_color)
        y += cast(f32) ui.text_line_height(card.title_font_size)
    }
    y += 4
    for line in ui.wrap_text(card.body, width, card.font_size) {
        ui.draw_text(line, x, cast(i32) y, card.font_size, card.muted_color)
        y += cast(f32) ui.text_line_height(card.font_size)
    }
    if card.shortcut != "" {
        y += 4
        ui.draw_text(card.shortcut, x, cast(i32) y, card.font_size, card.accent_color)
    }
    tip_card_draw_never(card, ctx)
}

// The counter, the two arrows and the close box. Split out so the draw above
// stays one pass down the card.
@(private = "file")
tip_card_draw_header_controls :: proc(card: ^Tip_Card, ctx: ^ui.Context) {
    if previous, next := tip_card_arrow_rects(card); previous.width > 0 {
        counter := fmt.tprintf("%d of %d", card.index + 1, card.count)
        ui.draw_text(
            counter,
            cast(i32) (previous.x - 10 - cast(f32) ui.measure_text(counter, card.font_size)),
            cast(i32) (card.bounds.y + (TIP_HEADER_HEIGHT - cast(f32) card.font_size) * 0.5),
            card.font_size,
            card.muted_color,
        )

        tip_card_draw_arrow(card, ctx, previous, "chevron-left", "Previous tip")
        tip_card_draw_arrow(card, ctx, next, "chevron-right", "Next tip")
    }

    if close := tip_card_close_rect(card); close.width > 0 {
        tip_card_draw_arrow(card, ctx, close, "x", "Close this tip")
    }
}

// The line that turns tips off, on the bottom edge of a card that can be closed.
@(private = "file")
tip_card_draw_never :: proc(card: ^Tip_Card, ctx: ^ui.Context) {
    rect := tip_card_never_rect(card)
    if rect.width == 0 {
        return
    }

    hovered := ctx.hot == &card.widget && rl.CheckCollisionPointRec(ctx.mouse_pos, rect)
    color := hovered ? card.text_color : card.muted_color
    ui.draw_text(TIP_NEVER_TEXT, cast(i32) rect.x, cast(i32) rect.y, card.font_size, color)
    if hovered {
        rl.DrawRectangleRec(rl.Rectangle {rect.x, rect.y + rect.height - 2, rect.width, 1}, color)
        ui.tooltip_request(ctx, rect, "Turn the tip of the day off")
    }
}

@(private = "file")
tip_card_draw_arrow :: proc(card: ^Tip_Card, ctx: ^ui.Context, rect: rl.Rectangle, icon, tip: string) {
    hovered := ctx.hot == &card.widget && rl.CheckCollisionPointRec(ctx.mouse_pos, rect)
    if hovered {
        rl.DrawRectangleRounded(rect, 0.35, 6, rl.Color {
            card.accent_color.r, card.accent_color.g, card.accent_color.b, 25,
        })
        ui.tooltip_request(ctx, rect, tip)
    }
    ui.draw_icon(
        icon,
        cast(i32) (rect.x + (rect.width - cast(f32) TIP_ICON_SIZE) * 0.5),
        cast(i32) (rect.y + (rect.height - cast(f32) TIP_ICON_SIZE) * 0.5),
        TIP_ICON_SIZE,
        hovered ? card.accent_color : card.muted_color,
    )
}

tip_card_destroy :: proc(widget: ^ui.Widget) {
    card := cast(^Tip_Card) widget
    delete(card.title)
    delete(card.body)
    delete(card.shortcut)
    free(card)
}
