// A centered modal that edits one color: a saturation/value square, a hue strip,
// an alpha strip and a hex field. Every change previews live, and Escape or an
// outside click asks the host to put back what it had.
//
// HSV is the authority while the picker is open: RGB loses the hue at saturation
// 0 and both hue and saturation at value 0, so a drag into a corner and back out
// would come back a different color.
package thor

import "core:strings"
import rl "vendor:raylib"

import "../theme"
import ui "../vendor/loom/loom"

// Fired on every change while the picker is open — a drag frame, or a hex the
// user committed. The host applies it live.
Color_Preview_Proc :: #type proc(data: rawptr, id: string, color: ui.Color)
// Fired on OK: apply and persist.
Color_Commit_Proc  :: #type proc(data: rawptr, id: string, color: ui.Color)
// Fired on Escape, Cancel or an outside click; the host restores what it had.
Color_Cancel_Proc  :: #type proc(data: rawptr, id: string)

COLOR_PICKER_WIDTH    :: f32(340)
COLOR_PICKER_SQUARE_H :: f32(200)
COLOR_PICKER_STRIP_H  :: f32(16)

Color_Picker :: struct {
    title:         string, // owned
    key:           string, // owned; the host's key for what is being edited
    hue:           f32,    // 0 to 360
    sat:           f32,    // 0 to 1
    val:           f32,    // 0 to 1
    alpha:         f32,    // 0 to 1
    // The color at open: the old swatch, and what a cancel means.
    original:      ui.Color,
    hex:           [dynamic]u8, // owned; ui.input edits it in place
    preview:       Color_Preview_Proc,
    commit:        Color_Commit_Proc,
    cancel:        Color_Cancel_Proc,
    data:          rawptr,
    // Pane key the focus goes back to when the picker closes.
    return_focus:  string,
    // The hex field takes the focus on the next frame.
    focus_pending: bool,
}

thor_color_picker_init :: proc(thor: ^Thor) {
    thor.color_picker.hex = make([dynamic]u8)
}

thor_color_picker_destroy :: proc(thor: ^Thor) {
    p := &thor.color_picker
    delete(p.hex)
    delete(p.title)
    delete(p.key)
}

thor_color_picker_open :: proc(
    thor: ^Thor,
    title, id: string,
    color: ui.Color,
    preview: Color_Preview_Proc,
    commit: Color_Commit_Proc,
    cancel: Color_Cancel_Proc,
    data: rawptr,
) {
    p := &thor.color_picker

    // Cloned before the old ones are freed: a caller can pass these back.
    heading := strings.clone(title)
    delete(p.title)
    p.title = heading
    key := strings.clone(id)
    delete(p.key)
    p.key = key

    p.preview = preview
    p.commit = commit
    p.cancel = cancel
    p.data = data
    p.original = color
    // Nothing to keep from a previous color, so the state starts neutral and
    // color_picker_set_from_color fills what the conversion can recover.
    p.hue, p.sat, p.val, p.alpha = 0, 0, 0, 1
    color_picker_set_from_color(p, color)
    color_picker_sync_hex(p)

    if !thor.color_picker_open {
        p.return_focus = thor.focus_owner
    }
    p.focus_pending = true
    thor.color_picker_open = true
}

// The HSV state as RGBA: the single conversion out.
thor_color_picker_color :: proc(p: ^Color_Picker) -> ui.Color {
    color := rl.ColorFromHSV(p.hue, p.sat, p.val)
    return {color.r, color.g, color.b, u8(clamp(p.alpha, 0, 1) * 255 + 0.5)}
}

// Takes the HSV the conversion can recover and keeps the rest. A grey color has
// no hue and black has no saturation, so those stay as they were.
@(private = "file")
color_picker_set_from_color :: proc(p: ^Color_Picker, color: ui.Color) {
    hsv := rl.ColorToHSV({color[0], color[1], color[2], color[3]})
    if hsv.y > 0 {
        p.hue = hsv.x
    }
    if hsv.z > 0 {
        p.sat = hsv.y
    }
    p.val = hsv.z
    p.alpha = f32(color[3]) / 255
}

@(private = "file")
color_picker_sync_hex :: proc(p: ^Color_Picker) {
    hex := theme.to_hex(thor_color_picker_color(p), context.temp_allocator)
    clear(&p.hex)
    append(&p.hex, hex)
}

// Takes the typed field as the color. A value that does not parse leaves the
// state alone, so a half-typed hex cannot wipe it.
@(private = "file")
color_picker_commit_hex :: proc(p: ^Color_Picker) -> bool {
    color, ok := theme.parse_hex(string(p.hex[:]))
    if !ok {
        return false
    }
    color_picker_set_from_color(p, color)
    return true
}

@(private = "file")
color_picker_close :: proc(thor: ^Thor) {
    thor.color_picker_open = false
    if thor.color_picker.return_focus != "" {
        thor.focus_request = thor.color_picker.return_focus
    }
}

