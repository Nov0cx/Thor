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

// App-level shortcuts, dispatched before widget focus (see
// ui.context_set_global_key): they work no matter what is focused.
thor_global_key :: proc(data: rawptr, event: ^ui.Event) -> bool {
    thor := cast(^Thor) data
    if !event.ctrl || event.alt {
        return false
    }

    #partial switch event.key {
    case .W:
        thor_close_file(thor, ui.signal_get(&thor.active_file))
        return true
    case .PAGE_DOWN:
        thor_cycle_tab(thor, 1)
        return true
    case .PAGE_UP:
        thor_cycle_tab(thor, -1)
        return true
    case .B:
        thor_toggle_explorer(thor, nil, nil)
        return true
    case .J:
        thor_toggle_console(thor, nil, nil)
        return true
    }
    return false
}

thor_cycle_tab :: proc(thor: ^Thor, direction: int) {
    count := len(thor.open_files)
    if count == 0 {
        return
    }
    active := ui.signal_get(&thor.active_file)
    thor_set_active_file(thor, ((active + direction) % count + count) % count)
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
