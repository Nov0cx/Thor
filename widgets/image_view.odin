package widgets

import "core:fmt"
import rl "vendor:raylib"

import "../ui"

// Shows a loaded image texture centered in the pane, fit to the view and
// scalable. The texture is borrowed from the open file, not owned here.
Image_View :: struct {
    using widget:     ui.Widget,
    texture:          rl.Texture2D,
    label:            string, // borrowed file name, drawn in the info overlay
    // User zoom on top of the fit-to-view base scale, and the pan offset of the
    // image center from the view center. Reset when the texture changes.
    zoom:             f32,
    offset:           rl.Vector2,
    dragging:         bool,
    font_size:        i32,
    background_color: rl.Color,
    checker_a:        rl.Color,
    checker_b:        rl.Color,
    text_color:       rl.Color,
}

ZOOM_STEP :: f32(1.1)
ZOOM_MIN :: f32(0.05)
ZOOM_MAX :: f32(40)
CHECKER_SIZE :: f32(16)

image_view_vtable := ui.Widget_VTable {
    layout = image_view_layout,
    handle_event = image_view_handle_event,
    draw = image_view_draw,
    destroy = image_view_destroy,
}

image_view_create :: proc(id: string) -> ^Image_View {
    view := new(Image_View)
    ui.widget_init(&view.widget, id, image_view_vtable)
    view.zoom = 1
    view.font_size = 15
    view.background_color = rl.Color {15, 17, 26, 255}
    view.checker_a = rl.Color {40, 43, 54, 255}
    view.checker_b = rl.Color {28, 30, 40, 255}
    view.text_color = rl.Color {238, 255, 255, 255}
    return view
}

image_view_set_colors :: proc(view: ^Image_View, background, checker_a, checker_b, text_color: rl.Color) {
    view.background_color = background
    view.checker_a = checker_a
    view.checker_b = checker_b
    view.text_color = text_color
}

// Points the view at a texture (zero-value clears it). Resets zoom and pan so a
// freshly opened image comes up fit and centered.
image_view_set_texture :: proc(view: ^Image_View, texture: rl.Texture2D, label: string) {
    if view.texture.id == texture.id && view.label == label {
        return
    }
    view.texture = texture
    view.label = label
    view.zoom = 1
    view.offset = {0, 0}
    view.dragging = false
}

image_view_layout :: proc(widget: ^ui.Widget, bounds: rl.Rectangle) {
    view := cast(^Image_View) widget
    view.bounds = bounds
}

// Scale that fits the image inside the view without upscaling past 1:1.
@(private = "file")
image_view_base_scale :: proc(view: ^Image_View) -> f32 {
    if view.texture.width == 0 || view.texture.height == 0 {
        return 1
    }
    fit := min(
        view.bounds.width / cast(f32) view.texture.width,
        view.bounds.height / cast(f32) view.texture.height,
    )
    return min(fit, 1)
}

image_view_handle_event :: proc(widget: ^ui.Widget, _: ^ui.Context, event: ^ui.Event) -> bool {
    view := cast(^Image_View) widget
    if view.texture.id == 0 {
        return false
    }

    #partial switch event.kind {
    case .Scroll:
        // Zoom toward the cursor: keep the pixel under it fixed as the scale grows.
        factor := event.wheel_delta > 0 ? ZOOM_STEP : 1 / ZOOM_STEP
        new_zoom := clamp(view.zoom * factor, ZOOM_MIN, ZOOM_MAX)
        ratio := new_zoom / view.zoom
        center := rl.Vector2 {
            view.bounds.x + view.bounds.width * 0.5,
            view.bounds.y + view.bounds.height * 0.5,
        }
        pivot := event.mouse_position
        view.offset.x = pivot.x - (pivot.x - (center.x + view.offset.x)) * ratio - center.x
        view.offset.y = pivot.y - (pivot.y - (center.y + view.offset.y)) * ratio - center.y
        view.zoom = new_zoom
        return true
    case .Mouse_Down:
        if event.mouse_button == .LEFT {
            view.dragging = true
            return true
        }
    case .Mouse_Move:
        if view.dragging {
            view.offset.x += event.mouse_delta.x
            view.offset.y += event.mouse_delta.y
            return true
        }
    case .Mouse_Up:
        view.dragging = false
    case:
    }
    return false
}

image_view_draw :: proc(widget: ^ui.Widget, _: ^ui.Context) {
    view := cast(^Image_View) widget
    rl.DrawRectangleRec(view.bounds, view.background_color)

    if view.texture.id == 0 {
        return
    }

    scale := image_view_base_scale(view) * view.zoom
    draw_w := cast(f32) view.texture.width * scale
    draw_h := cast(f32) view.texture.height * scale
    dest := rl.Rectangle {
        x = view.bounds.x + (view.bounds.width - draw_w) * 0.5 + view.offset.x,
        y = view.bounds.y + (view.bounds.height - draw_h) * 0.5 + view.offset.y,
        width = draw_w,
        height = draw_h,
    }

    ui.begin_clip(view.bounds)
    image_view_draw_checker(view, dest)
    source := rl.Rectangle {0, 0, cast(f32) view.texture.width, cast(f32) view.texture.height}
    rl.DrawTexturePro(view.texture, source, dest, rl.Vector2 {0, 0}, 0, rl.WHITE)
    ui.end_clip()

    image_view_draw_info(view, scale)
}

// Checkerboard behind the image so transparent pixels read as transparent
// rather than blending into the flat background.
@(private = "file")
image_view_draw_checker :: proc(view: ^Image_View, dest: rl.Rectangle) {
    cols := cast(int) (dest.width / CHECKER_SIZE) + 1
    rows := cast(int) (dest.height / CHECKER_SIZE) + 1
    for row in 0 ..< rows {
        for col in 0 ..< cols {
            color := (row + col) % 2 == 0 ? view.checker_a : view.checker_b
            cell := rl.Rectangle {
                x = dest.x + cast(f32) col * CHECKER_SIZE,
                y = dest.y + cast(f32) row * CHECKER_SIZE,
                width = min(CHECKER_SIZE, dest.x + dest.width - (dest.x + cast(f32) col * CHECKER_SIZE)),
                height = min(CHECKER_SIZE, dest.y + dest.height - (dest.y + cast(f32) row * CHECKER_SIZE)),
            }
            rl.DrawRectangleRec(cell, color)
        }
    }
}

// Bottom-left overlay: file name, pixel dimensions, and current zoom percent.
@(private = "file")
image_view_draw_info :: proc(view: ^Image_View, scale: f32) {
    text := fmt.tprintf("%s   %dx%d   %d%%", view.label, view.texture.width, view.texture.height, cast(int) (scale * 100 + 0.5))
    pad := i32(10)
    y := cast(i32) (view.bounds.y + view.bounds.height) - view.font_size - pad
    ui.draw_text(text, cast(i32) view.bounds.x + pad, y, view.font_size, view.text_color)
}

image_view_destroy :: proc(widget: ^ui.Widget) {
    // The texture is owned by the open file, not the view.
    free(cast(^Image_View) widget)
}