// Confirms: hands the color to the host, then closes.
@(private = "file")
color_picker_confirm :: proc(thor: ^Thor) {
    p      := &thor.color_picker
    color  := thor_color_picker_color(p)
    commit := p.commit
    data   := p.data
    id     := strings.clone(p.key, context.temp_allocator)
    color_picker_close(thor)
    if commit != nil {
        commit(data, id, color)
    }
}

// Cancels: asks the host to put back what it had, then closes.
@(private = "file")
color_picker_dismiss :: proc(thor: ^Thor) {
    p      := &thor.color_picker
    cancel := p.cancel
    data   := p.data
    id     := strings.clone(p.key, context.temp_allocator)
    color_picker_close(thor)
    if cancel != nil {
        cancel(data, id)
    }
}

@(private = "file")
color_picker_notify :: proc(p: ^Color_Picker) {
    color_picker_sync_hex(p)
    if p.preview != nil {
        p.preview(p.data, p.key, thor_color_picker_color(p))
    }
}

thor_color_picker_view :: proc(thor: ^Thor) {
    if !thor.color_picker_open {
        return
    }

    backdrop := ui.scope(
        {
            key = "picker-backdrop",
            transition = TK_ENTER,
            enter = {opacity = 0},
            flags = {.Floating, .Clickable},
            props = {
                opacity = 1,
                position = .Fixed,
                inset = {0, 0, 0, 0},
                w = ui.Grow(1),
                h = ui.Grow(1),
                dir = .Column,
                justify = .Center,
                align = .Center,
                z = 470,
                bg = tk_scrim(.Card),
            },
        },
    )

    color_picker_box(thor)

    if backdrop.clicked {
        color_picker_dismiss(thor)
        return
    }
    if ui.take_key(.Escape) {
        color_picker_dismiss(thor)
        return
    }
    if ui.take_key(.Enter) || ui.take_key(.Pad_Enter) {
        color_picker_confirm(thor)
    }
}

@(private = "file")
color_picker_box :: proc(thor: ^Thor) {
    p := &thor.color_picker

    ui.scope(
        {
            key = "picker-box",
            transition = TK_ENTER,
            enter = {opacity = 0},
            focus_scope = true,
            flags = {.Clickable},
            props = {
                opacity = 1,
                w = ui.Px(tk(COLOR_PICKER_WIDTH)),
                max_w = ui.viewport().x - 2 * TK_MODAL_MARGIN,
                h = ui.FIT,
                dir = .Column,
                pad = tk_pad_all(.XL),
                gap = tk_gap(.None, .M),
                bg = thor.theme.second_background,
                radius = tk_rad(.Card),
                border = {width = ui.all(1), color = thor.theme.border},
                shadow = tk_shadow(thor, .Card),
            },
        },
    )

    ui.label(p.title, {key = "title", props = {color = thor.theme.foreground, text_wrap = .Ellipsis}})

    color_picker_square(thor)
    color_picker_hue(thor)
    color_picker_alpha(thor)
    color_picker_row(thor)
    color_picker_buttons(thor)
}

// The saturation/value square. A bilinear fill draws it in one node: white and
// the pure hue over black.
@(private = "file")
color_picker_square :: proc(thor: ^Thor) {
    p     := &thor.color_picker
    pure  := rl.ColorFromHSV(p.hue, 1, 1)
    stops := []ui.Stop{{0, ui.Color{255, 255, 255, 255}}, {0, ui.Color{pure.r, pure.g, pure.b, 255}}, {0, ui.Color{0, 0, 0, 255}}, {0, ui.Color{0, 0, 0, 255}}}

    it := ui.scope(
        {
            key = "square",
            flags = {.Clickable, .Draggable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(tk(COLOR_PICKER_SQUARE_H)),
                radius = tk_rad(.Control),
                bg = ui.Gradient{kind = .Bilinear, stops = stops},
                cursor = .Grab,
            },
        },
    )

    if it.rect.w > 0 && it.rect.h > 0 {
        // The marker is painted over the fill, so it stays visible on any hue.
        x := it.rect.x + clamp(p.sat, 0, 1) * it.rect.w
        y := it.rect.y + (1 - clamp(p.val, 0, 1)) * it.rect.h
        ui.paint_rect({x - 5, y - 1, 10, 2}, ui.Color{255, 255, 255, 220}, over = true)
        ui.paint_rect({x - 1, y - 5, 2, 10}, ui.Color{255, 255, 255, 220}, over = true)
    }

    if (it.pressed || it.dragging) && it.rect.w > 0 && it.rect.h > 0 {
        point := ui.mouse_pos()
        p.sat = clamp((point.x - it.rect.x) / it.rect.w, 0, 1)
        p.val = clamp(1 - (point.y - it.rect.y) / it.rect.h, 0, 1)
        color_picker_notify(p)
    }
}

