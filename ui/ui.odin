package ui

import rl "vendor:raylib"

Axis :: enum {
    Horizontal,
    Vertical,
}

Padding :: struct {
    left:   f32,
    top:    f32,
    right:  f32,
    bottom: f32,
}

padding :: proc(value: f32) -> Padding {
    return Padding {
        left   = value,
        top    = value,
        right  = value,
        bottom = value,
    }
}

padding_xy :: proc(horizontal, vertical: f32) -> Padding {
    return Padding {
        left   = horizontal,
        top    = vertical,
        right  = horizontal,
        bottom = vertical,
    }
}

shrink_rectangle :: proc(rect: rl.Rectangle, inset: Padding) -> rl.Rectangle {
    width := rect.width - inset.left - inset.right
    height := rect.height - inset.top - inset.bottom

    if width < 0 {
        width = 0
    }
    if height < 0 {
        height = 0
    }

    return rl.Rectangle {
        x = rect.x + inset.left,
        y = rect.y + inset.top,
        width = width,
        height = height,
    }
}

begin_clip :: proc(rect: rl.Rectangle) {
    width := cast(i32) rect.width
    height := cast(i32) rect.height
    if width <= 0 || height <= 0 {
        return
    }

    rl.BeginScissorMode(
        cast(i32) rect.x,
        cast(i32) rect.y,
        width,
        height,
    )
}

end_clip :: proc() {
    rl.EndScissorMode()
}
