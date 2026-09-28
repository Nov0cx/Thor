// The image view: a loaded texture centred in the workspace area, fit to the
// pane and zoomable. The texture is borrowed from the open file.
package thor

import "core:fmt"

import "../render"
import ui "../vendor/loom/loom"

@(private = "file")
ZOOM_STEP :: f32(1.1)

@(private = "file")
ZOOM_MIN :: f32(0.05)

@(private = "file")
ZOOM_MAX :: f32(40)

@(private = "file")
CHECKER_SIZE :: f32(16)

@(private = "file")
INFO_PAD :: f32(10)

// User zoom on top of the fit-to-view base scale, and the pan offset of the
// image centre from the pane centre. Reset when the file changes.
Image_View :: struct {
    file:   ^Open_File, // borrowed, the identity the zoom belongs to
    zoom:   f32,
    offset: ui.Vec2,
}

// Points the view at a file, resetting zoom and pan so a freshly opened image
// comes up fit and centred.
@(private = "file")
thor_image_view_bind :: proc(view: ^Image_View, file: ^Open_File) {
    if view.file == file && view.zoom > 0 {
        return
    }
    view.file = file
    view.zoom = 1
    view.offset = {}
}

// Scale that fits the image inside the pane without upscaling past 1:1.
@(private = "file")
thor_image_base_scale :: proc(file: ^Open_File, pane: ui.Rect) -> f32 {
    if file.texture.width == 0 || file.texture.height == 0 {
        return 1
    }
    fit := min(
        pane.w / f32(file.texture.width),
        pane.h / f32(file.texture.height),
    )
    return min(fit, 1)
}

// One pane of the editor column, in the slot the file's tab owns.
thor_image_view :: proc(thor: ^Thor, view: ^Image_View, file: ^Open_File, key: string) {
    thor_image_view_bind(view, file)

    pane := ui.begin(
        {
            key = key,
            flags = {.Clip, .Clickable, .Draggable, .Wheel},
            // Relative, so it is the containing block of the overlays: Loom
            // resolves an absolute inset against the nearest positioned
            // ancestor, which would otherwise be the window.
            props = {
                position = .Relative,
                w = ui.Grow(1),
                h = ui.Grow(1),
                bg = thor.theme.background,
                cursor = .Grab,
            },
        },
    )
    defer ui.end()

    thor_image_input(view, pane)

    if pane.rect.w <= 0 || pane.rect.h <= 0 {
        return
    }

    scale := thor_image_base_scale(file, pane.rect) * view.zoom
    w := f32(file.texture.width) * scale
    h := f32(file.texture.height) * scale
    // Node-local, which is what paint_rect and an absolute child both take.
    dest := ui.Rect {
        x = (pane.rect.w - w) * 0.5 + view.offset.x,
        y = (pane.rect.h - h) * 0.5 + view.offset.y,
        w = w,
        h = h,
    }

    thor_image_checker(thor, dest, {0, 0, pane.rect.w, pane.rect.h})
    ui.image(
        render.register_texture(&thor.backend, file.texture),
        {
            key = "pixels",
            props = {
                position = .Absolute,
                inset = {l = dest.x, t = dest.y},
                w = ui.Px(dest.w),
                h = ui.Px(dest.h),
            },
        },
    )
    thor_image_info(thor, file, scale)
}

// Zoom toward the cursor keeps the pixel under it fixed as the scale grows.
@(private = "file")
thor_image_input :: proc(view: ^Image_View, pane: ui.Interaction) {
    if pane.dragging {
        view.offset += pane.drag_delta
    }
    if pane.wheel.y == 0 {
        return
    }
    // Loom counts a wheel notch down as positive.
    factor := pane.wheel.y < 0 ? ZOOM_STEP : 1 / ZOOM_STEP
    zoom := clamp(view.zoom * factor, ZOOM_MIN, ZOOM_MAX)
    if zoom == view.zoom {
        return
    }
    ratio := zoom / view.zoom
    centre := ui.Vec2{pane.rect.x + pane.rect.w * 0.5, pane.rect.y + pane.rect.h * 0.5}
    pivot := ui.mouse_pos()
    view.offset.x = pivot.x - (pivot.x - (centre.x + view.offset.x)) * ratio - centre.x
    view.offset.y = pivot.y - (pivot.y - (centre.y + view.offset.y)) * ratio - centre.y
    view.zoom = zoom
}

// Checkerboard behind the image, so a transparent pixel reads as transparent
// and not as the flat background. Only the cells the pane shows are painted;
// the indices stay absolute to `dest`, so the pattern keeps its phase on a pan.
@(private = "file")
thor_image_checker :: proc(thor: ^Thor, dest, pane: ui.Rect) {
    cols := int(dest.w / CHECKER_SIZE) + 1
    rows := int(dest.h / CHECKER_SIZE) + 1
    first_col := clamp(int((pane.x - dest.x) / CHECKER_SIZE), 0, cols)
    first_row := clamp(int((pane.y - dest.y) / CHECKER_SIZE), 0, rows)
    last_col := clamp(int((pane.x + pane.w - dest.x) / CHECKER_SIZE) + 1, first_col, cols)
    last_row := clamp(int((pane.y + pane.h - dest.y) / CHECKER_SIZE) + 1, first_row, rows)
    for row in first_row ..< last_row {
        for col in first_col ..< last_col {
            color := (row + col) % 2 == 0 ? thor.theme.highlight : thor.theme.contrast
            x := dest.x + f32(col) * CHECKER_SIZE
            y := dest.y + f32(row) * CHECKER_SIZE
            ui.paint_rect(
                {x, y, min(CHECKER_SIZE, dest.x + dest.w - x), min(CHECKER_SIZE, dest.y + dest.h - y)},
                color,
            )
        }
    }
}

// Bottom-left overlay: file name, pixel dimensions and the zoom percent.
@(private = "file")
thor_image_info :: proc(thor: ^Thor, file: ^Open_File, scale: f32) {
    text := fmt.tprintf(
        "%s   %dx%d   %d%%",
        file.name,
        file.texture.width,
        file.texture.height,
        int(scale * 100 + 0.5),
    )
    ui.label(
        text,
        {
            key = "image-info",
            props = {
                position = .Absolute,
                inset = {l = INFO_PAD, b = INFO_PAD},
                color = thor.theme.foreground,
                font_size = f32(thor.config.general.font_size),
            },
        },
    )
}
