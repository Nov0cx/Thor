// The design tokens of GOOD_UI.md section 5. A view takes each size, radius,
// shadow, scrim, type size and duration from here.
package thor

import "core:math"

import "../font"

import ui "../vendor/loom/loom"

// Spacing steps (5.1).
Tk_Space :: enum u8 {
    None,
    XXS,
    XS,
    S,
    M,
    L,
    XL,
    XXL,
    XXXL,
}

TK_SPACE_PX :: [Tk_Space]f32{.None = 0, .XXS = 2, .XS = 4, .S = 6, .M = 8, .L = 12, .XL = 16, .XXL = 24, .XXXL = 32}

// Bar, control and row heights (5.2).
Tk_Height :: enum u8 {
    Titlebar,
    Tabs,
    Bar,
    Control,
    Row_Compact,
    Row,
    Row_Picker,
    Row_Form,
    Row_Form_Desc,
    Row_Two_Line,
}

TK_HEIGHT_PX :: [Tk_Height]f32{
    .Titlebar = 44,
    .Tabs = 38,
    .Bar = 28,
    .Control = 28,
    .Row_Compact = 22,
    .Row = 26,
    .Row_Picker = 30,
    .Row_Form = 34,
    .Row_Form_Desc = 56,
    .Row_Two_Line = 46,
}

// Corner radius by layer (5.3).
Tk_Radius :: enum u8 {
    None,
    Control,
    Popup,
    Card,
    Modal,
}

TK_RADIUS_PX :: [Tk_Radius]f32{.None = 0, .Control = 4, .Popup = 6, .Card = 8, .Modal = 10}

// Elevation levels (5.5).
Tk_Level :: enum u8 {
    Flat,
    Popup,
    Card,
    Modal,
}

// Type sizes (5.6).
Tk_Type :: enum u8 {
    Small,
    Body,
    Title,
    Display,
}

// Modal and picker width classes (6.4, 6.5).
TK_W_QUESTION   :: f32(420)
TK_W_FORM       :: f32(520)
TK_W_PALETTE    :: f32(720)
TK_W_TOOL       :: f32(940)
TK_W_TOOL_MAX   :: f32(1080)
// The room a modal leaves to each window edge.
TK_MODAL_MARGIN :: f32(32)

// Durations in seconds (5.9).
TK_FAST   :: f32(0.1)
TK_NORMAL :: f32(0.15)

// The UI font size the pixel tokens are stated at.
TK_BASE_FONT_SIZE :: f32(18)

@(private = "file")
tk_scale: f32 = 1

// Sets the scale of every pixel token from the UI font size (9.3).
thor_set_ui_scale :: proc(font_size: int) {
    tk_scale = font_size > 0 ? f32(font_size) / TK_BASE_FONT_SIZE : 1
}

// The current UI scale.
thor_ui_scale :: proc() -> f32 {
    return tk_scale
}

// `px` at the UI scale, rounded to a whole pixel.
tk :: proc(px: f32) -> f32 {
    return math.round(px * tk_scale)
}

tk_sp :: proc(s: Tk_Space) -> f32 {
    px := TK_SPACE_PX
    return tk(px[s])
}

tk_h :: proc(h: Tk_Height) -> f32 {
    px := TK_HEIGHT_PX
    return tk(px[h])
}

tk_rad :: proc(r: Tk_Radius) -> ui.Radius {
    return ui.rad(tk_rad_px(r))
}

// The radius of `r` in pixels, for a corner set of its own.
tk_rad_px :: proc(r: Tk_Radius) -> f32 {
    px := TK_RADIUS_PX
    return tk(px[r])
}

// The radius of a shape nested `gap` inside a shape of radius `r` (5.3).
tk_rad_inner :: proc(r: Tk_Radius, gap: f32) -> f32 {
    return max(tk_rad_px(r) - gap, 0)
}

// A pill: the radius is half the height.
tk_pill :: proc(height: f32) -> ui.Radius {
    return ui.rad(height / 2)
}

tk_pad :: proc(x, y: Tk_Space) -> ui.Edges {
    return ui.xy(tk_sp(x), tk_sp(y))
}

tk_pad_all :: proc(s: Tk_Space) -> ui.Edges {
    return ui.all(tk_sp(s))
}

tk_pad_ltrb :: proc(l, t, r, b: Tk_Space) -> ui.Edges {
    return ui.ltrb(tk_sp(l), tk_sp(t), tk_sp(r), tk_sp(b))
}

tk_gap :: proc(x, y: Tk_Space) -> ui.Vec2 {
    return {tk_sp(x), tk_sp(y)}
}

// The shadow of a floating layer. The colour is the `contrast` role.
tk_shadow :: proc(thor: ^Thor, level: Tk_Level) -> ui.Shadow {
    switch level {
    case .Flat:
        return {}
    case .Popup:
        return {offset = {0, 4}, blur = 16, color = thor.theme.contrast}
    case .Card:
        return {offset = {0, 6}, blur = 24, color = thor.theme.contrast}
    case .Modal:
        return {offset = {0, 8}, blur = 32, color = thor.theme.contrast}
    }
    return {}
}

// The scrim behind a picker (level 2) or a large modal (level 3).
tk_scrim :: proc(level: Tk_Level) -> ui.Color {
    #partial switch level {
    case .Card:
        return {0, 0, 0, 120}
    case .Modal:
        return {0, 0, 0, 140}
    }
    return {}
}

// A type size from the UI font size.
tk_font :: proc(thor: ^Thor, t: Tk_Type) -> f32 {
    return tk_type_size(f32(thor.config.general.font_size), t)
}

// A type size from `body`, for a card that uses the editor font.
tk_type_size :: proc(body: f32, t: Tk_Type) -> f32 {
    switch t {
    case .Small:
        return body - 2
    case .Body:
        return body
    case .Title:
        return body + 2
    case .Display:
        return body * 2
    }
    return body
}

// The height of a code row in chrome (a diff line): the line height of the UI font size.
tk_code_row_h :: proc(thor: ^Thor) -> f32 {
    return f32(font.line_height(i32(thor.config.general.font_size)))
}

// A modal width of `class`, kept inside the window less the margin on each side.
tk_modal_w :: proc(class: f32) -> f32 {
    return max(min(tk(class), ui.viewport().x - 2 * TK_MODAL_MARGIN), 0)
}

// A modal height kept inside the window less the margin on each side.
tk_modal_h :: proc(height: f32) -> f32 {
    return max(min(tk(height), ui.viewport().y - 2 * TK_MODAL_MARGIN), 0)
}

// The colour fade of a control: hover out, press and border changes (Fast).
// Hover in and press are instant; the way out fades.
TK_FADE :: ui.Transition{props = {.Bg, .Color, .Border_Color}, dur = TK_FAST, ease = .Out_Quad, snap = {.Hover, .Active}}

// The focus ring of a control: a 1 px inset `accent` ring, shown for keyboard focus (7.4).
tk_focus_rules :: proc(thor: ^Thor) -> []ui.Rule {
    rules := make([]ui.Rule, 1, context.temp_allocator)
    rules[0] = {on = {.Focus_Visible}, props = {shadow = {spread = 1, color = thor.theme.accent_color, inset = true}}}
    return rules
}

// The opacity enter of a popup, a picker or a modal (Normal).
TK_ENTER :: ui.Transition{props = {.Opacity}, dur = TK_NORMAL, ease = .Out_Cubic}
