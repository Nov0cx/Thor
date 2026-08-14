package ui

import rl "vendor:raylib"

// Hover explanations. A widget carries its own text (Widget.tooltip), and a
// widget whose parts are not widgets of their own — a tab, a status bar segment,
// a tree row — asks for one per frame with tooltip_request from its draw, where
// the rectangle of the part is already known.
//
// The box draws after the whole widget tree (context_draw), so it is over every
// widget without any of them knowing about it.

// Hover time before a tooltip appears.
TOOLTIP_DELAY :: 0.55

// Space between the anchor and the box.
TOOLTIP_GAP :: f32(6)

TOOLTIP_PAD_X :: f32(9)

TOOLTIP_PAD_Y :: f32(6)

// Widest the box grows before its text wraps.
TOOLTIP_MAX_WIDTH :: f32(420)

// Distance the box keeps from the screen edge.
TOOLTIP_MARGIN :: f32(4)

Tooltip_Style :: struct {
    background: rl.Color,
    border:     rl.Color,
    text:       rl.Color,
    // The second line, for a key chord.
    hint:       rl.Color,
    font_size:  i32,
}

Tooltip_State :: struct {
    style:       Tooltip_Style,
    enabled:     bool,
    // This frame's request. Borrowed: callers pass temp-allocated text, which
    // dies at the end of the frame.
    text:        string,
    hint:        string,
    anchor:      rl.Rectangle,
    requested:   bool,
    // The request the dwell timer runs on, copied so it outlives the frame that
    // asked for it.
    held_text:   [dynamic]u8, // owned
    held_hint:   [dynamic]u8, // owned
    held_anchor: rl.Rectangle,
    held_since:  f64,
    held_valid:  bool,
    shown:       bool,
}

tooltip_init :: proc(state: ^Tooltip_State) {
    state.enabled = true
    state.held_text = make([dynamic]u8, 0, 64)
    state.held_hint = make([dynamic]u8, 0, 16)
    state.style = Tooltip_Style {
        background = rl.Color {30, 34, 45, 245},
        border     = rl.Color {60, 66, 82, 255},
        text       = rl.Color {228, 232, 241, 255},
        hint       = rl.Color {138, 146, 166, 255},
        font_size  = 15,
    }
}

tooltip_destroy :: proc(state: ^Tooltip_State) {
    delete(state.held_text)
    delete(state.held_hint)
    state.held_text = nil
    state.held_hint = nil
}

context_set_tooltip_style :: proc(ctx: ^Context, style: Tooltip_Style) {
    ctx.tooltip.style = style
}

context_set_tooltips_enabled :: proc(ctx: ^Context, enabled: bool) {
    ctx.tooltip.enabled = enabled
    if !enabled {
        tooltip_clear(&ctx.tooltip)
    }
}

// Asks for a tooltip over `anchor` this frame. Call it from a draw, once the
// part's rectangle is known; the last call of a frame wins, so a child drawn
// after its parent replaces the parent's.
tooltip_request :: proc(ctx: ^Context, anchor: rl.Rectangle, text: string, hint := "") {
    if !ctx.tooltip.enabled || text == "" {
        return
    }
    ctx.tooltip.text = text
    ctx.tooltip.hint = hint
    ctx.tooltip.anchor = anchor
    ctx.tooltip.requested = true
}

tooltip_held_text :: proc(state: ^Tooltip_State) -> string {
    return string(state.held_text[:])
}

tooltip_held_hint :: proc(state: ^Tooltip_State) -> string {
    return string(state.held_hint[:])
}

tooltip_clear :: proc(state: ^Tooltip_State) {
    clear(&state.held_text)
    clear(&state.held_hint)
    state.held_valid = false
    state.shown = false
}

// Adopts the frame's request and restarts the dwell.
@(private = "file")
tooltip_hold :: proc(state: ^Tooltip_State, now: f64) {
    clear(&state.held_text)
    append(&state.held_text, state.text)
    clear(&state.held_hint)
    append(&state.held_hint, state.hint)
    state.held_anchor = state.anchor
    state.held_since = now
    state.held_valid = true
    state.shown = false
}

