package widgets

import rl "vendor:raylib"

import "../ui"

// Draws a borrowed texture fit to the widget height, left-aligned. Used for the
// titlebar mark. The texture is owned by the host (unloaded at shutdown), not
// here, and no events are handled so the titlebar stays draggable over it.
Logo :: struct {
    using widget: ui.Widget,
    texture:      rl.Texture2D,
    padding:      ui.Padding,
}

logo_vtable := ui.Widget_VTable {
    layout = logo_layout,
    draw = logo_draw,
    destroy = logo_destroy,
}

logo_create :: proc(id: string) -> ^Logo {
    logo := new(Logo)
    ui.widget_init(&logo.widget, id, logo_vtable)
    logo.padding = ui.padding_xy(4, 6)
    logo.min_size = rl.Vector2 {36, 28}
    return logo
}

logo_set_texture :: proc(logo: ^Logo, texture: rl.Texture2D) -> ^Logo {
    logo.texture = texture
    return logo
}

logo_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    logo := cast(^Logo) widget
    logo.bounds = bounds
}

logo_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    logo := cast(^Logo) widget
    if logo.texture.id == 0 || logo.texture.width == 0 || logo.texture.height == 0 {
        return
    }

    avail_h := logo.bounds.height - logo.padding.top - logo.padding.bottom
    scale := avail_h / cast(f32) logo.texture.height
    draw_w := cast(f32) logo.texture.width * scale
    draw_h := avail_h
    dest := rl.Rectangle {
        x = logo.bounds.x + logo.padding.left,
        y = logo.bounds.y + (logo.bounds.height - draw_h) * 0.5,
        width = draw_w,
        height = draw_h,
    }
    source := rl.Rectangle {0, 0, cast(f32) logo.texture.width, cast(f32) logo.texture.height}
    rl.DrawTexturePro(logo.texture, source, dest, rl.Vector2 {0, 0}, 0, rl.WHITE)
}

logo_destroy :: proc(widget: ^ui.Widget) {
    // The texture is owned by the host, not the logo.
    free(cast(^Logo) widget)
}