@(private = "file")
color_picker_hue :: proc(thor: ^Thor) {
    p     := &thor.color_picker
    stops := make([]ui.Stop, 7, context.temp_allocator)
    for i in 0 ..< 7 {
        c := rl.ColorFromHSV(f32(i) * 60, 1, 1)
        stops[i] = {f32(i) / 6, ui.Color{c.r, c.g, c.b, 255}}
    }

    it := color_picker_strip(thor, "hue", ui.Gradient{kind = .Linear, stops = stops})
    color_picker_strip_marker(it, clamp(p.hue / 360, 0, 1))
    if (it.pressed || it.dragging) && it.rect.w > 0 {
        p.hue = clamp((ui.mouse_pos().x - it.rect.x) / it.rect.w, 0, 1) * 360
        color_picker_notify(p)
    }
}

@(private = "file")
color_picker_alpha :: proc(thor: ^Thor) {
    p     := &thor.color_picker
    solid := thor_color_picker_color(p)
    stops := []ui.Stop{{0, ui.Color{solid[0], solid[1], solid[2], 0}}, {1, ui.Color{solid[0], solid[1], solid[2], 255}}}

    it := color_picker_strip(thor, "alpha", ui.Gradient{kind = .Linear, stops = stops})
    color_picker_strip_marker(it, clamp(p.alpha, 0, 1))
    if (it.pressed || it.dragging) && it.rect.w > 0 {
        p.alpha = clamp((ui.mouse_pos().x - it.rect.x) / it.rect.w, 0, 1)
        color_picker_notify(p)
    }
}

@(private = "file")
color_picker_strip :: proc(thor: ^Thor, key: string, fill: ui.Paint) -> ui.Interaction {
    return ui.leaf(
        {
            key = key,
            flags = {.Clickable, .Draggable},
            props = {
                w = ui.Grow(1),
                h = ui.Px(tk(COLOR_PICKER_STRIP_H)),
                radius = tk_rad(.Control),
                bg = fill,
                border = {width = ui.all(1), color = thor.theme.border},
                cursor = .Resize_H,
            },
        },
    )
}

@(private = "file")
color_picker_strip_marker :: proc(it: ui.Interaction, t: f32) {
    if it.rect.w <= 0 {
        return
    }
    x := it.rect.x + t * it.rect.w
    ui.paint_rect({x - 1.5, it.rect.y - 2, 3, it.rect.h + 4}, ui.Color{255, 255, 255, 235}, over = true)
}

// The swatch pair and the hex field.
@(private = "file")
color_picker_row :: proc(thor: ^Thor) {
    p := &thor.color_picker

    ui.scope({key = "row", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, align = .Center, gap = tk_gap(.M, .None)}})

    ui.leaf(
        {
            key = "was",
            props = {
                w = ui.Px(tk_w(.Swatch_Large)),
                h = ui.Px(tk_h(.Row)),
                radius = tk_rad(.Control),
                bg = p.original,
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
    )
    ui.leaf(
        {
            key = "now",
            props = {
                w = ui.Px(tk_w(.Swatch_Large)),
                h = ui.Px(tk_h(.Row)),
                radius = tk_rad(.Control),
                bg = thor_color_picker_color(p),
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
    )

    it := ui.input(
        &p.hex,
        {
            key = "hex",
            props = {
                w = ui.Grow(1),
                bg = thor.theme.background,
                color = thor.theme.foreground,
                radius = tk_rad(.Control),
                border = {width = ui.all(1), color = thor.theme.border},
            },
        },
        "#RRGGBBAA",
    )
    if p.focus_pending {
        ui.set_focus(it.id)
        p.focus_pending = false
    }
    if it.changed {
        if color_picker_commit_hex(p) && p.preview != nil {
            p.preview(p.data, p.key, thor_color_picker_color(p))
        }
    }
}

@(private = "file")
color_picker_buttons :: proc(thor: ^Thor) {
    ui.scope({key = "buttons", props = {w = ui.Grow(1), h = ui.FIT, dir = .Row, justify = .End, gap = tk_gap(.M, .None), margin = {t = tk_sp(.XS)}}})

    if color_picker_button(thor, "cancel", "Cancel", thor.theme.muted_color) {
        color_picker_dismiss(thor)
        return
    }
    if color_picker_button(thor, "ok", "OK", thor.theme.accent_color) {
        color_picker_confirm(thor)
    }
}

@(private = "file")
color_picker_button :: proc(thor: ^Thor, key, label: string, color: ui.Color) -> bool {
    it := ui.scope(
        thor_control(
            thor,
            {
                key = key,
                flags = {.Clickable},
                props = {
                    w = ui.Px(tk(80)),
                    h = ui.Px(tk_h(.Row_Picker)),
                    dir = .Row,
                    justify = .Center,
                    align = .Center,
                    radius = tk_rad(.Popup),
                    bg = thor.theme.buttons,
                    border = {width = ui.all(1), color = color},
                    cursor = .Pointer,
                },
                hover = {bg = thor.theme.active},
            },
        ),
    )
    ui.label(label, {key = "text", props = {color = color, text_wrap = .None}})
    return it.clicked
}