// The dwell timer over this frame's request. True when the box must draw.
// A different text, hint or anchor restarts the dwell, and so does movement
// before it elapses — so a cursor crossing a row never flashes a tooltip, while
// a shown one survives small movement inside its anchor.
tooltip_step :: proc(state: ^Tooltip_State, now: f64, moved, suppressed: bool) -> bool {
    if suppressed || !state.requested || state.text == "" {
        tooltip_clear(state)
        return false
    }

    if !state.held_valid || state.anchor != state.held_anchor ||
       tooltip_held_text(state) != state.text || tooltip_held_hint(state) != state.hint {
        tooltip_hold(state, now)
    } else if !state.shown && moved {
        state.held_since = now
    }

    state.shown = now - state.held_since >= TOOLTIP_DELAY
    return state.shown
}

// Top-left of the box: under the anchor, over it when the space below is too
// small, and always inside the screen.
tooltip_place :: proc(anchor: rl.Rectangle, size, screen: rl.Vector2) -> rl.Vector2 {
    pos := rl.Vector2 {anchor.x, anchor.y + anchor.height + TOOLTIP_GAP}

    if pos.y + size.y > screen.y - TOOLTIP_MARGIN {
        above := anchor.y - TOOLTIP_GAP - size.y
        // A box too tall for either side stays below and is clamped, rather
        // than being pushed off the top.
        if above >= TOOLTIP_MARGIN {
            pos.y = above
        }
    }

    pos.x = clamp(pos.x, TOOLTIP_MARGIN, max(TOOLTIP_MARGIN, screen.x - size.x - TOOLTIP_MARGIN))
    pos.y = clamp(pos.y, TOOLTIP_MARGIN, max(TOOLTIP_MARGIN, screen.y - size.y - TOOLTIP_MARGIN))
    return pos
}

// The tooltip of the hovered widget, or of the nearest ancestor that has one.
// The fallback for the frames no widget asked for a tooltip in.
@(private = "file")
tooltip_from_hot :: proc(ctx: ^Context) {
    for widget := ctx.hot; widget != nil; widget = widget.parent {
        if widget.tooltip != "" {
            tooltip_request(ctx, widget.bounds, widget.tooltip, widget.tooltip_hint)
            return
        }
    }
}

// Closes the frame's draw: resolves the request, runs the dwell and draws.
tooltip_frame :: proc(ctx: ^Context) {
    state := &ctx.tooltip
    if !state.requested {
        tooltip_from_hot(ctx)
    }

    // A held button means a drag or a click, not a question about a control.
    suppressed := !state.enabled || ctx.hot == nil || context_active(ctx) != nil
    moved := ctx.mouse_pos != ctx.prev_mouse_pos
    if tooltip_step(state, rl.GetTime(), moved, suppressed) {
        tooltip_draw(state)
    }

    state.requested = false
    state.text = ""
    state.hint = ""
}

@(private = "file")
tooltip_draw :: proc(state: ^Tooltip_State) {
    size := state.style.font_size
    if size <= 0 {
        size = 15
    }
    hint_size := max(i32(11), size - 2)

    text := tooltip_held_text(state)
    hint := tooltip_held_hint(state)
    lines := wrap_text(text, TOOLTIP_MAX_WIDTH, size)
    line_height := cast(f32) text_line_height(size)

    width: f32 = 0
    for line in lines {
        width = max(width, cast(f32) measure_text(line, size))
    }
    height := line_height * cast(f32) len(lines)
    if hint != "" {
        width = max(width, cast(f32) measure_text(hint, hint_size))
        height += cast(f32) text_line_height(hint_size)
    }

    box := rl.Vector2 {width + TOOLTIP_PAD_X * 2, height + TOOLTIP_PAD_Y * 2}
    screen := rl.Vector2 {cast(f32) rl.GetScreenWidth(), cast(f32) rl.GetScreenHeight()}
    origin := tooltip_place(state.held_anchor, box, screen)
    rect := rl.Rectangle {origin.x, origin.y, box.x, box.y}

    rl.DrawRectangleRec(rect, state.style.background)
    rl.DrawRectangleLinesEx(rect, 1, state.style.border)

    x := cast(i32) (origin.x + TOOLTIP_PAD_X)
    y := origin.y + TOOLTIP_PAD_Y
    for line in lines {
        draw_text(line, x, cast(i32) y, size, state.style.text)
        y += line_height
    }
    if hint != "" {
        draw_text(hint, x, cast(i32) y, hint_size, state.style.hint)
    }
}
