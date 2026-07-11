package thor

import rl "vendor:raylib"

import "../ui"

thor_minimize_window :: proc(_: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    rl.MinimizeWindow()
}

thor_toggle_maximize :: proc(_: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    if rl.IsWindowMaximized() {
        rl.RestoreWindow()
    } else {
        rl.MaximizeWindow()
    }
}

thor_close_window :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    thor.should_close = true
}

thor_toggle_explorer :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    ui.signal_set(&thor.explorer_visible, !ui.signal_get(&thor.explorer_visible))
    thor_apply_layout_state(thor)
}

thor_toggle_console :: proc(data: rawptr, _: ^ui.Context, _: ^ui.Widget) {
    thor := cast(^Thor) data
    ui.signal_set(&thor.console_visible, !ui.signal_get(&thor.console_visible))
    thor_apply_layout_state(thor)
}

thor_resize_explorer :: proc(data: rawptr, delta: f32) {
    thor := cast(^Thor) data
    thor.explorer_width += delta
    if thor.explorer_width < 160 {
        thor.explorer_width = 160
    }
    if thor.explorer_width > 520 {
        thor.explorer_width = 520
    }
    thor_apply_layout_state(thor)
}

thor_resize_console :: proc(data: rawptr, delta: f32) {
    thor := cast(^Thor) data
    thor.console_height -= delta
    if thor.console_height < 120 {
        thor.console_height = 120
    }
    if thor.console_height > 420 {
        thor.console_height = 420
    }
    thor_apply_layout_state(thor)
}
